-- :checkhealth sottocc

local M = {}

---Run the CLI and return its stdout, or nil and why not.
---@param args string[]
---@return string?, string?
local function run(args)
  local ok, res = pcall(function() return vim.system(args, { text = true }):wait(10000) end)
  if not ok then return nil, tostring(res) end
  if res.code ~= 0 and (res.stdout or "") == "" then
    return nil, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("exit " .. res.code)
  end
  return res.stdout
end

function M.check()
  local h = vim.health
  local Config = require("sottocc.config")

  h.start("Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok(tostring(vim.version()))
  else
    h.error("Neovim 0.10 or newer is required")
  end

  h.start("Claude Code CLI")
  local exe = Config.options.cmd
  if vim.fn.executable(exe) == 0 then
    h.error(("`%s` is not executable"):format(exe), { "Install Claude Code, or set `cmd` to its path" })
    return
  end
  local version, err = run({ exe, "--version" })
  if version then h.ok(vim.trim(version)) else h.error("--version failed: " .. err) end

  -- The email is left out: a health report is often pasted into issues.
  local out, aerr = run({ exe, "auth", "status", "--json" })
  local ok, status = pcall(vim.json.decode, out or "")
  if not (ok and type(status) == "table") then
    h.warn("could not read `auth status`: " .. tostring(aerr or out))
  elseif status.loggedIn then
    local how = { status.authMethod, status.subscriptionType }
    h.ok(("logged in (%s)"):format(table.concat(vim.tbl_filter(function(v)
      return type(v) == "string"
    end, how), ", ")))
  else
    h.error("not logged in", { ("Run `%s auth login` in a terminal"):format(exe) })
  end

  h.start("Status line")
  if type(Config.options.statusline) == "function" then
    h.ok("drawn by the `statusline` function")
  elseif require("sottocc.statusline").setting() then
    h.ok("runs the statusLine command from Claude Code's settings")
  else
    h.info("no statusLine command in Claude Code's settings; the row is left out")
  end
end

return M
