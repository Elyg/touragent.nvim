---
name: connect
description: Connect (link) this agent to the user's running Neovim via the touragent MCP tools — pick the right nvim instance and link to it. Use when the user asks to connect/link to nvim, when touragent says no nvim is linked or linking is ambiguous, or when the user switched to or restarted another nvim.
---

# Connect to the user's Neovim

touragent normally links on its own: at startup, again within a few seconds when nvim
starts or restarts, and it moves to a better-matching nvim when one appears. Use this when
that didn't happen, when it picked the wrong one, or when the user wants a different nvim.

## Procedure

1. Call `list_sessions`. Entries come best match first. Each has:
   - `description`: a line the user will recognise, e.g. *opened in ~/gits/app · tmux
     main:3 "code", pane %14 · editing src/router.ts · tour "Routing" at step 2/5 ·
     started Sat 21:40*;
   - `match_score` (higher = same project, same tmux window as you), `orphaned` (its tmux
     pane is gone: almost certainly a leftover, not what the user is looking at), `linked`.
2. Choose:
   - The user named one ("the one in window 3", "the one with the router tour",
     "~/gits/app") → match it against the descriptions.
   - Exactly one non-orphaned entry, or one with a clearly higher `match_score` → take it.
   - **Otherwise ask the user** (AskUserQuestion when available) with one option per
     candidate: the label from its description's distinctive parts (folder, tmux window,
     current file or tour), the full description as the option's detail. Never make the
     user choose by pid alone.
   - No sessions → nvim isn't running the plugin: suggest opening nvim in the project (or
     `:checkhealth touragent`) and stop.
3. Call `link_session(pid)`.
4. Confirm in one line which nvim you linked (its description). If a tour is open there,
   offer to continue it.
