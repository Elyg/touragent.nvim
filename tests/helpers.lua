-- Shared test helpers: a child nvim running the plugin, and an MCP server process wired to it.
local H = {}

H.root = vim.g.touragent_root

--- Isolated runtime dir so tests never touch the real registry.
function H.tmp_runtime()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- Child nvim with the plugin initialised.
function H.child(runtime_dir)
  local child = MiniTest.new_child_neovim()
  vim.env.XDG_RUNTIME_DIR = runtime_dir
  vim.env.XDG_STATE_HOME = runtime_dir .. '/state' -- saved tours stay out of the real state dir
  child.start({ '-u', H.root .. '/tests/minimal_init.lua' })
  child.lua([[require('touragent')._auto(); require('touragent.registry').write()]])
  child.lua([[vim.cmd('cd ' .. ...)]], { H.root })
  child.o.lines, child.o.columns = 40, 160
  return child
end

--- Start the MCP server process linked to the child's socket.
function H.server(child, runtime_dir, env)
  local srv = { lines = {}, responses = {}, notifications = {}, next_id = 0 }
  local buf = ''
  srv.proc = vim.system({ 'nvim', '-l', H.root .. '/mcp/server.lua' }, {
    stdin = true,
    cwd = H.root,
    env = vim.tbl_extend('force', {
      TOURAGENT_NVIM = child.v.servername,
      NVIM = '', -- jobs spawned from nvim inherit $NVIM; never link to the test runner
      XDG_RUNTIME_DIR = runtime_dir,
      TMUX = '',
      TMUX_PANE = '',
    }, env or {}),
    stdout = function(_, data)
      if not data then
        return
      end
      buf = buf .. data
      while true do
        local nl = buf:find('\n', 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        local ok, msg = pcall(vim.json.decode, line)
        if ok then
          if msg.id ~= nil then
            srv.responses[msg.id] = msg
          else
            srv.notifications[#srv.notifications + 1] = msg
          end
        end
      end
    end,
  })

  function srv.send(method, params)
    srv.next_id = srv.next_id + 1
    local id = srv.next_id
    srv.proc:write(vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params }) .. '\n')
    return id
  end

  function srv.notify(method, params)
    srv.proc:write(vim.json.encode({ jsonrpc = '2.0', method = method, params = params }) .. '\n')
  end

  function srv.wait_for(id, timeout)
    vim.wait(timeout or 5000, function()
      return srv.responses[id] ~= nil
    end, 10)
    return srv.responses[id]
  end

  function srv.request(method, params, timeout)
    return srv.wait_for(srv.send(method, params), timeout)
  end

  --- Call a tool and return its decoded JSON payload (or the error text).
  function srv.tool(name, args, timeout)
    local res = srv.request('tools/call', { name = name, arguments = args or vim.empty_dict() }, timeout)
    return H.payload(res)
  end

  function srv.stop()
    pcall(function()
      srv.proc:write(nil)
    end)
    pcall(function()
      srv.proc:wait(2000)
    end)
  end

  srv.request('initialize', {
    protocolVersion = '2025-06-18',
    clientInfo = { name = 'test-agent' },
    capabilities = vim.empty_dict(),
  })
  -- wait for the eager link to land in the child
  vim.wait(3000, function()
    return child.lua_get([[require('touragent.session').link ~= nil]])
  end, 20)
  return srv
end

function H.payload(res)
  if not res then
    return nil, 'no response'
  end
  if res.error then
    return nil, res.error.message
  end
  local text = res.result.content[1].text
  if res.result.isError then
    return nil, text
  end
  return vim.json.decode(text)
end

--- Write a file inside a temp git repo; returns repo dir.
function H.git_repo(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.system({ 'git', 'init', '-q', dir }):wait()
  for name, lines in pairs(files or {}) do
    vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. name), 'p')
    vim.fn.writefile(lines, dir .. '/' .. name)
  end
  vim.system({ 'git', '-C', dir, 'add', '-A' }):wait()
  return dir
end

return H
