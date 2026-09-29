local M = {}

---@class sottocc.Config
M.defaults = {
  cmd = "claude",
  -- Extra CLI args appended after the fixed stream-json flags.
  extra_args = {},
  -- Which edge the sottocc column sits on: "right" or "left". Permission
  -- prompts cover the rest of the screen.
  position = "right",
  -- Width of the sottocc column as a fraction of the screen.
  width_ratio = 0.4,
  prompt_height = 10,
  -- Tool results longer than this are truncated with an ellipsis line. The
  -- result is folded shut anyway, so a generous cap costs no screen space.
  max_tool_result_lines = 200,
  -- File explorers to refresh after Claude changes files; only those already
  -- loaded are touched. false refreshes none, but changed buffers are still
  -- reloaded and User SottoccFilesChanged still fires.
  refresh = { "oil", "neo-tree", "nvim-tree", "mini.files" },
  -- "auto" uses vim.ui.select when a plugin has replaced it, and sottocc's
  -- own float otherwise. "vim.ui" and "builtin" force one or the other.
  picker = "auto",
  -- Slash commands handled inside Neovim. A function(core, args) adds one;
  -- false stops sottocc intercepting a command so the CLI receives it.
  slash = {},
  -- The row above the mode line. "claude" runs the statusLine command from
  -- Claude Code's settings.json and draws what it prints, or nothing when
  -- there is none. A function(data) returns chunks instead, given the same
  -- JSON the command would receive.
  statusline = "claude",
  -- Passed as --permission-mode when set, so the starting mode is known
  -- before the first turn. "default" is not a value the flag accepts; leave
  -- this nil to take the CLI's own default.
  permission_mode = nil,
  -- Shift+Tab walks this ring, matching the CLI. "default" is the state a
  -- session may start in but the CLI never cycles back into it.
  permission_modes = { "manual", "acceptEdits", "plan", "auto" },
  keymaps = {
    submit = "<CR>",
    interrupt = "<C-c>",
    goto_output = "go",
    goto_prompt = "gp",
    cycle_mode = "<S-Tab>",
    -- In the output buffer: open the file a tool line or result line names.
    open_file = "gf",
  },
}

---@type sottocc.Config
M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
