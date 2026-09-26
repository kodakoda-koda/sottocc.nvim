-- Context and rate-limit bars, modelled on the user's ~/.claude/statusline.py,
-- plus the permission-mode line the CLI prints under its input box.
--
-- Drawn as virtual lines above the first line of the prompt buffer. Not a
-- 'statusline' (lualine rewrites those on a timer), not a 'winbar' (only one
-- row, and global-local so it leaks across :split), and not a window of its
-- own (a third split fights the other two for rows).

local M = {}

local BAR_WIDTH = 10
local NS = vim.api.nvim_create_namespace("sottocc.bar")

M.state = {
  ctx = nil,       -- 0..100
  five_hour = nil, -- { pct = 0..100, resets_at = epoch }
  seven_day = nil,
  status = nil,
  model = nil,
  mode = nil,      -- permission mode reported by system/init
}

-- How the CLI labels each mode under the input box. "⏵⏵" means it will keep
-- going on its own, "⏸" means it stops to ask. The CLI prints nothing for
-- "default"; we do, because a blank line reads as "the feature is broken".
local MODE_LABEL = {
  default = { "⏸", "default mode on" },
  acceptEdits = { "⏵⏵", "accept edits on" },
  auto = { "⏵⏵", "auto mode on" },
  plan = { "⏸", "plan mode on" },
  manual = { "⏸", "manual mode on" },
  bypassPermissions = { "⏵⏵", "bypass permissions on" },
  dontAsk = { "⏵⏵", "dont ask on" },
}

local WINDOW_SECONDS = { five_hour = 5 * 3600, seven_day = 7 * 86400 }

-- statusline.py colours the reading, not the scaffolding: the label, the
-- filled cells and the percentage carry the gradient, while the brackets,
-- the unfilled cells and the reset time stay dim.
local DIM = "Comment"

---Pacing deficit damped by remaining time, as in statusline.py: burning the
---window early is worse than the same percentage near its reset.
---@param pct number
---@param resets_at integer
---@param window integer
---@return number
local function severity(pct, resets_at, window)
  local left = math.max(0, resets_at - os.time())
  local elapsed_pct = (window - left) / window * 100
  return (pct - elapsed_pct) * (left / window)
end

---@param t number 0..1
---@return string
local function grade_hl(t)
  return "SottoccGrade" .. math.max(0, math.min(4, math.floor((t or 0) * 5)))
end

---@param resets_at integer?
---@param key string
---@return string
local function remaining(resets_at, key)
  if not resets_at then return "" end
  local s = math.max(0, resets_at - os.time())
  if key == "five_hour" then
    return (" (%d:%02d)"):format(math.floor(s / 3600), math.floor(s % 3600 / 60))
  end
  return (" (%dd%02dh)"):format(math.floor(s / 86400), math.floor(s % 86400 / 3600))
end

---The usage row, as virtual-text chunks.
---@return { [1]: string, [2]: string }[]
function M.bar_chunks()
  local s = M.state
  local out = {}
  local function put(text, hl)
    if text ~= "" then out[#out + 1] = { text, hl or DIM } end
  end

  local function add(label, pct, hl, suffix)
    put(" ")
    if not pct then
      put(label, DIM)
      put(" [" .. ("░"):rep(BAR_WIDTH) .. "] -", DIM)
      put("  ")
      return
    end
    local filled = math.max(0, math.min(BAR_WIDTH, math.floor(pct / 100 * BAR_WIDTH + 0.5)))
    put(label, hl)
    put(" [", DIM)
    put(("█"):rep(filled), hl)
    put(("░"):rep(BAR_WIDTH - filled) .. "]", DIM)
    put(" ")
    put(("%d%%"):format(math.floor(pct + 0.5)), hl)
    put(suffix, DIM)
    put("  ")
  end

  add("ctx", s.ctx, grade_hl((s.ctx or 0) / 50), "")
  for _, key in ipairs({ "five_hour", "seven_day" }) do
    local info = s[key]
    if info then
      local sev = info.resets_at and severity(info.pct, info.resets_at, WINDOW_SECONDS[key]) or 0
      add(key == "five_hour" and "5h" or "7d", info.pct, grade_hl(sev / 20),
        remaining(info.resets_at, key))
    end
  end

  -- system/status usually carries a plain string, but not always; anything
  -- else is not something to paint.
  if type(s.status) == "string" and s.status ~= "" then
    put(" " .. s.status, DIM)
  end

  return out
end

---The mode row, as virtual-text chunks.
---@return { [1]: string, [2]: string }[]
function M.mode_chunks()
  local mode = M.state.mode
  local label = MODE_LABEL[mode]
  if not label then
    -- An unknown mode is still worth naming: silence hides the state.
    return { { (" ⏸ %s"):format(mode or "mode unknown"), "SottoccModePaused" } }
  end
  local hl = label[1] == "⏸" and "SottoccModePaused" or "SottoccModeAuto"
  return { { (" %s %s"):format(label[1], label[2]), hl } }
end

---The usage rows for the configured `statusline`: the output of the user's
---statusLine command, a function's chunks, or the built-in bars.
---@return { [1]: string, [2]: string }[][]
local function usage_rows()
  local Config = require("sottocc.config")
  local Statusline = require("sottocc.statusline")
  local mode = Config.options.statusline
  if type(mode) == "function" then
    local ok, r = pcall(mode, Statusline.data())
    if ok and type(r) == "table" then
      -- One row of chunks, or a list of rows.
      if type(r[1]) == "table" and type(r[1][1]) == "table" then return r end
      return { r }
    end
    return { { { ok and "statusline: not a table" or ("statusline: " .. tostring(r)), "ErrorMsg" } } }
  end
  if mode == "builtin" then return { M.bar_chunks() } end
  -- Nothing until the command prints, and nothing at all without one.
  local rows = vim.deepcopy(Statusline.rows() or {})
  -- The command cannot see system/status, so it is appended here.
  local s = M.state.status
  if type(s) == "string" and s ~= "" then
    if #rows == 0 then rows[1] = {} end
    table.insert(rows[#rows], { " " .. s, DIM })
  end
  return rows
end

---Repaint the two virtual rows, held against the bottom of the prompt window.
---
---Below the text, not above the first line: a winbar from lualine or navic
---already owns the row above, and two strips stacked there read as one
---garbled line. Blank virtual lines pad the gap so the bar stays put instead
---of sliding down every time a line is typed.
function M.paint()
  local Window = require("sottocc.window")
  local buf = Window.prompt_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  -- Clear first: the measurement below must see the real text height, not
  -- the rows this function added last time.
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  -- A copy: the statusline's rows are kept between paints and must not grow.
  local rows = vim.list_extend({}, usage_rows())
  table.insert(rows, M.mode_chunks())
  local win = Window.win_for(buf)
  if win then
    local ok, used = pcall(vim.api.nvim_win_text_height, win, {})
    if ok then
      -- Stop one row short of the bottom: the global statusline sits flush
      -- against the last window row and swallows whatever lands there.
      local pad = vim.api.nvim_win_get_height(win) - used.all - #rows - 1
      for _ = 1, math.max(0, pad) do
        table.insert(rows, 1, { { "", "Normal" } })
      end
    end
  end

  local last = vim.api.nvim_buf_line_count(buf) - 1
  pcall(vim.api.nvim_buf_set_extmark, buf, NS, last, 0, { virt_lines = rows })
end

function M.setup_highlights()
  -- blue -> green -> yellow -> orange -> red, matching statusline.py's ramp.
  local colors = { "#50a0dc", "#50c83c", "#dcc832", "#dc9632", "#dc3c32" }
  for i, c in ipairs(colors) do
    vim.api.nvim_set_hl(0, "SottoccGrade" .. (i - 1), { fg = c, default = true })
  end
  vim.api.nvim_set_hl(0, "SottoccModeAuto", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "SottoccModePaused", { link = "Comment", default = true })
end

return M
