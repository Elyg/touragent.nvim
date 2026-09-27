-- touragent: let an AI agent drive this nvim in real time (code tours, change walkthroughs).
local config = require('touragent.config')
local M = {}

local initialized = false
local mapped = {} ---@type { mode: string|string[], lhs: string }[]

local function tl()
  return require('touragent.timeline')
end

local function notify(msg, level)
  require('touragent.util').notify(msg, level)
end

--- Location for comments / kickoff: a range in a real file, or the current step when
--- invoked from the panel or a special buffer.
local function location(opts)
  local buf = vim.api.nvim_get_current_buf()
  local step = tl().current()
  if opts.from_panel or require('touragent.ui.panel').is_panel_buf(buf) or vim.bo[buf].buftype ~= '' then
    if not step then
      return nil
    end
    return step.file, step.range[1], step.range[2]
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  local s, e
  if opts.range and opts.range > 0 then
    s, e = opts.line1, opts.line2
  else
    s = vim.api.nvim_win_get_cursor(0)[1]
    e = s
  end
  return vim.fs.normalize(name), s, e
end

--- Comment on a line/range (or the current step); opens the floating input.
---@param opts? { from_panel?: boolean, range?: integer, line1?: integer, line2?: integer }
function M.comment(opts)
  opts = opts or {}
  local abs, s, e = location(opts)
  if not abs then
    return notify('nothing to comment on', vim.log.levels.WARN)
  end
  local buf = require('touragent.util').load(abs)
  local selected = vim.api.nvim_buf_get_lines(buf, s - 1, math.min(e, s + 199), false)
  local rel = tl().relpath(abs)
  local step = tl().current()
  require('touragent.ui.input').open({
    title = ('Comment on %s:%d-%d'):format(rel, s, e),
    on_submit = function(text)
      require('touragent.session').add_comment({
        file = rel,
        abs = abs,
        range = { s, e },
        selected_text = table.concat(selected, '\n'),
        text = text,
        step_id = step and step.id or nil,
      })
    end,
  })
end

--- Kick off the agent from nvim: types `<ask_prefix> file:range <question>` into its tmux pane.
function M.ask(opts)
  opts = opts or {}
  local abs, s, e = location(opts)
  local where = abs
      and (s == e and ('%s:%d'):format(tl().relpath(abs), s) or ('%s:%d-%d'):format(tl().relpath(abs), s, e))
    or ''
  vim.ui.input(
    { prompt = 'Ask agent about ' .. (where ~= '' and where or 'this project') .. ': ' },
    function(q)
      if q == nil then
        return
      end
      local msg = config.options.ask_template
        :gsub('{loc}', function()
          return where ~= '' and where or 'this project'
        end)
        :gsub('{question}', function()
          return q
        end)
      msg = vim.trim(msg)
      local session = require('touragent.session')
      local pane = session.link and session.link.agent.tmux_pane
      if config.options.tmux_push and pane and require('touragent.tmux').send(pane, msg) then
        return notify('sent to agent: ' .. msg)
      end
      vim.fn.setreg('+', msg)
      vim.fn.setreg('"', msg)
      notify('no linked agent pane — copied to clipboard: ' .. msg, vim.log.levels.WARN)
    end
  )
end

--- Side question (not about specific lines); answered in the panel's btw section.
function M.btw()
  local step = tl().current()
  require('touragent.ui.input').open({
    title = 'btw: ask anything',
    on_submit = function(text)
      require('touragent.session').add_comment({ text = text, btw = true, step_id = step and step.id or nil })
    end,
  })
end

--- Start the agent next to this nvim, linked to it: a tmux pane when inside tmux,
--- otherwise a :terminal split. Focuses the agent's pane if one is already linked.
---@param args? string extra arguments for the agent command
function M.start_agent(args)
  local session = require('touragent.session')
  local tmux = require('touragent.tmux')
  local pane = session.link and session.link.agent.tmux_pane
  if pane and pane ~= vim.NIL and tmux.focus(pane) then
    return
  end
  if session.link then
    return notify('an agent is already linked (' .. (session.link.agent.name or 'agent') .. ')')
  end
  local opts = config.options.agent or {}
  local cmd = vim.trim((opts.cmd or 'claude') .. ' ' .. (args or ''))
  local cwd = tl().root()
  -- Point the agent's MCP server at this exact nvim (beats registry matching).
  local env = { TOURAGENT_NVIM = vim.v.servername }
  if tmux.split({ cmd = cmd, cwd = cwd, env = env, size = opts.size or '45%' }) then
    return notify('started ' .. cmd .. ' in a tmux pane')
  end
  vim.cmd('botright vsplit')
  vim.cmd('enew')
  vim.fn.jobstart(cmd, { term = true, cwd = cwd, env = env })
  vim.cmd('startinsert')
end

--- Pick a saved tour of this project and reopen it where you left off.
---@param all? boolean list tours of every project (:TourResume!)
function M.resume(all)
  local store = require('touragent.store')
  local tours = store.list(all)
  if #tours == 0 then
    return notify(
      all and 'no saved tours' or 'no saved tours for this project (:TourResume! lists all)',
      vim.log.levels.WARN
    )
  end
  vim.ui.select(tours, {
    prompt = all and 'Resume tour (all projects)' or 'Resume tour',
    format_item = function(t)
      return ('%s %s  ·  step %d/%d  ·  %s%s'):format(
        t.mode == 'changes' and '✎ walkthrough:' or '◆ tour:',
        t.title or 'untitled',
        t.cur or 1,
        t.steps,
        os.date('%Y-%m-%d %H:%M', t.saved_at),
        all and t.project and ('  ·  ' .. t.project) or ''
      )
    end,
  }, function(choice)
    if choice then
      store.load(choice.path)
      notify(
        ('resumed "%s" — ask the agent to continue the tour for more steps'):format(choice.title or 'tour')
      )
    end
  end)
end

function M.statusline()
  return require('touragent.follow').statusline()
end

local function export(path)
  local lines = tl().export()
  if path and path ~= '' then
    vim.fn.writefile(lines, vim.fn.expand(path))
    return notify('tour exported to ' .. path)
  end
  vim.cmd('new')
  vim.bo.buftype = 'nofile'
  vim.bo.filetype = 'markdown'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

local function link_info()
  local session = require('touragent.session')
  local lines = {}
  if session.link then
    local a = session.link.agent
    lines[#lines + 1] = ('linked: %s (tmux pane %s, cwd %s)'):format(
      a.name or 'agent',
      a.tmux_pane or '-',
      a.cwd or '-'
    )
  else
    lines[#lines + 1] = session.disconnected and 'agent disconnected' or 'no agent linked'
  end
  lines[#lines + 1] = 'socket: ' .. vim.v.servername
  lines[#lines + 1] = 'registry: ' .. require('touragent.registry').dir()
  vim.notify('[touragent] ' .. table.concat(lines, '\n'))
end

local commands = {
  TourNext = {
    fn = function()
      tl().next()
    end,
    desc = 'Next tour step',
  },
  TourPrev = {
    fn = function()
      tl().prev()
    end,
    desc = 'Previous tour step',
  },
  TourGo = {
    fn = function()
      tl().goto_current()
    end,
    desc = 'Jump to the current step',
  },
  TourStop = {
    fn = function()
      tl().stop()
    end,
    desc = 'Tell the agent to stop',
  },
  TourClear = {
    fn = function()
      tl().clear()
      require('touragent.ui.marks').clear_comments()
    end,
    desc = 'Clear the timeline',
  },
  TourPanel = {
    fn = function()
      require('touragent.ui.panel').toggle()
    end,
    desc = 'Toggle the tour panel',
  },
  TourNote = {
    fn = function()
      require('touragent.ui.panel').float_note()
    end,
    desc = 'Show step note in a float',
  },
  TourFollow = {
    fn = function()
      require('touragent.follow').toggle()
    end,
    desc = 'Toggle follow mode',
  },
  TourLink = { fn = link_info, desc = 'Show agent link status' },
  TourReload = {
    fn = function()
      require('touragent.changes').reload_current()
    end,
    desc = "Load the agent's version",
  },
  TourDiff = {
    fn = function()
      require('touragent.changes').diff_head()
    end,
    desc = 'Cumulative diff vs HEAD',
  },
  TourComment = {
    fn = function(o)
      M.comment(o)
    end,
    desc = 'Comment for the agent',
    range = true,
  },
  TourAsk = {
    fn = function(o)
      M.ask(o)
    end,
    desc = 'Ask the agent (tmux push)',
    range = true,
  },
  TourAgent = {
    fn = function(o)
      M.start_agent(o.args)
    end,
    nargs = '*',
    desc = 'Start the agent (claude) next to nvim, linked to it',
  },
  TourBtw = {
    fn = function()
      M.btw()
    end,
    desc = 'Ask the agent a side question',
  },
  TourWake = {
    fn = function()
      require('touragent.session').wake()
    end,
    desc = 'Wake the agent: continue the tour now',
  },
  TourResume = {
    fn = function(o)
      M.resume(o.bang)
    end,
    bang = true,
    desc = 'Resume a saved tour of this project (! = all projects)',
  },
  TourExport = {
    fn = function(o)
      export(o.args)
    end,
    desc = 'Export timeline as markdown',
    nargs = '?',
    complete = 'file',
  },
}

local function create_commands()
  for name, c in pairs(commands) do
    vim.api.nvim_create_user_command(name, function(o)
      c.fn({ range = o.range, line1 = o.line1, line2 = o.line2, args = o.args, bang = o.bang })
    end, { desc = c.desc, range = c.range, nargs = c.nargs or 0, complete = c.complete, bang = c.bang })
  end
end

local function apply_keymaps()
  for _, m in ipairs(mapped) do
    pcall(vim.keymap.del, m.mode, m.lhs)
  end
  mapped = {}
  local keys = config.options.keys
  if not keys then
    return
  end
  local function map(mode, lhs, rhs, desc)
    if lhs then
      vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
      mapped[#mapped + 1] = { mode = mode, lhs = lhs }
    end
  end
  map('n', keys.ask, '<cmd>TourAsk<cr>', 'Tour: ask agent')
  map('x', keys.ask, ':TourAsk<cr>', 'Tour: ask agent about selection')
  map('n', keys.next, '<cmd>TourNext<cr>', 'Tour: next step')
  map('n', keys.prev, '<cmd>TourPrev<cr>', 'Tour: previous step')
  map('n', keys.comment, '<cmd>TourComment<cr>', 'Tour: comment')
  map('x', keys.comment, ':TourComment<cr>', 'Tour: comment on selection')
  map('n', keys.go, '<cmd>TourGo<cr>', 'Tour: go to current step')
  map('n', keys.panel, '<cmd>TourPanel<cr>', 'Tour: toggle panel')
  map('n', keys.follow, '<cmd>TourFollow<cr>', 'Tour: toggle follow')
  map('n', keys.stop, '<cmd>TourStop<cr>', 'Tour: stop agent')
  map('n', keys.btw, '<cmd>TourBtw<cr>', 'Tour: btw (side question)')
  map('n', keys.resume, '<cmd>TourResume<cr>', 'Tour: resume a saved tour')
  map('n', keys.agent, '<cmd>TourAgent<cr>', 'Tour: start / focus the agent')
  map('n', keys.wake, '<cmd>TourWake<cr>', 'Tour: wake agent (continue now)')
  local ok, wk = pcall(require, 'which-key')
  if ok and wk.add and keys.next then
    wk.add({ { keys.next:sub(1, -2), group = 'Tour agent', mode = { 'n', 'x' } } })
  end
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup('touragent', { clear = true })
  local registry = require('touragent.registry')
  local follow = require('touragent.follow')
  local au = function(ev, fn)
    vim.api.nvim_create_autocmd(ev, { group = group, callback = fn })
  end
  if vim.v.vim_did_enter == 1 then
    registry.write()
  else
    au('VimEnter', function()
      registry.write()
    end)
  end
  au('DirChanged', function()
    registry.write()
  end)
  au('VimLeavePre', function()
    require('touragent.store').flush()
    registry.remove()
    local session = require('touragent.session')
    if session.waiting() then
      session.emit('stop')
    end
  end)
  au({ 'WinEnter', 'BufWinEnter' }, function()
    follow.track_win()
  end)
  au({ 'InsertCharPre', 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI' }, function()
    follow.on_activity()
  end)
  au('ColorScheme', function()
    require('touragent.ui.marks').setup_highlights()
  end)
  au('CursorHold', function()
    local panel = require('touragent.ui.panel')
    local step = tl().current()
    if step and not panel.is_open() and vim.api.nvim_buf_get_name(0) == step.file then
      if vim.api.nvim_win_get_cursor(0)[1] == step.range[1] then
        panel.float_note()
      end
    end
  end)
end

local function init()
  if initialized then
    return
  end
  initialized = true
  require('touragent.ui.marks').setup_highlights()
  create_commands()
  create_autocmds()
  require('touragent.follow').track_win()
end

--- Optional: override defaults. Safe to call any number of times.
---@param opts? table see touragent.config
function M.setup(opts)
  config.set(opts)
  M._configured = true
  init()
  apply_keymaps()
end

--- Called from plugin/touragent.lua: zero-config startup with defaults.
function M._auto()
  init()
  if not M._configured then
    apply_keymaps()
  end
end

return M
