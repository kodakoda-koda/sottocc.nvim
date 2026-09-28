-- File snapshots taken just before an edit is approved, so a rewind can put
-- the code back.
--
-- Claude Code keeps its own copies under ~/.claude/file-history, but the
-- filenames there are opaque 16-hex hashes with no recoverable mapping back
-- to a path, and only edits made through its Edit/Write tools appear. We take
-- our own instead: the permission request already hands us the path.
--
-- Layout: <stdpath("data")>/sottocc/<session-id>/<prompt uuid>/<encoded path>
--
-- The prompt uuid is the transcript record the CLI echoes back for each
-- prompt, so a snapshot stays tied to its turn across restarts, and a fork --
-- which copies records with their uuids -- still finds the copies its parent
-- took.

local Claude = require("sottocc.claude")

local M = {}

M.root = vim.fn.stdpath("data") .. "/sottocc"

---@param path string
---@return string
local function encode(path)
  return (path:gsub("%%", "%%25"):gsub("/", "%%2F"))
end

---@param name string
---@return string
local function decode(name)
  return (name:gsub("%%2F", "/"):gsub("%%25", "%%"))
end

---Copy a file aside before the agent is allowed to change it.
---@param session string?
---@param uuid string? the prompt the edit belongs to
---@param path string
function M.save(session, uuid, path)
  if not session or not uuid or not path or path == "" then return end
  if vim.fn.filereadable(path) ~= 1 then return end

  local dir = ("%s/%s/%s"):format(M.root, session, uuid)
  local dest = dir .. "/" .. encode(path)
  -- The first snapshot of a turn is the one that holds the pre-edit content;
  -- later edits in the same turn must not overwrite it.
  if vim.fn.filereadable(dest) == 1 then return end

  vim.fn.mkdir(dir, "p")
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if ok then pcall(vim.fn.writefile, lines, dest, "b") end
end

---@return string[] session ids that have snapshots
local function sessions()
  local out = {}
  if vim.fn.isdirectory(M.root) ~= 1 then return out end
  for name, kind in vim.fs.dir(M.root) do
    if kind == "directory" then table.insert(out, name) end
  end
  return out
end

---Every file touched in the given turns, mapped to its earliest snapshot:
---that copy is the content as it stood before the first edit in the range.
---
---Turns are looked up under every session, since a forked session's early
---turns were snapshotted under the session it was forked from.
---@param uuids string[] prompt uuids, oldest first
---@return table<string, string> path -> snapshot file
function M.files_from(uuids)
  local found = {}
  local ids = sessions()
  for _, uuid in ipairs(uuids) do
    for _, session in ipairs(ids) do
      local dir = ("%s/%s/%s"):format(M.root, session, uuid)
      if vim.fn.isdirectory(dir) == 1 then
        for name, kind in vim.fs.dir(dir) do
          if kind == "file" then
            local path = decode(name)
            if not found[path] then found[path] = dir .. "/" .. name end
          end
        end
      end
    end
  end
  return found
end

---Put those files back on disk.
---@param uuids string[] prompt uuids, oldest first
---@return string[] restored paths
function M.restore_from(uuids)
  local restored = {}
  for path, snap in pairs(M.files_from(uuids)) do
    local ok, lines = pcall(vim.fn.readfile, snap, "b")
    if ok and pcall(vim.fn.writefile, lines, path, "b") then table.insert(restored, path) end
  end
  table.sort(restored)
  return restored
end

---Drop the snapshots of sessions the CLI would have cleaned up by now.
---
---A session counts as used when either its snapshots or its transcript
---changed, so a conversation that carries on without edits keeps them, as
---the CLI keeps its own file-history for as long as the transcript lives.
---@param days number
function M.prune(days)
  local cutoff = os.time() - days * 86400
  for _, session in ipairs(sessions()) do
    local dir = M.root .. "/" .. session
    local newest = vim.fn.getftime(dir)
    for _, t in
      ipairs(vim.fn.glob(("%s/*/%s.jsonl"):format(Claude.projects_dir(), session), false, true))
    do
      newest = math.max(newest, vim.fn.getftime(t))
    end
    if newest < cutoff then pcall(vim.fn.delete, dir, "rf") end
  end
end

return M
