# sottocc.nvim

Claude Code in Neovim, quietly.

The conversation is an ordinary Neovim buffer, so `<C-u>`, `/`, `y`, marks and
folds all work as they do anywhere else. The prompt is a second buffer, not a
mode. The rendering keeps to Claude Code's own vocabulary — `⏺` for a turn,
`⎿` for a tool result, two highlight groups, no emoji, no borders.

No ACP bridge and no PTY: the plugin speaks stream-json to the `claude` CLI
over stdin and stdout, and draws the conversation itself.

```
┌─────────┬──────────────────────────────┐
│         │ > what changed in options?    │
│  oil    │ ⏺ Read(lua/config/options.lua)│
│         │   ⎿  1  vim.g.mapleader = " " │
│         ├──────────────────────────────┤
│         │ type here                     │
│         │ ctx [██░░░░░░░░] 21%  5h …     │
│         │ ⏸ manual mode on              │
└─────────┴──────────────────────────────┘
```

## Requirements

- Neovim 0.10+
- `claude` in `$PATH`, already logged in

## Install

```lua
{
  "kodakoda-koda/sottocc.nvim",
  opts = {},
  keys = {
    { "<leader>ss", "<cmd>Sottocc<cr>",       desc = "Toggle sottocc" },
    { "<leader>sr", "<cmd>SottoccResume<cr>", desc = "Resume a session" },
    { "<leader>sw", "<cmd>SottoccRewind<cr>", desc = "Rewind" },
  },
}
```

## Keys

Inside the prompt buffer:

| Key | Action |
|---|---|
| `<CR>` (normal mode) | Send |
| `<C-c>` | Interrupt the current turn |
| `<S-Tab>` | Cycle the permission mode |
| `go` / `gp` | Jump to the output / prompt buffer |

Insert mode `<CR>` inserts a newline, as it should. `<C-c>` is bound in both
buffers; from anywhere else, `:SottoccInterrupt` does the same. The turn ends
and the session stays open for the next prompt.

## Output

Tool results are folded shut, as they are in the CLI: the `⎿` line stays, with
a count of what is behind it. They are ordinary folds, so `za`, `zo`, `zR` and
`zM` work, and `/` still finds text inside a closed one.

Markdown tables are redrawn with aligned, box-drawn columns, measured by
display width so CJK cells line up.

A delegated subagent collapses to two lines, as it does in the CLI:

```
⏺ Agent(Run ls and wc)
  ⎿  Done (1 tool use · 16.4k tokens · 8.0s)  (+27 lines)
```

Its own steps and its hand-back report are inside that fold, so `zo` still
shows everything the subagent did.

## Slash commands

Type them in the prompt. Everything the CLI advertises passes straight
through, including `/compact`, `/context` and plugin commands such as
`/precheck`. Completion comes from the list the CLI sends at startup.

Two are handled here instead, because the CLI refuses them in headless mode:

- `/resume` — pick an earlier session; its transcript is replayed into the
  buffer, since the CLI replays nothing itself
- `/rewind` — pick a prompt to return to, then restore the conversation, or
  the conversation and the code

`/clear`, `/model` and `/mcp` are also intercepted, to get a picker rather
than a round-trip in the transcript.

## Status line

The row above the permission mode is your own `statusLine` command from
Claude Code's `settings.json`, run the way the CLI runs it: the session as
JSON on stdin, its output drawn with its ANSI colours. It reruns after each
assistant message, result and rate-limit update, and every `refreshInterval`
seconds.

The JSON is rebuilt from the stream, so fields the stream does not carry are
missing or zero: `cost.total_lines_*`, `pr`, `prompt_cache`, `session_name`.

Without a `statusLine` setting the row is left out. `statusline = "builtin"`
draws sottocc's own context and rate-limit bars instead. A function gets the
same JSON and returns chunks:

```lua
statusline = function(data)
  return { { data.model.display_name, "Title" } }
end
```

## Permissions

A permission request floats over everything left of the column, never the
column itself. Splits already open there are not closed or resized; the prompt
sits on top, and closing it leaves the layout exactly as it was.

Edits show as a `before | after` diff across that whole region, half each.
Everything else shows its input in one pane. Answer with `y` or `n`.

Several tools in one turn queue up and are asked one at a time, with the
number still waiting shown beside the tool name.

There is deliberately no "always allow": the suggestion the CLI sends with a
request switches the whole session to `acceptEdits`, which is a decision worth
making on purpose. Use `:SottoccPermissionMode` or `<S-Tab>` for that.

## Rewind

Restoring the conversation forks the transcript — the original session is left
intact, exactly as the CLI's own rewind does — and resumes the copy.

Restoring the code uses snapshots this plugin takes just before each edit is
approved, under `stdpath("data")/sottocc/`. Turns from before you opened the
session here have no snapshots, and the conversation is restored alone.

## Configuration

```lua
opts = {
  cmd = "claude",
  extra_args = {},
  position = "right",           -- or "left"
  width_ratio = 0.4,
  prompt_height = 10,
  max_tool_result_lines = 200,
  show_thinking = false,
  refresh = { "oil", "neo-tree", "nvim-tree", "mini.files" },  -- explorers to refresh after a change
  picker = "auto",              -- "auto", "vim.ui" or "builtin"
  statusline = "claude",        -- "claude", "builtin" or function(data) return chunks end
  slash = {},                   -- { name = function(core, args) end } adds, { clear = false } passes through
  permission_mode = nil,        -- passed as --permission-mode when set
  permission_modes = { "manual", "acceptEdits", "plan", "auto" },
  keymaps = {
    submit = "<CR>",
    interrupt = "<C-c>",
    goto_output = "go",
    goto_prompt = "gp",
    cycle_mode = "<S-Tab>",
  },
}
```

## Status

Early. It does what the author uses it for.
