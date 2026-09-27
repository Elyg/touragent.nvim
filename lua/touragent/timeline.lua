-- The tour timeline: an ordered list of steps the agent appends to and the user navigates
-- locally (back-history is free; only "next" past the end of the queue involves the agent).
local M = {}

---@class touragent.Step
---@field id integer
---@field kind 'explain'|'change'
---@field file string absolute path
---@field range integer[] {start, end} 1-based inclusive
---@field title string
---@field note string markdown
---@field diff? table change overlay (see changes.lua)
---@field conflict? string

M.state = {
  id = nil, -- saved-tour id (store.lua)
  title = nil,
  mode = 'tour',
  steps = {}, ---@type touragent.Step[]
  cur = 0,
  visited = {},
  awaiting = false, -- user pressed next at the end; show the next pushed step immediately
  seq = 0,
}

function M.root()
  local cwd = vim.uv.cwd()
  return require('touragent.registry').git_root(cwd) or cwd
end

--- Path shown to humans/agents: relative to the git root when inside it.
function M.relpath(path)
  local root = M.root()
  if vim.startswith(path, root .. '/') then
    return path:sub(#root + 2)
  end
  return path
end

function M.abspath(file)
  if not file or file == '' then
    error('step.file is required')
  end
  file = vim.fs.normalize(file)
  if not vim.startswith(file, '/') then
    file = M.root() .. '/' .. file
  end
  return vim.fs.normalize(file)
end

---@param r any
---@return integer[]|nil
local function norm_range(r, line)
  if type(r) == 'table' then
    local s = r.start or r[1] or r.from
    local e = r['end'] or r[2] or r.to or s
    if s then
      s, e = math.max(1, math.floor(s)), math.max(1, math.floor(e))
      if e < s then
        s, e = e, s
      end
      return { s, e }
    end
  elseif type(r) == 'number' then
    return { r, r }
  end
  if line then
    return { line, line }
  end
end

function M.new(title, mode)
  local s = M.state
  s.id = require('touragent.store').new_id()
  s.title = title
  s.mode = mode or 'tour'
  s.steps = {}
  s.cur = 0
  s.visited = {}
  s.awaiting = false
  require('touragent.session').reset()
  require('touragent.follow').ready = nil
  require('touragent.ui.marks').clear()
  require('touragent.ui.marks').clear_comments()
  require('touragent.ui.panel').reset()
  return { ok = true, title = title, mode = s.mode }
end

--- Append steps. Returns the new step ids.
---@param steps table[]
function M.push(steps)
  if type(steps) ~= 'table' or #steps == 0 then
    error('steps must be a non-empty array')
  end
  local s = M.state
  local first_new = #s.steps + 1
  local ids, warnings = {}, {}
  for _, raw in ipairs(steps) do
    s.seq = s.seq + 1
    local step = {
      id = s.seq,
      kind = raw.kind == 'change' and 'change' or 'explain',
      file = M.abspath(raw.file),
      range = norm_range(raw.range, raw.line),
      title = raw.title or '',
      note = raw.note or '',
    }
    if step.kind == 'change' then
      require('touragent.changes').prepare(step)
    elseif vim.fn.filereadable(step.file) == 0 then
      error(('file not found: %s'):format(raw.file))
    end
    step.range = step.range or { 1, 1 }
    if step.conflict then
      warnings[#warnings + 1] = step.conflict
    end
    s.steps[#s.steps + 1] = step
    ids[#ids + 1] = step.id
  end

  if s.cur == 0 or s.awaiting then
    -- These steps answer a `next` pressed at the end of the queue while no call was
    -- blocking; drop it so the following wait doesn't return before they are read.
    local session = require('touragent.session')
    if session.pending_event == 'next' then
      session.pending_event = nil
    end
    s.awaiting = false
    M.go(first_new, { user = false })
  else
    require('touragent.ui.panel').render()
    require('touragent.follow').announce_queued()
  end
  require('touragent.store').schedule()
  return { step_ids = ids, total = #s.steps, current = M.current() and M.current().id, warnings = warnings }
end

function M.current()
  return M.state.steps[M.state.cur]
end

function M.index_of(id)
  for i, st in ipairs(M.state.steps) do
    if st.id == id then
      return i
    end
  end
end

---@param idx integer
---@param opts? { user?: boolean }
function M.go(idx, opts)
  local s = M.state
  local step = s.steps[idx]
  if not step then
    return
  end
  s.cur = idx
  s.visited[step.id] = true
  require('touragent.follow').show(step, opts or {})
  require('touragent.ui.panel').render()
  require('touragent.store').schedule()
end

function M.next()
  local s = M.state
  if s.cur < #s.steps then
    M.go(s.cur + 1, { user = true })
    return
  end
  if #s.steps == 0 then
    require('touragent.util').notify('no tour steps yet')
    return
  end
  s.awaiting = true
  local session = require('touragent.session')
  session.emit('next')
  require('touragent.ui.panel').render()
  if session.linked() then
    require('touragent.util').notify('end of queue — waiting for the agent…')
  end
end

function M.prev()
  if M.state.cur > 1 then
    M.go(M.state.cur - 1, { user = true })
  end
end

function M.goto_current()
  if M.state.cur > 0 then
    M.go(M.state.cur, { user = true })
  end
end

function M.stop()
  M.state.awaiting = false
  require('touragent.session').emit('stop')
  require('touragent.util').notify('stop sent to agent')
  require('touragent.ui.panel').render()
end

function M.clear()
  M.new(nil, 'tour')
end

function M.summary()
  local s = M.state
  local cur = M.current()
  return {
    title = s.title,
    mode = s.mode,
    total = #s.steps,
    current_index = s.cur,
    current_step = cur and { id = cur.id, file = M.relpath(cur.file), range = cur.range, title = cur.title }
      or nil,
    user_waiting_for_more = s.awaiting,
    -- Lets the agent pick up a tour the user resumed from disk (:TourResume).
    steps = vim.tbl_map(function(st)
      return { id = st.id, title = st.title, file = M.relpath(st.file), kind = st.kind }
    end, s.steps),
  }
end

--- Markdown export of the whole timeline (with comment threads).
function M.export()
  local s = M.state
  local lines = { '# ' .. (s.title or 'Tour'), '' }
  local comments = require('touragent.session').comments
  for i, st in ipairs(s.steps) do
    lines[#lines + 1] = ('## %d. %s'):format(i, st.title ~= '' and st.title or M.relpath(st.file))
    lines[#lines + 1] = ('`%s:%d-%d`%s'):format(
      M.relpath(st.file),
      st.range[1],
      st.range[2],
      st.kind == 'change' and ' (change)' or ''
    )
    lines[#lines + 1] = ''
    vim.list_extend(lines, vim.split(st.note, '\n', { plain = true }))
    for _, c in ipairs(comments) do
      if c.step_id == st.id and not c.btw then
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('> **you** (%s:%d-%d): %s'):format(c.file, c.range[1], c.range[2], c.text)
        for _, r in ipairs(c.replies) do
          for _, l in ipairs(vim.split(r.text, '\n', { plain = true })) do
            lines[#lines + 1] = '> ' .. l
          end
        end
      end
    end
    lines[#lines + 1] = ''
  end
  local btws = vim.tbl_filter(function(c)
    return c.btw
  end, comments)
  if #btws > 0 then
    lines[#lines + 1] = '## btw'
    for _, c in ipairs(btws) do
      lines[#lines + 1] = ''
      lines[#lines + 1] = '> **you**: ' .. c.text
      for _, r in ipairs(c.replies) do
        for _, l in ipairs(vim.split(r.text, '\n', { plain = true })) do
          lines[#lines + 1] = '> ' .. l
        end
      end
    end
  end
  return lines
end

return M
