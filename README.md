# nvim-touragent

Let Claude Code (or any MCP-capable agent) drive your Neovim in real time.

- **Code tours**: the agent walks you through how the code works. nvim jumps to each step,
  highlights the lines that matter and shows the explanation in a side panel. You move at
  your own pace, and you can ask a question about any line without leaving the editor.
- **Change walkthroughs**: the agent edits code and shows each change inline as it lands
  (added lines green, removed lines red). It waits for your go-ahead before the next edit.
  Comment on a line ("use the existing helper here") and it adjusts.

```
[claude / opencode] ──MCP stdio──▶ nvim -l mcp/server.lua ──msgpack-RPC──▶ [your nvim + touragent]
        ▲                                                                   timeline · panel · marks
        └──────────── tmux send-keys (kickoff / comments while idle) ◀──────────────┘
```

All Lua, with no runtime dependencies beyond Neovim itself. The MCP server is a headless
`nvim -l` process.

## Requirements

- Neovim **0.12+**
- An MCP-capable agent: Claude Code, opencode, …
- Optional: tmux, for kickoff and comment delivery from nvim to the agent pane.

## Install

### Neovim side

```lua
vim.pack.add({
  -- pin to 0.1.x releases (git tags); drop `version` to track main
  { src = 'https://github.com/Elyg/nvim-touragent', version = vim.version.range('0.1') },
})
-- optional; zero-config defaults work without it
require('touragent').setup({})
```

`:lua vim.pack.update()` moves to the newest tag in the range. While the repo is private, use
the SSH URL (`src = 'git@github.com:Elyg/nvim-touragent'`) so git uses your key. For
development, `just dev` starts nvim with the local checkout on `runtimepath`.

### Claude Code (MCP server + snapshot hook + `/tour` & `/walkthrough` skills)

The repo is also a Claude Code plugin marketplace:

```
/plugin marketplace add Elyg/nvim-touragent      # or a local path: ~/gits/nvim-touragent
/plugin install touragent@touragent
```

Or register just the MCP server by hand:

```sh
claude mcp add touragent -- nvim -l /path/to/nvim-touragent/mcp/server.lua
```

### opencode

`opencode.json`:

```json
{
  "mcp": {
    "touragent": {
      "type": "local",
      "command": ["nvim", "-l", "/path/to/nvim-touragent/mcp/server.lua"],
      "enabled": true
    }
  }
}
```

opencode doesn't load Claude skills, so a short instruction is enough: *"use the touragent
tools to walk me through …"*. The MCP server's `instructions` describe the protocol.

## How linking works

Every nvim running the plugin registers itself in `$XDG_RUNTIME_DIR/touragent/<pid>.json`
with its socket, cwd, git root and tmux location. When the agent starts, the MCP server links
to one nvim, choosing the first match in this order:

1. `TOURAGENT_NVIM=/path/to/socket`, an explicit override
2. `$NVIM`, when the agent runs inside a nvim `:terminal`
3. The registry: the nvim with the same git root, preferring the one in the same tmux
   window. This is the usual setup, with the agent in one tmux pane and nvim in another.
4. If several nvims match equally well, the agent calls `list_sessions` and then
   `link_session(pid)`.

If nvim starts (or restarts) after the agent, the server notices within ~2 s and links on
its own. To link by hand, or to switch to another nvim, run `/touragent:connect` in Claude
Code.

Only one agent can be linked to an nvim at a time. `:TourLink` shows the link status.

## Using it

Ask the agent in its own terminal ("give me a tour of how requests are routed"), or start
from nvim: `<leader>aa`, or select lines and press `<leader>aa`, types the question into the
agent's tmux pane.

| Key | Command | |
|---|---|---|
| `<leader>aa` | `:TourAsk` | Ask the agent about the cursor line or selection (tmux push) |
| `<leader>an` / `<leader>ap` | `:TourNext` / `:TourPrev` | Next / previous step. Next past the end tells the agent to continue. |
| `<leader>ac` | `:TourComment` | Comment on a line or selection, which the agent receives as feedback |
| `<leader>ab` | `:TourBtw` | btw: ask a side question (not about specific lines), answered in the panel |
| `<leader>ao` | `:TourAgent [args]` | Start the agent (`claude`) in a tmux pane next to nvim (or a `:terminal`), linked to this nvim; focuses it if already running |
| `<leader>ar` | `:TourResume[!]` | Reopen a saved tour or walkthrough where you left off (`!` = all projects) |
| `<leader>aw` | `:TourWake` | Wake the agent now: more steps while you keep reading, or "continue the tour" if it's idle |
| `<leader>ag` | `:TourGo` | Jump back to the current step |
| `<leader>at` | `:TourPanel` | Toggle the tour panel |
| `<leader>af` | `:TourFollow` | Toggle follow mode (auto-jump to new steps) |
| `<leader>aq` | `:TourStop` | Tell the agent to stop |
| | `:TourReload` | Take the agent's version of a file you had unsaved edits in |
| | `:TourDiff` | Cumulative diff vs HEAD (diffview.nvim if installed) |
| | `:TourExport [file]` | Export the timeline and comment threads as markdown |
| | `:TourNote` | Show the current step's note in a float |
| | `:TourClear` | Clear the timeline |

Inside the panel: `n` next · `p` prev · `c` comment · `b` btw · `w` wake · `Enter` jump · `q` stop.

The panel header and status line show what the agent is doing: **waiting for you** (a tour
call is blocked on you), **working** (with a live timer), **idle**, or **disconnected**.

**Follow mode never steals focus while you're typing.** If you're in insert mode or typed in
the last 3 seconds, the new step is announced instead (`▶ step 4 ready`), and `<leader>ag`
takes you there. You can add `require('touragent').statusline()` to your statusline.

**Your unsaved edits are never overwritten.** If the agent edits a file you have unsaved
changes in, that step is flagged ⚠ and the agent is told. You then either `:w` your version
or run `:TourReload` to take the agent's.

## Configuration

```lua
require('touragent').setup({
  follow = true,          -- auto-jump to new steps
  idle_ms = 3000,         -- "typing recently" window for follow mode
  panel = { width = 60, auto_open = true, style = 'native' }, -- 'markdown' = raw md for render-markdown
  agent = { cmd = 'claude', size = '45%' }, -- :TourAgent command + tmux pane size
  tmux_push = true,       -- deliver :TourAsk and idle-time comments to the agent's tmux pane
  persist = true,         -- autosave tours for :TourResume (stdpath('state')/touragent/tours)
  highlights = {},        -- colour overrides, see Highlights below
  messages = 'panel',     -- info messages in the panel's status line ('notify' = always vim.notify)
  ask_template = 'Use touragent to walk me through {loc} in nvim. {question}',
  keys = { ask = '<leader>aa', next = '<leader>an', prev = '<leader>ap', comment = '<leader>ac',
           go = '<leader>ag', panel = '<leader>at', follow = '<leader>af', stop = '<leader>aq',
           btw = '<leader>ab', wake = '<leader>aw', resume = '<leader>ar' },
  -- keys = false disables all global mappings; set any single key to false to skip it
  panel_keys = { next = 'n', prev = 'p', comment = 'c', stop = 'q', go = '<CR>', btw = 'b', wake = 'w' },
})
```

Highlight groups, all linked by default: `TourAgentRange`, `TourAgentSign`, `TourAgentTag`,
`TourAgentAdd`, `TourAgentDelete`, `TourAgentConflict`, `TourAgentComment`.

MCP server environment variables:

- `TOURAGENT_WAIT_TIMEOUT` (seconds, default 600): after this long, a blocking call returns
  `timeout` and the agent calls `timeline_wait` again.
- `TOURAGENT_NVIM`: force a socket.
- `TOURAGENT_LOG`: path to a debug log.

Run `:checkhealth touragent` to diagnose setup problems.

## Highlights

Every colour links to a standard group, so it follows your colorscheme. Override any of them
with `setup({ highlights = { … } })`. The overrides are re-applied on every `:colorscheme`.
A table is an `nvim_set_hl` spec; a string links to another group.

```lua
require('touragent').setup({
  highlights = {
    TourAgentRange = { bg = '#2a2f3a' }, -- step range background
    TourAgentTag = 'Visual',             -- link to another group
  },
})
```

| Group | Used for | Default link |
|---|---|---|
| `TourAgentRange` | background of the current step's lines | `CursorLine` |
| `TourAgentTag` / `TourAgentSign` | the `◆ 3/7 · title` tag / sign column marker | `DiagnosticVirtualTextInfo` / `DiagnosticInfo` |
| `TourAgentComment` | `✎ #1` comment tags | `DiagnosticVirtualTextHint` |
| `TourAgentConflict` | ⚠ unsaved-edits warning | `DiagnosticVirtualTextWarn` |
| `TourAgentAdd` / `TourAgentDelete` | inline diff lines | `DiffAdd` / `DiffDelete` |
| `TourAgentTitle` / `TourAgentHeading` / `TourAgentSection` | panel headings | `@markup.heading.1/2/3` |
| `TourAgentStrong` / `TourAgentEmph` / `TourAgentCode` / `TourAgentLink` | panel inline text | `@markup.strong/italic/raw/link` |
| `TourAgentCodeBlock` | panel code block background | `CursorLine` |
| `TourAgentYou` / `TourAgentAgent` / `TourAgentWarn` | comment thread bars | `DiagnosticInfo` / `DiagnosticOk` / `DiagnosticWarn` |
| `TourAgentCurrent` / `TourAgentDone` | timeline: current step / visited ✓ | `Title` / `DiagnosticOk` |
| `TourAgentKey` / `TourAgentMuted` | key hints / secondary text | `Special` / `Comment` |
| `TourAgentStateWaiting` / `TourAgentStateWorking` / `TourAgentStateOff` | agent state | `DiagnosticWarn` / `DiagnosticInfo` / `DiagnosticError` |

## MCP tools

| Tool | |
|---|---|
| `status` | Current file, cursor, visible range, last visual selection, buffers, timeline |
| `list_sessions` / `link_session` | Linking fallback |
| `timeline_new(title, mode)` | Start a fresh tour (`tour`) or change walkthrough (`changes`) |
| `timeline_push(steps, wait)` | Append steps. With `wait` it blocks until the user presses next, comments or stops. |
| `timeline_wait` | Block again, for example after a timeout |
| `reply(comment_id, markdown, wait)` | Answer an nvim comment. The reply renders as a thread in the panel. |
| `get_feedback` | Drain queued comments. Every result also carries `pending_user_messages`. |
| `lsp(kind, file, line, symbol?)` | definition / references / hover / symbols / incoming & outgoing calls … |
| `diagnostics(file?)` | Current diagnostics |

## Development

```sh
direnv allow            # or: nix develop
just test               # unit + integration (headless nvim + real MCP server over stdio)
just lint               # stylua --check, selene, plugin manifest validation
just dev                # nvim with this checkout on the runtimepath
just release            # tag vX.Y.(Z+1) and push → GitHub release
```

Versions come from git tags only. `lua/touragent/version.lua` holds the wire
`PROTOCOL_VERSION`, which is checked when the server links, because the Claude plugin cache
and the nvim pack directory can drift apart.

## License

MIT
