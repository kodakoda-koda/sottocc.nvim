-- Turns stream-json events into buffer lines.
--
-- Claude Code's own TUI draws with glyphs and foreground colour only: no
-- background fills, no borders. We mirror that vocabulary.
--
-- Blocks are tracked by extmark, not by line number: a tool_result can land
-- in the middle of a later tool_use's deltas, so "append at the end" is wrong.

local Config = require("sottocc.config")
local Window = require("sottocc.window")

local M = {}

local NS = vim.api.nvim_create_namespace("sottocc.blocks")

-- block key -> { mark_id, kind }
M.blocks = {}

local GLYPH = {
  agent = "⏺",
  user = ">",
  result = "  ⎿  ",
}

function M.reset()
  M.blocks = {}
  Window.with_output(function(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end)
end

---Append lines at the end of the output buffer.
---@param lines string[]
---@param hl string? line highlight applied to every appended line
---@param spans table[]? per-line extras: { row, line_hl } or { row, col, end_col, hl }
---@return integer start_row 0-indexed row of the first appended line
local function append(lines, hl, spans)
  local start_row
  Window.with_output(function(buf)
    local count = vim.api.nvim_buf_line_count(buf)
    -- An untouched scratch buffer still reports one empty line.
    if count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
      count = 0
    end
    start_row = count
    vim.api.nvim_buf_set_lines(buf, count, -1, false, lines)
    if hl then
      for i = 0, #lines - 1 do
        vim.api.nvim_buf_set_extmark(buf, NS, count + i, 0, { line_hl_group = hl })
      end
    end
    for _, sp in ipairs(spans or {}) do
      local opts = sp.line_hl and { line_hl_group = sp.line_hl }
          or { end_col = sp.end_col, hl_group = sp.hl }
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, count + sp.row, sp.col or 0, opts)
    end
  end)
  Window.follow()
  return start_row or 0
end

M.append = append

---Remember where a block starts so later deltas can find it.
---@param key string
---@param row integer
local function mark(key, row)
  Window.with_output(function(buf)
    M.blocks[key] = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {})
  end)
end

---@param key string
---@return integer? row
local function row_of(key)
  local id = M.blocks[key]
  if not id then return nil end
  local buf = Window.output_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, NS, id, {})
  return pos and pos[1] or nil
end

---Collapse a value to something that fits on one line.
---@param v string
---@return string
local function one_line(v)
  local first = vim.split(v, "\n", { plain = true })[1] or ""
  first = first:gsub("%s+", " ")
  if #first > 120 then first = first:sub(1, 117) .. "…" end
  return first
end

---Replace the single line a block owns.
---@param key string
---@param text string
---@param hl string?
local function replace_line(key, text, hl)
  text = one_line(text)
  local row = row_of(key)
  if not row then return end
  Window.with_output(function(buf)
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { text })
    -- set_lines can drift the anchor; pin it back to this exact row.
    M.blocks[key] = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {})
    if hl then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { line_hl_group = hl })
    end
  end)
end

---The prompt the user just submitted.
---@param text string
function M.user_message(text)
  local lines = { "" }
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, ("%s %s"):format(GLYPH.user, l))
  end
  append(lines, "SottoccUser")
end

---Agent prose, with fenced blocks and inline spans picked out.
---Markdown is highlighted by hand rather than by setting the buffer's
---filetype: the buffer also holds tool headers and raw output, which a
---markdown parser would happily mangle.
---@param text string
function M.agent_text(text)
  local lines, spans, in_fence = { "" }, {}, false

  for i, l in ipairs(vim.split(text, "\n", { plain = true })) do
    local body = i == 1 and ("%s %s"):format(GLYPH.agent, l) or ("  " .. l)
    table.insert(lines, body)
    local row = #lines - 1 -- 0-indexed offset within this append

    if l:match("^%s*```") then
      in_fence = not in_fence
      table.insert(spans, { row = row, line_hl = "SottoccFence" })
    elseif in_fence then
      table.insert(spans, { row = row, line_hl = "SottoccCode" })
    else
      -- Inline `code`: mark the span including its backticks.
      local from = 1
      while true do
        local a, b = body:find("`[^`]+`", from)
        if not a then break end
        table.insert(spans, { row = row, col = a - 1, end_col = b, hl = "SottoccCode" })
        from = b + 1
      end
    end
  end

  append(lines, nil, spans)
end

---A tool call whose arguments are not known yet.
---@param id string
---@param name string
function M.tool_start(id, name)
  local row = append({ "", one_line(("%s %s"):format(GLYPH.agent, name)) })
  mark("tool:" .. id, row + 1)
end

---Fill in the summary once the assistant message confirms the arguments.
---@param id string
---@param name string
---@param input table
function M.tool_confirm(id, name, input)
  local summary = input.file_path or input.command or input.pattern
      or input.path or input.query or input.description
  local text = summary and ("%s %s(%s)"):format(GLYPH.agent, name, one_line(tostring(summary)))
      or ("%s %s"):format(GLYPH.agent, name)
  replace_line("tool:" .. id, text)
end

---@param id string
---@param content string
---@param is_error boolean?
function M.tool_result(id, content, is_error)
  local row = row_of("tool:" .. id)
  local max = Config.options.max_tool_result_lines
  local raw = vim.split(content or "", "\n", { plain = true })
  local lines = {}
  for i = 1, math.min(#raw, max) do
    table.insert(lines, (i == 1 and GLYPH.result or "     ") .. raw[i])
  end
  if #raw > max then
    table.insert(lines, ("     … +%d lines"):format(#raw - max))
  end
  if #lines == 0 then lines = { GLYPH.result .. "(no output)" } end

  local hl = is_error and "SottoccError" or "SottoccResult"
  if not row then
    append(lines, hl)
    return
  end
  -- Insert directly beneath the owning tool line, wherever it now sits.
  Window.with_output(function(buf)
    vim.api.nvim_buf_set_lines(buf, row + 1, row + 1, false, lines)
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_set_extmark(buf, NS, row + 1 + i, 0, { line_hl_group = hl })
    end
  end)
  Window.follow()
end

---@param text string
function M.notice(text)
  append({ "", "  " .. text }, "SottoccResult")
end

---@param text string
function M.error(text)
  vim.notify("sottocc: " .. text, vim.log.levels.ERROR)
  append({ "", "  " .. text }, "SottoccError")
end

function M.setup_highlights()
  local function link(name, target)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
  end
  link("SottoccUser", "Title")
  link("SottoccResult", "Comment")
  link("SottoccError", "DiagnosticError")
  link("SottoccCode", "@markup.raw")
  link("SottoccFence", "Comment")
end

return M
