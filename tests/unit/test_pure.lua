-- Pure-logic tests that need no editor state.
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T['jsonrpc'] = MiniTest.new_set()

T['jsonrpc']['decodes partial and batched lines'] = function()
  local d = require('touragent.server.jsonrpc').decoder()
  eq(d.feed('{"id":1,"meth'), {})
  local msgs = d.feed('od":"a"}\n{"id":2,"method":"b"}\n\n{"id":3')
  eq(#msgs, 2)
  eq(msgs[1].method, 'a')
  eq(msgs[2].id, 2)
  msgs = d.feed(',"method":"c","params":{"x":null}}\r\n')
  eq(msgs[1].method, 'c')
  eq(msgs[1].params.x, nil)
end

T['jsonrpc']['reports parse errors without dying'] = function()
  local d = require('touragent.server.jsonrpc').decoder()
  local msgs = d.feed('{nope\n{"id":1}\n')
  eq(msgs[1].__parse_error ~= nil, true)
  eq(msgs[2].id, 1)
end

T['registry.rank'] = MiniTest.new_set()

local entries = {
  { pid = 1, cwd = '/p', git_root = '/p', tmux = { session = 's1', window = '@1' } },
  { pid = 2, cwd = '/p', git_root = '/p', tmux = { session = 's1', window = '@2' } },
  { pid = 3, cwd = '/other', git_root = '/other', tmux = { session = 's1', window = '@2' } },
  { pid = 4, cwd = '/p/sub', git_root = nil },
}

T['registry.rank']['prefers git root, then same tmux window'] = function()
  local r = require('touragent.registry').rank(
    { cwd = '/p', git_root = '/p', tmux = { session = 's1', window = '@2' } },
    entries
  )
  eq(r[1].entry.pid, 2)
  eq(r[2].entry.pid, 1)
  eq(#r, 2)
end

T['registry.rank']['equal scores stay ambiguous'] = function()
  local r = require('touragent.registry').rank({ cwd = '/p', git_root = '/p' }, entries)
  eq(r[1].score, r[2].score)
end

T['registry.rank']['falls back to cwd containment without git'] = function()
  local r = require('touragent.registry').rank({ cwd = '/p/sub/deeper' }, entries)
  eq(r[1].entry.pid, 4)
end

T['changes'] = MiniTest.new_set()

T['changes']['hunks and derived range'] = function()
  local c = require('touragent.changes')
  local old = { 'a', 'b', 'c', 'd' }
  local new = { 'a', 'B', 'c', 'd', 'e' }
  local h = c.hunks(old, new)
  eq(#h, 2)
  eq(h[1], { old_start = 2, old_count = 1, new_start = 2, new_count = 1 })
  eq(h[2].new_start, 5)
  eq(c.range_of(h, #new), { 2, 5 })
end

T['changes']['pure deletion anchors inside the file'] = function()
  local c = require('touragent.changes')
  local h = c.hunks({ 'a', 'b', 'c' }, { 'a', 'c' })
  eq(h[1].new_count, 0)
  eq(c.range_of(h, 2), { 1, 1 })
end

T['changes']['new file diffs against empty'] = function()
  local c = require('touragent.changes')
  local h = c.hunks({}, { 'x', 'y' })
  eq(h[1], { old_start = 0, old_count = 0, new_start = 1, new_count = 2 })
  eq(c.range_of(h, 2), { 1, 2 })
end

T['tools'] = MiniTest.new_set()

T['tools']['definitions are well formed'] = function()
  local tools = require('touragent.server.tools')
  local defs = tools.definitions()
  local names = {}
  for _, d in ipairs(defs) do
    names[#names + 1] = d.name
    eq(type(d.description), 'string')
    eq(d.inputSchema.type, 'object')
  end
  table.sort(names)
  eq(names, {
    'diagnostics',
    'get_feedback',
    'link_session',
    'list_sessions',
    'lsp',
    'reply',
    'status',
    'timeline_new',
    'timeline_push',
    'timeline_wait',
  })
  -- empty property maps must encode as JSON objects, not arrays
  eq(vim.json.encode(tools.by_name.status.inputSchema):find('"properties":{}', 1, true) ~= nil, true)
end

T['render'] = MiniTest.new_set()

local function has_hl(hls, row, hl)
  for _, h in ipairs(hls) do
    if h[1] == row and h[4] == hl then
      return true
    end
  end
  return false
end

T['render']['hides inline markup and highlights it'] = function()
  local lines, hls =
    require('touragent.ui.render').render({ '## Step 1', 'a **bold** `code` [link](http://x)' }, 60)
  eq(lines, { 'Step 1', 'a bold code link' })
  eq(has_hl(hls, 0, 'TourAgentHeading'), true)
  eq(has_hl(hls, 1, 'TourAgentStrong'), true)
  eq(has_hl(hls, 1, 'TourAgentCode'), true)
  eq(has_hl(hls, 1, 'TourAgentLink'), true)
end

T['render']['wraps with hanging indents and keeps code spans whole'] = function()
  local lines = require('touragent.ui.render').render({ '- one two three `vim.uv.new_timer` four' }, 24)
  eq(lines, { '• one two three', '  vim.uv.new_timer four' })
end

T['render']['fenced code gets treesitter highlights'] = function()
  local lines, hls = require('touragent.ui.render').render({ '```lua', 'local x = 1', '```' }, 60)
  eq(lines, { '  local x = 1' })
  eq(has_hl(hls, 0, 'TourAgentCodeBlock'), true)
  eq(has_hl(hls, 0, '@keyword.lua'), true)
end

T['render']['callouts become coloured bars'] = function()
  local lines, hls = require('touragent.ui.render').render({ '> [!QUESTION] you · #1', '> why?' }, 60)
  eq(lines, { '▍ you · #1', '▍ why?' })
  eq(has_hl(hls, 1, 'TourAgentYou'), true)
end

T['key_label'] = function()
  local label = require('touragent.util').key_label
  eq(label('<CR>'), 'Enter')
  eq(label('n'), 'n')
  eq(label('<C-s>'), 'Ctrl-s')
  eq(label('<leader>an'), 'Leader an')
end

T['render']['untagged fences and inline code use the tour language'] = function()
  local render = require('touragent.ui.render')
  local lines, hls =
    render.render({ 'call `session.touch()` or see `lua/x.lua:3`', '```', 'return 1', '```' }, 80, 'lua')
  eq(lines[1], 'call session.touch() or see lua/x.lua:3')
  local function hl_at(row, col)
    local found = {}
    for _, h in ipairs(hls) do
      if h[1] == row and h[2] <= col and col < h[3] then
        found[#found + 1] = h[4]
      end
    end
    return found
  end
  -- `touch` is coloured as a Lua call, the path stays plain inline code
  eq(vim.tbl_contains(hl_at(0, 13), '@function.call.lua'), true)
  eq(hl_at(0, 30), { 'TourAgentCode' })
  eq(vim.tbl_contains(hl_at(1, 2), '@keyword.return.lua'), true)
end

return T
