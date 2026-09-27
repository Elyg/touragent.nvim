local M = {}

function M.check()
  local h = vim.health
  h.start('touragent')
  if vim.fn.has('nvim-0.12') == 1 then
    h.ok('nvim ' .. tostring(vim.version()))
  else
    h.error('nvim 0.12+ required')
  end

  local registry = require('touragent.registry')
  local dir = registry.dir()
  if vim.fn.isdirectory(dir) == 1 then
    h.ok('registry dir: ' .. dir)
  else
    h.warn('registry dir missing (created on startup): ' .. dir)
  end
  if vim.v.servername ~= '' then
    h.ok('socket: ' .. vim.v.servername)
  else
    h.error('no v:servername — agents cannot connect')
  end
  local mine = vim.uv.fs_stat(dir .. '/' .. vim.uv.os_getpid() .. '.json')
  if mine then
    h.ok('this nvim is registered')
  else
    h.warn('this nvim is not registered yet (happens on VimEnter)')
  end

  if vim.env.TMUX then
    h.ok('running inside tmux (pane ' .. tostring(vim.env.TMUX_PANE) .. ')')
  else
    h.info('not in tmux: registry matching falls back to git root only; tmux push disabled')
  end

  local session = require('touragent.session')
  if session.link then
    h.ok(
      ('linked to %s (tmux pane %s)'):format(
        session.link.agent.name or 'agent',
        session.link.agent.tmux_pane or '-'
      )
    )
  else
    h.info('no agent linked (start your agent with the touragent MCP server)')
  end

  local settings = vim.fn.expand('~/.claude/settings.json')
  local plugins = vim.fn.expand('~/.claude/plugins')
  if
    vim.fn.isdirectory(plugins) == 1
    and #vim.fn.globpath(plugins, '**/touragent*/hooks/hooks.json', true, true) > 0
  then
    h.ok('Claude Code plugin (MCP server + snapshot hook) installed')
  elseif vim.fn.filereadable(settings) == 1 and vim.fn.readblob(settings):find('snapshot.lua', 1, true) then
    h.ok('snapshot hook configured in ~/.claude/settings.json')
  else
    h.info('snapshot hook not detected — change diffs fall back to buffer/git baselines')
  end
end

return M
