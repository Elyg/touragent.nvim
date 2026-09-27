-- End-to-end: real `nvim -l mcp/server.lua` process over stdio JSON-RPC, driving a child nvim.
-- No LLM involved: the test plays the agent (tool calls) and the user (child.lua actions).
local H = dofile(vim.g.touragent_root .. '/tests/helpers.lua')
local eq = MiniTest.expect.equality

local child, runtime, srv
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      runtime = H.tmp_runtime()
      child = H.child(runtime)
      child.lua([[require('touragent.follow').last_typed = -1e9]])
    end,
    post_case = function()
      if srv then
        srv.stop()
        srv = nil
      end
      child.stop()
    end,
  },
})

local function step(line, title)
  return {
    file = 'lua/touragent/init.lua',
    range = { start = line, ['end'] = line + 1 },
    title = title,
    note = 'n',
  }
end

local function user(code)
  child.lua(code)
end

T['initialize links eagerly and lists tools'] = function()
  srv = H.server(child, runtime)
  eq(child.lua_get([[require('touragent.session').link.agent.name]]), 'test-agent')
  local res = srv.request('tools/list', {})
  eq(#res.result.tools, 10)
  eq(srv.request('ping', {}).result, {})
end

T['server links on its own to an nvim that starts later'] = function()
  -- The server starts first: its registry dir is empty, so the eager link finds nothing.
  local late = H.tmp_runtime()
  srv = H.server(child, late, { TOURAGENT_NVIM = '', TOURAGENT_RELINK_MS = '100' })
  eq(child.lua_get([[require('touragent.session').link]]), vim.NIL)
  -- "nvim starts": its registry entry appears where the server looks.
  vim.fn.mkdir(late .. '/touragent', 'p')
  for _, f in ipairs(vim.fn.glob(runtime .. '/touragent/*.json', true, true)) do
    vim.fn.writefile(vim.fn.readfile(f), late .. '/touragent/' .. vim.fs.basename(f))
  end
  vim.wait(3000, function()
    return child.lua_get([[require('touragent.session').link ~= nil]])
  end, 20)
  eq(child.lua_get([[require('touragent.session').link.agent.name]]), 'test-agent')
end

T['two equally good nvims: the server asks instead of guessing'] = function()
  local other = H.child(runtime) -- a second nvim in the same project
  srv = H.server(child, runtime, { TOURAGENT_NVIM = '' })
  local ok, err = pcall(function()
    local _, msg = srv.tool('status')
    eq(msg:find('ambiguous', 1, true) ~= nil, true)
    eq(msg:find('ask the user', 1, true) ~= nil, true)
    eq(msg:find('opened in', 1, true) ~= nil, true)
    local sessions = srv.tool('list_sessions').sessions
    eq(#sessions, 2)
    eq(sessions[1].description:find('opened in', 1, true) ~= nil, true)
    -- the user picked the second nvim
    local pid = other.lua_get('vim.uv.os_getpid()')
    eq(srv.tool('link_session', { pid = pid }).ok, true)
    eq(other.lua_get([[require('touragent.session').link.agent.name]]), 'test-agent')
    eq(child.lua_get([[require('touragent.session').link]]), vim.NIL)
  end)
  other.stop()
  if not ok then
    error(err, 0)
  end
end

T['timeline_push(wait) blocks until the user presses next'] = function()
  srv = H.server(child, runtime)
  srv.tool('timeline_new', { title = 'T', mode = 'tour' })
  local id = srv.send('tools/call', { name = 'timeline_push', arguments = { steps = { step(10, 'a') } } })
  -- still pending, but other calls are served meanwhile
  local st = srv.tool('status')
  eq(st.timeline.total, 1)
  eq(srv.responses[id], nil)
  eq(child.lua_get([[require('touragent.session').waiting()]]), true)
  user([[require('touragent.timeline').next()]])
  local res = H.payload(srv.wait_for(id))
  eq(res.action, 'next')
  eq(res.pushed_step_ids, { 1 })
end

T['a comment resolves the wait with the comment payload'] = function()
  srv = H.server(child, runtime)
  local id = srv.send('tools/call', { name = 'timeline_push', arguments = { steps = { step(10, 'a') } } })
  vim.wait(2000, function()
    return child.lua_get([[require('touragent.session').waiting()]])
  end)
  user([[require('touragent.session').add_comment({ file = 'lua/touragent/init.lua', range = { 10, 11 },
    selected_text = 'code', text = 'why this?', step_id = 1 })]])
  local res = H.payload(srv.wait_for(id))
  eq(res.action, 'comment')
  eq(res.comments[1].text, 'why this?')
  eq(res.comments[1].selected_text, 'code')
  -- reply renders in the panel, then blocks again until stop
  local rid = srv.send(
    'tools/call',
    { name = 'reply', arguments = { comment_id = res.comments[1].id, markdown = 'because' } }
  )
  vim.wait(2000, function()
    return child.lua_get([[require('touragent.session').waiting()]])
  end)
  eq(vim.tbl_contains(child.lua_get([[require('touragent.ui.panel').lines()]]), '> because'), true)
  user([[require('touragent.timeline').stop()]])
  eq(H.payload(srv.wait_for(rid)).action, 'stop')
end

T['comments left while the agent works piggyback on the next result'] = function()
  srv = H.server(child, runtime)
  srv.tool('timeline_push', { steps = { step(10, 'a') }, wait = false })
  user(
    [[require('touragent.session').add_comment({ file = 'x', range = { 1, 1 }, selected_text = '', text = 'hey', step_id = 1 })]]
  )
  local st = srv.tool('status')
  eq(st.pending_user_messages[1].text, 'hey')
  eq(#srv.tool('get_feedback').comments, 0)
end

T['wait timeout returns action=timeout and clears the waiter'] = function()
  srv = H.server(child, runtime, { TOURAGENT_WAIT_TIMEOUT = '1' })
  local res = srv.tool('timeline_push', { steps = { step(10, 'a') } }, 5000)
  eq(res.action, 'timeout')
  eq(child.lua_get([[require('touragent.session').waiting()]]), false)
  -- timeline_wait picks up a later user action
  local id = srv.send('tools/call', { name = 'timeline_wait', arguments = vim.empty_dict() })
  vim.wait(2000, function()
    return child.lua_get([[require('touragent.session').waiting()]])
  end)
  user([[require('touragent.timeline').next()]])
  eq(H.payload(srv.wait_for(id)).action, 'next')
end

T['notifications/cancelled drops the pending wait'] = function()
  srv = H.server(child, runtime)
  local id = srv.send('tools/call', { name = 'timeline_push', arguments = { steps = { step(10, 'a') } } })
  vim.wait(2000, function()
    return child.lua_get([[require('touragent.session').waiting()]])
  end)
  srv.notify('notifications/cancelled', { requestId = id })
  vim.wait(2000, function()
    return not child.lua_get([[require('touragent.session').waiting()]])
  end)
  eq(child.lua_get([[require('touragent.session').waiting()]]), false)
end

T['only one agent per nvim'] = function()
  srv = H.server(child, runtime)
  local other = H.server(child, runtime)
  local _, err = other.tool('status')
  eq(err:find('already linked', 1, true) ~= nil, true)
  other.stop()
  -- the first agent still works
  eq(srv.tool('status').timeline.total, 0)
end

T['registry resolution links without TOURAGENT_NVIM'] = function()
  srv = H.server(child, runtime, { TOURAGENT_NVIM = '', NVIM = '' })
  eq(child.lua_get([[require('touragent.session').link ~= nil]]), true)
  local sessions = srv.tool('list_sessions')
  eq(sessions.linked_pid, child.lua_get('vim.uv.os_getpid()'))
end

T['agent exit marks the link disconnected'] = function()
  srv = H.server(child, runtime)
  srv.stop()
  srv = nil
  vim.wait(3000, function()
    return child.lua_get([[require('touragent.session').disconnected]])
  end)
  eq(child.lua_get([[require('touragent.session').link]]), vim.NIL)
end

T['hook snapshot is the baseline for the next change step'] = function()
  local repo = H.git_repo({ ['f.txt'] = { 'a', 'b', 'c' } })
  child.lua([[vim.cmd('cd ' .. ...)]], { repo })
  srv = H.server(child, runtime)
  -- agent edits twice; the hook snapshots before each edit
  local hook = function()
    vim
      .system({ 'nvim', '-l', H.root .. '/hooks/snapshot.lua' }, {
        stdin = vim.json.encode({ cwd = repo, tool_name = 'Edit', tool_input = { file_path = 'f.txt' } }),
        env = { XDG_RUNTIME_DIR = runtime },
      })
      :wait()
  end
  vim.fn.writefile({ 'a', 'b', 'c', 'd' }, repo .. '/f.txt')
  hook() -- snapshot of the working-tree state before the first push (a,b,c,d)
  vim.fn.writefile({ 'a', 'B', 'c', 'd' }, repo .. '/f.txt')
  local res = srv.tool(
    'timeline_push',
    { steps = { { kind = 'change', file = 'f.txt', title = 'B', note = 'n' } }, wait = false }
  )
  eq(res.step_ids, { 1 })
  local st = child.lua_get([[require('touragent.timeline').current()]])
  eq(st.diff.source, 'hook')
  eq(st.range, { 2, 2 })
end

T['lsp reports a clear error without a language server'] = function()
  srv = H.server(child, runtime)
  local _, err = srv.tool('lsp', { kind = 'definition', file = 'README.md', line = 1 }, 15000)
  eq(err ~= nil, true)
end

T['tmux push delivers idle comments to the agent pane'] = function()
  if vim.fn.executable('tmux') == 0 then
    MiniTest.skip('tmux not available')
  end
  local sock = vim.fn.tempname()
  vim.system({ 'tmux', '-S', sock, 'new-session', '-d', '-s', 'ta', '-x', '200', '-y', '20', 'cat' }):wait()
  local pane =
    vim.trim(vim.system({ 'tmux', '-S', sock, 'display', '-p', '-t', 'ta', '#{pane_id}' }):wait().stdout)
  child.lua([[vim.env.TMUX = ... .. ',0,0']], { sock })
  child.lua(
    [[require('touragent.session').link = { chan = -1, agent = { name = 'x', tmux_pane = ... } }]],
    { pane }
  )
  user(
    [[require('touragent.session').add_comment({ file = 'a.txt', range = { 3, 4 }, selected_text = '', text = 'rename this', step_id = nil })]]
  )
  local out
  vim.wait(3000, function()
    out = vim.system({ 'tmux', '-S', sock, 'capture-pane', '-p', '-t', pane }):wait().stdout
    return out:find('rename this', 1, true) ~= nil
  end)
  vim.system({ 'tmux', '-S', sock, 'kill-server' }):wait()
  eq(out:find('[touragent] comment #1 on a.txt:3-4: rename this', 1, true) ~= nil, true)
  eq(child.lua_get([[require('touragent.session').comments[1].delivered]]), true)
end

return T
