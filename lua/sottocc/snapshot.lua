-- File snapshots taken just before an edit is approved, so a rewind can put
-- the code back.
--
-- Claude Code keeps its own copies under ~/.claude/file-history, but the
-- filenames there are opaque 16-hex hashes with no recoverable mapping back
-- to a path, and only edits made through its Edit/Write tools appear. We take
-- our own instead: the permission request already hands us the path.
--
-- Layout: <stdpath("data")>/sottocc/<session-id>/<turn>/<encoded path>

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

---@param session string
---@param turn integer
---@return string
local function turn_dir(session, turn)
  return ("%s/%s/%d"):format(M.root, session, turn)
end

---Copy a file aside before the agent is allowed to change it.
---@param session string?
---@param turn integer
---@param path string
function M.save(session, turn, path)
  if not session or not path or path == "" then return end
  if vim.fn.filereadable(path) ~= 1 then return end

  local dir = turn_dir(session, turn)
  local dest = dir .. "/" .. encode(path)
  -- The first snapshot of a turn is the one that holds the pre-edit content;
  -- later edits in the same turn must not overwrite it.
  if vim.fn.filereadable(dest) == 1 then return end

  vim.fn.mkdir(dir, "p")
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if ok then pcall(vim.fn.writefile, lines, dest, "b") end
end

---Every file that was touched at or after `turn`, mapped to the earliest
---snapshot taken from `turn` onwards: that copy is the content as it stood
---before the first edit in the range.
---@param session string?
---@param turn integer
---@return table<string, string> path -> snapshot file
function M.files_from(session, turn)
  local found = {}
  if not session then return found end
  local base = ("%s/%s"):format(M.root, session)
  if vim.fn.isdirectory(base) ~= 1 then return found end

  local turns = {}
  for name, kind in vim.fs.dir(base) do
    local n = tonumber(name)
    if kind == "directory" and n and n >= turn then
      table.insert(turns, n)
    end
  end
  table.sort(turns)

  for _, n in ipairs(turns) do
    local dir = turn_dir(session, n)
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" then
        local path = decode(name)
        if not found[path] then found[path] = dir .. "/" .. name end
      end
    end
  end
  return found
end

---Put those files back on disk.
---@param session string?
---@param turn integer
---@return string[] restored paths
function M.restore_from(session, turn)
  local restored = {}
  for path, snap in pairs(M.files_from(session, turn)) do
    local ok, lines = pcall(vim.fn.readfile, snap, "b")
    if ok and pcall(vim.fn.writefile, lines, path, "b") then
      table.insert(restored, path)
    end
  end
  table.sort(restored)
  return restored
end

---Drop a session's snapshots.
---@param session string?
function M.clear(session)
  if not session then return end
  pcall(vim.fn.delete, ("%s/%s"):format(M.root, session), "rf")
end

return M
