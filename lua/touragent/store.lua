-- Saved tours: the timeline (steps, position, comment threads) is written as JSON after
-- every change, so a tour survives closing nvim and can be picked up with :TourResume.
--   stdpath('state')/touragent/tours/<project>/<tour id>.json
local M = {}

local KEEP = 30 -- saved tours kept per project (oldest pruned)
local DEBOUNCE_MS = 300

local timer = nil

local function enabled()
  return require('touragent.config').options.persist ~= false
end

--- Directory for the current project's tours.
function M.dir()
  local root = require('touragent.timeline').root()
  local name = vim.fs.basename(root):gsub('[^%w._-]', '_') .. '-' .. vim.fn.sha256(root):sub(1, 8)
  return vim.fn.stdpath('state') .. '/touragent/tours/' .. name
end

--- A fresh id for a new tour (sortable: newest last).
function M.new_id()
  return os.date('%Y%m%d-%H%M%S') .. ('-%04d'):format(math.random(0, 9999))
end

local function snapshot()
  local tl = require('touragent.timeline')
  local session = require('touragent.session')
  local s = tl.state
  local visited = {}
  for id in pairs(s.visited) do
    visited[#visited + 1] = id
  end
  local comments = {}
  for _, c in ipairs(session.comments) do
    comments[#comments + 1] = {
      id = c.id,
      file = c.file,
      abs = c.abs,
      range = c.range,
      selected_text = c.selected_text,
      text = c.text,
      step_id = c.step_id,
      replies = c.replies,
    }
  end
  return {
    version = 1,
    id = s.id,
    title = s.title,
    mode = s.mode,
    root = tl.root(),
    saved_at = os.time(),
    cur = s.cur,
    seq = s.seq,
    visited = visited,
    steps = s.steps,
    comments = comments,
    comment_seq = session.comment_seq,
  }
end

--- Write the current tour now. Empty timelines are not saved.
function M.save()
  local s = require('touragent.timeline').state
  if not enabled() or not s.id or #s.steps == 0 then
    return
  end
  local dir = M.dir()
  vim.fn.mkdir(dir, 'p')
  local ok, json = pcall(vim.json.encode, snapshot())
  if ok then
    vim.fn.writefile({ json }, dir .. '/' .. s.id .. '.json')
    M.prune(dir)
  end
end

--- Save soon (coalesces bursts of changes into one write).
function M.schedule()
  if not enabled() then
    return
  end
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(M.save))
end

--- Flush a pending save immediately (VimLeavePre).
function M.flush()
  if timer and timer:is_active() then
    timer:stop()
    M.save()
  end
end

function M.prune(dir)
  local files = vim.fn.glob(dir .. '/*.json', true, true)
  table.sort(files)
  for i = 1, #files - KEEP do
    vim.fn.delete(files[i])
  end
end

--- Saved tours, newest first: { id, title, mode, project, steps, cur, saved_at, path }.
---@param all? boolean every project, not just the current one
function M.list(all)
  local out = {}
  local pattern = all and (vim.fs.dirname(M.dir()) .. '/*/*.json') or (M.dir() .. '/*.json')
  for _, path in ipairs(vim.fn.glob(pattern, true, true)) do
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    end)
    if ok and type(data) == 'table' and data.steps then
      out[#out + 1] = {
        id = data.id,
        title = data.title,
        mode = data.mode or 'tour',
        project = data.root and vim.fs.basename(data.root) or nil,
        steps = #data.steps,
        cur = data.cur,
        saved_at = data.saved_at or 0,
        path = path,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.saved_at > b.saved_at
  end)
  return out
end

--- Load a saved tour into the editor, restoring position and comment threads.
---@param path string
function M.load(path)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'), { luanil = { object = true } })
  local tl = require('touragent.timeline')
  local session = require('touragent.session')
  tl.new(data.title, data.mode)
  local s = tl.state
  s.id = data.id -- keep saving into the same file
  s.steps = data.steps or {}
  s.seq = data.seq or #s.steps
  for _, id in ipairs(data.visited or {}) do
    s.visited[id] = true
  end
  for _, c in ipairs(data.comments or {}) do
    c.replies = c.replies or {}
    c.delivered = true -- the agent already saw them (or they belong to a past session)
    session.comments[#session.comments + 1] = c
    pcall(require('touragent.ui.marks').comment_tag, c)
  end
  session.comment_seq = data.comment_seq or #session.comments
  local cur = math.max(1, math.min(data.cur or 1, #s.steps))
  if #s.steps > 0 then
    tl.go(cur, { user = true })
  end
  return data
end

return M
