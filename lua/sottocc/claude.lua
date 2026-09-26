-- Where Claude Code keeps its state, and what it has been told in settings.
--
-- Every path goes through config_dir(), so a CLAUDE_CONFIG_DIR set for the
-- CLI moves sottocc's reads along with it.

local M = {}

---The CLI's own directory: CLAUDE_CONFIG_DIR when set, ~/.claude otherwise.
---@return string
function M.config_dir()
  local dir = vim.env.CLAUDE_CONFIG_DIR
  if dir and dir ~= "" then
    return vim.fs.normalize(dir)
  end
  return vim.fs.normalize("~/.claude")
end

---The root the transcripts are filed under, one folder per working directory.
---@return string
function M.projects_dir()
  return M.config_dir() .. "/projects"
end

---A settings file, or an empty table when it is missing or does not parse.
---@param path string
---@return table
local function read_settings(path)
  local fd = io.open(path, "r")
  if not fd then return {} end
  local text = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, text)
  return (ok and type(decoded) == "table") and decoded or {}
end

---The user-level settings.json, or an empty table when it is missing or
---does not parse.
---@return table
function M.settings()
  return read_settings(M.config_dir() .. "/settings.json")
end

---One top-level key as the CLI resolves it: the project's local settings
---win over the project's shared ones, which win over the user's.
---@param key string
---@param cwd string
---@return any
function M.setting(key, cwd)
  for _, path in ipairs({
    cwd .. "/.claude/settings.local.json",
    cwd .. "/.claude/settings.json",
    M.config_dir() .. "/settings.json",
  }) do
    local v = read_settings(path)[key]
    if v ~= nil then return v end
  end
end

---A random version 4 UUID, in the lower-case form the CLI uses for ids.
---@return string
function M.uuid()
  local bytes = { vim.uv.random(16):byte(1, 16) }
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  local hex = {}
  for i, b in ipairs(bytes) do hex[i] = ("%02x"):format(b) end
  local s = table.concat(hex)
  return ("%s-%s-%s-%s-%s"):format(s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

return M
