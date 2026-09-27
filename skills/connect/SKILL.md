---
name: connect
description: Connect (link) this agent to the user's running Neovim via the touragent MCP tools — pick the right nvim instance and link to it. Use when the user asks to connect/link to nvim, when touragent says no nvim is linked or linking is ambiguous, or when the user switched to or restarted another nvim.
---

# Connect to the user's Neovim

touragent normally links on its own (and re-links within a few seconds when nvim starts or
restarts). Use this when that didn't happen, or when the user wants a different nvim.

## Procedure

1. Call `list_sessions`. Each entry has `pid`, `cwd`, `git_root`, `tmux` (session, window,
   pane), `match_score` (higher = better match for this agent's project and tmux window) and
   `linked`.
2. Choose the target:
   - If the user named one (pid, project, "the one in window 3"), use it.
   - Otherwise take the highest `match_score`. Prefer the same tmux window as the agent.
   - If two or more are tied and nothing distinguishes them, ask the user which one
     (show pid, cwd and tmux window for each) instead of guessing.
   - No sessions at all → nvim isn't running the plugin: suggest opening nvim in the
     project (or `:checkhealth touragent`), and stop.
3. Call `link_session(pid)`.
4. Confirm in one line: which nvim (pid, project, tmux pane). If a tour is open there,
   `status` shows its title and position; offer to continue it.
