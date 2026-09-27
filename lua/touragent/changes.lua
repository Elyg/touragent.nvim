-- Change steps: controlled reload of agent-edited files and the diff baseline chain.
--
-- Baseline precedence for a change to `path`:
--   1. buffer lines captured just before we reloaded it (FileChangedShell / prepare)
--   2. oldest hook snapshot taken since the last change step for that file
--   3. what we showed last time (per-file snapshot after each change step)
--   4. git index version (`git show :path`)
--   5. empty (new file)
-- Unsaved user edits are never overwritten: the step is flagged as a conflict instead.
local M = {}

M.captured = {} ---@type table<string, string[]>
M.known = {} ---@type table<string, string[]>
local group = nil

local function read_disk(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  return vim.fn.readfile(path)
end

local function buf_for(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
end

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

--- Take over FileChangedShell while linked so we can capture pre-reload lines.
function M.attach()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup('touragent_changes', { clear = true })
  vim.api.nvim_create_autocmd('FileChangedShell', {
    group = group,
    callback = function(ev)
      local path = vim.fs.normalize(vim.api.nvim_buf_get_name(ev.buf))
      if vim.v.fcs_reason ~= 'changed' then
        vim.v.fcs_choice = 'ask'
        return
      end
      if vim.bo[ev.buf].modified then
        vim.v.fcs_choice = '' -- keep the user's unsaved edits; the change step reports it
        return
      end
      M.captured[path] = M.captured[path] or vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
      vim.v.fcs_choice = 'reload'
    end,
  })
end

function M.detach()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
end

local function git_index(path)
  local root = require('touragent.registry').git_root(vim.fs.dirname(path))
  if not root then
    return nil
  end
  local rel = path:sub(#root + 2)
  local res = vim.system({ 'git', '-C', root, 'show', ':' .. rel }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local lines = vim.split(res.stdout, '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

--- Baseline for `path` per the precedence above. Returns (lines, source).
function M.baseline(path)
  if M.captured[path] then
    return M.captured[path], 'buffer'
  end
  local snap = require('touragent.snapshots').oldest(path)
  if snap then
    return snap, 'hook'
  end
  if M.known[path] then
    return M.known[path], 'previous-step'
  end
  local idx = git_index(path)
  if idx then
    return idx, 'git-index'
  end
  return {}, 'empty'
end

---@param old string[]
---@param new string[]
function M.hunks(old, new)
  local a = #old > 0 and (table.concat(old, '\n') .. '\n') or ''
  local b = #new > 0 and (table.concat(new, '\n') .. '\n') or ''
  local idx = vim.text.diff(a, b, { result_type = 'indices', algorithm = 'histogram' })
  local hunks = {}
  for _, h in ipairs(idx or {}) do
    hunks[#hunks + 1] = { old_start = h[1], old_count = h[2], new_start = h[3], new_count = h[4] }
  end
  return hunks
end

--- Step range covering all hunks (in new-file lines).
function M.range_of(hunks, new_len)
  local s, e
  for _, h in ipairs(hunks) do
    local hs = math.max(1, h.new_count > 0 and h.new_start or h.new_start)
    local he = h.new_count > 0 and (h.new_start + h.new_count - 1) or hs
    s = s and math.min(s, hs) or hs
    e = e and math.max(e, he) or he
  end
  if not s then
    return { 1, 1 }
  end
  return { math.min(s, math.max(1, new_len)), math.min(e, math.max(1, new_len)) }
end

--- Force-reload a buffer from disk, capturing its current lines as the baseline.
function M.reload(buf, path)
  M.captured[path] = M.captured[path] or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('silent! edit!')
  end)
end

--- Fill in step.diff / step.range / step.conflict for a change step.
---@param step touragent.Step
function M.prepare(step)
  local path = step.file
  local disk = read_disk(path)
  if not disk then
    -- Deleted file: show nothing but a note.
    step.conflict = nil
    step.diff = nil
    step.deleted = true
    return
  end
  local buf = buf_for(path)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if not same(lines, disk) then
      if vim.bo[buf].modified then
        step.conflict = ("unsaved edits in %s — the agent's change is not loaded in the editor"):format(
          require('touragent.timeline').relpath(path)
        )
        return
      end
      M.reload(buf, path)
    end
  end

  local old, source = M.baseline(path)
  local hunks = M.hunks(old, disk)
  step.diff = { hunks = hunks, old = old, source = source }
  if not step.range then
    step.range = M.range_of(hunks, #disk)
  end

  -- This step is now the baseline for the next change to the same file.
  M.captured[path] = nil
  require('touragent.snapshots').consume(path)
  M.known[path] = disk
end

--- :TourReload — take the agent's version of the current step's file (discarding unsaved
--- edits) and recompute the step.
function M.reload_current()
  local tl = require('touragent.timeline')
  local step = tl.current()
  if not step or step.kind ~= 'change' then
    vim.notify('[touragent] current step is not a change step', vim.log.levels.WARN)
    return
  end
  local buf = buf_for(step.file)
  if buf then
    M.captured[step.file] = M.captured[step.file] or M.known[step.file]
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('silent! edit!')
    end)
  end
  step.conflict = nil
  step.range = nil
  M.prepare(step)
  step.range = step.range or { 1, 1 }
  tl.go(tl.state.cur, { user = true })
end

--- :TourDiff — cumulative diff vs HEAD (diffview.nvim when available).
function M.diff_head()
  if vim.fn.exists(':DiffviewOpen') == 2 then
    vim.cmd('DiffviewOpen')
    return
  end
  local tl = require('touragent.timeline')
  local step = tl.current()
  local path = step and step.file or vim.api.nvim_buf_get_name(0)
  local root = require('touragent.registry').git_root(vim.fs.dirname(path))
  if not root then
    vim.notify('[touragent] not in a git repository', vim.log.levels.WARN)
    return
  end
  local res = vim
    .system({ 'git', '-C', root, 'show', 'HEAD:' .. path:sub(#root + 2) }, { text = true })
    :wait()
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  vim.cmd('diffthis')
  vim.cmd('vnew')
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(res.stdout or '', '\n', { plain = true }))
  vim.cmd('diffthis')
end

return M
