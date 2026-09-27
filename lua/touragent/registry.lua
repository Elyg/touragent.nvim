-- Instance registry: every nvim running the plugin advertises itself as
-- $XDG_RUNTIME_DIR/touragent/<pid>.json so an MCP server started in another tmux pane can
-- find it. Pure functions here are shared with the server process (nvim -l).
local uv = vim.uv
local M = {}

function M.dir()
  local base = vim.env.XDG_RUNTIME_DIR
  if not base or base == '' then
    base = vim.fn.stdpath('run')
  end
  return base .. '/touragent'
end

local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, 'p', tonumber('700', 8))
  end
end

---@param path string
---@return string|nil
function M.git_root(path)
  return vim.fs.root(path, '.git')
end

---@param pid integer
function M.pid_alive(pid)
  -- Signal 0 only checks existence. EPERM (someone else's pid) counts as dead: not ours.
  return uv.kill(pid, 0) == 0
end

M.started_at = os.time()

--- Current tmux location of a pane: { pane, session, window, window_index, window_name }.
---@param pane string|nil
function M.tmux_info(pane)
  pane = pane or vim.env.TMUX_PANE
  if not pane or pane == '' or not vim.env.TMUX then
    return nil
  end
  local fmt = '#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}'
  local res = vim.system({ 'tmux', 'display-message', '-p', '-t', pane, fmt }):wait()
  if res.code ~= 0 then
    return { pane = pane }
  end
  local session, window, index, name = vim.trim(res.stdout):match('^(.-)\t(.-)\t(.-)\t(.*)$')
  return {
    pane = pane,
    session = session,
    window = window,
    window_index = tonumber(index),
    window_name = name,
  }
end

--- Set of pane ids that currently exist, or nil when tmux can't be asked.
---@return table<string, true>|nil
function M.live_panes()
  if not vim.env.TMUX or vim.fn.executable('tmux') == 0 then
    return nil
  end
  local res = vim.system({ 'tmux', 'list-panes', '-a', '-F', '#{pane_id}' }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local set = {}
  for id in res.stdout:gmatch('%S+') do
    set[id] = true
  end
  return set
end

--- Registry entry for this nvim.
function M.entry()
  local cwd = uv.cwd()
  return {
    pid = uv.os_getpid(),
    socket = vim.v.servername,
    cwd = cwd,
    git_root = M.git_root(cwd),
    tmux = M.tmux_info(),
    protocol = require('touragent.version').PROTOCOL_VERSION,
    started_at = M.started_at,
  }
end

local function file_for(pid)
  return M.dir() .. '/' .. pid .. '.json'
end

function M.write()
  local entry = M.entry()
  if not entry.socket or entry.socket == '' then
    return nil
  end
  ensure_dir(M.dir())
  local path = file_for(entry.pid)
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then
    return nil
  end
  f:write(vim.json.encode(entry))
  f:close()
  os.rename(tmp, path)
  return entry
end

function M.remove()
  os.remove(file_for(uv.os_getpid()))
end

--- All live entries (stale ones — dead pid or missing socket — are pruned).
---@return table[]
function M.list()
  local out = {}
  local dir = M.dir()
  for name, kind in vim.fs.dir(dir) do
    local pid = kind == 'file' and tonumber(name:match('^(%d+)%.json$'))
    if pid then
      local path = dir .. '/' .. name
      local f = io.open(path, 'r')
      local ok, entry = false, nil
      if f then
        ok, entry = pcall(vim.json.decode, f:read('*a'))
        f:close()
      end
      if ok and type(entry) == 'table' and M.pid_alive(pid) and uv.fs_stat(entry.socket or '') then
        out[#out + 1] = entry
      else
        os.remove(path)
      end
    end
  end
  table.sort(out, function(a, b)
    return a.pid < b.pid
  end)
  return out
end

--- Rank candidate nvims for an agent. Returns (sorted matches, all entries).
--- Match = same git root (or agent cwd inside the nvim cwd); same tmux window ranks
--- first, then same tmux session.
---@param agent { cwd: string, git_root?: string, tmux?: table }
---@param entries table[]
function M.rank(agent, entries)
  local matches = {}
  for _, e in ipairs(entries) do
    local score
    if agent.git_root and e.git_root == agent.git_root then
      score = 10
    elseif e.cwd and agent.cwd and (agent.cwd == e.cwd or vim.startswith(agent.cwd, e.cwd .. '/')) then
      -- deeper (more specific) cwd wins
      score = 5 + select(2, e.cwd:gsub('/', '')) / 100
    end
    if score then
      local at, et = agent.tmux or {}, e.tmux or {}
      if at.session and at.session == et.session then
        score = score + 1
        if at.window and at.window == et.window then
          score = score + 2
        end
      end
      matches[#matches + 1] = { entry = e, score = score }
    end
  end
  table.sort(matches, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.entry.pid < b.entry.pid
  end)
  return matches
end

return M
