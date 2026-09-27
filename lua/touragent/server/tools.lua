-- MCP tool definitions. Descriptions double as the agent's operating manual, so they spell
-- out the protocol (when to block, how to treat comments, timeouts).
local link = require('touragent.server.link')
local M = {}

M.instructions = [[
touragent lets you drive the user's Neovim in real time. The user reads along in nvim while you narrate, and can reply from nvim (comments anchored to lines) or from this chat.

Workflows:
- Code tour (explaining code / "how does X work"): timeline_new(mode="tour"), then timeline_push steps that walk the real control flow (use the lsp tool: definition, references, incoming_calls/outgoing_calls to follow calls accurately). One idea per step, range = the lines that matter, note = markdown explanation (why, not just what). You may push a few steps with wait=false to stay ahead, but end each batch with wait=true.
- Change walkthrough (while editing code, or reviewing uncommitted changes): timeline_new(mode="changes"). After EACH edit lands, push exactly one kind="change" step for that file with wait=true, explaining what changed and why. The editor shows the diff inline. Do not start the next edit until the call returns, so the user's feedback applies before you build on it.

Linking: the server links to the user's nvim on its own. If a tool reports that linking is ambiguous, do not guess: ask the user which nvim to use, offering each candidate's description (where it was opened, tmux window, current file, open tour), then call link_session(pid).
Results of blocking calls: action="next" → continue; action="comment" → read `comments` (each has file, range, selected_text, text): answer questions with reply(comment_id, markdown) (it renders in the user's panel) or apply requested changes, then continue; comments with btw=true are side questions not tied to code (no file/range): answer them with reply and carry on exactly where the tour was; action="next" while current_step < steps_total means the user asked for more steps early (they keep reading), so push the next steps; action="stop" → stop the tour/walkthrough and summarise; action="timeout" → call timeline_wait to keep waiting.
Every tool result may carry pending_user_messages: comments the user left while you were busy — handle them before continuing.
When the user asks you (in chat) about what they are looking at, call status first: it returns their current file, cursor, visible lines and last visual selection.
]]

local step_schema = {
  type = 'object',
  properties = {
    kind = {
      type = 'string',
      enum = { 'explain', 'change' },
      description = 'explain (default): highlight + explain a range. change: an edit you just made; the diff against the previous version is shown inline and range defaults to the changed lines.',
    },
    file = { type = 'string', description = 'Path relative to the project root, or absolute.' },
    range = {
      type = 'object',
      description = '1-based inclusive line range. Optional for change steps.',
      properties = { start = { type = 'integer' }, ['end'] = { type = 'integer' } },
      required = { 'start' },
    },
    title = { type = 'string', description = 'Short step title (shown in the editor, ~6 words).' },
    note = { type = 'string', description = 'Markdown explanation shown in the tour panel.' },
  },
  required = { 'file', 'title', 'note' },
}

local function obj(properties, required)
  return { type = 'object', properties = properties or vim.empty_dict(), required = required }
end

---@param ctx { call: fun(method: string, params?: table): table, await: fun(method: string, params: table, opts: table): table, wait: fun(): table }
M.list = {
  {
    name = 'status',
    description = "What the user is looking at in nvim: current file, cursor, visible line range, last visual selection (with text), open buffers, and tour timeline position. Call this first when the user refers to 'this', 'here' or 'what I'm looking at'.",
    inputSchema = obj(),
    handler = function(_, ctx)
      return ctx.call('status')
    end,
  },
  {
    name = 'list_sessions',
    description = 'List nvim instances running touragent, best match first. Each has a human `description` (where it was opened, tmux window, file being edited, open tour, start time), match_score and orphaned. Use when linking is ambiguous or failed. If more than one could be right, ask the user which one using the descriptions (not bare pids), then call link_session.',
    inputSchema = obj(),
    handler = function()
      return { sessions = link.sessions(), linked_pid = link.linked() and link.target.pid or vim.NIL }
    end,
  },
  {
    name = 'link_session',
    description = 'Link to a specific nvim instance by pid (from list_sessions). Only one agent can be linked to an nvim at a time.',
    inputSchema = obj({ pid = { type = 'integer' } }, { 'pid' }),
    handler = function(args)
      local ok, err = link.link_pid(args.pid)
      if not ok then
        error(err, 0)
      end
      return { ok = true, linked = link.target }
    end,
  },
  {
    name = 'timeline_new',
    description = 'Start a fresh timeline (clears previous steps, highlights and comments). mode: "tour" for explaining code, "changes" for walking through edits.',
    inputSchema = obj({
      title = { type = 'string', description = 'Title shown at the top of the tour panel.' },
      mode = { type = 'string', enum = { 'tour', 'changes' } },
    }, { 'title' }),
    handler = function(args, ctx)
      return ctx.call('timeline_new', { title = args.title, mode = args.mode or 'tour' })
    end,
  },
  {
    name = 'timeline_push',
    description = [[Append one or more steps to the timeline in the user's nvim. The first new step is shown immediately if the user is waiting for more; otherwise steps queue and the user moves through them locally (next/prev).
wait=true (default): block until the user presses next past the last queued step, comments, or stops. Returns {action: next|comment|stop|timeout, comments[], pending_user_messages[]}.
wait=false: return immediately (queue steps ahead while the user reads; tours only). Change walkthroughs must use wait=true with one change step per edit, pushed right after the edit.]],
    inputSchema = obj({
      steps = { type = 'array', items = step_schema, minItems = 1 },
      wait = { type = 'boolean', description = 'Block for the user (default true).' },
    }, { 'steps' }),
    handler = function(args, ctx)
      local res = ctx.call('timeline_push', { steps = args.steps })
      if res.error or args.wait == false then
        return res
      end
      local w = ctx.wait()
      w.pushed_step_ids = res.step_ids
      w.warnings = res.warnings
      if res.pending_user_messages and #res.pending_user_messages > 0 then
        w.comments = vim.list_extend(res.pending_user_messages, w.comments or {})
      end
      return w
    end,
  },
  {
    name = 'timeline_wait',
    description = 'Block until the user acts in nvim (next past the end / comment / stop). Use after a timeout, or after pushing steps with wait=false.',
    inputSchema = obj(),
    handler = function(_, ctx)
      return ctx.wait()
    end,
  },
  {
    name = 'reply',
    description = "Answer a comment the user left in nvim; the markdown renders as a thread under their comment in the tour panel. wait=true (default) then blocks for the user's next action like timeline_wait.",
    inputSchema = obj({
      comment_id = { type = 'integer' },
      markdown = { type = 'string' },
      wait = { type = 'boolean' },
    }, { 'comment_id', 'markdown' }),
    handler = function(args, ctx)
      local res = ctx.call('reply', { comment_id = args.comment_id, markdown = args.markdown })
      if res.error or args.wait == false then
        return res
      end
      return ctx.wait()
    end,
  },
  {
    name = 'get_feedback',
    description = 'Return (and mark delivered) comments the user left in nvim that you have not seen yet.',
    inputSchema = obj(),
    handler = function(_, ctx)
      return ctx.call('get_feedback')
    end,
  },
  {
    name = 'lsp',
    description = "Query the user's language servers (read-only) to follow real code structure: definition, type_definition, implementation, references, hover, symbols (document outline), incoming_calls / outgoing_calls (call hierarchy). Position = line (1-based) plus either symbol (name on that line, preferred) or col (1-based).",
    inputSchema = obj({
      kind = {
        type = 'string',
        enum = {
          'definition',
          'type_definition',
          'implementation',
          'references',
          'hover',
          'symbols',
          'incoming_calls',
          'outgoing_calls',
        },
      },
      file = { type = 'string' },
      line = { type = 'integer' },
      symbol = { type = 'string' },
      col = { type = 'integer' },
    }, { 'kind', 'file' }),
    handler = function(args, ctx)
      return ctx.await('lsp', args, { timeout_ms = 20000, on_timeout = { error = 'LSP request timed out' } })
    end,
  },
  {
    name = 'diagnostics',
    description = 'Current LSP/linter diagnostics from nvim, for one file or all loaded buffers.',
    inputSchema = obj({ file = { type = 'string' } }),
    handler = function(args, ctx)
      return ctx.call('diagnostics', { file = args.file })
    end,
  },
}

M.by_name = {}
for _, t in ipairs(M.list) do
  M.by_name[t.name] = t
end

function M.definitions()
  local out = {}
  for _, t in ipairs(M.list) do
    out[#out + 1] = { name = t.name, description = t.description, inputSchema = t.inputSchema }
  end
  return out
end

return M
