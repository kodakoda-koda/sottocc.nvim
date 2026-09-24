-- Permission prompts take over the LEFT region, never the sottocc column.
-- Edit-like tools get a before | after diff; everything else gets its input
-- in a single buffer. Answering restores whatever was there (oil, a file).

local Window = require("sottocc.window")

local M = {}

local EDIT_TOOLS = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

---@type { win: integer, buf: integer, view: table, extra: integer[], focus: integer }?
local saved = nil

---Find a window in this tab that is not part of the sottocc column.
---@return integer? win
local function left_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf ~= Window.output_buf and buf ~= Window.prompt_buf then
      return win
    end
  end
  return nil
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

local function restore()
  if not saved then return end
  for _, win in ipairs(saved.extra) do
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  if vim.api.nvim_win_is_valid(saved.win) then
    vim.wo[saved.win].winfixbuf = false
    if vim.api.nvim_buf_is_valid(saved.buf) then
      vim.api.nvim_win_set_buf(saved.win, saved.buf)
      vim.api.nvim_win_call(saved.win, function()
        vim.cmd("diffoff")
        vim.fn.winrestview(saved.view)
      end)
    end
  end
  -- Answering a prompt should not move the user; put them back where they were.
  if saved.focus and vim.api.nvim_win_is_valid(saved.focus) then
    pcall(vim.api.nvim_set_current_win, saved.focus)
  end
  saved = nil
end

---@param win integer
---@param answer_buf integer
---@param respond fun(behavior: "allow"|"deny")
local function bind_keys(win, answer_buf, respond)
  local answered = false
  local function answer(behavior)
    if answered then return end
    answered = true
    restore()
    respond(behavior)
  end
  local opts = { buffer = answer_buf, nowait = true }
  vim.keymap.set("n", "y", function() answer("allow") end, opts)
  vim.keymap.set("n", "n", function() answer("deny") end, opts)
  vim.keymap.set("n", "q", function() answer("deny") end, opts)
  vim.keymap.set("n", "<Esc>", function() answer("deny") end, opts)
  vim.api.nvim_set_current_win(win)
end

---Show a permission request and call `respond(behavior)` exactly once.
---
---There is deliberately no "always allow": the CLI's permission_suggestions
---carry {type = "setMode", mode = "acceptEdits"}, which turns off confirmation
---for every later edit rather than whitelisting this one tool. Changing the
---mode is an explicit act; see :SottoccPermissionMode.
---@param tool_name string
---@param input table
---@param respond fun(behavior: "allow"|"deny")
function M.ask(tool_name, input, respond)
  local host = left_win()
  if not host then
    -- No left region to borrow: fall back to a plain confirm rather than
    -- silently doing nothing.
    local choice = vim.fn.confirm(("Allow %s?"):format(tool_name), "&Yes\n&No", 2)
    respond(choice == 1 and "allow" or "deny")
    return
  end

  saved = {
    win = host,
    buf = vim.api.nvim_win_get_buf(host),
    view = vim.api.nvim_win_call(host, vim.fn.winsaveview),
    extra = {},
    focus = vim.api.nvim_get_current_win(),
  }

  local hint = ("  [y] allow   [n] deny      %s"):format(tool_name)

  if EDIT_TOOLS[tool_name] and input.file_path then
    local before = {}
    if vim.fn.filereadable(input.file_path) == 1 then
      before = vim.fn.readfile(input.file_path)
    end
    local after = vim.deepcopy(before)
    if tool_name == "Write" then
      after = vim.split(input.content or "", "\n", { plain = true })
    elseif input.old_string then
      local joined = table.concat(before, "\n")
      joined = joined:gsub(vim.pesc(input.old_string), (input.new_string or ""):gsub("%%", "%%%%"), 1)
      after = vim.split(joined, "\n", { plain = true })
    end

    local ft = vim.filetype.match({ filename = input.file_path }) or ""
    local before_buf = scratch(before, ft)
    local after_buf = scratch(vim.list_extend({ hint, "" }, after), ft)

    vim.api.nvim_win_set_buf(host, before_buf)
    vim.api.nvim_win_call(host, function() vim.cmd("diffthis") end)

    vim.api.nvim_set_current_win(host)
    vim.cmd("rightbelow vsplit")
    local right = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right, after_buf)
    vim.api.nvim_win_call(right, function() vim.cmd("diffthis") end)
    table.insert(saved.extra, right)

    bind_keys(right, after_buf, respond)
    bind_keys(right, before_buf, respond)
  else
    local body = input.command or vim.inspect(input)
    local ft = input.command and "bash" or "lua"
    local buf = scratch(vim.list_extend({ hint, "" }, vim.split(body, "\n", { plain = true })), ft)
    vim.api.nvim_win_set_buf(host, buf)
    bind_keys(host, buf, respond)
  end
end

return M
