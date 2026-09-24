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

Insert mode `<CR>` inserts a newline, as it should.

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

## Permissions

A permission request takes over the window to the left of the column, never
the column itself. Edits show as a `before | after` diff; everything else
shows its input. Answer with `y` or `n`, and the left window goes back to
whatever it was holding.

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
  width_ratio = 0.4,
  prompt_height = 10,
  max_tool_result_lines = 30,
  show_thinking = false,
  auto_refresh = true,          -- reload buffers and oil after an edit
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
