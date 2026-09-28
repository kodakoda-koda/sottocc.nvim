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
-- tool_use_id -> the file the call names, for opening it from the tool line.
M.targets = {}

local GLYPH = {
  agent = "⏺",
  user = ">",
  result = "  ⎿  ",
}

function M.reset()
  M.blocks = {}
  M.targets = {}
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
    if count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then count = 0 end
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
  -- Only the first line, and no tabs: runs of spaces are left alone, since
  -- the indent and the two spaces after ⎿ are what the fold rule reads.
  local first = vim.split(v, "\n", { plain = true })[1] or ""
  first = first:gsub("\t", " "):gsub("%s+$", "")
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
    -- The text only, not the line: replacing the line that opens a fold
    -- makes Neovim end the fold a line early.
    local old = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    vim.api.nvim_buf_set_text(buf, row, 0, row, #old, { text })
    -- The anchor may have moved with the text; pin it back to column 0.
    M.blocks[key] = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {})
    if hl then vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { line_hl_group = hl }) end
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

---A `|---|:--:|` rule, which is what turns the line above it into a header.
---@param l string
---@return boolean
local function is_rule(l)
  return l:match("^[%s|:%-]+$") ~= nil and l:find("%-") ~= nil and l:find("|") ~= nil
end

---@param l string
---@return string[]
local function split_row(l)
  local s = vim.trim(l):gsub("^|", ""):gsub("|%s*$", "")
  local cells = {}
  for c in (s .. "|"):gmatch("([^|]*)|") do
    table.insert(cells, vim.trim(c))
  end
  return cells
end

---@param cells string[]
---@return string[]
local function aligns_of(cells)
  local out = {}
  for i, c in ipairs(cells) do
    local left, right = c:sub(1, 1) == ":", c:sub(-1) == ":"
    out[i] = (left and right) and "center" or (right and "right") or "left"
  end
  return out
end

---Pad to a display width, so CJK and emoji keep the columns straight.
---@param s string
---@param w integer
---@param align string
---@return string
local function pad(s, w, align)
  local space = math.max(0, w - vim.fn.strdisplaywidth(s))
  if align == "right" then return (" "):rep(space) .. s end
  if align == "center" then
    local l = math.floor(space / 2)
    return (" "):rep(l) .. s .. (" "):rep(space - l)
  end
  return s .. (" "):rep(space)
end

---@param head string[]
---@param aligns string[]
---@param body string[][]
---@return string[]
local function draw_table(head, aligns, body)
  local ncol = #head
  for _, r in ipairs(body) do
    ncol = math.max(ncol, #r)
  end

  local w = {}
  local function measure(r)
    for i = 1, ncol do
      local d = vim.fn.strdisplaywidth(r[i] or "")
      if d > (w[i] or 0) then w[i] = d end
    end
  end
  measure(head)
  for _, r in ipairs(body) do
    measure(r)
  end

  local function rule(left, mid, right)
    local parts = {}
    for i = 1, ncol do
      table.insert(parts, ("─"):rep(w[i] + 2))
    end
    return left .. table.concat(parts, mid) .. right
  end
  local function row(cells)
    local parts = {}
    for i = 1, ncol do
      table.insert(parts, " " .. pad(cells[i] or "", w[i], aligns[i] or "left") .. " ")
    end
    return "│" .. table.concat(parts, "│") .. "│"
  end

  local out = { rule("┌", "┬", "┐"), row(head), rule("├", "┼", "┤") }
  for _, r in ipairs(body) do
    table.insert(out, row(r))
  end
  table.insert(out, rule("└", "┴", "┘"))
  return out
end

---Replace every markdown table with an aligned, box-drawn one.
---Pipes alone do not line up once the cells hold text of different widths,
---which is why the CLI draws borders too.
---@param lines string[]
---@return string[]
local function expand_tables(lines)
  local out, i, in_fence = {}, 1, false
  while i <= #lines do
    local l = lines[i]
    if l:match("^%s*```") then in_fence = not in_fence end

    local next_line = lines[i + 1]
    if not in_fence and l:find("|") and next_line and is_rule(next_line) then
      local head = split_row(l)
      local aligns = aligns_of(split_row(next_line))
      local body, j = {}, i + 2
      while j <= #lines and lines[j]:find("|") and vim.trim(lines[j]) ~= "" do
        table.insert(body, split_row(lines[j]))
        j = j + 1
      end
      vim.list_extend(out, draw_table(head, aligns, body))
      i = j
    else
      table.insert(out, l)
      i = i + 1
    end
  end
  return out
end

---Agent prose, with fenced blocks and inline spans picked out.
---Markdown is highlighted by hand rather than by setting the buffer's
---filetype: the buffer also holds tool headers and raw output, which a
---markdown parser would happily mangle.
---@param text string
function M.agent_text(text)
  local lines, spans, in_fence = { "" }, {}, false

  for i, l in ipairs(expand_tables(vim.split(text, "\n", { plain = true }))) do
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

---What to put in the parentheses after a tool's name. A path is shown
---relative to the working directory, as the CLI shows it.
---@param input table
---@return string?
local function describe(input)
  local path = input.file_path or input.path
  if type(path) == "string" and path ~= "" then return vim.fn.fnamemodify(path, ":.") end
  local v = input.command or input.pattern or input.query or input.description
  return v and tostring(v) or nil
end

---Where a tool call points: the file, and the line it read from or the text
---an edit put there.
---@param input table
---@return { path: string, line: integer?, find: string? }?
local function target(input)
  local path = input.file_path or input.notebook_path or input.path
  if type(path) ~= "string" or path == "" then return nil end
  local new = type(input.new_string) == "string" and input.new_string or nil
  return {
    path = vim.fn.fnamemodify(path, ":p"),
    line = tonumber(input.offset),
    find = new and vim.split(new, "\n", { plain = true })[1] or nil,
  }
end

---The target of the tool call whose line is at `row`.
---@param row integer 0-indexed
---@return { path: string, line: integer?, find: string? }?
function M.target_at(row)
  for id, t in pairs(M.targets) do
    if row_of("tool:" .. id) == row then return t end
  end
  return nil
end

---A tool call whose arguments are not known yet.
---@param id string
---@param name string
function M.tool_start(id, name)
  local row = append({ "", one_line(("%s %s"):format(GLYPH.agent, name)) })
  mark("tool:" .. id, row + 1)
end

---Fill in the summary once the assistant message confirms the arguments.
---
---A subagent's own tool calls never appear as partial stream events, only as
---finished assistant messages, so there may be no line to fill in yet.
---@param id string
---@param name string
---@param input table
function M.tool_confirm(id, name, input)
  M.targets[id] = target(input)
  local summary = describe(input)
  local text = summary and ("%s %s(%s)"):format(GLYPH.agent, name, one_line(summary))
    or ("%s %s"):format(GLYPH.agent, name)
  if M.blocks["tool:" .. id] then
    replace_line("tool:" .. id, text)
  else
    mark("tool:" .. id, append({ "", one_line(text) }) + 1)
  end
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
  if #raw > max then table.insert(lines, ("     … +%d lines"):format(#raw - max)) end
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

-- A subagent's steps are indented far enough to count as continuation lines
-- of its ⎿ summary, so the whole delegation folds away behind one line, the
-- way the CLI hides it behind "Done (…)".
local NEST = "     "

---Insert lines just after the block `key` owns, then move its anchor to the
---last of them, so the next insertion lands below.
---@param key string
---@param lines string[]
local function insert_after(key, lines)
  if #lines == 0 then return end
  local row = row_of(key)
  if not row then return end
  Window.with_output(function(buf)
    vim.api.nvim_buf_set_lines(buf, row + 1, row + 1, false, lines)
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_set_extmark(buf, NS, row + 1 + i, 0, { line_hl_group = "SottoccResult" })
    end
    M.blocks[key] = vim.api.nvim_buf_set_extmark(buf, NS, row + #lines, 0, {})
  end)
  Window.follow()
end

---Open a delegation: the ⎿ line that its steps will hang under.
---@param id string
function M.agent_open(id)
  local row = row_of("tool:" .. id)
  if not row then return end
  Window.with_output(function(buf)
    vim.api.nvim_buf_set_lines(buf, row + 1, row + 1, false, { GLYPH.result .. "running…" })
    vim.api.nvim_buf_set_extmark(buf, NS, row + 1, 0, { line_hl_group = "SottoccResult" })
    M.blocks["res:" .. id] = vim.api.nvim_buf_set_extmark(buf, NS, row + 1, 0, {})
    M.blocks["end:" .. id] = vim.api.nvim_buf_set_extmark(buf, NS, row + 1, 0, {})
  end)
  Window.follow()
end

---@param parent string
---@param name string
---@param input table
function M.nested_tool(parent, name, input)
  local summary = describe(input)
  local text = summary and ("%s %s(%s)"):format(GLYPH.agent, name, one_line(summary))
    or ("%s %s"):format(GLYPH.agent, name)
  insert_after("end:" .. parent, { NEST .. one_line(text) })
end

---@param parent string
---@param text string
function M.nested_text(parent, text)
  local lines = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, NEST .. l)
  end
  insert_after("end:" .. parent, lines)
end

---@param parent string
---@param content string
function M.nested_result(parent, content)
  local max = Config.options.max_tool_result_lines
  local raw = vim.split(content or "", "\n", { plain = true })
  local lines = {}
  for i = 1, math.min(#raw, max) do
    table.insert(lines, NEST .. (i == 1 and "⎿  " or "   ") .. raw[i])
  end
  if #raw > max then table.insert(lines, NEST .. ("   … +%d lines"):format(#raw - max)) end
  if #lines == 0 then lines = { NEST .. "⎿  (no output)" } end
  insert_after("end:" .. parent, lines)
end

---@param n integer
---@return string
local function fmt_tokens(n)
  if n >= 1000 then return ("%.1fk tokens"):format(n / 1000) end
  return ("%d tokens"):format(n)
end

---Close a delegation: the ⎿ line becomes the CLI's "Done (…)" summary, and
---the hand-back report goes inside the fold rather than on screen.
---@param id string
---@param content string
---@param status string? how a background agent ended, when not completed
function M.agent_done(id, content, status)
  content = content or ""
  local uses = content:match("tool_uses:%s*(%d+)")
  local tokens = content:match("subagent_tokens:%s*(%d+)")
  local ms = content:match("duration_ms:%s*(%d+)")

  local bits = {}
  if uses then table.insert(bits, ("%s tool use%s"):format(uses, uses == "1" and "" or "s")) end
  if tokens then table.insert(bits, fmt_tokens(tonumber(tokens))) end
  if ms then table.insert(bits, ("%.1fs"):format(tonumber(ms) / 1000)) end
  local word = status and (status:sub(1, 1):upper() .. status:sub(2)) or "Done"
  local head = #bits > 0 and ("%s (%s)"):format(word, table.concat(bits, " · ")) or word

  if M.blocks["res:" .. id] then
    replace_line("res:" .. id, GLYPH.result .. head, "SottoccResult")
  end

  local body = vim.trim((content:gsub("<usage>.-</usage>%s*$", "")))
  local lines = {}
  for _, l in ipairs(body == "" and {} or vim.split(body, "\n", { plain = true })) do
    table.insert(lines, NEST .. "   " .. l)
  end
  insert_after("end:" .. id, lines)
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
