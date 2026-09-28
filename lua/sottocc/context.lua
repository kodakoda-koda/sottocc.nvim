-- Traffic between the files being edited and the conversation: a file or a
-- range of it goes into the prompt as an @-mention, and a tool line in the
-- output opens the file it names.
--
-- The CLI expands the mention itself, in print mode too: @path attaches the
-- file, @path#L10-20 only those lines. A path with spaces is quoted with the
-- range inside the quotes, @"a b.txt#L4"; outside them the range is ignored
-- and the whole file is attached.

local Window = require("sottocc.window")

local M = {}

---The mention for a path, relative to the session's directory when inside it.
---@param path string absolute
---@param first integer?
---@param last integer?
---@return string
function M.mention(path, first, last)
  local core = require("sottocc")
  local root = vim.fs.normalize(core.cwd or vim.fn.getcwd())
  path = vim.fs.normalize(path)
  if path:sub(1, #root + 1) == root .. "/" then path = path:sub(#root + 2) end
  if first then
    path = path .. (first == last and ("#L%d"):format(first) or ("#L%d-%d"):format(first, last))
  end
  if path:find("%s") then path = ('"%s"'):format(path) end
  return "@" .. path
end

---Append text to the end of the prompt and leave the cursor after it.
---@param text string
function M.insert(text)
  require("sottocc").open()
  local buf = Window.prompt_buf
  local win = Window.win_for(buf)
  if not (buf and win) then return end
  local n = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
  local sep = (last == "" or last:match("%s$")) and "" or " "
  local line = last .. sep .. text .. " "
  vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { line })
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { n, #line })
  vim.cmd("startinsert!")
end

---Mention the current file, or lines of it, in the prompt.
---@param first integer?
---@param last integer?
function M.add(first, last)
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" then
    vim.notify("sottocc: this buffer is not a file", vim.log.levels.WARN)
    return
  end
  M.insert(M.mention(name, first, last))
end

----------------------------------------------------------------- opening

---A window outside the sottocc column to open a file in: the one used last,
---then any other, then a new split on the far side of the screen.
---@return integer
local function target_win()
  local ours = { [Window.output_buf or -1] = true, [Window.prompt_buf or -1] = true }
  local function usable(win)
    return win ~= 0 and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_config(win).relative == ""
        and not ours[vim.api.nvim_win_get_buf(win)]
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if usable(prev) then return prev end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  local side = require("sottocc.config").options.position == "left" and "right" or "left"
  return vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), false, { split = side, win = -1 })
end

---Open a file beside the column, at a line or at the first match of a text.
---@param t { path: string, line: integer?, find: string? }
function M.open(t)
  local win = target_win()
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(t.path))
  if t.line then
    pcall(vim.api.nvim_win_set_cursor, win, { t.line, 0 })
  elseif t.find and t.find ~= "" then
    vim.fn.cursor(1, 1)
    vim.fn.search("\\V" .. vim.fn.escape(t.find, "\\"), "cW")
  end
  vim.cmd("normal! zvzz")
end

---A path as the output shows it, if it names something on disk.
---@param s string
---@return string?
local function existing(s)
  if s == "" or s:find("…", 1, true) then return nil end
  local p = vim.fn.fnamemodify(vim.fn.expand(s), ":p")
  if vim.fn.filereadable(p) == 1 or vim.fn.isdirectory(p) == 1 then return p end
  return nil
end

local HEADER = "^%s*⏺ [%w_]+%((.*)%)$"
local RESULT = { "  ⎿  ", "     " }

---@param l string
---@return boolean
local function in_result(l)
  for _, p in ipairs(RESULT) do
    if l:sub(1, #p) == p then return true end
  end
  return false
end

---What the output line under the cursor points at.
---
---A result line that is itself a path, with or without :line (Grep and Glob
---print these), opens that. Otherwise the tool line above it: the input the
---tool was called with when it is known, the path in its parentheses when
---not, as for a subagent's steps or a line cut short.
---@return { path: string, line: integer?, find: string? }?
function M.target_at_cursor()
  local Render = require("sottocc.render")
  local buf = Window.output_buf
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local lines = vim.api.nvim_buf_get_lines(buf, 0, row + 1, false)

  local body = lines[row + 1]:gsub("^%s*⎿?%s*", "")
  local file, lnum = body:match("^(.-):(%d+)")
  local path = file and existing(file)
  if path then return { path = path, line = tonumber(lnum) } end
  path = existing(vim.trim(body))
  if path then return { path = path } end

  for r = row, 0, -1 do
    local l = lines[r + 1]
    local arg = l:match(HEADER)
    if arg then
      local t = Render.target_at(r)
      if t then return t end
      path = existing(arg)
      return path and { path = path } or nil
    end
    if not in_result(l) then return nil end
  end
  return nil
end

function M.open_at_cursor()
  local t = M.target_at_cursor()
  if not t then
    vim.notify("sottocc: no file on this line", vim.log.levels.WARN)
    return
  end
  M.open(t)
end

return M
