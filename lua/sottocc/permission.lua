-- Permission prompts take over the LEFT region, never the sottocc column.
-- Edit-like tools get a before | after diff; everything else gets its input
-- in a single buffer. Answering restores whatever was there (oil, a file).
--
-- One turn can call several tools, so requests arrive faster than they are
-- answered. They queue and are shown one at a time, as the CLI asks them, and
-- the left region is put back only after the last one has been answered.

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

-- What the left region held before the first prompt took it over. Saved once,
-- not per request: a later request must never record the prompt it is about
-- to replace as the thing to restore.
--
-- The name is kept beside the handle because a buffer can be gone by the time
-- the answer comes: oil deletes its hidden buffers two seconds after the last
-- one leaves the screen, which a short queue of prompts easily outlasts.
---@type { win: integer, buf: integer, name: string, view: table, focus: integer }?
local saved = nil

-- Windows a prompt opened beside the host, closed before the next is drawn.
---@type integer[]
local extra = {}

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

---The window prompts are drawn in: the one already borrowed, or a fresh one.
---@return integer? win
local function host_win()
  if saved and vim.api.nvim_win_is_valid(saved.win) then return saved.win end
  return left_win()
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

local function close_extra()
  for _, win in ipairs(extra) do
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  extra = {}
end

---Hand the left region back to whatever held it before the first prompt.
local function restore()
  close_extra()
  if not saved then return end
  if vim.api.nvim_win_is_valid(saved.win) then
    vim.wo[saved.win].winfixbuf = false
    local back = vim.api.nvim_buf_is_valid(saved.buf)
    if back then
      vim.api.nvim_win_set_buf(saved.win, saved.buf)
    elseif saved.name ~= "" then
      -- Gone while the prompts were up. The name still opens it, and for an
      -- oil listing that means the directory comes back, not a blank window.
      back = vim.api.nvim_win_call(saved.win, function()
        return pcall(vim.cmd.edit, vim.fn.fnameescape(saved.name))
      end)
    end
    if back then
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

local show

---Answer the request on screen, then draw the next one or give the region back.
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
  local host = host_win()
  if not host then
    -- No left region to borrow: fall back to a plain confirm rather than
    -- silently doing nothing.
    local choice = vim.fn.confirm(("Allow %s?"):format(req.tool_name), "&Yes\n&No", 2)
    slot.answered = true
    req.respond(choice == 1 and "allow" or "deny")
    vim.schedule(advance)
    return
  end

  if not saved then
    local buf = vim.api.nvim_win_get_buf(host)
    saved = {
      win = host,
      buf = buf,
      name = vim.api.nvim_buf_get_name(buf),
      view = vim.api.nvim_win_call(host, vim.fn.winsaveview),
      focus = vim.api.nvim_get_current_win(),
    }
  end
  -- The previous prompt's diff pane, if it is still up.
  close_extra()

  -- One flag for the whole prompt, so the two buffers of a diff cannot both
  -- answer the same request.
  local function answer(behavior)
    if slot.answered then return end
    slot.answered = true
    req.respond(behavior)
    -- Off the keymap callback before the buffer it is bound to is wiped.
    vim.schedule(advance)
  end

  ---@param win integer
  ---@param buf integer
  local function bind_keys(win, buf)
    local opts = { buffer = buf, nowait = true }
    vim.keymap.set("n", "y", function() answer("allow") end, opts)
    vim.keymap.set("n", "n", function() answer("deny") end, opts)
    vim.keymap.set("n", "q", function() answer("deny") end, opts)
    vim.keymap.set("n", "<Esc>", function() answer("deny") end, opts)
    vim.api.nvim_set_current_win(win)
  end

  local waiting = #queue > 0 and ("   (+%d waiting)"):format(#queue) or ""
  local hint = ("  [y] allow   [n] deny      %s%s"):format(req.tool_name, waiting)
  local input = req.input

  if EDIT_TOOLS[req.tool_name] and input.file_path then
    local before = {}
    if vim.fn.filereadable(input.file_path) == 1 then
      before = vim.fn.readfile(input.file_path)
    end
    local after = vim.deepcopy(before)
    if req.tool_name == "Write" then
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
    table.insert(extra, right)

    bind_keys(right, after_buf)
    bind_keys(right, before_buf)
  else
    local body = input.command or vim.inspect(input)
    local ft = input.command and "bash" or "lua"
    local buf = scratch(vim.list_extend({ hint, "" }, vim.split(body, "\n", { plain = true })), ft)
    vim.api.nvim_win_call(host, function() vim.cmd("diffoff") end)
    vim.api.nvim_win_set_buf(host, buf)
    bind_keys(host, buf)
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

---Drop every pending request, answering each with a denial, and give the left
---region back. Called when a turn is abandoned.
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
