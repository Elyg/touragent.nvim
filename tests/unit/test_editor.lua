-- Editor-state tests in a child nvim (no MCP server involved).
local H = dofile(vim.g.touragent_root .. '/tests/helpers.lua')
local eq = MiniTest.expect.equality

local child, runtime
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      runtime = H.tmp_runtime()
      child = H.child(runtime)
    end,
    post_case = function()
      child.stop()
    end,
  },
})

local function push(steps)
  return child.lua_get('require("touragent.timeline").push(...)', { steps })
end

local step = function(line, title)
  return {
    file = 'lua/touragent/init.lua',
    range = { start = line, ['end'] = line + 2 },
    title = title,
    note = 'note ' .. title,
  }
end

T['timeline'] = MiniTest.new_set()

T['timeline']['first step jumps, opens panel, places marks'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  eq(child.lua_get([[vim.api.nvim_buf_get_name(0):match('init.lua$') ~= nil]]), true)
  eq(child.api.nvim_win_get_cursor(0)[1], 10)
  eq(child.lua_get([[require('touragent.ui.panel').is_open()]]), true)
  local marks =
    child.lua_get([[#vim.api.nvim_buf_get_extmarks(0, require('touragent.ui.marks').ns, 0, -1, {})]])
  eq(marks >= 3, true)
  local panel = child.lua_get([[require('touragent.ui.panel').lines()]])
  eq(vim.tbl_contains(panel, 'note one'), true)
end

T['timeline']['queued steps do not jump; next/prev navigate locally'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  push({ step(30, 'two'), step(50, 'three') })
  eq(child.api.nvim_win_get_cursor(0)[1], 10)
  child.lua([[require('touragent.timeline').next()]])
  eq(child.api.nvim_win_get_cursor(0)[1], 30)
  child.lua([[require('touragent.timeline').next()]])
  child.lua([[require('touragent.timeline').prev()]])
  eq(child.api.nvim_win_get_cursor(0)[1], 30)
  eq(child.lua_get([[require('touragent.timeline').state.cur]]), 2)
end

T['timeline']['next past the end records a pending event and awaits more'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  child.lua([[require('touragent.timeline').next()]])
  eq(child.lua_get([[require('touragent.timeline').state.awaiting]]), true)
  eq(child.lua_get([[require('touragent.session').pending_event]]), 'next')
  -- a wait now resolves immediately
  local res = child.lua_get([[require('touragent.session').wait('t1')]])
  eq(res.action, 'next')
  -- the next push shows its first step right away
  push({ step(40, 'two') })
  eq(child.lua_get([[require('touragent.timeline').state.cur]]), 2)
end

T['timeline']['steps pushed after next-at-end consume it, so the next wait blocks'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  child.lua([[require('touragent.timeline').next()]])
  push({ step(40, 'two') })
  eq(child.lua_get([[require('touragent.session').pending_event]]), vim.NIL)
  eq(child.lua_get([[require('touragent.session').wait('t1').__async]]), true)
end

T['timeline']['info messages go to the panel status line, not vim.notify'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  child.lua([[_G.notified = 0; vim.notify = function() _G.notified = _G.notified + 1 end]])
  child.lua([[require('touragent.follow').toggle()]])
  eq(child.lua_get([[_G.notified]]), 0)
  eq(child.lua_get([[require('touragent.ui.panel').message]]), 'follow mode off')
  eq(
    child.lua_get([[require('touragent.ui.panel').statusline():find('follow mode off', 1, true) ~= nil]]),
    true
  )
  -- warnings still pop up
  child.lua([[require('touragent.util').notify('boom', vim.log.levels.WARN)]])
  eq(child.lua_get([[_G.notified]]), 1)
end

T['store'] = MiniTest.new_set()

T['store']['tours autosave and resume with position and threads'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  child.lua([[require('touragent.timeline').new('Saved tour', 'tour')]])
  push({ step(10, 'one'), step(30, 'two') })
  child.lua([[require('touragent.timeline').next()]])
  child.lua(
    [[require('touragent.session').add_comment({
    file = 'lua/touragent/init.lua', range = { 30, 31 }, selected_text = 'x', text = 'why?', step_id = 2 })]]
  )
  child.lua([[require('touragent.session').reply(1, 'because')]])
  child.lua([[require('touragent.store').save()]])
  -- wipe the in-memory tour, then resume it from disk
  child.lua([[require('touragent.timeline').clear()]])
  eq(child.lua_get([[#require('touragent.timeline').state.steps]]), 0)
  local tours = child.lua_get([[require('touragent.store').list()]])
  eq(#tours, 1)
  eq(tours[1].title, 'Saved tour')
  eq(tours[1].mode, 'tour')
  eq(#child.lua_get([[require('touragent.store').list(true)]]), 1)
  child.lua([[require('touragent.store').load(...)]], { tours[1].path })
  eq(child.lua_get([[require('touragent.timeline').state.cur]]), 2)
  eq(child.api.nvim_win_get_cursor(0)[1], 30)
  eq(child.lua_get([[require('touragent.session').comments[1].replies[1].text]]), 'because')
  eq(child.lua_get([[require('touragent.timeline').summary().steps[2].title]]), 'two')
end

T['highlight overrides survive a colorscheme change'] = function()
  child.lua(
    [[require('touragent').setup({ highlights = { TourAgentRange = { bg = '#123456' }, TourAgentTag = 'Visual' } })]]
  )
  child.cmd('colorscheme default')
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = 'TourAgentRange' }).bg]]), 0x123456)
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = 'TourAgentTag' }).link]]), 'Visual')
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = 'TourAgentCode' }).link]]), '@markup.raw')
end

T['btw & wake'] = MiniTest.new_set()

T['btw & wake']['btw is a side question with its own panel section'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  child.lua(
    [[require('touragent.session').add_comment({ text = 'what is msgpack?', btw = true, step_id = 1 })]]
  )
  local c = child.lua_get([[require('touragent.session').drain()[1] ]])
  eq(c.btw, true)
  eq(c.file, nil)
  child.lua([[require('touragent.session').reply(1, 'a binary JSON')]])
  local panel = child.lua_get(
    [[vim.tbl_filter(function(l) return type(l) == 'string' end, require('touragent.ui.panel').lines())]]
  )
  eq(vim.tbl_contains(panel, '### btw'), true)
  eq(vim.tbl_contains(panel, '> a binary JSON'), true)
  eq(vim.tbl_contains(panel, '### Comments'), false)
end

T['btw & wake']['wake releases a waiting agent without moving the user'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one'), step(30, 'two') })
  -- fake a linked agent that is blocked in timeline_wait
  child.lua([[require('touragent.session').link = { chan = 0, agent = { name = 'test' } }]])
  child.lua([[require('touragent.session').wait('t9')]])
  eq(child.lua_get([[require('touragent.session').agent_state()]]), 'waiting')
  child.lua([[require('touragent.session').wake()]])
  eq(child.lua_get([[require('touragent.session').agent_state()]]), 'working')
  eq(child.lua_get([[require('touragent.timeline').state.cur]]), 1)
  eq(child.lua_get([[require('touragent.session').pending_event]]), vim.NIL)
end

T['btw & wake']['timeline and key hints are pre-styled rows'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one'), step(30, 'two') })
  local text = child.lua_get([[vim.api.nvim_buf_get_lines(require('touragent.ui.panel').buf, 0, -1, false)]])
  eq(vim.tbl_contains(text, '▶ 1. one'), true)
  eq(vim.tbl_contains(text, '· 2. two'), true)
  eq(vim.tbl_contains(text, 'n next · p prev · Enter jump to code · q stop'), true)
  eq(vim.tbl_contains(text, 'c comment · b btw · w wake agent'), true)
end

T['btw & wake']['timeline is pinned on top with a fixed-height window'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  local steps = {}
  for i = 1, 9 do
    steps[i] = step(i * 3, 's' .. i)
  end
  push(steps)
  local function panel_text()
    return child.lua_get([[vim.api.nvim_buf_get_lines(require('touragent.ui.panel').buf, 0, -1, false)]])
  end
  local function index_of(lines, needle)
    for i, l in ipairs(lines) do
      if l == needle then
        return i
      end
    end
  end
  local top = panel_text()
  eq(index_of(top, '  ↓ 3 more') ~= nil, true)
  eq(index_of(top, '· 7. s7'), nil) -- outside the 6-step window
  local rule = index_of(top, ('─'):rep(40))
  for _ = 1, 5 do
    child.lua([[require('touragent.timeline').next()]])
  end
  local later = panel_text()
  eq(index_of(later, '▶ 6. s6') ~= nil, true)
  eq(index_of(later, '  ↑ 3 earlier') ~= nil, true)
  eq(index_of(later, '✓ 5. s5') ~= nil, true)
  -- the explanation starts at the same row no matter which step is shown
  eq(index_of(later, ('─'):rep(40)), rule)
end

T['follow'] = MiniTest.new_set()

T['follow']['does not steal focus while typing'] = function()
  child.lua([[require('touragent.follow').last_typed = vim.uv.now()]])
  push({ step(10, 'one') })
  eq(child.api.nvim_win_get_cursor(0)[1], 1)
  eq(child.lua_get([[require('touragent.follow').ready]]), 1)
  eq(child.lua_get([[require('touragent').statusline()]]):find('ready') ~= nil, true)
  child.lua([[require('touragent.timeline').goto_current()]])
  eq(child.api.nvim_win_get_cursor(0)[1], 10)
end

T['follow']['insert mode counts as busy'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  child.type_keys('i')
  eq(child.lua_get([[require('touragent.follow').busy()]]), true)
  child.type_keys('<Esc>')
end

T['comments'] = MiniTest.new_set()

T['comments']['status carries undelivered comments once'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  child.lua(
    [[require('touragent.session').add_comment({
    file = 'lua/touragent/init.lua', range = { 11, 12 }, selected_text = 'x', text = 'why?', step_id = 1 })]]
  )
  local res = child.lua_get([[require('touragent.rpc').dispatch('status', {})]])
  eq(#res.pending_user_messages, 1)
  eq(res.pending_user_messages[1].text, 'why?')
  res = child.lua_get([[require('touragent.rpc').dispatch('status', {})]])
  eq(#res.pending_user_messages, 0)
end

T['comments']['reply renders as a thread in the panel'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ step(10, 'one') })
  child.lua(
    [[require('touragent.session').add_comment({
    file = 'lua/touragent/init.lua', range = { 11, 12 }, selected_text = 'x', text = 'why?', step_id = 1 })]]
  )
  child.lua([[require('touragent.session').reply(1, 'because **reasons**')]])
  local panel = child.lua_get([[require('touragent.ui.panel').lines()]])
  eq(vim.tbl_contains(panel, '> because **reasons**'), true)
  eq(vim.tbl_contains(panel, '> why?'), true)
end

T['changes'] = MiniTest.new_set()

T['changes']['reloads an unmodified buffer and diffs against its old lines'] = function()
  local repo = H.git_repo({ ['a.txt'] = { 'one', 'two', 'three' } })
  child.lua([[vim.cmd('cd ' .. ...); vim.cmd('edit a.txt')]], { repo })
  vim.fn.writefile({ 'one', 'TWO', 'three', 'four' }, repo .. '/a.txt')
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  push({ { kind = 'change', file = 'a.txt', title = 'edit', note = 'changed two' } })
  local st = child.lua_get([[require('touragent.timeline').current()]])
  eq(st.diff.source, 'buffer')
  eq(st.range, { 2, 4 })
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'one', 'TWO', 'three', 'four' })
end

T['changes']['never reloads over unsaved edits'] = function()
  local repo = H.git_repo({ ['a.txt'] = { 'one', 'two' } })
  child.lua([[vim.cmd('cd ' .. ...); vim.cmd('edit a.txt')]], { repo })
  child.api.nvim_buf_set_lines(0, 0, 1, false, { 'user edit' })
  vim.fn.writefile({ 'one', 'agent edit' }, repo .. '/a.txt')
  push({ { kind = 'change', file = 'a.txt', title = 'edit', note = 'n' } })
  local st = child.lua_get([[require('touragent.timeline').current()]])
  eq(type(st.conflict), 'string')
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'user edit', 'two' })
  -- :TourReload takes the agent's version
  child.cmd('TourReload')
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { 'one', 'agent edit' })
  eq(child.lua_get([[require('touragent.timeline').current().conflict]]), vim.NIL)
end

T['changes']['baseline chain: hook > previous step > git index > empty'] = function()
  local repo = H.git_repo({ ['b.txt'] = { 'indexed' } })
  child.lua([[vim.cmd('cd ' .. ...)]], { repo })
  local path = repo .. '/b.txt'
  -- git index
  local _, src = unpack(child.lua_get([[{ require('touragent.changes').baseline(...) }]], { path }))
  eq(src, 'git-index')
  -- previous step
  child.lua([[require('touragent.changes').known[...] = { 'known' }]], { path })
  _, src = unpack(child.lua_get([[{ require('touragent.changes').baseline(...) }]], { path }))
  eq(src, 'previous-step')
  -- hook snapshot (oldest wins)
  vim.fn.writefile({ 'pre-edit 1' }, path)
  child.lua([[require('touragent.snapshots').take(...)]], { path })
  vim.fn.writefile({ 'pre-edit 2' }, path)
  child.lua([[require('touragent.snapshots').take(...)]], { path })
  local lines
  lines, src = unpack(child.lua_get([[{ require('touragent.changes').baseline(...) }]], { path }))
  eq(src, 'hook')
  eq(lines, { 'pre-edit 1' })
  -- new untracked file → empty
  _, src = unpack(child.lua_get([[{ require('touragent.changes').baseline(...) }]], { repo .. '/new.txt' }))
  eq(src, 'empty')
end

T['registry'] = MiniTest.new_set()

T['registry']['lists live entries and prunes stale ones'] = function()
  local dir = runtime .. '/touragent'
  vim.fn.writefile({ vim.json.encode({ pid = 999999, socket = '/nonexistent' }) }, dir .. '/999999.json')
  local list = child.lua_get([[require('touragent.registry').list()]])
  eq(#list, 1)
  eq(list[1].pid, child.lua_get('vim.uv.os_getpid()'))
  eq(vim.fn.filereadable(dir .. '/999999.json'), 0)
end

T['export'] = function()
  child.lua([[require('touragent.follow').last_typed = -1e9]])
  child.lua([[require('touragent.timeline').new('My tour')]])
  push({ step(10, 'one') })
  local md = child.lua_get([[require('touragent.timeline').export()]])
  eq(md[1], '# My tour')
  eq(md[3], '## 1. one')
end

return T
