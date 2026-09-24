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

local M = {}

M.proc = nil
M.cwd = nil
-- Counts prompts in this session; snapshots are filed under it so a rewind
-- knows which copies predate the point being restored.
M.turn = 0
-- tool_use_id -> tool name, so results know whether a refresh is due.
M.tools = {}

local PERMISSION_MODES = {
  "default", "manual", "acceptEdits", "plan", "auto", "bypassPermissions", "dontAsk",
}

local MODELS = {
  "default", "opus", "sonnet", "haiku", "fable", "best",
  "opus[1m]", "sonnet[1m]", "fable[1m]", "opusplan",
}

--------------------------------------------------------------------- events

---@param msg table
local function handle(msg)
  local t = msg.type

  if t == "system" and msg.subtype == "init" then
    Slash.available = msg.slash_commands or {}
    Winbar.state.model = msg.model
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

  elseif t == "system" and msg.subtype == "compact_boundary" then
    Render.notice("── compacted ──")

  elseif t == "rate_limit_event" then
    local w = (msg.rate_limit_info or {}).unifiedWindows or {}
    for key in pairs({ five_hour = true, seven_day = true }) do
      local info = w[key]
      if info then
        Winbar.state[key] = { pct = (info.utilization or 0) * 100, resets_at = info.resetsAt }
      end
    end
    Winbar.paint()

  elseif t == "stream_event" then
    local e = msg.event or {}
    local cb = e.content_block
    if e.type == "content_block_start" and cb and cb.type == "tool_use" then
      M.tools[cb.id] = cb.name
      Render.tool_start(cb.id, cb.name)
    end

  elseif t == "assistant" then
    for _, b in ipairs((msg.message or {}).content or {}) do
      if b.type == "text" and b.text ~= "" then
        Render.agent_text(b.text)
      elseif b.type == "tool_use" then
        M.tools[b.id] = b.name
        Render.tool_confirm(b.id, b.name, b.input or {})
      end
    end

  elseif t == "user" then
    for _, b in ipairs((msg.message or {}).content or {}) do
      if b.type == "tool_result" then
        local content = b.content
        if type(content) == "table" then
          local parts = {}
          for _, c in ipairs(content) do table.insert(parts, c.text or "") end
          content = table.concat(parts, "\n")
        end
        Render.tool_result(b.tool_use_id, content or "", b.is_error)
        local name = M.tools[b.tool_use_id]
        if Config.options.auto_refresh and name and Refresh.is_edit(name) then
          Refresh.run()
        end
      end
    end

  elseif t == "control_request" then
    local req = msg.request or {}
    if req.subtype == "can_use_tool" then
      local input = req.input or {}
      if Refresh.is_edit(req.tool_name) and input.file_path then
        Snapshot.save(M.session_id, M.turn, input.file_path)
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
    local usage = msg.modelUsage or {}
    local main = usage[Winbar.state.model or ""] or select(2, next(usage))
    if type(main) == "table" and main.contextWindow then
      local used = (main.inputTokens or 0) + (main.outputTokens or 0)
          + (main.cacheReadInputTokens or 0) + (main.cacheCreationInputTokens or 0)
      Winbar.state.ctx = used / main.contextWindow * 100
    end
    Winbar.paint()
    if msg.is_error then
      Render.error("error: " .. tostring(msg.api_error_status or msg.subtype))
    end
  end
end

--------------------------------------------------------------------- process

---@param resume string?
function M.start(resume)
  if M.proc and M.proc.alive then return end
  M.cwd = vim.fn.getcwd()
  M.tools = {}
  M.turn = 0
  -- The CLI stays silent until the first prompt, so nothing would report the
  -- mode before then. Show what we asked for and let system/init correct it.
  Winbar.state.mode = Config.options.permission_mode or "default"
  Winbar.paint()
  M.proc = Process.start({
    cwd = M.cwd,
    resume = resume,
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
      -- 143 is our own SIGTERM from :SottoccStop, /clear and /resume.
      if deliberate or code == 0 then return end
      Render.error(("process exited with code %d"):format(code))
    end,
  })
end

function M.stop()
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
  M.turn = M.turn + 1
  Render.user_message(text)
  M.proc:send_user(text)
end

function M.interrupt()
  if M.proc and M.proc.alive then
    M.proc:interrupt()
    Render.notice("interrupt sent")
  end
end

function M.clear()
  M.stop()
  Render.reset()
  M.start()
end

---Restart the process against an existing transcript and paint that
---transcript back into the buffer, since the CLI replays nothing itself.
---@param id string
---@param label string?
local function resume_into(id, label)
  M.stop()
  Render.reset()
  M.start(id)
  Render.notice(("resumed %s"):format(label or id:sub(1, 8)))
  for _, e in ipairs(Session.replay(id, vim.fn.getcwd())) do
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
  local entries = Session.list(vim.fn.getcwd())
  if #entries == 0 then
    Render.notice("no resumable sessions for this directory")
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
    if with_code then
      local restored = Snapshot.restore_from(id, entry.turn)
      if #restored == 0 then
        Render.notice("no snapshots for this range; code left as it is")
      else
        Render.notice(("restored %d file(s)"):format(#restored))
        for _, path in ipairs(restored) do
          Render.notice("  " .. vim.fn.fnamemodify(path, ":."))
        end
        Refresh.run()
      end
    end

    local new_id = Session.fork(id, cwd, entry.record)
    if not new_id then
      Render.error("could not fork the transcript")
      return
    end
    resume_into(new_id, ("rewound to: %s"):format(entry.text))
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

  local cmd = vim.api.nvim_create_user_command
  cmd("Sottocc", M.toggle, { desc = "Toggle sottocc" })
  cmd("SottoccOpen", M.open, {})
  cmd("SottoccClose", Window.close, {})
  cmd("SottoccClear", M.clear, {})
  cmd("SottoccResume", function(a) M.resume(M, a.args) end, { nargs = "?" })
  cmd("SottoccRewind", function(a) M.rewind(M, a.args) end, { nargs = "?" })
  cmd("SottoccModel", function(a) M.model(M, a.args) end, { nargs = "?" })
  cmd("SottoccMcp", M.mcp, {})
  cmd("SottoccMode", M.cycle_mode, { desc = "Cycle the permission mode" })
  cmd("SottoccPermissionMode", function(a) M.permission_mode(a.args) end, {
    nargs = 1,
    complete = function() return PERMISSION_MODES end,
    desc = "Change the session permission mode",
  })
  cmd("SottoccStop", M.stop, {})
end

return M
