-- Tool results are folded away, the way the CLI collapses them.
--
-- Real folds rather than a bespoke toggle: za, zo, zR and zM then work as
-- they do anywhere else, and a search still finds text inside a closed fold.
--
-- The level cannot be decided from a line alone, because agent prose may also
-- be indented. It is decided by a single sequential scan -- a continuation
-- line only belongs to a result if the line above did too -- cached per
-- changedtick so 'foldexpr' stays one lookup per line.

local M = {}

local HEAD = "  ⎿  "
local CONT = "     "

local cache = { buf = -1, tick = -1, levels = {} }

---@param buf integer
---@return string[]
local function rebuild(buf)
  local levels, inside = {}, false
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:sub(1, #HEAD) == HEAD then
      inside = true
      levels[i] = ">1"
    elseif inside and l:sub(1, #CONT) == CONT then
      levels[i] = "1"
    else
      inside = false
      levels[i] = "0"
    end
  end
  return levels
end

---@return string
function M.expr()
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if cache.buf ~= buf or cache.tick ~= tick then
    cache = { buf = buf, tick = tick, levels = rebuild(buf) }
  end
  return cache.levels[vim.v.lnum] or "0"
end

---The first line of the result, plus how much is hidden behind it.
---@return string
function M.text()
  local first = vim.fn.getline(vim.v.foldstart)
  local hidden = vim.v.foldend - vim.v.foldstart
  if hidden > 0 then
    return ("%s  (+%d lines)"):format(first, hidden)
  end
  return first
end

---Apply the fold settings to the output window.
---@param win integer
function M.attach(win)
  local function set(name, value)
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
  end
  set("foldmethod", "expr")
  set("foldexpr", "v:lua.require'sottocc.fold'.expr()")
  set("foldtext", "v:lua.require'sottocc.fold'.text()")
  set("foldlevel", 0)
  set("foldenable", true)
  set("foldcolumn", "0")
  -- No trailing dots after the fold text, and no highlight bar across it.
  set("fillchars", "fold: ")
  set("winhighlight", "Folded:SottoccResult")
end

return M
