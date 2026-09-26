-- The user's own statusLine command from settings.json, run the way the CLI
-- runs it: the session as JSON on stdin, whatever it prints drawn in place
-- of the built-in usage row, ANSI colours included.
--
-- The stream never hands us the CLI's statusline payload, so the JSON is
-- rebuilt from the messages that pass through. Fields the stream does not
-- carry (lines changed, PR, prompt cache) are left out or zero rather than
-- guessed.

local Claude = require("sottocc.claude")
local Config = require("sottocc.config")
local Session = require("sottocc.session")

local M = {}

-- The CLI waits this long after the last trigger before running the command,
-- so a burst of messages costs one run.
local DEBOUNCE_MS = 300

-- The payload as far as the stream has told us. Reset on every start.
local data = nil
-- The last stdout, kept raw so a colorscheme change can re-derive the colours.
local last_output = nil
local rows = nil
local job = nil
local debounce = nil
local ticker = nil

---The statusLine setting, when it names a command.
---@return table?
local function setting()
  if Config.options.statusline ~= "claude" then return nil end
  local s = Claude.setting("statusLine", vim.fn.getcwd())
  if type(s) == "table" and s.type == "command" and type(s.command) == "string" and s.command ~= "" then
    return s
  end
end

---"claude-haiku-4-5-20251001" -> "Haiku 4.5", "opus[1m]" -> "Opus", the way
---the CLI names models. Anything unrecognised passes through untouched.
---@param id string?
---@return string?
function M.display_name(id)
  if type(id) ~= "string" then return nil end
  local base = id:gsub("%[.*%]$", "")
  local family, rest = base:match("^claude%-(%a+)%-?(.*)$")
  if not family then family, rest = base:match("^(%a+)$"), "" end
  if not family then return id end
  local version = {}
  for n in (rest or ""):gmatch("%d+") do
    if #n < 8 then table.insert(version, n) end -- drop the date stamp
  end
  local name = family:sub(1, 1):upper() .. family:sub(2)
  return #version > 0 and (name .. " " .. table.concat(version, ".")) or name
end

--------------------------------------------------------------------- payload

---Start a fresh payload for a new process.
---@param cwd string
function M.reset(cwd)
  data = {
    cwd = cwd,
    workspace = { current_dir = cwd, project_dir = cwd, added_dirs = {} },
    cost = {
      total_cost_usd = 0,
      total_duration_ms = 0,
      total_api_duration_ms = 0,
      total_lines_added = 0,
      total_lines_removed = 0,
    },
    context_window = {
      total_input_tokens = 0,
      total_output_tokens = 0,
      context_window_size = 200000,
      used_percentage = vim.NIL,
      remaining_percentage = vim.NIL,
      current_usage = vim.NIL,
    },
    exceeds_200k_tokens = false,
  }
end

---The payload the command receives, also handed to a statusline function.
---@return table
function M.data()
  return data or {}
end

---Fold one stream message into the payload, and schedule a run when the CLI
---itself would rerun its status line.
---@param msg table
function M.observe(msg)
  if not data then return end
  local t = msg.type

  if t == "system" and msg.subtype == "init" then
    data.session_id = msg.session_id
    data.cwd = msg.cwd or data.cwd
    data.workspace.current_dir = data.cwd
    data.model = { id = msg.model, display_name = M.display_name(msg.model) }
    data.version = msg.claude_code_version
    data.output_style = { name = msg.output_style }
    data.fast_mode = msg.fast_mode_state == "on"
    if msg.session_id then
      data.transcript_path = Session.transcript(msg.session_id, data.workspace.project_dir)
    end
    M.trigger()

  elseif t == "system" and msg.subtype == "compact_boundary" then
    M.trigger()

  elseif t == "assistant" then
    -- A subagent's request says nothing about the main context.
    if type(msg.parent_tool_use_id) == "string" then return end
    local u = (msg.message or {}).usage
    if type(u) ~= "table" then return end
    local cw = data.context_window
    local input = (u.input_tokens or 0) + (u.cache_creation_input_tokens or 0)
        + (u.cache_read_input_tokens or 0)
    cw.total_input_tokens = input
    cw.total_output_tokens = u.output_tokens or 0
    cw.current_usage = {
      input_tokens = u.input_tokens or 0,
      output_tokens = u.output_tokens or 0,
      cache_creation_input_tokens = u.cache_creation_input_tokens or 0,
      cache_read_input_tokens = u.cache_read_input_tokens or 0,
    }
    -- Input only, as the CLI computes it.
    local pct = math.floor(input / cw.context_window_size * 100 + 0.5)
    cw.used_percentage = pct
    cw.remaining_percentage = 100 - pct
    data.exceeds_200k_tokens = input + cw.total_output_tokens > 200000
    M.trigger()

  elseif t == "rate_limit_event" then
    local w = (msg.rate_limit_info or {}).unifiedWindows or {}
    for _, key in ipairs({ "five_hour", "seven_day" }) do
      local info = w[key]
      if type(info) == "table" then
        data.rate_limits = data.rate_limits or {}
        data.rate_limits[key] = {
          used_percentage = (info.utilization or 0) * 100,
          resets_at = info.resetsAt,
        }
      end
    end
    M.trigger()

  elseif t == "result" then
    local usage = msg.modelUsage or {}
    local main = usage[(data.model or {}).id or ""] or select(2, next(usage))
    if type(main) == "table" and main.contextWindow then
      local cw = data.context_window
      cw.context_window_size = main.contextWindow
      if cw.current_usage ~= vim.NIL then
        local pct = math.floor(cw.total_input_tokens / cw.context_window_size * 100 + 0.5)
        cw.used_percentage = pct
        cw.remaining_percentage = 100 - pct
      end
    end
    if type(msg.total_cost_usd) == "number" then data.cost.total_cost_usd = msg.total_cost_usd end
    data.cost.total_duration_ms = data.cost.total_duration_ms + (tonumber(msg.duration_ms) or 0)
    data.cost.total_api_duration_ms = data.cost.total_api_duration_ms + (tonumber(msg.duration_api_ms) or 0)
    M.trigger()
  end
end

--------------------------------------------------------------------- ANSI

-- xterm's first sixteen, used when the colorscheme sets no terminal colours.
local BASE16 = {
  "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
  "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
}

---@param n integer 0..255
---@return string
local function color256(n)
  if n < 16 then return vim.g["terminal_color_" .. n] or BASE16[n + 1] end
  if n >= 232 then
    local v = 8 + (n - 232) * 10
    return ("#%02x%02x%02x"):format(v, v, v)
  end
  n = n - 16
  local function level(c) return c == 0 and 0 or 55 + c * 40 end
  return ("#%02x%02x%02x"):format(level(math.floor(n / 36)), level(math.floor(n / 6) % 6), level(n % 6))
end

---Apply one SGR parameter list to the running attributes.
---@param attr table
---@param params integer[]
local function sgr(attr, params)
  local i = 1
  while i <= #params do
    local p = params[i]
    if p == 0 then
      for k in pairs(attr) do attr[k] = nil end
    elseif p == 1 then attr.bold = true
    elseif p == 2 then attr.dim = true
    elseif p == 3 then attr.italic = true
    elseif p == 4 then attr.underline = true
    elseif p == 7 then attr.reverse = true
    elseif p == 9 then attr.strikethrough = true
    elseif p == 22 then attr.bold, attr.dim = nil, nil
    elseif p == 23 then attr.italic = nil
    elseif p == 24 then attr.underline = nil
    elseif p == 27 then attr.reverse = nil
    elseif p == 29 then attr.strikethrough = nil
    elseif p >= 30 and p <= 37 then attr.fg = color256(p - 30)
    elseif p >= 90 and p <= 97 then attr.fg = color256(p - 90 + 8)
    elseif p == 39 then attr.fg = nil
    elseif p >= 40 and p <= 47 then attr.bg = color256(p - 40)
    elseif p >= 100 and p <= 107 then attr.bg = color256(p - 100 + 8)
    elseif p == 49 then attr.bg = nil
    elseif p == 38 or p == 48 then
      local key = p == 38 and "fg" or "bg"
      if params[i + 1] == 5 and params[i + 2] then
        attr[key] = color256(params[i + 2] % 256)
        i = i + 2
      elseif params[i + 1] == 2 and params[i + 4] then
        attr[key] = ("#%02x%02x%02x"):format(params[i + 2] % 256, params[i + 3] % 256, params[i + 4] % 256)
        i = i + 4
      end
    end
    i = i + 1
  end
end

local hl_cache = {}

---A highlight group for one set of attributes, defined on first use.
---
---Neovim has no faint attribute. Dim text without its own colour takes the
---Comment colour, which is how every colorscheme already says "quiet".
---@param attr table
---@return string
local function hl_for(attr)
  local fg = attr.fg
  if attr.dim and not fg then
    local c = vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg
    fg = c and ("#%06x"):format(c) or nil
  end
  local key = table.concat({
    fg or "", attr.bg or "", attr.bold and "b" or "", attr.italic and "i" or "",
    attr.underline and "u" or "", attr.reverse and "r" or "", attr.strikethrough and "s" or "",
  }, ",")
  if key == ",,,,,," then return "Normal" end
  local name = hl_cache[key]
  if not name then
    name = "SottoccAnsi" .. vim.fn.sha256(key):sub(1, 10)
    vim.api.nvim_set_hl(0, name, {
      fg = fg, bg = attr.bg, bold = attr.bold, italic = attr.italic,
      underline = attr.underline, reverse = attr.reverse, strikethrough = attr.strikethrough,
    })
    hl_cache[key] = name
  end
  return name
end

---Turn a command's stdout into virtual-line rows.
---
---SGR sequences become highlight groups, OSC sequences (hyperlinks) are
---dropped with their text kept, and every other escape is discarded.
---@param text string
---@param padding integer?
---@return { [1]: string, [2]: string }[][]
function M.parse(text, padding)
  local out = {}
  local attr = {}
  text = text:gsub("\r", ""):gsub("\n+$", "")
  if text == "" then return out end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local row = {}
    if padding and padding > 0 then row[1] = { (" "):rep(padding), "Normal" } end
    local pos = 1
    local function emit(s)
      if s ~= "" then row[#row + 1] = { s, hl_for(attr) } end
    end
    while pos <= #line do
      local esc = line:find("\27", pos, true)
      if not esc then
        emit(line:sub(pos))
        break
      end
      emit(line:sub(pos, esc - 1))
      local nxt = line:sub(esc + 1, esc + 1)
      if nxt == "[" then
        local params, final, stop = line:match("^%[([0-9;:?]*)([@-~])()", esc + 1)
        if not stop then break end
        if final == "m" then
          local list = {}
          for _, n in ipairs(vim.split(params == "" and "0" or params, "[;:]")) do
            list[#list + 1] = tonumber(n) or 0
          end
          sgr(attr, list)
        end
        pos = stop
      elseif nxt == "]" then
        -- OSC runs to BEL or to ESC \.
        local bel = line:find("\7", esc, true)
        local st = line:find("\27\\", esc + 1, true)
        local stop = (bel and st and math.min(bel + 1, st + 2)) or (bel and bel + 1) or (st and st + 2)
        if not stop then break end
        pos = stop
      else
        pos = esc + 2
      end
    end
    if #row == 0 then row[1] = { "", "Normal" } end
    out[#out + 1] = row
  end
  return out
end

--------------------------------------------------------------------- running

---The rows to draw in place of the built-in usage row, or nil to fall back:
---no command is configured, or it has not printed anything yet.
---@return { [1]: string, [2]: string }[][]?
function M.rows()
  return rows
end

local function apply(stdout)
  last_output = stdout
  local s = setting()
  rows = M.parse(stdout, s and tonumber(s.padding) or 0)
  require("sottocc.winbar").paint()
end

---Run the command now, cancelling any run still in flight.
function M.run()
  local s = setting()
  if not (s and data) then
    rows = nil
    return
  end
  if job then
    pcall(job.kill, job, 15)
    job = nil
  end
  local Window = require("sottocc.window")
  local win = Window.win_for(Window.prompt_buf)
  local env = {
    COLUMNS = tostring(win and vim.api.nvim_win_get_width(win) or vim.o.columns),
    LINES = tostring(vim.o.lines),
  }
  local ok, handle
  ok, handle = pcall(vim.system, { "sh", "-c", s.command }, {
    stdin = vim.json.encode(data),
    cwd = data.cwd,
    env = env,
    text = true,
  }, function(res)
    vim.schedule(function()
      if job ~= handle then return end -- superseded
      job = nil
      -- A killed run printed half a line at best; keep what is on screen.
      if res.signal ~= 0 then return end
      apply(res.stdout or "")
    end)
  end)
  job = ok and handle or nil
end

---Ask for a run after the debounce window.
function M.trigger()
  if not setting() then return end
  debounce = debounce or vim.uv.new_timer()
  debounce:stop()
  debounce:start(DEBOUNCE_MS, 0, vim.schedule_wrap(M.run))
end

---Begin a session: fresh payload, the refreshInterval timer, and the first run.
---@param cwd string
function M.start(cwd)
  M.stop()
  M.reset(cwd)
  local s = setting()
  if not s then return end
  local every = tonumber(s.refreshInterval)
  if every and every >= 1 then
    ticker = vim.uv.new_timer()
    ticker:start(every * 1000, every * 1000, vim.schedule_wrap(M.trigger))
  end
  M.trigger()
end

---Stop timers and any run in flight. The last rows stay on screen.
function M.stop()
  if ticker then
    ticker:stop()
    ticker:close()
    ticker = nil
  end
  if debounce then debounce:stop() end
  if job then
    pcall(job.kill, job, 15)
    job = nil
  end
end

-- Highlight groups vanish with :colorscheme; rebuild them from the raw text.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("sottocc.statusline", { clear = true }),
  callback = function()
    hl_cache = {}
    if last_output then apply(last_output) end
  end,
})

return M
