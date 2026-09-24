-- Minimal floating picker: j/k to move, <CR> to choose, q/<Esc> to cancel.
-- Deliberately not vim.ui.select — inputlist() drops keystrokes when another
-- prompt follows it.

local M = {}

---@param opts { title: string, items: string[], on_choice: fun(index: integer)? }
function M.open(opts)
  local items = opts.items
  if #items == 0 then
    vim.notify("sottocc: nothing to pick", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, items)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 0
  for _, s in ipairs(items) do width = math.max(width, vim.fn.strdisplaywidth(s)) end
  width = math.min(math.max(width + 2, 30), vim.o.columns - 8)
  local height = math.min(#items, math.floor(vim.o.lines * 0.5))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "single",
    title = " " .. opts.title .. " ",
  })
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local function choose()
    local idx = vim.api.nvim_win_get_cursor(win)[1]
    close()
    if opts.on_choice then opts.on_choice(idx) end
  end

  local map = function(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
  map("<CR>", choose)
  map("q", close)
  map("<Esc>", close)
end

return M
