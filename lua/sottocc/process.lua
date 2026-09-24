-- Persistent `claude` subprocess speaking stream-json over stdin/stdout.
--
-- The CLI only accepts --input-format with --print, so the long-lived session
-- runs in print mode and stays alive because stdin is never closed.

local Config = require("sottocc.config")

local Process = {}
Process.__index = Process

local FIXED_ARGS = {
  "-p",
  "--input-format", "stream-json",
  "--output-format", "stream-json",
  "--include-partial-messages",
  "--verbose",
  "--permission-prompt-tool", "stdio",
}

---@param opts { cwd: string, resume: string?, on_message: fun(msg: table), on_exit: fun(code: integer, deliberate: boolean) }
---@return table?
function Process.start(opts)
  local o = Config.options
  local args = vim.list_extend(vim.deepcopy(FIXED_ARGS), o.extra_args or {})
  if o.permission_mode then
    vim.list_extend(args, { "--permission-mode", o.permission_mode })
  end
  if opts.resume then
    vim.list_extend(args, { "--resume", opts.resume })
  end

  local self = setmetatable({
    alive = false,
    -- Set before a deliberate kill so on_exit can tell SIGTERM from a crash.
    stopping = false,
    pending = {}, -- request_id -> callback
    _buf = "",
    on_message = opts.on_message,
  }, Process)

  local ok, handle = pcall(vim.system, vim.list_extend({ o.cmd }, args), {
    cwd = opts.cwd,
    stdin = true,
    stdout = function(err, data) self:_on_stdout(err, data) end,
    stderr = function(_, data)
      if data and data ~= "" then
        vim.schedule(function()
          vim.notify("sottocc: " .. data, vim.log.levels.WARN)
        end)
      end
    end,
  }, function(res)
    self.alive = false
    local deliberate = self.stopping
    vim.schedule(function() opts.on_exit(res.code, deliberate) end)
  end)

  if not ok then
    vim.notify("sottocc: failed to spawn: " .. tostring(handle), vim.log.levels.ERROR)
    return nil
  end

  self.handle = handle
  self.alive = true
  return self
end

---Split the stdout stream into NDJSON lines.
function Process:_on_stdout(err, data)
  if err then
    vim.schedule(function()
      vim.notify("sottocc: stdout error: " .. err, vim.log.levels.ERROR)
    end)
    return
  end
  if not data then return end

  self._buf = self._buf .. data
  while true do
    local nl = self._buf:find("\n", 1, true)
    if not nl then break end
    local line = self._buf:sub(1, nl - 1)
    self._buf = self._buf:sub(nl + 1)
    if line ~= "" then
      local decoded, msg = pcall(vim.json.decode, line)
      if decoded then
        vim.schedule(function() self.on_message(msg) end)
      end
    end
  end
end

---@param msg table
function Process:write(msg)
  if not self.alive then
    vim.notify("sottocc: process is not running", vim.log.levels.WARN)
    return false
  end
  self.handle:write(vim.json.encode(msg) .. "\n")
  return true
end

---@param text string
function Process:send_user(text)
  return self:write({
    type = "user",
    message = { role = "user", content = { { type = "text", text = text } } },
  })
end

local function uuid()
  return ("%s-%s"):format(os.time(), math.random(100000, 999999))
end

---@param request table body with a `subtype` field
---@param cb fun(response: table)?
function Process:control(request, cb)
  local id = uuid()
  if cb then self.pending[id] = cb end
  return self:write({ type = "control_request", request_id = id, request = request })
end

function Process:interrupt()
  return self:control({ subtype = "interrupt" })
end

---@param model string
function Process:set_model(model)
  return self:control({ subtype = "set_model", model = model })
end

---Resolve a control_response against its pending callback.
---@param msg table
function Process:resolve_control(msg)
  local cb = self.pending[msg.request_id]
  if cb then
    self.pending[msg.request_id] = nil
    cb(msg.response or {})
  end
end

function Process:stop()
  if self.handle then
    self.stopping = true
    self.alive = false
    pcall(function() self.handle:kill("sigterm") end)
  end
end

return Process
