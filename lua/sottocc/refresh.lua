-- After Claude edits files, reload stale buffers and refresh oil's listing.
-- This is the one thing living inside Neovim buys over a terminal wrapper.

local M = {}

local EDIT_TOOLS = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

---@param tool_name string
---@return boolean
function M.is_edit(tool_name)
  return EDIT_TOOLS[tool_name] == true
end

function M.run()
  -- Reload any buffer whose file changed on disk. Buffers with unsaved
  -- changes are left alone and Neovim warns about them.
  pcall(vim.cmd, "checktime")

  -- oil listings do not react to filesystem changes on their own; this is
  -- the <C-l> the user would otherwise press.
  local ok, actions = pcall(require, "oil.actions")
  if not ok then return end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "oil" then
      pcall(vim.api.nvim_win_call, win, function() actions.refresh.callback() end)
    end
  end
end

return M
