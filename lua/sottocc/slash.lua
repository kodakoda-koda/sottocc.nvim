-- One dispatch table for slash commands typed in the prompt buffer.
--
-- Three behaviours:
--   local       handled here, never sent to the CLI
--   observed    sent to the CLI, but we react to what comes back
--   passthrough sent as-is (the other ~60 commands the CLI advertises)
--
-- The CLI refuses /resume and /rewind in headless mode; the rest are
-- intercepted because a Neovim UI beats a round-trip in the transcript.

--
-- The user's `slash` option layers on top: a function adds a local command,
-- and false drops a local one so the text goes to the CLI instead.

local Config = require("sottocc.config")

local M = {}

-- Advertised by system/init; used for completion.
M.available = {}

---@param core table the sottocc module
---@return table<string, { kind: string, fn: fun(core: table, args: string)? }>
local function table_for(core)
  local t = {
    resume = { kind = "local", fn = core.resume },
    rewind = { kind = "local", fn = core.rewind },
    clear = { kind = "local", fn = core.clear },
    model = { kind = "local", fn = core.model },
    mcp = { kind = "local", fn = core.mcp },
    compact = { kind = "observed" },
  }
  for name, v in pairs(Config.options.slash or {}) do
    if v == false then
      t[name] = nil
    elseif type(v) == "function" then
      t[name] = { kind = "local", fn = v }
    end
  end
  return t
end

---Decide what to do with a submitted prompt.
---@param core table
---@param text string
---@return boolean handled true when the text must not be sent to the CLI
function M.dispatch(core, text)
  -- Only a single line that is nothing but a command counts. A multi-line
  -- prompt that happens to start with "/" is speech, not an instruction.
  if text:find("\n") then return false end
  local cmd, args = text:match("^%s*/([%w:_-]+)%s*(.-)%s*$")
  if not cmd then return false end

  local entry = table_for(core)[cmd]
  if not entry or entry.kind ~= "local" then return false end

  entry.fn(core, args)
  return true
end

---Completion candidates for "/" in the prompt buffer.
---@return string[]
function M.candidates()
  local seen, out = {}, {}
  for name in pairs(table_for(require("sottocc"))) do
    seen[name] = true
    table.insert(out, "/" .. name)
  end
  for _, name in ipairs(M.available) do
    if not seen[name] then table.insert(out, "/" .. name) end
  end
  table.sort(out)
  return out
end

---omnifunc for the prompt buffer.
function M.omnifunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  if findstart == 1 then
    local col = vim.fn.col(".") - 1
    local start = line:sub(1, col):find("/[%w:_-]*$")
    return start and (start - 1) or -1
  end
  local out = {}
  for _, c in ipairs(M.candidates()) do
    if c:find(base, 1, true) == 1 then table.insert(out, c) end
  end
  return out
end

return M
