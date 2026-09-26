-- Permission prompts cover the region LEFT of the sottocc column, and nothing
-- else. They are floating windows, so whatever splits the user has there are
-- neither closed nor resized: the prompt sits on top and the layout underneath
-- comes back untouched.
--
-- Edit-like tools get a before | after diff across that whole region, which is
-- the point of covering it: half the screen each, rather than a sliver beside
-- the splits that were already open.
--
-- One turn can call several tools, so requests arrive faster than they are
-- answered. They queue and are shown one at a time, as the CLI asks them.

local Window = require("sottocc.window")

local M = {}

local EDIT_TOOLS = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

---@class sottocc.Request
---@field tool_name string
---@field input table
---@field respond fun(behavior: "allow"|"deny")

---@type sottocc.Request[]
local queue = {}
local showing = false

-- The request on screen, held in a table so that whoever answers it first --
-- a keymap or a reset -- can mark it done for the other.
---@type { req: sottocc.Request, answered: boolean }?
local current = nil

-- The floats currently up, and the window that had the cursor before the
-- first of them took it.
---@type integer[]
local floats = {}
---@type integer?
local focus = nil

---The rectangle left of the sottocc column, in editor coordinates.
---@return { row: integer, col: integer, width: integer, height: integer }?
local function left_region()
  local out = Window.win_for(Window.output_buf)
  if not out then return nil end
  -- One column of the gap is the vertical separator.
  local width = vim.api.nvim_win_get_position(out)[2] - 1
  if width < 20 then return nil end

  local tabs = #vim.api.nvim_list_tabpages()
  local top = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and tabs > 1)) and 1 or 0
  local height = vim.o.lines - vim.o.cmdheight - 1 - top
  if height < 5 then return nil end
  return { row = top, col = 0, width = width, height = height }
end

---@param lines string[]
---@param ft string
---@return integer
local function scratch(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  return buf
end

---@param buf integer
---@param rect table
---@param hint string
---@return integer win
local function open_float(buf, rect, hint)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = rect.row,
    col = rect.col,
    width = rect.width,
    height = rect.height,
    style = "minimal",
    zindex = 60,
  })
  -- The hint goes in the winbar rather than in the buffer: two extra lines of
  -- text would offset one side of a diff against the other.
  vim.wo[win].winbar = hint:gsub("%%", "%%%%")
  vim.wo[win].winhighlight = "Normal:Normal,WinBar:SottoccUser,WinBarNC:SottoccUser"
  table.insert(floats, win)
  return win
end

local function close_floats()
  for _, win in ipairs(floats) do
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  floats = {}
end

---Take the prompt down and put the cursor back where it was.
local function restore()
  close_floats()
  if focus and vim.api.nvim_win_is_valid(focus) then
    pcall(vim.api.nvim_set_current_win, focus)
  end
  focus = nil
end

---@class sottocc.Diff
---@field before string[]
---@field after string[]
---@field ft string
---@field title string

---What an Edit or Write would do to the file on disk.
---@param tool_name string
---@param input table
---@return sottocc.Diff
local function file_diff(tool_name, input)
  local before = {}
  if vim.fn.filereadable(input.file_path) == 1 then
    before = vim.fn.readfile(input.file_path)
  end
  local after = vim.deepcopy(before)
  if tool_name == "Write" then
    after = vim.split(input.content or "", "\n", { plain = true })
  elseif input.old_string then
    local joined = table.concat(before, "\n")
    -- replace_all rewrites every occurrence; without it the tool refuses an
    -- ambiguous match, so the first one is the only one.
    local count = not input.replace_all and 1 or nil
    joined = joined:gsub(vim.pesc(input.old_string), (input.new_string or ""):gsub("%%", "%%%%"), count)
    after = vim.split(joined, "\n", { plain = true })
  end
  return {
    before = before,
    after = after,
    ft = vim.filetype.match({ filename = input.file_path }) or "",
    title = vim.fn.fnamemodify(input.file_path, ":."),
  }
end

---A cell's source, which nbformat stores either as one string or as a list
---of lines that keep their own newlines.
---@param cell table?
---@return string[]
local function cell_lines(cell)
  if type(cell) ~= "table" then return {} end
  local src = cell.source
  if type(src) == "table" then src = table.concat(src) end
  if type(src) ~= "string" or src == "" then return {} end
  return vim.split(src, "\n", { plain = true })
end

---The one cell a NotebookEdit touches, before and after. The rest of the
---notebook is JSON nobody wants to read in a diff.
---@param input table
---@return sottocc.Diff
local function notebook_diff(input)
  local nb = {}
  if vim.fn.filereadable(input.notebook_path) == 1 then
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(input.notebook_path), "\n"))
    if ok and type(decoded) == "table" then nb = decoded end
  end

  local cell
  for _, c in ipairs(type(nb.cells) == "table" and nb.cells or {}) do
    if type(c) == "table" and c.id == input.cell_id then cell = c break end
  end

  local meta = type(nb.metadata) == "table" and nb.metadata or {}
  local lang = (type(meta.kernelspec) == "table" and meta.kernelspec.language)
      or (type(meta.language_info) == "table" and meta.language_info.name)
      or ""

  local mode = input.edit_mode or "replace"
  local new = vim.split(input.new_source or "", "\n", { plain = true })
  local before, after, kind, where
  if mode == "insert" then
    -- cell_id names the cell the new one goes after.
    before, after = {}, new
    kind = input.cell_type or "code"
    where = input.cell_id and ("new cell after %s"):format(input.cell_id) or "new cell at top"
  elseif mode == "delete" then
    before, after = cell_lines(cell), {}
    kind = cell and cell.cell_type or "code"
    where = ("cell %s deleted"):format(tostring(input.cell_id))
  else
    before, after = cell_lines(cell), new
    kind = input.cell_type or (cell and cell.cell_type) or "code"
    where = ("cell %s"):format(tostring(input.cell_id))
  end

  return {
    before = before,
    after = after,
    ft = kind == "markdown" and "markdown" or (type(lang) == "string" and lang or ""),
    title = ("%s  %s"):format(vim.fn.fnamemodify(input.notebook_path, ":."), where),
  }
end

local show

---Draw the next request, or give the screen back when there are none left.
local function advance()
  current = nil
  local req = table.remove(queue, 1)
  if not req then
    showing = false
    restore()
    return
  end
  showing = true
  current = { req = req, answered = false }
  show(current)
end

---Show one request and call its `respond` exactly once.
---
---There is deliberately no "always allow": the CLI's permission_suggestions
---carry {type = "setMode", mode = "acceptEdits"}, which turns off confirmation
---for every later edit rather than whitelisting this one tool. Changing the
---mode is an explicit act; see :SottoccPermissionMode.
---@param slot { req: sottocc.Request, answered: boolean }
function show(slot)
  local req = slot.req
  local rect = left_region()
  if not rect then
    -- Nowhere to draw: fall back to a plain confirm rather than silently
    -- doing nothing.
    local choice = vim.fn.confirm(("Allow %s?"):format(req.tool_name), "&Yes\n&No", 2)
    slot.answered = true
    req.respond(choice == 1 and "allow" or "deny")
    vim.schedule(advance)
    return
  end

  if not focus then focus = vim.api.nvim_get_current_win() end
  -- The previous request's floats, if it was answered a moment ago.
  close_floats()

  -- One flag for the whole prompt, so the two panes of a diff cannot both
  -- answer the same request.
  local function answer(behavior)
    if slot.answered then return end
    slot.answered = true
    req.respond(behavior)
    -- Off the keymap callback before the buffer it is bound to is wiped.
    vim.schedule(advance)
  end

  ---@param buf integer
  local function bind_keys(buf)
    local opts = { buffer = buf, nowait = true }
    vim.keymap.set("n", "y", function() answer("allow") end, opts)
    vim.keymap.set("n", "n", function() answer("deny") end, opts)
    vim.keymap.set("n", "q", function() answer("deny") end, opts)
    vim.keymap.set("n", "<Esc>", function() answer("deny") end, opts)
  end

  local waiting = #queue > 0 and ("   (+%d waiting)"):format(#queue) or ""
  local hint = ("  [y] allow   [n] deny      %s%s"):format(req.tool_name, waiting)
  local input = req.input

  local diff
  if req.tool_name == "NotebookEdit" and input.notebook_path then
    diff = notebook_diff(input)
  elseif EDIT_TOOLS[req.tool_name] and input.file_path then
    diff = file_diff(req.tool_name, input)
  end

  if diff then
    local before_buf = scratch(diff.before, diff.ft)
    local after_buf = scratch(diff.after, diff.ft)

    local half = math.floor((rect.width - 1) / 2)
    local left = open_float(before_buf,
      { row = rect.row, col = rect.col, width = half, height = rect.height },
      ("  %s  (before)"):format(diff.title))
    local right = open_float(after_buf,
      { row = rect.row, col = rect.col + half + 1, width = rect.width - half - 1, height = rect.height },
      hint)

    for _, win in ipairs({ left, right }) do
      vim.api.nvim_win_call(win, function() vim.cmd("diffthis") end)
    end
    bind_keys(before_buf)
    bind_keys(after_buf)
    vim.api.nvim_set_current_win(right)
  else
    local body = input.command or vim.inspect(input)
    local ft = input.command and "bash" or "lua"
    local buf = scratch(vim.split(body, "\n", { plain = true }), ft)
    local win = open_float(buf, rect, hint)
    bind_keys(buf)
    vim.api.nvim_set_current_win(win)
  end
end

---Queue a permission request; it is shown as soon as the ones before it are
---answered.
---@param tool_name string
---@param input table
---@param respond fun(behavior: "allow"|"deny")
function M.ask(tool_name, input, respond)
  table.insert(queue, { tool_name = tool_name, input = input, respond = respond })
  if not showing then advance() end
end

---Drop every pending request, answering each with a denial, and take the
---prompt down. Called when a turn is abandoned.
function M.reset()
  local pending, live = queue, current
  queue, current, showing = {}, nil, false
  if live and not live.answered then
    live.answered = true
    pcall(live.req.respond, "deny")
  end
  for _, req in ipairs(pending) do
    pcall(req.respond, "deny")
  end
  restore()
end

return M
