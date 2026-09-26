-- Session discovery for /resume.
--
-- The CLI refuses /resume in headless mode ("isn't available in this
-- environment") and offers no listing API, so we read the transcripts:
--   <config dir>/projects/<cwd with / and . replaced by ->/<session-id>.jsonl

local Claude = require("sottocc.claude")

local M = {}

---The transcript folder for a working directory.
---
---The CLI replaces every character outside [A-Za-z0-9] with a dash, not just
---the separators: a path under /nfs_home lands in -nfs-home. It walks the
---path character by character, so one multi-byte character becomes one dash
---rather than one per byte.
---@param cwd string
---@return string
function M.encode_cwd(cwd)
  local out = {}
  for _, ch in ipairs(vim.fn.split(cwd, "\\zs")) do
    table.insert(out, ch:match("^[A-Za-z0-9]$") and ch or "-")
  end
  return table.concat(out)
end

---The folder a working directory's transcripts are filed in.
---@param cwd string
---@return string
function M.dir(cwd)
  return Claude.projects_dir() .. "/" .. M.encode_cwd(cwd)
end

---Pull a display title out of one transcript.
---
---A transcript is worth listing when someone actually said something in it.
---Counting records instead would hide a short conversation, which is exactly
---the one a person is most likely to have just left.
---@param path string
---@return string? title, integer records
local function scan(path)
  local fd = io.open(path, "r")
  if not fd then return nil, 0 end
  local title, fallback, records = nil, nil, 0
  for line in fd:lines() do
    records = records + 1
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" then
      if rec.customTitle then title = rec.customTitle end
      if rec.aiTitle and not title then title = rec.aiTitle end
      if not fallback and rec.type == "user" then
        local c = rec.message and rec.message.content
        local text = type(c) == "string" and c or nil
        if type(c) == "table" then
          for _, b in ipairs(c) do
            if b.type == "text" then text = b.text break end
          end
        end
        -- Synthetic wrappers such as <local-command-caveat> are not prompts.
        if text and text ~= "" and not text:match("^<") then
          fallback = text:gsub("%s+", " "):sub(1, 60)
        end
      end
    end
  end
  fd:close()
  return title or fallback, records
end

---@param cwd string
---@return { id: string, title: string, mtime: integer }[]
function M.list(cwd)
  local dir = M.dir(cwd)
  if vim.fn.isdirectory(dir) == 0 then return {} end

  local out = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.jsonl$") then
      local path = dir .. "/" .. name
      local title, records = scan(path)
      if title then
        table.insert(out, {
          id = name:gsub("%.jsonl$", ""),
          title = title,
          mtime = vim.fn.getftime(path),
        })
      end
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

---The path of one session's transcript.
---@param id string
---@param cwd string
---@return string
function M.transcript(id, cwd)
  return ("%s/%s.jsonl"):format(M.dir(cwd), id)
end

---@param entry { title: string, mtime: integer }
---@return string
function M.format(entry)
  return ("%s  %s"):format(os.date("%m-%d %H:%M", entry.mtime), entry.title)
end

---Read one transcript back as render-ready events.
---
---Resuming only restores the CLI's own context: it emits nothing until the
---next prompt, so without this the buffer would sit empty and look broken.
---@param id string
---@param cwd string
---@return { kind: string, text: string?, name: string?, input: table?, id: string? }[]
function M.replay(id, cwd)
  local fd = io.open(M.transcript(id, cwd), "r")
  if not fd then return {} end

  local events = {}
  for line in fd:lines() do
    local ok, rec = pcall(vim.json.decode, line)
    local msg = ok and type(rec) == "table" and rec.message or nil
    if msg then
      local content = msg.content
      if type(content) == "string" then
        content = { { type = "text", text = content } }
      end
      for _, b in ipairs(type(content) == "table" and content or {}) do
        if rec.type == "user" and b.type == "text" then
          -- Synthetic wrappers are protocol noise, not something the user said.
          -- A transcript also repeats the same prompt across restarts and
          -- compactions, so collapse a run of identical turns into one.
          local prev = events[#events]
          local dup = prev and prev.kind == "user" and prev.text == b.text
          if not b.text:match("^<") and not dup then
            table.insert(events, { kind = "user", text = b.text })
          end
        elseif rec.type == "user" and b.type == "tool_result" then
          local c = b.content
          if type(c) == "table" then
            local parts = {}
            for _, x in ipairs(c) do table.insert(parts, x.text or "") end
            c = table.concat(parts, "\n")
          end
          table.insert(events, { kind = "tool_result", id = b.tool_use_id, text = c or "" })
        elseif rec.type == "assistant" and b.type == "text" and b.text ~= "" then
          table.insert(events, { kind = "agent", text = b.text })
        elseif rec.type == "assistant" and b.type == "tool_use" then
          table.insert(events, { kind = "tool", id = b.id, name = b.name, input = b.input or {} })
        end
      end
    end
  end
  fd:close()
  return events
end


---Pull out one line of the text a user record carries.
---@param rec table
---@return string?
local function user_text(rec)
  if rec.type ~= "user" then return nil end
  local c = rec.message and rec.message.content
  if type(c) == "string" then return c end
  if type(c) ~= "table" then return nil end
  for _, b in ipairs(c) do
    if b.type == "text" then return b.text end
  end
  return nil
end

---The prompts a rewind can return to, newest last.
---
---`record` is the index of the transcript line that carries the prompt;
---`turn` counts prompts from one, which is how snapshots are filed.
---@param id string
---@param cwd string
---@return { record: integer, turn: integer, text: string }[]
function M.user_turns(id, cwd)
  local fd = io.open(M.transcript(id, cwd), "r")
  if not fd then return {} end

  local out, idx, turn, last = {}, 0, 0, nil
  for line in fd:lines() do
    idx = idx + 1
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" then
      local text = user_text(rec)
      -- Synthetic wrappers are protocol noise, and a transcript repeats the
      -- same prompt across restarts and compactions.
      if text and text ~= "" and not text:match("^<") and text ~= last then
        turn = turn + 1
        last = text
        table.insert(out, {
          record = idx,
          turn = turn,
          text = text:gsub("%s+", " "):sub(1, 70),
        })
      end
    end
  end
  fd:close()
  return out
end

---Write the transcript up to (but not including) `record` as a new session.
---
---This is what the CLI's own rewind does when it says "the conversation will
---be forked": the original is left untouched, and `--resume` picks up the
---copy. The CLI refuses /rewind in headless mode, so we build the fork here.
---@param id string
---@param cwd string
---@param record integer 1-based transcript line to cut before
---@return string? new_id
function M.fork(id, cwd, record)
  local src = M.transcript(id, cwd)
  local fd = io.open(src, "r")
  if not fd then return nil end

  local kept = {}
  local idx = 0
  for line in fd:lines() do
    idx = idx + 1
    if idx >= record then break end
    table.insert(kept, line)
  end
  fd:close()
  if #kept == 0 then return nil end

  local new_id = Claude.uuid()
  local out = io.open(M.transcript(new_id, cwd), "w")
  if not out then return nil end
  for _, line in ipairs(kept) do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" then
      rec.sessionId = new_id
      out:write(vim.json.encode(rec) .. "\n")
    else
      out:write(line .. "\n")
    end
  end
  out:close()
  return new_id
end

return M
