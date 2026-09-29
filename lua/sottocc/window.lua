-- The sottocc column: output buffer on top, prompt buffer below, pinned to the
-- right edge, or the left one with position = "left". Both windows carry
-- 'winfixbuf' so nothing can steal them, and the rest of the screen (oil, a
-- file, anything) is never touched.

local Config = require("sottocc.config")

local M = {}

M.output_buf = nil
M.prompt_buf = nil

local AUGROUP = vim.api.nvim_create_augroup("sottocc.window", { clear = true })

local function make_output_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "sottocc"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, "sottocc://output")
  return buf
end

local function make_prompt_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "sottocc://prompt")
  return buf
end

---@param buf integer
---@return integer? winid
function M.win_for(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then return win end
  end
  return nil
end

function M.is_open()
  return M.win_for(M.output_buf) ~= nil
end

-- The bar and mode rows are virtual lines inside the prompt window, and a
-- winbar from lualine or navic takes one more, so the prompt needs room for
-- three rows beyond the lines the user types.
local RESERVED_ROWS = 3

---Give the prompt its starting height. Called once, at open: the height is
---deliberately not pinned, so winresizer and friends can change it.
function M.size_prompt()
  local prompt = M.win_for(M.prompt_buf)
  if not prompt then return end
  pcall(vim.api.nvim_win_set_height, prompt, Config.options.prompt_height + RESERVED_ROWS)
end

---Pin a window so other buffers cannot be opened into it.
---@param win integer
local function pin(win)
  vim.wo[win].winfixbuf = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = true
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(M.win_for(M.prompt_buf))
    return
  end

  M.output_buf = (M.output_buf and vim.api.nvim_buf_is_valid(M.output_buf)) and M.output_buf
    or make_output_buf()
  M.prompt_buf = (M.prompt_buf and vim.api.nvim_buf_is_valid(M.prompt_buf)) and M.prompt_buf
    or make_prompt_buf()
  -- Claim a fresh column at the far edge; the rest survives untouched.
  vim.cmd(Config.options.position == "left" and "topleft vsplit" or "botright vsplit")
  local out_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(out_win, M.output_buf)
  vim.api.nvim_win_set_width(out_win, math.floor(vim.o.columns * Config.options.width_ratio))

  vim.cmd("belowright split")
  local prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(prompt_win, M.prompt_buf)

  pin(out_win)
  pin(prompt_win)
  require("sottocc.fold").attach(out_win)
  M.size_prompt()
  require("sottocc.winbar").paint()

  vim.api.nvim_set_current_win(prompt_win)
end

function M.close()
  for _, buf in ipairs({ M.output_buf, M.prompt_buf }) do
    local win = M.win_for(buf)
    if win then
      vim.wo[win].winfixbuf = false
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

---Run `fn` with the output buffer temporarily modifiable.
---@param fn fun(buf: integer)
function M.with_output(fn)
  local buf = M.output_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  vim.bo[buf].modifiable = false
  if not ok then vim.notify("sottocc: render error: " .. tostring(err), vim.log.levels.ERROR) end
end

---Keep the tail in view while output streams in.
---
---When the user is not in the output window there is nothing to disturb, so
---always jump to the end. When they are reading it, only follow if they were
---already at the bottom.
function M.follow()
  local win = M.win_for(M.output_buf)
  if not win then return end
  local last = vim.api.nvim_buf_line_count(M.output_buf)
  if vim.api.nvim_get_current_win() ~= win then
    pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  if last - cur <= 3 then pcall(vim.api.nvim_win_set_cursor, win, { last, 0 }) end
end

-- Repaint after layout changes so the virtual bar rows cannot go missing.
-- The height is not restored here on purpose: resizing the prompt is the
-- user's call, not ours.
vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter", "BufEnter", "WinEnter" }, {
  group = AUGROUP,
  callback = function()
    if not M.prompt_buf then return end
    vim.schedule(function()
      require("sottocc.winbar").paint()
    end)
  end,
})

-- The rows hang off the last line, so typing has to move them.
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  group = AUGROUP,
  callback = function(ev)
    if ev.buf ~= M.prompt_buf then return end
    require("sottocc.winbar").paint()
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = AUGROUP,
  callback = function()
    require("sottocc").stop()
  end,
})

return M
