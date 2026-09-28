# sottocc.nvim

Claude Code in Neovim, quietly.

Claude Code as the CLI gives it to you, with Neovim's hands: the same slash
commands, the same settings, the same look, and a conversation you scroll,
search and yank like any other buffer.

```
┌──────────────┬───────────────────────────────┐
│              │ > what changed in options?    │
│  your files, │ ⏺ Read(lua/config/options.lua)│
│  splits and  │   ⎿  1  vim.g.mapleader = " " │
│  explorer,   ├───────────────────────────────┤
│  untouched   │ type here                     │
│              │ (your statusLine output)      │
│              │ ⏸ manual mode on              │
└──────────────┴───────────────────────────────┘
```

sottocc takes one column at the edge of the screen, the right one by default:
the output buffer on top, the prompt below. Whatever you have open beside it is
left as it is.

## Why

**Not a terminal.** Running the CLI in `:terminal` means switching modes
before you can scroll, and the TUI redraws what you were reading, so there is
no going back through the conversation. Here it is an ordinary buffer:
`<C-u>`, `/`, `y`, marks and folds work as they do anywhere else, and the
prompt is a buffer of its own rather than a mode.

**Not ACP.** The Agent Client Protocol is made for any agent, so Claude Code
reaches you through an adapter, and what is Claude Code's own tends to get
lost on the way: its slash commands, its settings, its statusLine, its
sessions. sottocc drives Claude Code and nothing else. It speaks the CLI's
own stream-json over stdin and stdout, and draws the conversation itself.

**As close to the CLI as it can be.** `/resume` opens a picker, `<S-Tab>`
walks the permission modes, and your `statusLine` command draws the status
row, as they do in the CLI. What the CLI refuses without a terminal, sottocc
does for it.

**Quiet.** Claude Code's glyphs and nothing more: `⏺` for a turn, `⎿` for a
tool result, foreground colour only, no emoji, no icons, no borders. Tool
results fold away, and thinking is not shown.

**Your layout stays yours.** Your files, splits and file explorer keep the
rest of the screen. A permission diff floats over them and leaves them
exactly as they were.

## Requirements

- Neovim 0.10+
- `claude` in `$PATH`, already logged in

`:checkhealth sottocc` checks both.

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

The commands exist without `setup()`; `opts` only changes the defaults.
`:help sottocc` lists every command, option and highlight group.

## Keys

| Key | Where | Action |
|---|---|---|
| `<CR>` (normal mode) | prompt | Send |
| `<C-x><C-o>` | prompt | Complete a slash command |
| `<C-c>` | prompt, output | Interrupt the current turn |
| `<S-Tab>` | prompt, output | Cycle the permission mode |
| `go` | prompt | Jump to the output buffer |
| `gp` | output | Jump to the prompt buffer |
| `gf` | output | Open the file on this line |

Insert mode `<CR>` inserts a newline, as it should. From anywhere else,
`:SottoccInterrupt` stops the turn. The session stays open for the next
prompt either way.

## Output

Tool results are folded shut, as they are in the CLI: the `⎿` line stays, with
a count of what is behind it. They are ordinary folds, so `za`, `zo`, `zR` and
`zM` work, and `/` still finds text inside a closed one.

Markdown tables are redrawn with aligned, box-drawn columns, measured by
display width so CJK cells line up. Thinking is not shown.

A delegated subagent collapses to two lines, as it does in the CLI:

```
⏺ Agent(Run ls and wc)
  ⎿  Done (1 tool use · 16.4k tokens · 8.0s)  (+27 lines)
```

Until it finishes, the second line reads `running…`, including for a subagent
the CLI runs in the background. Its own steps and its hand-back report are
inside that fold, so `zo` still shows everything the subagent did.

## Files

After an edit or a Bash command, changed buffers are reloaded and any loaded
file explorer is refreshed: oil, neo-tree, nvim-tree and mini.files. Then
`User SottoccFilesChanged` fires, for anything else that wants to know.

`gf` in the output buffer opens the file a tool line names, beside the column:
a `Read` at the line it read from, an `Edit` at the text it wrote. A result
line that is a path, with or without `:line`, opens that path.

`:SottoccAdd` puts the current file into the prompt as `@path`, and
`:'<,'>SottoccAdd` the selected lines as `@path#L10-20`. The CLI attaches
them itself, so Claude reads only those lines.

## Slash commands

Type them in the prompt. Everything the CLI advertises passes straight
through, including `/compact`, `/context` and commands from plugins. Completion
comes from the list the CLI sends at startup.

Two are handled here instead, because the CLI refuses them in headless mode:

- `/resume`: pick an earlier session; its transcript is replayed into the
  buffer, since the CLI replays nothing itself
- `/rewind`: pick a prompt to return to, then restore the conversation, or
  the conversation and the code

`/clear`, `/model` and `/mcp` are also intercepted, to get a picker rather
than a round-trip in the transcript. The `slash` option adds commands of your
own, or hands these back to the CLI.

## Status line

The row above the permission mode is your own `statusLine` command from
Claude Code's `settings.json`, run the way the CLI runs it: the session as
JSON on stdin, its output drawn with its ANSI colours. It reruns after each
assistant message, result and rate-limit update, and every `refreshInterval`
seconds.

The JSON is rebuilt from the stream, so fields the stream does not carry are
missing or zero: `cost.total_lines_*`, `pr`, `prompt_cache`, `session_name`.

Without a `statusLine` setting the row is left out. A function in its place
gets the same JSON and returns chunks:

```lua
statusline = function(data)
  return { { data.model.display_name, "Title" } }
end
```

## Permissions

A permission request floats over everything beside the column, never the
column itself. Splits already open there are not closed or resized; the prompt
sits on top, and closing it leaves the layout exactly as it was.

Edits show as a `before | after` diff across that whole region, half each.
Everything else shows its input in one pane. Answer with `y`, or deny with
`n`, `q` or `<Esc>`.

Several tools in one turn queue up and are asked one at a time, with the
number still waiting shown beside the tool name.

There is deliberately no "always allow": the suggestion the CLI sends with a
request switches the whole session to `acceptEdits`, which is a decision worth
making on purpose. Use `<S-Tab>` or `:SottoccPermissionMode` for that.

## Rewind

Restoring the conversation forks the transcript and resumes the copy. The
original session is left intact, as the CLI's own rewind leaves it.

Restoring the code uses snapshots this plugin takes just before each edit is
approved, under `stdpath("data")/sottocc/`. Turns from before you opened the
session here have no snapshots, and the conversation is restored alone.

## Configuration

```lua
opts = {
  cmd = "claude",
  extra_args = {},              -- appended to the CLI's arguments
  position = "right",           -- or "left"
  width_ratio = 0.4,
  prompt_height = 10,
  max_tool_result_lines = 200,
  refresh = { "oil", "neo-tree", "nvim-tree", "mini.files" },  -- or false
  picker = "auto",              -- "auto", "vim.ui" or "builtin"
  statusline = "claude",        -- "claude" or function(data) return chunks end
  slash = {},                   -- { name = function(core, args) end } adds, { clear = false } passes through
  permission_mode = nil,        -- passed as --permission-mode when set
  permission_modes = { "manual", "acceptEdits", "plan", "auto" },  -- the <S-Tab> ring
  keymaps = {
    submit = "<CR>",
    interrupt = "<C-c>",
    goto_output = "go",
    goto_prompt = "gp",
    cycle_mode = "<S-Tab>",
    open_file = "gf",
  },
}
```

`picker = "auto"` uses `vim.ui.select` when telescope, fzf-lua, snacks or the
like has replaced it, and a small float of its own otherwise.

## Development

```sh
make test     # play tests/fixtures/*.ndjson and compare with tests/expected/
make update   # rewrite tests/expected/ from the current rendering
```

The fixtures are streams recorded from the real CLI. Code is formatted with
[StyLua](https://github.com/JohnnyMorganz/StyLua).

## Status

Early. It does what the author uses it for.

## License

MIT
