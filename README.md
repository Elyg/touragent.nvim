# touragent.nvim

Let Claude Code, or any agent that speaks MCP, drive your Neovim in real time. The agent
**gives you code tours**: it jumps through the code and explains it step by step in a side
panel. It also **walks you through its edits** as it makes them. You read at your own pace
and steer with comments on specific lines, without leaving the editor.

## What it looks like

### Code tour

The agent jumps nvim to each step and highlights the lines that matter. The explanation, a
timeline and your conversation with the agent sit in a panel on the right:

```
┌─ lua/touragent/store.lua ─────────────────────────┬─ touragent ─────────────────────────────────┐
│ 12                                                │ Saved tours: autosave → :TourResume          │
│ 13  --- Directory for the current project's tours.│ claude-code · ⏸ waiting for you              │
│▎14  function M.dir()             ◆ 4/6 · Where …  │                                              │
│▎15    local root = require('touragent.timeline')… │ ✓ 1. Every tour gets an id                   │
│▎16    local name = vim.fs.basename(root)…  ✎ #1   │ ✓ 2. schedule(): save, but not too often     │
│▎17    return vim.fn.stdpath('state') .. …         │ ✓ 3. snapshot() + save()                     │
│▎18  end                                           │ ▶ 4. Where the files live                    │
│ 19                                                │ · 5. :TourResume → picker                    │
│ 20  --- A fresh id for a new tour …               │ · 6. load(): rebuild the tour                │
│ 21  function M.new_id()                           │ ──────────────────────────────────────────── │
│                                                   │ Step 4/6 · Where the files live              │
│                                                   │ lua/touragent/store.lua:14-18                │
│                                                   │                                              │
│                                                   │ Tours are grouped per project:               │
│                                                   │   ~/.local/state/nvim/touragent/tours/…      │
│                                                   │ The folder name is the project folder's      │
│                                                   │ name plus the first 8 characters of its      │
│                                                   │ path's sha256, so two projects called `api`  │
│                                                   │ don't share tours.                           │
│                                                   │                                              │
│                                                   │ Comments                                     │
│                                                   │ ▍ you · #1 · lua/touragent/store.lua:16      │
│                                                   │ ▍ why not the full path?                     │
│                                                   │ ▍ claude-code                                │
│                                                   │ ▍ It has to be a single folder name; a hash  │
│                                                   │ ▍ keeps it short and filesystem-safe.        │
│                                                   │                                              │
│                                                   │ n next · p prev · Enter jump to code · q stop│
│                                                   │ c comment · b btw · w wake agent             │
│                                                   │ ◆ 4/6  ⏸ waiting for you   comment #1 sent   │
└───────────────────────────────────────────────────┴──────────────────────────────────────────────┘
```

- **Code window:** the step's lines are highlighted, with a `◆ 4/6 · title` tag. A `✎ #1`
  tag marks a line you commented on.
- **Timeline:** pinned at the top of the panel. It shows up to 6 steps and scrolls to keep
  the current one (`▶`) in view. Visited steps get a green `✓`.
- **Explanation:** plain text with the markdown markup hidden. Code blocks and inline code
  get treesitter syntax colours in the toured file's language.
- **Threads:** your comments and the agent's replies, as coloured bars.
- **Status line:** shows what the agent is doing: ⏸ **waiting for you**, ⠋ **working 12s**
  or ○ **idle**. The latest message appears on the right, instead of a notification popup.

### Change walkthrough

The agent makes one edit at a time. nvim reloads the file and shows the diff inline, then
waits for your go-ahead or a comment before the next edit:

```
 40 │ local function notify(msg, level)
    │   vim.notify('[touragent] ' .. msg, level or vim.log.levels.INFO)   ← removed (red)
 41 │   require('touragent.util').notify(msg, level)                      ← added (green)  ◆ 2/5 · Route messages
 42 │ end
```

If you have unsaved edits in that file, the agent's change is **not** loaded over them. The
step is flagged ⚠ and the agent is told.

## Requirements

- Neovim **0.12+**
- An MCP-capable agent: Claude Code, opencode, …
- Optional: **tmux**. With the agent in a tmux pane, nvim can type into it: kick off a tour
  from nvim, or send comments while the agent isn't waiting on you. Everything else works
  without tmux (see [How it works](#how-it-works)).

## Installation

### 1. Neovim plugin

With `vim.pack` (Neovim 0.12):

```lua
vim.pack.add({
  -- pin to 0.1.x releases (git tags); drop `version` to track main
  { src = 'https://github.com/Elyg/touragent.nvim', version = vim.version.range('0.1') },
})
-- optional: the defaults work without it
require('touragent').setup({})
```

`:lua vim.pack.update()` moves to the newest tag in the range. For a private fork, use the
SSH URL (`src = 'git@github.com:Elyg/touragent.nvim'`) so git uses your key.

### 2. Claude Code plugin

The repo is also a Claude Code plugin marketplace. The plugin bundles the MCP server, the
snapshot hook and the `/touragent:tour`, `/touragent:walkthrough` and `/touragent:connect`
skills:

```
/plugin marketplace add Elyg/touragent.nvim
/plugin install touragent@touragent
```

Update later with `/plugin marketplace update touragent`, then `/reload-plugins`.

To register only the MCP server, without the skills or the hook:

```sh
claude mcp add touragent -- nvim -l /path/to/touragent.nvim/mcp/server.lua
```

### opencode

In `opencode.json`:

```json
{
  "mcp": {
    "touragent": {
      "type": "local",
      "command": ["nvim", "-l", "/path/to/touragent.nvim/mcp/server.lua"],
      "enabled": true
    }
  }
}
```

opencode doesn't load Claude skills, so a short instruction is enough: *"use the touragent
tools to walk me through …"*. The MCP server's instructions teach the agent the rest.

## Quick start

1. Open nvim in your project.
2. Start the agent next to it: `<leader>ao` (`:TourAgent`) opens `claude` in a tmux pane,
   or a `:terminal` split outside tmux, already linked to this nvim. Or start `claude`
   yourself in another pane: it finds your nvim on its own.
3. Ask for a tour, either in the agent (*"give me a tour of how requests are routed"*,
   `/touragent:tour src/router.ts`), or from nvim: select some lines and press
   `<leader>aa`.
4. Read at your own pace with `n` / `p` in the panel. Press `c` to comment on the current
   step, or select lines in the code and press `<leader>ac`. Press `b` for a side
   question.
5. For edits, ask for a walkthrough: *"walk me through renaming X to Y"* or
   `/touragent:walkthrough`.

Tours save automatically. `<leader>ar` reopens one later where you left off.

## Commands and keys

| Key | Command | What it does |
|---|---|---|
| `<leader>ao` | `:TourAgent [args]` | Start the agent next to nvim, linked to it. Focuses it if it's already running. Extra args go to the agent (`:TourAgent --continue`). |
| `<leader>aa` | `:TourAsk` | Ask the agent about the cursor line or selection: types the question into its tmux pane (clipboard fallback). |
| `<leader>an` / `<leader>ap` | `:TourNext` / `:TourPrev` | Next / previous step. Next past the last step tells the agent to continue. |
| `<leader>ac` | `:TourComment` | Comment on the cursor line or selection. The agent gets the file, range, selected code and your text. |
| `<leader>ab` | `:TourBtw` | btw: a side question not tied to any lines, answered in the panel's btw section. |
| `<leader>aw` | `:TourWake` | Wake the agent now: it queues more steps while you keep reading, or continues the tour if it's idle. |
| `<leader>ar` | `:TourResume[!]` | Reopen a saved tour or walkthrough where you left off. `!` lists every project. |
| `<leader>ag` | `:TourGo` | Jump back to the current step. |
| `<leader>at` | `:TourPanel` | Toggle the tour panel. |
| `<leader>af` | `:TourFollow` | Toggle follow mode (auto-jump to new steps). |
| `<leader>aq` | `:TourStop` | Tell the agent to stop. |
| | `:TourReload` | Take the agent's version of a file you had unsaved edits in. |
| | `:TourDiff` | Cumulative diff against HEAD (diffview.nvim if installed). |
| | `:TourExport [file]` | Export the timeline and comment threads as markdown. |
| | `:TourNote` | Show the current step's note in a float (when the panel is closed). |
| | `:TourLink` | Show the link status. |
| | `:TourClear` | Clear the timeline. |

**Inside the panel:** `n` next · `p` prev · `c` comment · `b` btw · `w` wake · `Enter` jump
to code · `q` stop.

**In the comment box:** `Ctrl-s` (or `Enter` in normal mode) sends; `q` / `Esc` cancels.

**Claude Code skills:**
- **`/touragent:tour [topic|path|symbol]`:** a code tour.
- **`/touragent:walkthrough`:** a live edit walkthrough, or a review of existing changes.
- **`/touragent:connect`:** link to (or switch to) an nvim by hand.

**Behaviour to know:**
- **Follow mode never steals focus while you type.** If you're in insert mode, or typed in
  the last 3 s, a new step is announced (`▶ step 4 ready`) instead of jumping. `<leader>ag`
  takes you there.
- **Your unsaved edits are never overwritten.** Save to keep yours, or `:TourReload` to
  take the agent's.
- **Statusline component:** `require('touragent').statusline()` gives `◆ 3/7 · your turn`
  for your own statusline.

## Configuration

All options with their defaults:

```lua
require('touragent').setup({
  follow = true,           -- auto-jump to new steps (:TourFollow toggles)
  idle_ms = 3000,          -- "typed recently" window: don't steal focus within it
  panel = {
    width = 60,
    auto_open = true,      -- open the panel when the first step arrives
    style = 'native',      -- 'markdown' = raw markdown buffer, for render-markdown & co.
    timeline_max = 6,      -- timeline rows shown at once
  },
  agent = { cmd = 'claude', size = '45%' }, -- :TourAgent command + tmux pane width
  tmux_push = true,        -- type :TourAsk and idle-time comments into the agent's pane
  ask_template = 'Use touragent to walk me through {loc} in nvim. {question}',
  persist = true,          -- autosave tours for :TourResume
  messages = 'panel',      -- info messages in the panel status line ('notify' = vim.notify)
  highlights = {},         -- colour overrides, see Highlights
  keys = {                 -- global keys; false disables all, or set one to false
    ask = '<leader>aa', next = '<leader>an', prev = '<leader>ap', comment = '<leader>ac',
    btw = '<leader>ab', wake = '<leader>aw', resume = '<leader>ar', agent = '<leader>ao',
    go = '<leader>ag', panel = '<leader>at', follow = '<leader>af', stop = '<leader>aq',
  },
  panel_keys = { next = 'n', prev = 'p', comment = 'c', btw = 'b', wake = 'w', go = '<CR>', stop = 'q' },
})
```

`ask_template` placeholders: `{loc}` is `file:range`, `{question}` is what you typed. Use,
for example, `'/touragent:tour {loc} {question}'` to call the skill explicitly.

**MCP server environment variables:**
- **`TOURAGENT_NVIM`:** link to this nvim socket, skipping the automatic matching.
- **`TOURAGENT_WAIT_TIMEOUT`** (seconds, default 600): how long a blocking call waits
  before returning `timeout`. The agent then calls `timeline_wait` again.
- **`TOURAGENT_RELINK_MS`** (default 2000): how often an unlinked server looks for nvim.
- **`TOURAGENT_LOG`:** path to a debug log.

### Highlights

Every colour links to a standard group, so it follows your colorscheme. Override any group
with `setup({ highlights = { … } })`. The overrides are re-applied on every
`:colorscheme`. A table is an `nvim_set_hl` spec; a string links to another group.

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
| `TourAgentCurrent` / `TourAgentCurrentLine` | timeline: current step text / its row background | `DiagnosticWarn` / `CursorLine` |
| `TourAgentDone` | timeline: visited ✓ | `DiagnosticOk` |
| `TourAgentKey` / `TourAgentMuted` | key hints / secondary text | `Special` / `Comment` |
| `TourAgentRule` | divider under the timeline | `WinSeparator` |
| `TourAgentStateWaiting` / `TourAgentStateWorking` / `TourAgentStateOff` | agent state | `DiagnosticWarn` / `DiagnosticInfo` / `DiagnosticError` |

## MCP tools

These are what the agent calls. You don't call them yourself; they're listed here for
anyone wiring up another agent.

| Tool | |
|---|---|
| `status` | Current file, cursor, visible range, last visual selection, buffers, timeline (with step titles) |
| `list_sessions` / `link_session(pid)` | Find and link an nvim by hand |
| `timeline_new(title, mode)` | Start a fresh tour (`tour`) or change walkthrough (`changes`) |
| `timeline_push(steps, wait)` | Append steps. With `wait`, blocks until the user presses next, comments or stops. |
| `timeline_wait` | Block again, for example after a timeout |
| `reply(comment_id, markdown, wait)` | Answer a comment. The reply shows as a thread in the panel. |
| `get_feedback` | Drain queued comments. Every result also carries `pending_user_messages`. |
| `lsp(kind, file, line, symbol?)` | definition / references / hover / symbols / incoming & outgoing calls … |
| `diagnostics(file?)` | Current diagnostics |

## Troubleshooting

- **`:checkhealth touragent`** checks the nvim version, the registry, tmux, the link and
  the snapshot hook.
- **Not linked** (the panel says *no agent linked*): wait ~2 s after starting the agent, or
  run `/touragent:connect` in Claude Code. `:TourLink` shows what nvim sees.
- **Several nvims open on the same project, outside tmux:** the server won't guess. Use
  `/touragent:connect`, or start the agent with `<leader>ao`, which links to the nvim it was
  started from.
- **Agent keeps timing out on a long read:** that's expected. It calls `timeline_wait` and
  carries on; raise `TOURAGENT_WAIT_TIMEOUT` if you prefer.

## Development

```sh
direnv allow            # or: nix develop
just test               # unit + integration (headless nvim + real MCP server over stdio)
just lint               # stylua --check, selene, plugin manifest validation
just dev                # nvim with this checkout first on the runtimepath
just release            # tag vX.Y.(Z+1) and push → GitHub release
```

Versions come from git tags only. `lua/touragent/version.lua` holds the wire
`PROTOCOL_VERSION`, which is checked when the server links, because the Claude plugin cache
and the nvim pack directory can drift apart.

## License

MIT

## How it works

```
[claude / opencode] ──MCP stdio──▶ nvim -l mcp/server.lua ──msgpack-RPC──▶ [your nvim + touragent]
        ▲                                                                   timeline · panel · marks
        └──────────── tmux send-keys (kickoff / comments while idle) ◀──────────────┘
```

**All Lua, no runtime dependencies beyond Neovim.** The MCP server is a second, headless
nvim (`nvim -l mcp/server.lua`). It speaks MCP over stdio and calls into your nvim over its
RPC socket with `nvim_exec_lua` → `require('touragent.rpc').dispatch(...)`. That's a small,
fixed API: there are no editing tools and no arbitrary code execution.

### Linking

Every nvim running the plugin registers itself in `$XDG_RUNTIME_DIR/touragent/<pid>.json`,
with its socket, cwd, git root and tmux location. The server picks the first match in this
order:

1. `TOURAGENT_NVIM=/path/to/socket`, an explicit override (`:TourAgent` sets it).
2. `$NVIM`, when the agent runs inside an nvim `:terminal`.
3. The registry: the nvim with the same git root, preferring the one in the agent's tmux
   window.
4. If several match equally well, nothing is guessed: `list_sessions` + `link_session`, or
   `/touragent:connect`.

The server links as soon as the agent starts. While it isn't linked, it keeps checking
every 2 s, so an nvim that starts or restarts later is picked up on its own. On link, the
server and plugin compare `PROTOCOL_VERSION` and warn on a mismatch. Only one agent is
linked to an nvim at a time.

### Blocking checkpoints

Each tool call runs in a coroutine on the server. A call that waits for you
(`timeline_push` with `wait`, `timeline_wait`, `reply` with `wait`) yields instead of
blocking, so the server keeps serving other calls, pings and cancellations. Your nvim never
blocks either. It records a waiter token, and when you act (next at the end, a comment,
stop, wake) it sends the result back with `rpcnotify`. Long waits send MCP progress
notifications, so the client doesn't give up, and return `timeout` after 10 minutes.

**Feedback is never lost:**
- **The agent is waiting:** your comment answers the waiting call immediately.
- **The agent is idle, in tmux:** the comment is typed into its pane.
- **Otherwise:** the comment is queued, and every tool result carries
  `pending_user_messages`.

The panel's agent state follows the same signals: *waiting* while a call is blocked on you,
*working* for 90 s after any call, *idle* after that.

### Change steps

The agent edits files with its own tools. The `PreToolUse` hook (`hooks/snapshot.lua`)
copies each file before the edit to `$XDG_RUNTIME_DIR/touragent/snapshots/`. When a
`change` step arrives, the plugin reloads the buffer and diffs it against the first
available baseline:

1. the buffer's lines before the reload
2. the hook snapshot
3. the previous step's version
4. the git index
5. an empty file

`vim.text.diff` hunks become green added lines and red virtual lines for removed ones, and
set the step's range. A buffer with unsaved edits is never reloaded; the step is flagged
instead.

### Panel rendering

The panel is built as markdown and drawn natively: markup is hidden, text is wrapped by the
plugin with hanging indents, and callouts become coloured bars. Code blocks, and inline
code that parses in the toured file's language, get treesitter captures as extmarks, so
they use your colorscheme's syntax colours. The timeline and key hints are pre-styled rows.
With `panel.style = 'markdown'`, the raw markdown is shown instead.

### Saved tours

The timeline, your position and the comment threads are saved as JSON after every change
(300 ms debounce, and on exit). They go in
`stdpath('state')/touragent/tours/<project>-<hash>/`, and the newest 30 per project are
kept. `:TourResume` rebuilds the tour and marks old comments as delivered. The `status`
tool reports the step titles, so a newly linked agent can continue the tour.
