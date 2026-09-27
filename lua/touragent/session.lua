-- Link to the (single) agent, the comment inbox, and the blocking-wait bridge.
--
-- Blocking tool calls never block the editor: the server registers a waiter token, and when
-- the user acts (next at end of queue / comment / stop) we rpcnotify the server with the
-- result. Comments made while nobody waits sit in the inbox and piggyback on the next tool
-- result (or get pushed to the agent's tmux pane when tmux_push is on).
local M = {}

M.link = nil ---@type { chan: integer, agent: table, since: integer }|nil
M.waiter = nil ---@type { token: string }|nil
M.pending_event = nil ---@type string|nil
M.comments = {} ---@type table[]
M.comment_seq = 0
M.disconnected = false
M.last_seen = 0 -- vim.uv.now() of the agent's last call (or of releasing its wait)

local IDLE_MS = 90000 -- no call for this long and not waiting → the agent is idle
local ticker = nil

local watch_timer = nil

local function notify(msg, level)
  require('touragent.util').notify(msg, level)
end

function M.linked()
  return M.link ~= nil
end

local function chan_alive(chan)
  local ok, info = pcall(vim.api.nvim_get_chan_info, chan)
  return ok and info and info.id ~= nil
end

function M.unlink(reason)
  if not M.link then
    return
  end
  M.link = nil
  M.waiter = nil
  M.disconnected = true
  if watch_timer then
    watch_timer:stop()
    watch_timer:close()
    watch_timer = nil
  end
  require('touragent.changes').detach()
  notify('agent disconnected' .. (reason and (' (' .. reason .. ')') or ''), vim.log.levels.WARN)
  require('touragent.ui.panel').render()
end

--- Handshake from the MCP server.
---@param params { chan: integer, protocol: integer, agent: table }
function M.hello(params)
  local version = require('touragent.version').PROTOCOL_VERSION
  if M.link and M.link.chan ~= params.chan and chan_alive(M.link.chan) then
    return {
      ok = false,
      error = 'this nvim is already linked to another agent (one agent per nvim)',
      pid = vim.uv.os_getpid(),
    }
  end
  M.link = { chan = params.chan, agent = params.agent or {}, since = os.time() }
  M.disconnected = false
  require('touragent.changes').attach()
  if params.protocol ~= version then
    notify(
      ('protocol mismatch: plugin v%d, MCP server v%d — update both copies'):format(
        version,
        params.protocol or -1
      ),
      vim.log.levels.WARN
    )
  else
    notify('agent linked' .. (params.agent and params.agent.name and (': ' .. params.agent.name) or ''))
  end
  watch_timer = watch_timer or vim.uv.new_timer()
  watch_timer:start(
    2000,
    2000,
    vim.schedule_wrap(function()
      if M.link and not chan_alive(M.link.chan) then
        M.unlink('channel closed')
      end
    end)
  )
  require('touragent.ui.panel').render()
  return {
    ok = true,
    protocol = version,
    pid = vim.uv.os_getpid(),
    cwd = vim.uv.cwd(),
    git_root = require('touragent.registry').git_root(vim.uv.cwd()),
  }
end

function M.bye()
  M.unlink('agent exited')
  return { ok = true }
end

--- Send an async result back to the server.
function M.resolve(token, result)
  if not M.link then
    return
  end
  pcall(
    vim.rpcnotify,
    M.link.chan,
    'nvim_exec_lua',
    'return require("touragent.server.main").on_resolve(...)',
    { token, result }
  )
end

--- Undelivered comments, marked delivered.
function M.drain()
  local out = {}
  for _, c in ipairs(M.comments) do
    if not c.delivered then
      c.delivered = true
      out[#out + 1] = M.public_comment(c)
    end
  end
  return out
end

function M.has_undelivered()
  for _, c in ipairs(M.comments) do
    if not c.delivered then
      return true
    end
  end
  return false
end

function M.public_comment(c)
  return {
    id = c.id,
    file = c.file,
    range = c.range,
    selected_text = c.selected_text,
    text = c.text,
    step_id = c.step_id,
    btw = c.btw or nil,
  }
end

local function event_result(action)
  local tl = require('touragent.timeline')
  local cur = tl.current()
  return {
    action = action,
    comments = M.drain(),
    current_step = cur and cur.id or nil,
    steps_total = #tl.state.steps,
  }
end

--- Server wants to block until the user acts.
function M.wait(token)
  if M.pending_event or M.has_undelivered() then
    local action = M.pending_event or 'comment'
    M.pending_event = nil
    return event_result(action)
  end
  M.waiter = { token = token }
  require('touragent.ui.panel').render()
  return { __async = true }
end

function M.cancel(token)
  if M.waiter and M.waiter.token == token then
    M.waiter = nil
    require('touragent.ui.panel').render()
  end
  return { ok = true }
end

function M.waiting()
  return M.waiter ~= nil
end

--- User event: 'next' (past the end of the queue), 'stop', or 'comment'.
function M.emit(action)
  if M.waiter then
    local w = M.waiter
    M.waiter = nil
    M.pending_event = nil
    M.touch() -- the agent resumes working
    M.resolve(w.token, event_result(action))
    require('touragent.ui.panel').render()
    return true
  end
  if action ~= 'comment' then
    M.pending_event = action
  end
  return false
end

--- Record a user comment (from the float). Returns the comment.
--- A `btw` comment is a side question with no file/range.
---@param c { file?: string, range?: integer[], selected_text?: string, text: string, step_id?: integer, btw?: boolean }
function M.add_comment(c)
  M.comment_seq = M.comment_seq + 1
  c.id = M.comment_seq
  c.replies = {}
  c.delivered = false
  M.comments[#M.comments + 1] = c
  if c.file then
    require('touragent.ui.marks').comment_tag(c)
  end
  local what = c.btw and 'btw' or 'comment'

  if M.emit('comment') then
    notify(('%s #%d sent to agent'):format(what, c.id))
  elseif M.link and require('touragent.config').options.tmux_push and M.link.agent.tmux_pane then
    local msg = c.btw and ('[touragent] btw #%d (side question, answer with reply): %s'):format(c.id, c.text)
      or ('[touragent] comment #%d on %s:%d-%d: %s'):format(c.id, c.file, c.range[1], c.range[2], c.text)
    if require('touragent.tmux').send(M.link.agent.tmux_pane, msg) then
      c.delivered = true
      notify(('%s #%d typed into agent pane'):format(what, c.id))
    else
      notify(("%s #%d queued — delivered with the agent's next tool call"):format(what, c.id))
    end
  else
    notify(("comment #%d queued — delivered with the agent's next tool call"):format(c.id))
  end
  require('touragent.ui.panel').render()
  require('touragent.store').schedule()
  return c
end

--- Wake the agent now: a blocked call returns `next` (the user keeps reading while more
--- steps are queued); an idle agent gets a prompt typed into its tmux pane.
function M.wake()
  local tl = require('touragent.timeline')
  local s = tl.state
  if M.emit('next') then
    return notify('agent woken — more steps coming')
  end
  M.pending_event = nil -- emit() stored it for a later wait; waking is a one-shot
  local pane = M.link and M.link.agent.tmux_pane or nil
  local msg = #s.steps > 0
      and ('[touragent] continue the tour "%s" (I am on step %d/%d)'):format(s.title or '', s.cur, #s.steps)
    or '[touragent] continue'
  if require('touragent.config').options.tmux_push and pane and require('touragent.tmux').send(pane, msg) then
    return notify('typed into agent pane: ' .. msg)
  end
  notify(
    M.link and 'agent is not waiting and its tmux pane is unknown — ask it in its terminal'
      or 'no agent linked — start one with :TourAgent (it links within a few seconds)',
    vim.log.levels.WARN
  )
end

---@return 'waiting'|'working'|'idle'|'offline'|'disconnected'
function M.agent_state()
  if not M.link then
    return M.disconnected and 'disconnected' or 'offline'
  end
  if M.waiter then
    return 'waiting'
  end
  if M.last_seen > 0 and vim.uv.now() - M.last_seen < IDLE_MS then
    return 'working'
  end
  return 'idle'
end

local spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

--- Human label + highlight group for the agent's state.
---@param live? boolean include spinner and elapsed seconds (status line)
---@return string label
---@return string hl
function M.state_label(live)
  local st = M.agent_state()
  if st == 'waiting' then
    return '⏸ waiting for you', 'TourAgentStateWaiting'
  elseif st == 'working' then
    if not live then
      return '● working…', 'TourAgentStateWorking'
    end
    local now = vim.uv.now()
    local frame = spinner[math.floor(now / 100) % #spinner + 1]
    return ('%s working %ds'):format(frame, math.floor((now - M.last_seen) / 1000)), 'TourAgentStateWorking'
  elseif st == 'idle' then
    return '○ idle', 'TourAgentMuted'
  elseif st == 'disconnected' then
    return '⚠ agent disconnected', 'TourAgentStateOff'
  end
  return '○ no agent linked', 'TourAgentMuted'
end

--- The agent did something (a call arrived, or its wait was released): it's working.
--- A ticker animates the status line until the state changes, then re-renders the panel.
function M.touch()
  M.last_seen = vim.uv.now()
  if ticker then
    return
  end
  ticker = vim.uv.new_timer()
  local last = M.agent_state()
  ticker:start(
    100,
    100,
    vim.schedule_wrap(function()
      local st = M.agent_state()
      if st ~= last then
        last = st
        require('touragent.ui.panel').render()
      end
      pcall(vim.cmd, 'redrawstatus!')
      if st ~= 'working' and ticker then
        ticker:stop()
        ticker:close()
        ticker = nil
      end
    end)
  )
end

function M.find_comment(id)
  for _, c in ipairs(M.comments) do
    if c.id == id then
      return c
    end
  end
end

function M.reply(id, markdown)
  local c = M.find_comment(id)
  if not c then
    error(('no comment with id %s'):format(tostring(id)))
  end
  c.replies[#c.replies + 1] = { author = 'agent', text = markdown }
  require('touragent.store').schedule()
  require('touragent.ui.panel').render({ reveal_comment = id })
  return { ok = true }
end

function M.reset()
  M.comments = {}
  M.comment_seq = 0
  M.pending_event = nil
end

return M
