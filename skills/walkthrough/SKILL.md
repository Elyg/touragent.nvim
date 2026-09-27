---
name: walkthrough
description: Walk the user through code changes live in their Neovim using the touragent MCP tools — either narrating each edit as you make it (showing the inline diff and waiting for feedback before the next edit), or reviewing existing uncommitted changes step by step. Use when the user asks you to walk them through changes, show changes as you make them, review a diff together, or pair on a refactor, and touragent tools are available.
---

# Change walkthrough in the user's Neovim

Each `kind="change"` step reloads the edited file in the user's nvim and shows the diff
inline (added lines green, removed lines red) against the version before your edit. The
user can comment on specific lines to steer the next edit.

## Live mode (you are making the changes)

1. `timeline_new(title, mode="changes")`.
2. Make **one coherent edit** with your normal edit tools.
3. Immediately `timeline_push([{kind="change", file, title, note}], wait=true)`:
   - omit `range` (it is derived from the diff) unless you want to focus a sub-range;
   - `note` = what changed and why, plus anything the user should double-check.
4. Do **not** start the next edit until the call returns:
   - `next` → proceed with the next edit;
   - `comment` → apply the requested adjustment (then push a new change step for it) or
     answer with `reply`;
   - `stop` → stop editing, summarise what was done and what remains;
   - `timeout` → `timeline_wait`.
5. If a result has `warnings` about unsaved edits, the user has unsaved changes in that
   file and your edit is not loaded in their editor: tell them, and wait for them to save
   or run `:TourReload` (take your version) before editing that file again.

## Review mode (changes already exist)

1. Get the change set (`git diff --stat`, `git diff`).
2. `timeline_new(title, mode="tour")` and push `kind="explain"` steps over the changed
   ranges in a logical order (core change first, then call sites, then tests), with notes
   explaining intent and risks. Use `wait=true` per step or small batches.
3. Handle comments/replies as in live mode.
