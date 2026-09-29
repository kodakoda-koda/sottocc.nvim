-- nvim --headless -u NONE -l tests/run.lua
--
-- Each tests/fixtures/<name>.ndjson is a stream recorded from the real CLI
-- (tests/record.sh). It is played through the whole plugin, process
-- included, and the output buffer is compared with tests/expected/<name>.txt.
-- UPDATE=1 rewrites the expected files instead. CHECKS then looks at what
-- the buffer alone does not show, and the unit tests follow.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
-- No user settings: no statusLine command, no cleanupPeriodDays.
vim.env.CLAUDE_CONFIG_DIR = vim.fn.tempname()
vim.o.columns, vim.o.lines = 200, 50
-- Without a UI the first window keeps its 80 columns until told otherwise,
-- and the column would leave no room beside it for a permission prompt.
vim.cmd("wincmd =")
vim.cmd("runtime plugin/sottocc.lua")

local FAKE = root .. "/tests/bin/fake-claude"
local core = require("sottocc")
core.setup({ cmd = FAKE })
local Config = require("sottocc.config")
local Context = require("sottocc.context")
local Process = require("sottocc.process")
local Window = require("sottocc.window")

local failures = 0
local function fail(name, msg)
  failures = failures + 1
  io.stdout:write(("FAIL %s\n%s\n"):format(name, msg))
end

local function eq(name, want, got)
  if vim.deep_equal(want, got) then
    io.stdout:write(("ok   %s\n"):format(name))
  else
    fail(name, ("want %s\n got %s"):format(vim.inspect(want), vim.inspect(got)))
  end
end

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
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

--------------------------------------------------------------- capture

-- Everything the plugin sends to the CLI. The fake CLI has exited by the time
-- a permission prompt is answered, so the real write would drop the answer.
local written = {}
Process.write = function(_, msg)
  table.insert(written, msg)
  return true
end

-- Every User SottoccFilesChanged, by its data.paths.
local changed = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "SottoccFilesChanged",
  callback = function(ev)
    table.insert(changed, ev.data.paths)
  end,
})

---@return integer
local function floats()
  local n = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then n = n + 1 end
  end
  return n
end

---Where `gf` goes from the first output line that starts with `prefix`.
---@param prefix string
local function target_on(prefix)
  local win = Window.win_for(Window.output_buf)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(Window.output_buf, 0, -1, false)) do
    if l:sub(1, #prefix) == prefix then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      return Context.target_at_cursor()
    end
  end
  return "no line starts with " .. prefix
end

---The first message of a type in a fixture.
---@param fixture string
---@param type string
---@return table?
local function first_of(fixture, type)
  for line in io.lines(fixture) do
    local msg = vim.json.decode(line)
    if msg.type == type then return msg end
  end
end

--------------------------------------------------------------- checks

local NOTES = "/private/tmp/sotrec/notes.txt"

---@type table<string, fun(fixture: string)>
local CHECKS = {
  tools = function()
    -- Bash changed something, but cannot say what.
    eq("tools: files changed after Bash", { {} }, changed)
  end,

  edit = function()
    eq("edit: files changed after Edit", { { NOTES } }, changed)
    eq("edit: gf on Read", { path = NOTES }, target_on("⏺ Read("))
    eq("edit: gf on Edit", { path = NOTES, find = "ALPHA" }, target_on("⏺ Edit("))
  end,

  permission = function(fixture)
    eq("permission: diff floats", 2, floats())
    local req = first_of(fixture, "control_request")
    vim.api.nvim_feedkeys("y", "x", false)
    eq("permission: allow sent", {
      type = "control_response",
      response = {
        subtype = "success",
        request_id = req.request_id,
        response = { behavior = "allow", updatedInput = req.request.input },
      },
    }, written[#written])
    vim.wait(100)
    eq("permission: floats closed", 0, floats())
  end,
}

--------------------------------------------------------------- fixtures

for _, fixture in ipairs(vim.fn.glob(root .. "/tests/fixtures/*.ndjson", false, true)) do
  local name = vim.fn.fnamemodify(fixture, ":t:r")
  vim.env.SOTTOCC_FIXTURE = fixture
  written, changed = {}, {}
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
  if CHECKS[name] then CHECKS[name](fixture) end
  core.stop()
end

--------------------------------------------------------------- units

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

-- Slash commands: which ones sottocc takes, and which go to the CLI.
local Slash = require("sottocc.slash")
local calls = {}
local fake = setmetatable({}, {
  __index = function(_, k)
    return function(_, a)
      table.insert(calls, { k, a })
    end
  end,
})
local function dispatch(slash, text)
  Config.setup({ cmd = FAKE, slash = slash })
  calls = {}
  return Slash.dispatch(fake, text), calls
end
eq("slash /resume is ours", { true, { { "resume", "abc" } } }, { dispatch({}, "/resume abc") })
eq("slash /compact goes to the CLI", { false, {} }, { dispatch({}, "/compact") })
eq("slash /review goes to the CLI", { false, {} }, { dispatch({}, "/review") })
eq("slash only as a whole prompt", { false, {} }, { dispatch({}, "hello\n/resume") })
eq("slash handed back", { false, {} }, { dispatch({ clear = false }, "/clear") })
local got
dispatch({
  hello = function(c, a)
    got = { c == fake, a }
  end,
}, "/hello x")
eq("slash of your own", { true, "x" }, got)
Config.setup({ cmd = FAKE })

-- Transcripts: listing, turns, replay and fork, on tests/data/transcript.jsonl.
local Session = require("sottocc.session")
local dir = Session.dir("/work")
vim.fn.mkdir(dir, "p")
vim.fn.writefile(vim.fn.readfile(root .. "/tests/data/transcript.jsonl"), dir .. "/s.jsonl")

local list = Session.list("/work")
eq("transcript list", { { id = "s", title = "first prompt" } }, {
  list[1] and { id = list[1].id, title = list[1].title },
})
eq("transcript turns", {
  { record = 2, turn = 1, text = "first prompt" },
  { record = 5, turn = 2, text = "second prompt" },
}, Session.user_turns("s", "/work"))
eq("transcript uuids from a turn", { "u3", "u4", "u5" }, Session.uuids_from("s", "/work", 5))
eq(
  "transcript replay",
  { "user", "agent", "user", "tool", "tool_result", "user" },
  vim.tbl_map(function(e)
    return e.kind
  end, Session.replay("s", "/work"))
)

local new_id, conversation = Session.fork("s", "/work", 5)
local forked = vim.fn.readfile(Session.transcript(new_id, "/work"))
eq("fork keeps the turns before", { true, 4 }, { conversation, #forked })
eq(
  "fork renames the session",
  { new_id, new_id, new_id, new_id },
  vim.tbl_map(function(l)
    return vim.json.decode(l).sessionId
  end, forked)
)
local empty_id, empty_conversation = Session.fork("s", "/work", 2)
eq(
  "fork before the first prompt writes nothing",
  { false, 0 },
  { empty_conversation, vim.fn.filereadable(Session.transcript(empty_id, "/work")) }
)

-- Tool lines drawn one at a time into an empty output buffer.
local Render = require("sottocc.render")

---Draw one tool call and return its line.
---@param id string
---@param name string
---@param input table
---@return string
local function tool_line(id, name, input)
  Render.reset()
  Render.tool_start(id, name)
  Render.tool_confirm(id, name, input)
  local lines = vim.api.nvim_buf_get_lines(Window.output_buf, 0, -1, false)
  return lines[#lines]
end

local function valid_utf8(s)
  local i = 1
  while i <= #s do
    local c = s:byte(i)
    local n = c < 0x80 and 0 or c >= 0xF0 and 3 or c >= 0xE0 and 2 or c >= 0xC0 and 1 or -1
    if n < 0 then return false end
    for k = 1, n do
      local b = s:byte(i + k)
      if not b or b < 0x80 or b > 0xBF then return false end
    end
    i = i + n + 1
  end
  return true
end

local long = tool_line("u1", "Agent", { description = ("あいうえお"):rep(30) })
eq("long header stays UTF-8", { true, "…" }, { valid_utf8(long), long:sub(-#"…") })

eq(
  "NotebookEdit header names the notebook",
  "⏺ NotebookEdit(/work/n.ipynb)",
  tool_line("u2", "NotebookEdit", { notebook_path = "/work/n.ipynb" })
)

tool_line("u3", "mcp__srv_a-b__read", { file_path = "/work/a.lua" })
eq("gf on an MCP tool with a hyphen", { path = "/work/a.lua" }, target_on("⏺ mcp__"))

local far = "/work/" .. ("x"):rep(200) .. ".lua"
tool_line("u4", "Read", { file_path = far })
eq("gf on a header cut short", { path = far }, target_on("⏺ Read("))

io.stdout:write(failures == 0 and "all passed\n" or ("%d failed\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
