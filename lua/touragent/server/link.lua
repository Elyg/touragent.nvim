-- Server side of linking: find the right nvim and hold the msgpack-RPC channel to it.
-- Resolution (first match wins): TOURAGENT_NVIM → $NVIM → registry (git root, tmux window).
local registry = require('touragent.registry')
local version = require('touragent.version')
local M = {}

M.chan = nil ---@type integer|nil
M.target = nil ---@type table|nil registry entry (or {socket=...}) of the linked nvim
M.agent_name = 'agent'
M.manual = false -- linked by explicit choice (env var, $NVIM, link_session): never auto-switch

local function agent_info()
  local cwd = vim.uv.cwd()
  return {
    cwd = cwd,
    git_root = registry.git_root(cwd),
    tmux = registry.tmux_info(vim.env.TMUX_PANE),
  }
end

local function alive(chan)
  local ok, info = pcall(vim.api.nvim_get_chan_info, chan)
  return ok and info and info.id ~= nil
end

function M.linked()
  return M.chan ~= nil and alive(M.chan)
end

local function close()
  if M.chan then
    pcall(vim.fn.chanclose, M.chan)
  end
  M.chan, M.target = nil, nil
end

--- Connect + handshake. Returns (ok, err).
function M.connect(socket, entry)
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', socket, { rpc = true })
  if not ok or not chan or chan == 0 then
    return false, 'cannot connect to ' .. socket
  end
  local ok2, info = pcall(vim.rpcrequest, chan, 'nvim_get_api_info')
  if not ok2 then
    pcall(vim.fn.chanclose, chan)
    return false, 'no response from ' .. socket
  end
  local a = agent_info()
  local ok3, res =
    pcall(vim.rpcrequest, chan, 'nvim_exec_lua', 'return require("touragent.rpc").dispatch(...)', {
      'hello',
      {
        chan = info[1],
        protocol = version.PROTOCOL_VERSION,
        agent = { name = M.agent_name, tmux_pane = a.tmux and a.tmux.pane or vim.NIL, cwd = a.cwd },
      },
      vim.NIL,
    })
  if not ok3 then
    pcall(vim.fn.chanclose, chan)
    return false, ('nvim at %s does not have touragent loaded (%s)'):format(socket, tostring(res))
  end
  if type(res) ~= 'table' or not res.ok then
    pcall(vim.fn.chanclose, chan)
    return false, (type(res) == 'table' and res.error) or 'handshake failed'
  end
  close()
  M.chan = chan
  M.target = vim.tbl_extend(
    'force',
    entry or { socket = socket },
    { pid = res.pid, git_root = res.git_root, cwd = res.cwd }
  )
  if res.protocol ~= version.PROTOCOL_VERSION then
    M.warning = ('protocol mismatch: nvim plugin v%s, MCP server v%d — update both'):format(
      tostring(res.protocol),
      version.PROTOCOL_VERSION
    )
  end
  return true
end

--- Registered nvims, with their tmux location refreshed (panes can move between windows)
--- and `orphaned` set when their tmux pane no longer exists (e.g. a leftover headless nvim).
local function candidates()
  local live = registry.live_panes()
  local entries = registry.list()
  for _, e in ipairs(entries) do
    local pane = type(e.tmux) == 'table' and e.tmux.pane or nil
    if live and pane then
      if live[pane] then
        e.tmux = registry.tmux_info(pane) or e.tmux
      else
        e.orphaned = true
      end
    end
  end
  return entries
end

--- Ask an nvim to describe itself (current file, open tour). nil if it can't answer.
local function probe(e)
  local chan, own = nil, false
  if M.linked() and M.target and M.target.pid == e.pid then
    chan = M.chan
  else
    local ok, c = pcall(vim.fn.sockconnect, 'pipe', e.socket, { rpc = true })
    if not ok or not c or c == 0 then
      return nil
    end
    chan, own = c, true
  end
  local ok, res =
    pcall(vim.rpcrequest, chan, 'nvim_exec_lua', 'return require("touragent.rpc").dispatch(...)', {
      'describe',
      vim.empty_dict(),
      vim.NIL,
    })
  if own then
    pcall(vim.fn.chanclose, chan)
  end
  return ok and type(res) == 'table' and not res.error and res or nil
end

--- One line a user can recognise: where it was opened, tmux window, file, tour, start time.
local function describe(e, info)
  local home = vim.env.HOME or ''
  local cwd = (e.cwd or '?'):gsub('^' .. vim.pesc(home), '~')
  local parts = { 'opened in ' .. cwd }
  local t = type(e.tmux) == 'table' and e.tmux or nil
  if t and t.session then
    parts[#parts + 1] = ('tmux %s:%s%s, pane %s'):format(
      t.session,
      t.window_index or t.window or '?',
      t.window_name and (' "' .. t.window_name .. '"') or '',
      t.pane or '?'
    )
  elseif not t then
    parts[#parts + 1] = 'not in tmux'
  end
  if info then
    if info.file and info.file ~= vim.NIL then
      parts[#parts + 1] = 'editing ' .. info.file
    end
    local tour = info.tour ~= vim.NIL and info.tour or nil
    if tour then
      parts[#parts + 1] = ('%s "%s" at step %d/%d'):format(
        tour.mode == 'changes' and 'walkthrough' or 'tour',
        tour.title ~= vim.NIL and tour.title or 'untitled',
        tour.cur or 0,
        tour.total or 0
      )
    end
    if info.linked_agent and info.linked_agent ~= vim.NIL and not (M.linked() and M.target.pid == e.pid) then
      parts[#parts + 1] = 'linked to another agent (' .. info.linked_agent .. ')'
    end
  end
  if e.started_at then
    parts[#parts + 1] = 'started ' .. os.date('%a %H:%M', e.started_at)
  end
  if e.orphaned then
    parts[#parts + 1] = 'its tmux pane is gone (probably a leftover)'
  end
  return table.concat(parts, ' · ')
end

--- Auto-link candidates ranked for this agent (orphans excluded).
local function ranked_candidates(entries)
  return registry.rank(
    agent_info(),
    vim.tbl_filter(function(e)
      return not e.orphaned
    end, entries)
  )
end

--- All registered nvims, best match first, each with a human `description`.
function M.sessions()
  local entries = candidates()
  local score = {}
  for _, m in ipairs(ranked_candidates(entries)) do
    score[m.entry.pid] = m.score
  end
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = {
      pid = e.pid,
      description = describe(e, probe(e)),
      cwd = e.cwd,
      git_root = e.git_root or vim.NIL,
      tmux = e.tmux or vim.NIL,
      match_score = score[e.pid] or 0,
      orphaned = e.orphaned or false,
      linked = M.linked() and M.target.pid == e.pid,
    }
  end
  table.sort(out, function(a, b)
    if a.match_score ~= b.match_score then
      return a.match_score > b.match_score
    end
    return a.pid < b.pid
  end)
  return out
end

--- Make sure we are linked, resolving a target if needed. Returns (ok, err).
function M.ensure()
  if M.linked() then
    return true
  end
  close()
  M.manual = false
  local env = vim.env.TOURAGENT_NVIM
  if env and env ~= '' then
    M.manual = true
    return M.connect(env)
  end
  if vim.env.NVIM and vim.env.NVIM ~= '' then
    local ok, err = M.connect(vim.env.NVIM)
    if ok then
      M.manual = true
      return true
    end
    M.last_error = err
  end
  local ranked = ranked_candidates(candidates())
  local errors = {}
  for _, m in ipairs(ranked) do
    -- Several equally good candidates: don't guess, have the user pick.
    if ranked[2] and ranked[2].score == ranked[1].score and m == ranked[1] then
      local lines = {}
      for _, x in ipairs(ranked) do
        if x.score == ranked[1].score then
          lines[#lines + 1] = ('- pid %d: %s'):format(x.entry.pid, describe(x.entry, probe(x.entry)))
        end
      end
      return false,
        ('ambiguous: %d nvims match this project equally well. Do not guess: ask the user which one to use '):format(
          #lines
        )
          .. '(show each description below as an option), then call link_session(pid).\n'
          .. table.concat(lines, '\n')
    end
    local ok, err = M.connect(m.entry.socket, m.entry)
    if ok then
      return true
    end
    errors[#errors + 1] = err
  end
  if #ranked == 0 then
    return false,
      'no nvim with touragent found for this project (open nvim in the project, or call list_sessions/link_session)'
  end
  return false, table.concat(errors, '; ')
end

function M.link_pid(pid)
  for _, e in ipairs(registry.list()) do
    if e.pid == pid then
      close()
      local ok, err = M.connect(e.socket, e)
      M.manual = ok and true or false
      return ok, err
    end
  end
  return false, 'no registered nvim with pid ' .. tostring(pid)
end

--- Move an automatic link to a strictly better match (e.g. the user's nvim started after
--- the agent had settled for another one). Never touches a link the user chose.
--- Returns true when it switched.
function M.upgrade()
  if not M.linked() or M.manual or not M.target then
    return false
  end
  local entries = candidates()
  if #entries < 2 then
    return false
  end
  local ranked = ranked_candidates(entries)
  local best, current = ranked[1], -1
  for _, m in ipairs(ranked) do
    if m.entry.pid == M.target.pid then
      current = m.score
    end
  end
  local unique = best and (not ranked[2] or ranked[2].score < best.score)
  if not (unique and best.entry.pid ~= M.target.pid and best.score > current) then
    return false
  end
  M.bye() -- the old nvim shows "agent disconnected"
  return M.connect(best.entry.socket, best.entry)
end

--- Synchronous call into the nvim plugin. Raises on transport failure.
function M.call(method, params, token)
  local ok, err = M.ensure()
  if not ok then
    error(err, 0)
  end
  local ok2, res = pcall(
    vim.rpcrequest,
    M.chan,
    'nvim_exec_lua',
    'return require("touragent.rpc").dispatch(...)',
    { method, params or vim.empty_dict(), token or vim.NIL }
  )
  if not ok2 then
    close()
    error('lost connection to nvim: ' .. tostring(res), 0)
  end
  return res
end

function M.bye()
  if M.linked() then
    pcall(
      vim.rpcrequest,
      M.chan,
      'nvim_exec_lua',
      'return require("touragent.rpc").dispatch(...)',
      { 'bye', {}, vim.NIL }
    )
  end
  close()
end

return M
