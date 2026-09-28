local Claude = require("sottocc.claude")
local Config = require("sottocc.config")
local Process = require("sottocc.process")
local Window = require("sottocc.window")
local Render = require("sottocc.render")
local Picker = require("sottocc.picker")
local Session = require("sottocc.session")
local Permission = require("sottocc.permission")
local Refresh = require("sottocc.refresh")
local Snapshot = require("sottocc.snapshot")
local Slash = require("sottocc.slash")
local Winbar = require("sottocc.winbar")
local Statusline = require("sottocc.statusline")
local Context = require("sottocc.context")

local M = {}

M.proc = nil
M.cwd = nil
-- The transcript uuid of the prompt being answered, as the CLI echoes it
-- back; snapshots are filed under it so a rewind knows which copies predate
-- the point being restored.
M.prompt_uuid = nil
-- Stale snapshots are pruned once per Neovim, on the first start.
local pruned = false
-- tool_use_id -> tool name, so results know whether a refresh is due.
M.tools = {}
-- tool_use_id -> the file an edit names, handed on with the refresh.
M.tool_paths = {}
-- Agent calls running in the background, by tool_use_id. Their tool_result
-- only says the agent was launched; the report comes in task_notification.
M.background = {}
-- Set while an interrupt is in flight, so the abort it causes reads as an
-- interruption rather than as a failure.
M.interrupted = false

---The delegation tool, whose own steps arrive in this same stream tagged with
---its id. It has been called Task and is now called Agent.
---@param name string?
---@return boolean
local function is_agent(name)
  return name == "Agent" or name == "Task"
end

---The id of the Agent call a message belongs to, or nil for the main thread.
---A JSON null decodes to vim.NIL, which is truthy in Lua.
---@param msg table
---@return string?
local function parent_of(msg)
  local id = msg.parent_tool_use_id
  return type(id) == "string" and id or nil
end

M.PERMISSION_MODES = {
  "default", "manual", "acceptEdits", "plan", "auto", "bypassPermissions", "dontAsk",
}

local MODELS = {
  "default", "opus", "sonnet", "haiku", "fable", "best",
  "opus[1m]", "sonnet[1m]", "fable[1m]", "opusplan",
}

--------------------------------------------------------------------- events

---A background agent's task_notification, in the shape of the tool_result a
---foreground agent returns, so both close the same way. Only the usage: the
---summary repeats the agent's last message, already drawn among its steps.
---@param msg table
---@return string
local function background_report(msg)
  local u = type(msg.usage) == "table" and msg.usage or {}
  local usage = {}
  for _, k in ipairs({ "tool_uses", "total_tokens", "duration_ms" }) do
    if tonumber(u[k]) then
      table.insert(usage, ("%s: %d"):format(k == "total_tokens" and "subagent_tokens" or k, u[k]))
    end
  end
  return ("<usage>%s</usage>"):format(table.concat(usage, "\n"))
end

---@param msg table
local function handle(msg)
  local t = msg.type
  Statusline.observe(msg)

  if t == "system" and msg.subtype == "init" then
    Slash.available = msg.slash_commands or {}
    Winbar.state.status = nil
    M.mcp_servers = msg.mcp_servers or {}
    M.session_id = msg.session_id
    Winbar.state.mode = msg.permissionMode or Winbar.state.mode
    Winbar.paint()

  elseif t == "system" and msg.subtype == "status" then
    -- Most status events carry a plain string; keep any other shape out of
    -- the bar rather than letting it blow up the renderer.
    Winbar.state.status = type(msg.status) == "string" and msg.status or nil
    Winbar.paint()

  elseif t == "system" and msg.subtype == "task_started" then
    if msg.is_backgrounded and type(msg.tool_use_id) == "string" then
      M.background[msg.tool_use_id] = true
    end

  elseif t == "system" and msg.subtype == "task_notification" then
    local id = msg.tool_use_id
    if type(id) == "string" and M.background[id] then
      M.background[id] = nil
      local status = type(msg.status) == "string" and msg.status or "completed"
      Render.agent_done(id, background_report(msg), status ~= "completed" and status or nil)
    end

  elseif t == "system" and msg.subtype == "compact_boundary" then
    Render.notice("── compacted ──")

  elseif t == "stream_event" then
    local e = msg.event or {}
    local cb = e.content_block
    if e.type == "content_block_start" and cb and cb.type == "tool_use" then
      M.tools[cb.id] = cb.name
      Render.tool_start(cb.id, cb.name)
    end

  elseif t == "assistant" then
    -- A message from a delegated subagent carries the id of the Agent call
    -- that spawned it. Its steps belong under that call, not beside it.
    local parent = parent_of(msg)
    for _, b in ipairs((msg.message or {}).content or {}) do
      if b.type == "text" and b.text ~= "" then
        if parent then Render.nested_text(parent, b.text) else Render.agent_text(b.text) end
      elseif b.type == "tool_use" then
        M.tools[b.id] = b.name
        local input = type(b.input) == "table" and b.input or {}
        M.tool_paths[b.id] = input.file_path or input.notebook_path
        if parent then
          Render.nested_tool(parent, b.name, b.input or {})
        else
          Render.tool_confirm(b.id, b.name, b.input or {})
          if is_agent(b.name) then Render.agent_open(b.id) end
        end
      end
    end

  elseif t == "user" and msg.isReplay then
    -- Our own prompt, echoed back by --replay-user-messages. It is already
    -- on screen; what it adds is the uuid of its transcript record.
    if type(msg.uuid) == "string" then M.prompt_uuid = msg.uuid end
    if type(msg.session_id) == "string" then M.session_id = msg.session_id end

  elseif t == "user" then
    local parent = parent_of(msg)
    for _, b in ipairs((msg.message or {}).content or {}) do
      if b.type == "tool_result" then
        local content = b.content
        if type(content) == "table" then
          local parts = {}
          for _, c in ipairs(content) do table.insert(parts, c.text or "") end
          content = table.concat(parts, "\n")
        end
        content = content or ""
        local name = M.tools[b.tool_use_id]
        if parent then
          Render.nested_result(parent, content)
        elseif is_agent(name) then
          -- A background agent has only been launched; it closes later.
          if not M.background[b.tool_use_id] then Render.agent_done(b.tool_use_id, content) end
        else
          Render.tool_result(b.tool_use_id, content, b.is_error)
        end
        if name and Refresh.touches_files(name) then
          Refresh.run({ M.tool_paths[b.tool_use_id] })
        end
      end
    end

  elseif t == "control_request" then
    local req = msg.request or {}
    if req.subtype == "can_use_tool" then
      local input = req.input or {}
      -- NotebookEdit names its file notebook_path; the others, file_path.
      local path = input.file_path or input.notebook_path
      if Refresh.is_edit(req.tool_name) and path then
        Snapshot.save(M.session_id, M.prompt_uuid, path)
      end
      Permission.ask(req.tool_name, input, function(behavior)
        local body = { behavior = behavior }
        if behavior == "allow" then
          body.updatedInput = req.input
        else
          body.message = "denied in sottocc"
        end
        M.proc:write({
          type = "control_response",
          response = { subtype = "success", request_id = msg.request_id, response = body },
        })
        Render.notice(("%s %s"):format(behavior == "allow" and "allowed" or "denied", req.tool_name))
      end)
    end

  elseif t == "control_response" then
    if M.proc then M.proc:resolve_control(msg) end

  elseif t == "result" then
    Winbar.state.status = nil
    Winbar.paint()

    local aborted = msg.terminal_reason == "aborted_streaming" or M.interrupted
    M.interrupted = false
    if aborted then
      Render.notice("⏹ interrupted")
    elseif msg.is_error then
      Render.error("error: " .. tostring(msg.api_error_status or msg.subtype))
    end
  end
end

--------------------------------------------------------------------- process

---@param resume string? an existing session to continue
---@param session_id string? an id for a new session, used when resume is nil
function M.start(resume, session_id)
  if M.proc and M.proc.alive then return end
  M.cwd = vim.fn.getcwd()
  M.tools = {}
  M.tool_paths = {}
  M.background = {}
  -- The CLI names the session only once the first prompt is answered. Until
  -- then, a resume or a chosen id already says which session it is, and a
  -- fresh start has none: keeping the previous id would aim a rewind at the
  -- wrong transcript.
  M.session_id = resume or session_id
  M.prompt_uuid = nil
  if not pruned then
    pruned = true
    local days = tonumber(Claude.settings().cleanupPeriodDays) or 30
    pcall(Snapshot.prune, days)
  end
  M.interrupted = false
  -- The CLI stays silent until the first prompt, so nothing would report the
  -- mode before then. Show what we asked for and let system/init correct it.
  Winbar.state.mode = Config.options.permission_mode or "default"
  Winbar.paint()
  Statusline.start(M.cwd)
  M.proc = Process.start({
    cwd = M.cwd,
    resume = resume,
    session_id = session_id,
    -- One malformed field must not take the stream down with it: report the
    -- failure and keep reading.
    on_message = function(msg)
      local ok, err = pcall(handle, msg)
      if not ok then
        Render.error(("render failed on %s/%s: %s")
          :format(tostring(msg.type), tostring(msg.subtype), tostring(err)))
      end
    end,
    on_exit = function(code, deliberate)
      Statusline.stop()
      -- 143 is our own SIGTERM from :SottoccStop, /clear and /resume.
      if deliberate or code == 0 then return end
      Render.error(("process exited with code %d"):format(code))
    end,
  })
end

function M.stop()
  Statusline.stop()
  if M.proc then M.proc:stop() end
  M.proc = nil
end

--------------------------------------------------------------------- actions

function M.open()
  Window.open()
  if not (M.proc and M.proc.alive) then M.start() end
end

function M.toggle()
  if Window.is_open() then Window.close() else M.open() end
end

function M.submit()
  local lines = vim.api.nvim_buf_get_lines(Window.prompt_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then return end
  vim.api.nvim_buf_set_lines(Window.prompt_buf, 0, -1, false, {})

  if Slash.dispatch(M, text) then return end

  if not (M.proc and M.proc.alive) then M.start() end
  M.interrupted = false
  Render.user_message(text)
  M.proc:send_user(text)
end

function M.interrupt()
  if not (M.proc and M.proc.alive) then
    Render.notice("nothing to interrupt")
    return
  end
  M.interrupted = true
  -- Requests still queued belong to the turn being abandoned; deny them so
  -- the CLI is not left waiting and the region beside the column comes back.
  Permission.reset()
  M.proc:interrupt()
end

function M.clear()
  M.stop()
  Render.reset()
  M.start()
end

---Restart the process against an existing transcript and paint that
---transcript back into the buffer, since the CLI replays nothing itself.
---
---With `empty`, the session has no transcript yet -- a rewind to before the
---first prompt -- so the id is handed to --session-id rather than --resume.
---@param id string
---@param label string?
---@param empty boolean?
local function resume_into(id, label, empty)
  M.stop()
  Render.reset()
  if empty then M.start(nil, id) else M.start(id) end
  Render.notice(("resumed %s"):format(label or id:sub(1, 8)))
  for _, e in ipairs(empty and {} or Session.replay(id, vim.fn.getcwd())) do
    if e.kind == "user" then
      Render.user_message(e.text)
    elseif e.kind == "agent" then
      Render.agent_text(e.text)
    elseif e.kind == "tool" then
      Render.tool_start(e.id, e.name)
      Render.tool_confirm(e.id, e.name, e.input)
      M.tools[e.id] = e.name
    elseif e.kind == "tool_result" then
      Render.tool_result(e.id, e.text)
    end
  end
  Render.notice("── resumed here ──")
end

---@param _ table
---@param args string?
function M.resume(_, args)
  if args and args ~= "" then
    resume_into(args)
    return
  end
  local cwd = vim.fn.getcwd()
  local entries = Session.list(cwd)
  if #entries == 0 then
    -- Name the directory: a session started from a different one lives in a
    -- different transcript folder, which is the usual reason for an empty list.
    Render.notice(("no resumable sessions under %s"):format(cwd))
    Render.notice(("  looked in %s"):format(vim.fn.fnamemodify(Session.dir(cwd), ":~")))
    return
  end
  local items = vim.tbl_map(Session.format, entries)
  Picker.open({
    title = "resume",
    items = items,
    on_choice = function(i)
      resume_into(entries[i].id, entries[i].title)
    end,
  })
end

---Restore the conversation, and optionally the code, to just before a prompt.
---
---The CLI refuses /rewind in headless mode, but its own rewind forks the
---session rather than editing it, which is exactly what Session.fork does:
---the original transcript stays intact, so a rewind can be redone.
---@param _ table
---@param args string?
function M.rewind(_, args)
  local cwd = vim.fn.getcwd()
  local id = M.session_id
  if not id then
    Render.error("no session to rewind yet; send a prompt first")
    return
  end

  local turns = Session.user_turns(id, cwd)
  if #turns == 0 then
    Render.error("nothing to rewind to")
    return
  end

  local function do_rewind(entry, with_code)
    local restored
    if with_code then
      restored = Snapshot.restore_from(Session.uuids_from(id, cwd, entry.record))
      if #restored > 0 then Refresh.run(restored) end
    end

    -- Reported after the resume, which clears the buffer on its way in.
    local function report()
      if not restored then return end
      if #restored == 0 then
        Render.notice("no snapshots for this range; code left as it is")
        return
      end
      Render.notice(("restored %d file(s)"):format(#restored))
      for _, path in ipairs(restored) do
        Render.notice("  " .. vim.fn.fnamemodify(path, ":."))
      end
    end

    local new_id, conversation = Session.fork(id, cwd, entry.record)
    if not new_id then
      report()
      Render.error("could not fork the transcript")
      return
    end
    resume_into(new_id, ("rewound to: %s"):format(entry.text), not conversation)
    report()
  end

  local function choose(entry)
    Picker.open({
      title = "rewind: " .. entry.text,
      items = { "restore conversation", "restore conversation and code", "nevermind" },
      on_choice = function(i)
        if i == 1 then do_rewind(entry, false)
        elseif i == 2 then do_rewind(entry, true) end
      end,
    })
  end

  if args and args ~= "" then
    local n = tonumber(args)
    if n and turns[n] then choose(turns[n]) else Render.error("no such turn: " .. args) end
    return
  end

  local items = {}
  for _, t in ipairs(turns) do
    table.insert(items, ("%2d  %s"):format(t.turn, t.text))
  end
  Picker.open({
    title = "rewind to the point before",
    items = items,
    on_choice = function(i) choose(turns[i]) end,
  })
end

---@param _ table
---@param args string?
function M.model(_, args)
  if args and args ~= "" then
    if M.proc then M.proc:set_model(args) end
    Render.notice("model -> " .. args)
    return
  end
  Picker.open({
    title = "model",
    items = MODELS,
    on_choice = function(i)
      if M.proc then M.proc:set_model(MODELS[i]) end
      Render.notice("model -> " .. MODELS[i])
    end,
  })
end

---Changing the mode is the only way to stop being asked; it is never a side
---effect of answering a single prompt.
---@param mode string
function M.permission_mode(mode)
  if not (M.proc and M.proc.alive) then
    Render.error("no session running")
    return
  end
  M.proc:control({ subtype = "set_permission_mode", mode = mode })
  -- Show it straight away; the CLI echoes the authoritative value in the
  -- next system/init, which overwrites this.
  Winbar.state.mode = mode
  Winbar.paint()
  Statusline.trigger()
end

---Walk the configured ring, exactly as Shift+Tab does in the CLI.
function M.cycle_mode()
  local ring = Config.options.permission_modes
  if #ring == 0 then return end
  local at = 0
  for i, m in ipairs(ring) do
    if m == Winbar.state.mode then at = i break end
  end
  M.permission_mode(ring[at % #ring + 1])
end

function M.mcp()
  local items = {}
  for _, s in ipairs(M.mcp_servers or {}) do
    table.insert(items, ("%-12s %s"):format(s.status or "?", s.name or "?"))
  end
  if #items == 0 then items = { "(no MCP servers)" } end
  Picker.open({ title = "mcp", items = items })
end

--------------------------------------------------------------------- setup

local function buffer_keymaps()
  local k = Config.options.keymaps
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("sottocc.keys", { clear = true }),
    callback = function(ev)
      if ev.buf == Window.prompt_buf then
        vim.bo[ev.buf].omnifunc = "v:lua.require'sottocc.slash'.omnifunc"
        vim.keymap.set("n", k.submit, M.submit, { buffer = ev.buf, desc = "sottocc submit" })
        vim.keymap.set({ "n", "i" }, k.interrupt, M.interrupt, { buffer = ev.buf })
        vim.keymap.set("n", k.goto_output, function()
          local w = Window.win_for(Window.output_buf)
          if w then vim.api.nvim_set_current_win(w) end
        end, { buffer = ev.buf })
        vim.keymap.set({ "n", "i" }, k.cycle_mode, M.cycle_mode,
          { buffer = ev.buf, desc = "sottocc cycle permission mode" })
      elseif ev.buf == Window.output_buf then
        vim.keymap.set("n", k.goto_prompt, function()
          local w = Window.win_for(Window.prompt_buf)
          if w then vim.api.nvim_set_current_win(w) end
        end, { buffer = ev.buf })
        vim.keymap.set("n", k.interrupt, M.interrupt, { buffer = ev.buf })
        vim.keymap.set("n", k.cycle_mode, M.cycle_mode, { buffer = ev.buf })
        vim.keymap.set("n", k.open_file, Context.open_at_cursor,
          { buffer = ev.buf, desc = "sottocc open the file on this line" })
      end
    end,
  })
end

---@param opts table?
function M.setup(opts)
  Config.setup(opts)
  Render.setup_highlights()
  Winbar.setup_highlights()
  buffer_keymaps()
  M.configured = true
end

return M
