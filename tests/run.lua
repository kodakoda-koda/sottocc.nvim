-- nvim --headless -u NONE -l tests/run.lua
--
-- Each tests/fixtures/<name>.ndjson is a stream recorded from the real CLI.
-- It is played through the whole plugin, process included, and the output
-- buffer is compared with tests/expected/<name>.txt. UPDATE=1 rewrites the
-- expected files instead.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
-- No user settings: no statusLine command, no cleanupPeriodDays.
vim.env.CLAUDE_CONFIG_DIR = vim.fn.tempname()
vim.o.columns, vim.o.lines = 200, 50
vim.cmd("runtime plugin/sottocc.lua")

local core = require("sottocc")
core.setup({ cmd = root .. "/tests/bin/fake-claude" })
local Window = require("sottocc.window")

local failures = 0
local function fail(name, msg)
  failures = failures + 1
  io.stdout:write(("FAIL %s\n%s\n"):format(name, msg))
end

---The output buffer, one line per row, each led by its fold level so a
---change in what folds away shows up too.
local function snapshot()
  local win = Window.win_for(Window.output_buf)
  local out = {}
  vim.api.nvim_win_call(win, function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      table.insert(out, ("%d|%s"):format(vim.fn.foldlevel(i), l))
    end
  end)
  return table.concat(out, "\n") .. "\n"
end

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

--------------------------------------------------------------- fixtures

for _, fixture in ipairs(vim.fn.glob(root .. "/tests/fixtures/*.ndjson", false, true)) do
  local name = vim.fn.fnamemodify(fixture, ":t:r")
  vim.env.SOTTOCC_FIXTURE = fixture
  core.clear()
  core.open()
  vim.wait(5000, function()
    return core.proc and not core.proc.alive
  end, 10)
  -- Messages are handed over on the main loop; let the last of them land.
  vim.wait(100)

  local got = snapshot()
  local path = ("%s/tests/expected/%s.txt"):format(root, name)
  if vim.env.UPDATE == "1" then
    local f = assert(io.open(path, "w"))
    f:write(got)
    f:close()
    io.stdout:write(("wrote %s\n"):format(path))
  else
    local want = read(path)
    if not want then
      fail(name, "no expected file; run with UPDATE=1")
    elseif want ~= got then
      fail(name, vim.diff(want, got, { ctxlen = 2 }))
    else
      io.stdout:write(("ok   %s\n"):format(name))
    end
  end
  core.stop()
end

--------------------------------------------------------------- units

local function eq(name, want, got)
  if vim.deep_equal(want, got) then
    io.stdout:write(("ok   %s\n"):format(name))
  else
    fail(name, ("want %s\n got %s"):format(vim.inspect(want), vim.inspect(got)))
  end
end

local Context = require("sottocc.context")
core.cwd = "/work"
eq("mention a file", "@lua/a.lua", Context.mention("/work/lua/a.lua"))
eq("mention a range", "@lua/a.lua#L3-9", Context.mention("/work/lua/a.lua", 3, 9))
eq("mention one line", "@a.lua#L3", Context.mention("/work/a.lua", 3, 3))
eq("mention outside", "@/etc/hosts", Context.mention("/etc/hosts"))
eq("mention spaces", '@"a b.txt#L4"', Context.mention("/work/a b.txt", 4, 4))

local Statusline = require("sottocc.statusline")
eq("display name", "Haiku 4.5", Statusline.display_name("claude-haiku-4-5-20251001"))
local rows = Statusline.parse("\27[2mdim\27[0m plain\n\nsecond\n", 0)
eq("parse rows", 3, #rows)
eq(
  "parse text",
  "dim plain",
  table.concat(vim.tbl_map(function(c)
    return c[1]
  end, rows[1]))
)

io.stdout:write(failures == 0 and "all passed\n" or ("%d failed\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
