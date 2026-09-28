-- Commands exist from startup, with or without setup(). Each one loads the
-- plugin only when run, and runs setup() with the defaults if nothing has.

if vim.g.loaded_sottocc then return end
vim.g.loaded_sottocc = true

local function core()
  local m = require("sottocc")
  if not m.configured then m.setup() end
  return m
end

local cmd = vim.api.nvim_create_user_command

cmd("Sottocc", function() core().toggle() end, { desc = "Toggle sottocc" })
cmd("SottoccOpen", function() core().open() end, {})
cmd("SottoccClose", function() core(); require("sottocc.window").close() end, {})
cmd("SottoccClear", function() core().clear() end, {})
cmd("SottoccStop", function() core().stop() end, {})
cmd("SottoccInterrupt", function() core().interrupt() end, { desc = "Stop the turn in progress" })
cmd("SottoccResume", function(a) local m = core(); m.resume(m, a.args) end, { nargs = "?" })
cmd("SottoccRewind", function(a) local m = core(); m.rewind(m, a.args) end, { nargs = "?" })
cmd("SottoccModel", function(a) local m = core(); m.model(m, a.args) end, { nargs = "?" })
cmd("SottoccMcp", function() core().mcp() end, {})
cmd("SottoccMode", function() core().cycle_mode() end, { desc = "Cycle the permission mode" })
cmd("SottoccPermissionMode", function(a) core().permission_mode(a.args) end, {
  nargs = 1,
  complete = function() return require("sottocc").PERMISSION_MODES end,
  desc = "Change the session permission mode",
})
cmd("SottoccAdd", function(a)
  core()
  local Context = require("sottocc.context")
  if a.range > 0 then Context.add(a.line1, a.line2) else Context.add() end
end, { range = true, desc = "Mention this file, or the selected lines, in the prompt" })
