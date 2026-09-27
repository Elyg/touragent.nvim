---
name: tour
description: Give the user a live, step-by-step tour of code in their Neovim using the touragent MCP tools — explain how the logic flows across files and functions while nvim jumps to and highlights each part. Use when the user asks for a tour, walkthrough or explanation of how code, a file, a function, a feature or a repository works, or refers to "this"/"here" in their editor, and touragent tools are available.
---

# Code tour in the user's Neovim

The user is reading along in nvim. Each step you push jumps their editor to a range,
highlights it and shows your note in a side panel. They move with next/prev and can leave
comments anchored to lines, which come back to you as tool results.

## Procedure

1. **Orient.** If the request refers to "this", "here" or a selection, call `status` first
   (current file, cursor, visible lines, last visual selection). Otherwise locate the entry
   point with your normal search tools.
2. **Map the real flow before narrating.** Use the `lsp` tool on the user's language
   servers — `symbols` for a file outline, `definition` to follow a call,
   `outgoing_calls` / `incoming_calls` for the call hierarchy, `references` for usages.
   Don't guess the call chain from names.
3. **Start the timeline:** `timeline_new(title, mode="tour")`.
4. **Push steps in reading order.** One idea per step:
   - `range` = only the lines that matter (a function signature + key branch, not a whole
     200-line file);
   - `title` ≈ 3–6 words;
   - code in a note goes in a fenced block tagged with its language (```` ```lua ````);
     inline `code` is coloured in the step file's language, so keep it to real code;
   - `note` = markdown explaining *why* and how it connects to the previous step
     ("`parse_args` hands the config to…"), mention edge cases and gotchas.
   Push the first step with `wait=true` so the user sets the pace. For a known linear chain
   you may push 2–4 steps at once (the user reads them locally); the last call in a batch
   must use `wait=true`.
5. **React to the result:**
   - `next` → continue with the next part of the flow.
   - `comment` → the user asked something about `selected_text` at `file:range`. Answer
     with `reply(comment_id, markdown)` (shows in their panel). If the answer needs a
     detour, push steps for it, then resume.
   - `stop` → end the tour and give a short recap in chat.
   - `timeout` → call `timeline_wait` (the user is still reading).
   - Always handle `pending_user_messages` before continuing.
6. **Finish** with a final step (or chat message) summarising the whole flow in a few
   bullets.

Questions the user types in chat during the tour are answered in chat as usual — push extra
steps when showing the code helps.
