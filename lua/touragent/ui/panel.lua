-- Tour panel: a right-hand markdown split with the current step's note, comment threads,
-- the timeline overview and key hints.
local config = require('touragent.config')
local M = {}

M.buf = nil ---@type integer|nil
M.win = nil ---@type integer|nil
M.auto_opened = false
M.message = nil ---@type string|nil latest info message, shown in the panel's status line
local message_timer = nil
local MESSAGE_MS = 10000

function M.is_panel_buf(buf)
  return buf ~= nil and buf == M.buf
end

function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win) and vim.api.nvim_win_get_buf(M.win) == M.buf
end

local function native()
  return (config.options.panel.style or 'native') ~= 'markdown'
end

local function ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.buf, 'touragent://panel')
  vim.bo[M.buf].buftype = 'nofile'
  vim.bo[M.buf].bufhidden = 'hide'
  vim.bo[M.buf].swapfile = false
  -- 'touragent' keeps markdown plugins away from the natively rendered panel.
  vim.bo[M.buf].filetype = native() and 'touragent' or 'markdown'
  vim.bo[M.buf].modifiable = false
  local tl = function()
    return require('touragent.timeline')
  end
  local keys = config.options.panel_keys or {}
  local map = function(lhs, fn, desc)
    if lhs then
      vim.keymap.set('n', lhs, fn, { buffer = M.buf, nowait = true, desc = desc })
    end
  end
  map(keys.next, function()
    tl().next()
  end, 'Tour: next step')
  map(keys.prev, function()
    tl().prev()
  end, 'Tour: previous step')
  map(keys.stop, function()
    tl().stop()
  end, 'Tour: stop')
  map(keys.go, function()
    tl().goto_current()
    local follow = require('touragent.follow')
    if follow.tour_win and vim.api.nvim_win_is_valid(follow.tour_win) then
      vim.api.nvim_set_current_win(follow.tour_win)
    end
  end, 'Tour: jump to current step')
  map(keys.btw, function()
    require('touragent').btw()
  end, 'Tour: btw (side question)')
  map(keys.wake, function()
    require('touragent.session').wake()
  end, 'Tour: wake agent (continue now)')
  map(keys.comment, function()
    require('touragent').comment({ from_panel = true })
  end, 'Tour: comment on current step')
  return M.buf
end

function M.open()
  if M.is_open() then
    return
  end
  local prev = vim.api.nvim_get_current_win()
  ensure_buf()
  vim.cmd('botright vsplit')
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)
  vim.api.nvim_win_set_width(M.win, config.options.panel.width)
  local wo = vim.wo[M.win]
  wo.winfixwidth = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.spell = false
  wo.cursorline = false
  wo.conceallevel = native() and 0 or 2
  wo.winbar = ' touragent'
  wo.statusline = "%!v:lua.require'touragent.ui.panel'.statusline()"
  if vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  -- Native rendering hard-wraps to the window width: re-render when it changes.
  local group = vim.api.nvim_create_augroup('touragent.panel', { clear = true })
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      if M.is_open() and vim.tbl_contains(vim.v.event.windows or {}, M.win) then
        M.render()
      end
    end,
  })
  M.render()
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Panel status line: tour position on the left, the latest message on the right.
function M.statusline()
  local esc = function(str)
    return (str:gsub('%%', '%%%%'):gsub('\n', ' '))
  end
  local s = require('touragent.timeline').state
  local label, hl = require('touragent.session').state_label(true)
  local pos = #s.steps > 0 and ('◆ %d/%d  '):format(s.cur, #s.steps) or ''
  return (' %s%%#%s#%s%%*%%=%s '):format(esc(pos), hl, esc(label), esc(M.message or ''))
end

--- Show `msg` in the panel's status line for a while (instead of a vim.notify popup).
function M.set_message(msg)
  M.message = msg
  if not message_timer then
    message_timer = vim.uv.new_timer()
  end
  message_timer:stop()
  message_timer:start(
    MESSAGE_MS,
    0,
    vim.schedule_wrap(function()
      M.message = nil
      vim.cmd('redrawstatus!')
    end)
  )
  vim.cmd('redrawstatus!')
end

function M.maybe_auto_open()
  if not M.auto_opened and config.options.panel.auto_open then
    M.auto_opened = true
    M.open()
  end
end

local function key(lhs)
  return lhs and require('touragent.util').key_label(lhs) or '-'
end

--- A pre-styled row: parts = { {text, hl?}, ... } → { text, hls } (see render.lua).
local function row(parts)
  local text, hls, col = {}, {}, 0
  for _, p in ipairs(parts) do
    text[#text + 1] = p[1]
    if p[2] then
      hls[#hls + 1] = { col, col + #p[1], p[2] }
    end
    col = col + #p[1]
  end
  return { text = table.concat(text), hls = hls }
end

local function header_row()
  local session = require('touragent.session')
  local label, hl = session.state_label(false)
  if session.link then
    return row({
      { session.link.agent.name or 'agent', 'TourAgentStrong' },
      { ' · ', 'TourAgentMuted' },
      { label, hl },
    })
  end
  return row({ { label, hl } })
end

--- Key hints as rows of `key label · key label`.
local function hint_rows()
  local k = config.options.panel_keys or {}
  local groups = {
    { { k.next, 'next' }, { k.prev, 'prev' }, { k.go, 'jump' }, { k.stop, 'stop' } },
    { { k.comment, 'comment' }, { k.btw, 'btw' }, { k.wake, 'wake agent' } },
  }
  local rows = {}
  for _, g in ipairs(groups) do
    local parts = {}
    for _, item in ipairs(g) do
      if item[1] then
        if #parts > 0 then
          parts[#parts + 1] = { ' · ', 'TourAgentMuted' }
        end
        parts[#parts + 1] = { key(item[1]), 'TourAgentKey' }
        parts[#parts + 1] = { ' ' .. item[2], 'TourAgentMuted' }
      end
    end
    if #parts > 0 then
      rows[#rows + 1] = row(parts)
    end
  end
  return rows
end

--- The timeline, pinned at the top: a window of at most `panel.timeline_max` steps that
--- keeps the current one in view. Once there are more steps than fit, the height stays
--- fixed (both overflow rows are always present), so moving between steps never makes the
--- panel jump around.
local function timeline_rows()
  local tl = require('touragent.timeline')
  local s = tl.state
  local total = #s.steps
  if total == 0 then
    return {}
  end
  local max = math.max(3, config.options.panel.timeline_max or 6)
  local first, last = 1, total
  if total > max then
    -- keep one step of context above the current one
    first = math.max(1, math.min(s.cur - 1, total - max + 1))
    last = first + max - 1
  end
  local rows = {}
  local function overflow(n, what)
    rows[#rows + 1] = row({
      {
        n > 0 and ('  %s %d %s'):format(what == 'earlier' and '↑' or '↓', n, what) or '',
        'TourAgentMuted',
      },
    })
  end
  if total > max then
    overflow(first - 1, 'earlier')
  end
  for i = first, last do
    local st = s.steps[i]
    local label = st.title ~= '' and st.title or tl.relpath(st.file)
    local parts
    if i == s.cur then
      parts = { { '▶ ', 'TourAgentCurrent' }, { ('%d. %s'):format(i, label), 'TourAgentCurrent' } }
    elseif s.visited[st.id] then
      parts = { { '✓ ', 'TourAgentDone' }, { ('%d. '):format(i), 'TourAgentMuted' }, { label } }
    else
      parts = { { '· ', 'TourAgentMuted' }, { ('%d. '):format(i), 'TourAgentMuted' }, { label } }
    end
    if st.conflict then
      parts[#parts + 1] = { ' ⚠', 'TourAgentWarn' }
    end
    rows[#rows + 1] = row(parts)
  end
  local waiting_row = row({ { '  … waiting for more steps', 'TourAgentMuted' } })
  if total > max then
    -- the "more" slot is empty exactly when the user is at the end: reuse it
    if s.awaiting and last == total then
      rows[#rows + 1] = waiting_row
    else
      overflow(total - last, 'more')
    end
  elseif s.awaiting then
    rows[#rows + 1] = waiting_row
  end
  return rows
end

--- Build the panel's lines (exposed for tests).
function M.lines()
  local tl = require('touragent.timeline')
  local session = require('touragent.session')
  local s = tl.state
  local out = {}
  local add = function(l)
    out[#out + 1] = l
  end
  add('# ' .. (s.title or 'touragent'))
  add('')
  add(header_row())
  add('')
  for _, r in ipairs(timeline_rows()) do
    add(r)
  end
  if #s.steps > 0 then
    add(row({ { ('─'):rep(40), 'TourAgentRule' } }))
    add('')
  end

  local step = tl.current()
  if step then
    add(('## Step %d/%d%s'):format(s.cur, #s.steps, step.title ~= '' and (' · ' .. step.title) or ''))
    add(
      ('`%s:%d-%d`%s'):format(
        tl.relpath(step.file),
        step.range[1],
        step.range[2],
        step.kind == 'change' and ' · change' or ''
      )
    )
    if step.conflict then
      add('')
      add('> [!WARNING]')
      add('> ' .. step.conflict)
    end
    add('')
    for _, l in ipairs(vim.split(step.note, '\n', { plain = true })) do
      add(l)
    end
  else
    add('_Waiting for the agent to push the first step…_')
  end

  -- Each message is its own callout so replies don't blend into the step note.
  local agent = session.link and session.link.agent.name or 'agent'
  local quote = function(text)
    for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
      add(l == '' and '>' or ('> ' .. l))
    end
  end
  local function thread(c, where)
    add('')
    add(('> [!QUESTION] you · #%d%s%s'):format(c.id, where, c.delivered and '' or ' (queued)'))
    quote(c.text)
    for _, r in ipairs(c.replies) do
      add('')
      add('> [!NOTE] ' .. agent)
      quote(r.text)
    end
  end

  local threads, btws = {}, {}
  for _, c in ipairs(session.comments) do
    if c.btw then
      btws[#btws + 1] = c
    elseif not step or c.step_id == step.id or c.step_id == nil then
      threads[#threads + 1] = c
    end
  end
  if #threads > 0 then
    add('')
    add('### Comments')
    for _, c in ipairs(threads) do
      local r = c.range
      thread(
        c,
        ' · ' .. (r[1] == r[2] and ('%s:%d'):format(c.file, r[1]) or ('%s:%d-%d'):format(c.file, r[1], r[2]))
      )
    end
  end
  if #btws > 0 then
    add('')
    add('### btw')
    for _, c in ipairs(btws) do
      thread(c, '')
    end
  end

  add('')
  for _, r in ipairs(hint_rows()) do
    add(r)
  end
  return out
end

function M.render()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  local lines = M.lines()
  vim.bo[M.buf].modifiable = true
  if native() then
    local width = M.is_open() and vim.api.nvim_win_get_width(M.win) or config.options.panel.width
    -- The toured file's language colours untagged code blocks and inline code.
    local step = require('touragent.timeline').current()
    local ft = step and vim.filetype.match({ filename = step.file }) or nil
    require('touragent.ui.render').apply(M.buf, lines, width - 1, ft)
  else
    local flat = vim.tbl_map(function(l)
      return type(l) == 'table' and l.text or l
    end, lines)
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, flat)
  end
  vim.bo[M.buf].modifiable = false
  if M.is_open() then
    pcall(vim.api.nvim_win_set_cursor, M.win, { 1, 0 })
  end
end

--- Hover float for the current step when the panel is closed.
function M.float_note()
  local tl = require('touragent.timeline')
  local step = tl.current()
  if not step then
    return
  end
  local lines = { ('**%d/%d · %s**'):format(tl.state.cur, #tl.state.steps, step.title), '' }
  vim.list_extend(lines, vim.split(step.note, '\n', { plain = true }))
  vim.lsp.util.open_floating_preview(
    lines,
    'markdown',
    { border = 'rounded', max_width = 80, focus_id = 'touragent_note' }
  )
end

function M.reset()
  M.auto_opened = false
  M.render()
end

return M
