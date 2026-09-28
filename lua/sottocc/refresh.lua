-- After Claude changes files, reload stale buffers, refresh file explorers,
-- and tell anyone else who is listening.
-- This is the one thing living inside Neovim buys over a terminal wrapper.

local Config = require("sottocc.config")

local M = {}

local EDIT_TOOLS = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

---@param tool_name string
---@return boolean
function M.is_edit(tool_name)
  return EDIT_TOOLS[tool_name] == true
end

---Whether a tool can change the filesystem. Bash can move, delete and
---rewrite anything, but says nothing about which paths it touched.
---@param tool_name string
---@return boolean
function M.touches_files(tool_name)
  return M.is_edit(tool_name) or tool_name == "Bash"
end

---Windows in this tab showing a buffer of the given filetype.
---@param ft string
---@return { win: integer, buf: integer }[]
local function windows_of(ft)
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == ft then table.insert(out, { win = win, buf = buf }) end
  end
  return out
end

-- One refresher per explorer. Each only acts when its plugin is already
-- loaded: requiring it here would make lazy.nvim load an explorer nobody
-- opened. oil and mini.files are edited like buffers, and refreshing one with
-- unsaved edits would throw them away or stop to ask, so those are skipped.
local ADAPTERS = {
  oil = function()
    if not package.loaded["oil"] then return end
    local ok, actions = pcall(require, "oil.actions")
    if not ok then return end
    for _, w in ipairs(windows_of("oil")) do
      if not vim.bo[w.buf].modified then
        pcall(vim.api.nvim_win_call, w.win, function()
          actions.refresh.callback()
        end)
      end
    end
  end,

  ["neo-tree"] = function()
    if not package.loaded["neo-tree"] then return end
    local ok, manager = pcall(require, "neo-tree.sources.manager")
    if ok then pcall(manager.refresh, "filesystem") end
  end,

  ["nvim-tree"] = function()
    if not package.loaded["nvim-tree"] then return end
    local ok, api = pcall(require, "nvim-tree.api")
    if ok then pcall(api.tree.reload) end
  end,

  ["mini.files"] = function()
    local mf = rawget(_G, "MiniFiles")
    if type(mf) ~= "table" then return end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "minifiles" and vim.bo[buf].modified then return end
    end
    -- With nothing edited, synchronize only re-reads the filesystem.
    pcall(mf.synchronize)
  end,
}

---@param paths string[]? files known to have changed; empty after Bash
function M.run(paths)
  -- Reload any buffer whose file changed on disk. Buffers with unsaved
  -- changes are left alone and Neovim warns about them.
  pcall(vim.cmd, "checktime")

  local list = Config.options.refresh
  if type(list) == "table" then
    for _, name in ipairs(list) do
      local adapter = ADAPTERS[name]
      if adapter then adapter() end
    end
  end

  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "SottoccFilesChanged",
    data = { paths = paths or {} },
  })
end

return M
