-- Server side of linking: find the right nvim and hold the msgpack-RPC channel to it.
-- Resolution (first match wins): TOURAGENT_NVIM → $NVIM → registry (git root, tmux window).
local registry = require('touragent.registry')
local version = require('touragent.version')
local M = {}

M.chan = nil ---@type integer|nil
M.target = nil ---@type table|nil registry entry (or {socket=...}) of the linked nvim
M.agent_name = 'agent'

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

--- All registered nvims, annotated with how well they match this agent.
function M.sessions()
  local entries = registry.list()
  local ranked = registry.rank(agent_info(), entries)
  local score = {}
  for _, m in ipairs(ranked) do
    score[m.entry.pid] = m.score
  end
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = {
      pid = e.pid,
      cwd = e.cwd,
      git_root = e.git_root or vim.NIL,
      tmux = e.tmux or vim.NIL,
      match_score = score[e.pid] or 0,
      linked = M.linked() and M.target.pid == e.pid,
    }
  end
  return out
end

--- Make sure we are linked, resolving a target if needed. Returns (ok, err).
function M.ensure()
  if M.linked() then
    return true
  end
  close()
  local env = vim.env.TOURAGENT_NVIM
  if env and env ~= '' then
    return M.connect(env)
  end
  if vim.env.NVIM and vim.env.NVIM ~= '' then
    local ok, err = M.connect(vim.env.NVIM)
    if ok then
      return true
    end
    M.last_error = err
  end
  local ranked = registry.rank(agent_info(), registry.list())
  local errors = {}
  for _, m in ipairs(ranked) do
    -- Several equally good candidates → ambiguous; let the agent/user pick.
    if ranked[2] and ranked[2].score == ranked[1].score and m == ranked[1] then
      return false,
        ('ambiguous: %d nvim instances match this project equally well; call list_sessions then link_session(pid)'):format(
          #vim.tbl_filter(function(x)
            return x.score == ranked[1].score
          end, ranked)
        )
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
      return M.connect(e.socket, e)
    end
  end
  return false, 'no registered nvim with pid ' .. tostring(pid)
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
