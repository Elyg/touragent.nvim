-- MCP server main loop (runs inside `nvim -l mcp/server.lua`).
--
-- Each tools/call runs in a coroutine. Calls that must wait (user action, LSP) yield a
-- token; the nvim plugin later rpcnotifies on_resolve(token, result) and the coroutine
-- resumes. stdin keeps being serviced meanwhile (cancellation, other calls, ping).
local jsonrpc = require('touragent.server.jsonrpc')
local link = require('touragent.server.link')
local tools = require('touragent.server.tools')

local M = {}

M.stopped = false
M.client = nil

local SUPPORTED = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05' }
local WAIT_TIMEOUT_MS = (tonumber(vim.env.TOURAGENT_WAIT_TIMEOUT or '') or 600) * 1000
local PROGRESS_EVERY_MS = 25000
local RELINK_MS = (tonumber(vim.env.TOURAGENT_RELINK_MS or '') or 2000)

local pending = {} ---@type table<string, table>
local by_request = {} ---@type table<any, string>
local seq = 0

local function log(...)
  if vim.env.TOURAGENT_LOG then
    local f = io.open(vim.env.TOURAGENT_LOG, 'a')
    if f then
      f:write(os.date('%H:%M:%S '), table.concat(vim.tbl_map(tostring, { ... }), ' '), '\n')
      f:close()
    end
  end
end

local function send(msg)
  io.stdout:write(jsonrpc.encode(msg))
  io.stdout:flush()
end

local function tool_result(ok, res)
  if not ok then
    return { content = { { type = 'text', text = 'Error: ' .. tostring(res) } }, isError = true }
  end
  if type(res) ~= 'table' then
    res = { result = res }
  end
  res.__async = nil
  if link.warning then
    res.warning = link.warning
  end
  if res.error then
    return { content = { { type = 'text', text = 'Error: ' .. tostring(res.error) } }, isError = true }
  end
  return { content = { { type = 'text', text = vim.json.encode(res) } } }
end

local function stop_timers(entry)
  for _, key in ipairs({ 'timer', 'progress' }) do
    local t = entry[key]
    if t and not t:is_closing() then
      t:stop()
      t:close()
    end
  end
end

local step

--- Drive a tool coroutine after resume().
step = function(co, req_id, meta, ok, val)
  if not ok then
    log('tool error', val)
    return send(jsonrpc.response(req_id, tool_result(false, val)))
  end
  if coroutine.status(co) == 'dead' then
    return send(jsonrpc.response(req_id, tool_result(true, val)))
  end
  -- Yielded: waiting for token val.token.
  local entry = { co = co, req_id = req_id, meta = meta, token = val.token }
  pending[val.token] = entry
  by_request[req_id] = val.token
  entry.timer = vim.uv.new_timer()
  entry.timer:start(
    val.timeout_ms,
    0,
    vim.schedule_wrap(function()
      M.expire(val.token, val.on_timeout)
    end)
  )
  local progress_token = meta and meta.progressToken
  if progress_token ~= nil then
    local n = 0
    entry.progress = vim.uv.new_timer()
    entry.progress:start(
      PROGRESS_EVERY_MS,
      PROGRESS_EVERY_MS,
      vim.schedule_wrap(function()
        n = n + 1
        send({
          method = 'notifications/progress',
          params = { progressToken = progress_token, progress = n, message = 'waiting for the user in nvim' },
        })
      end)
    )
  end
end

local function take(token)
  local entry = pending[token]
  if not entry then
    return nil
  end
  pending[token] = nil
  by_request[entry.req_id] = nil
  stop_timers(entry)
  return entry
end

--- Called by the nvim plugin (via rpcnotify → nvim_exec_lua) when an async result is ready.
function M.on_resolve(token, result)
  vim.schedule(function()
    local entry = take(token)
    if entry then
      step(entry.co, entry.req_id, entry.meta, coroutine.resume(entry.co, result))
    end
  end)
end

function M.expire(token, value)
  local entry = take(token)
  if not entry then
    return
  end
  pcall(link.call, 'cancel', { token = token })
  step(entry.co, entry.req_id, entry.meta, coroutine.resume(entry.co, value or { error = 'timed out' }))
end

local function cancel_request(req_id)
  local token = by_request[req_id]
  if token and take(token) then
    pcall(link.call, 'cancel', { token = token })
  end
end

local ctx = {}
ctx.call = function(method, params)
  return link.call(method, params)
end
ctx.await = function(method, params, opts)
  seq = seq + 1
  local token = 't' .. seq
  local res = link.call(method, params, token)
  if type(res) ~= 'table' or not res.__async then
    return res
  end
  return coroutine.yield({ token = token, timeout_ms = opts.timeout_ms, on_timeout = opts.on_timeout })
end
ctx.wait = function()
  return ctx.await('wait', {}, {
    timeout_ms = WAIT_TIMEOUT_MS,
    on_timeout = {
      action = 'timeout',
      hint = 'The user has not responded yet. Call timeline_wait to keep waiting, or continue if appropriate.',
    },
  })
end

local function server_version()
  local root = vim.g.touragent_root or vim.uv.cwd()
  local res = vim.system({ 'git', '-C', root, 'describe', '--tags', '--always' }, { text = true }):wait()
  return res.code == 0 and vim.trim(res.stdout) or 'dev'
end

local function handle(msg)
  if msg.__parse_error then
    return send(jsonrpc.error(nil, -32700, 'parse error: ' .. msg.__parse_error))
  end
  local id, method, params = msg.id, msg.method, msg.params or {}
  if not method then
    return -- response to a server→client request (we send none)
  end
  log('<-', method, id)

  if method == 'initialize' then
    M.client = params.clientInfo
    link.agent_name = (params.clientInfo and params.clientInfo.name) or 'agent'
    local wanted = params.protocolVersion
    local version = vim.tbl_contains(SUPPORTED, wanted) and wanted or SUPPORTED[1]
    send(jsonrpc.response(id, {
      protocolVersion = version,
      capabilities = { tools = { listChanged = false } },
      serverInfo = { name = 'touragent', version = server_version() },
      instructions = tools.instructions,
    }))
    -- Link eagerly so the user's nvim shows the agent (and knows its tmux pane) right away.
    vim.defer_fn(function()
      local ok, err = link.ensure()
      log('eager link', ok, err)
    end, 0)
  elseif method == 'ping' then
    send(jsonrpc.response(id, vim.empty_dict()))
  elseif method == 'tools/list' then
    send(jsonrpc.response(id, { tools = tools.definitions() }))
  elseif method == 'tools/call' then
    local tool = tools.by_name[params.name]
    if not tool then
      return send(jsonrpc.error(id, -32602, 'unknown tool: ' .. tostring(params.name)))
    end
    local co = coroutine.create(function()
      return tool.handler(params.arguments or {}, ctx)
    end)
    step(co, id, params._meta, coroutine.resume(co))
  elseif method == 'notifications/cancelled' then
    cancel_request(params.requestId)
  elseif method:match('^notifications/') then
    return
  elseif id ~= nil then
    send(jsonrpc.error(id, -32601, 'method not found: ' .. method))
  end
end

function M.run()
  -- Keep stdout clean for the protocol: anything chatty goes to stderr.
  -- selene: allow(global_usage)
  _G.print = function(...)
    io.stderr:write(table.concat(vim.tbl_map(tostring, { ... }), '\t') .. '\n')
  end
  vim.notify = function(m)
    io.stderr:write(tostring(m) .. '\n')
  end

  local decoder = jsonrpc.decoder()
  local stdin = vim.uv.new_pipe(false)
  stdin:open(0)
  stdin:read_start(vim.schedule_wrap(function(err, data)
    if err or not data then
      M.stopped = true
      return
    end
    for _, msg in ipairs(decoder.feed(data)) do
      local ok, e = pcall(handle, msg)
      if not ok then
        log('handler crash', e)
        if msg.id ~= nil then
          send(jsonrpc.error(msg.id, -32603, tostring(e)))
        end
      end
    end
  end))

  -- Keep looking for the user's nvim while unlinked: nvim may start (or restart) after the
  -- agent, and only a link lets nvim reach the agent (wake, next, comments via tmux).
  local relink = vim.uv.new_timer()
  relink:start(
    RELINK_MS,
    RELINK_MS,
    vim.schedule_wrap(function()
      if not M.client then
        return
      end
      if not link.linked() then
        local ok, linked = pcall(link.ensure)
        if ok and linked then
          log('auto-linked', link.target and link.target.pid)
        end
      elseif next(pending) == nil then
        -- nothing is waiting on the user: safe to move to a better-matching nvim
        local ok, switched = pcall(link.upgrade)
        if ok and switched then
          log('moved link to', link.target and link.target.pid)
        end
      end
    end)
  )

  while not M.stopped do
    vim.wait(1000, function()
      return M.stopped
    end, 50)
  end
  link.bye()
  os.exit(0)
end

return M
