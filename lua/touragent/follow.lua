-- Follow mode: decides whether an agent-driven step may move the user's view, and does the
-- actual jump inside the "tour window" (the last focused normal window). Never steals focus
-- while the user is typing; announces the step instead.
local config = require('touragent.config')
local M = {}

M.enabled = nil ---@type boolean|nil nil = use config
M.last_typed = 0
M.tour_win = nil ---@type integer|nil
M.ready = nil ---@type integer|nil step id announced but not jumped to
local ignore_until = 0

function M.is_enabled()
  if M.enabled == nil then
    return config.options.follow
  end
  return M.enabled
end

function M.toggle()
  M.enabled = not M.is_enabled()
  require('touragent.util').notify('follow mode ' .. (M.enabled and 'on' or 'off'))
end

function M.on_activity()
  if vim.uv.now() >= ignore_until then
    M.last_typed = vim.uv.now()
  end
end

local function is_tour_win(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == '' and not require('touragent.ui.panel').is_panel_buf(buf)
end

function M.track_win()
  local win = vim.api.nvim_get_current_win()
  if is_tour_win(win) then
    M.tour_win = win
  end
end

function M.busy()
  local mode = vim.api.nvim_get_mode().mode
  local m = mode:sub(1, 1)
  if m == 'i' or m == 'R' or m == 'c' or m == 't' then
    return true
  end
  return vim.uv.now() - M.last_typed < config.options.idle_ms
end

function M.pick_win()
  if is_tour_win(M.tour_win) then
    return M.tour_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_tour_win(win) then
      M.tour_win = win
      return win
    end
  end
  -- Only special windows (e.g. just the panel): make room on the left.
  local cur = vim.api.nvim_get_current_win()
  vim.cmd('topleft vnew')
  M.tour_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
  return M.tour_win
end

---@param step touragent.Step
function M.load(step)
  local buf = require('touragent.util').load(step.file)
  vim.bo[buf].buflisted = true
  return buf
end

---@param step touragent.Step
function M.jump(step, buf)
  local win = M.pick_win()
  ignore_until = vim.uv.now() + 200
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'") -- jumplist entry so <C-o> returns
  end)
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local start = math.min(step.range[1], line_count)
  vim.api.nvim_win_set_cursor(win, { start, 0 })
  local height = vim.api.nvim_win_get_height(win)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = math.max(1, start - math.floor(height / 3)), lnum = start, col = 0 })
    vim.cmd('silent! normal! zv')
  end)
  M.ready = nil
end

---@param step touragent.Step
---@param opts { user?: boolean }
function M.show(step, opts)
  local buf = M.load(step)
  require('touragent.ui.marks').show(step, buf)
  local panel = require('touragent.ui.panel')
  panel.maybe_auto_open()
  if opts.user or (M.is_enabled() and not M.busy()) then
    M.jump(step, buf)
  else
    M.ready = step.id
    local tl = require('touragent.timeline')
    require('touragent.util').notify(
      ('▶ step %d/%d ready: %s'):format(tl.state.cur, #tl.state.steps, step.title)
    )
  end
  vim.cmd('redrawstatus')
end

function M.announce_queued()
  vim.cmd('redrawstatus')
end

--- Statusline component, e.g. `◆ 3/7` or `▶ 4/7 ready`.
function M.statusline()
  local tl = require('touragent.timeline')
  local s = tl.state
  if #s.steps == 0 then
    return ''
  end
  local session = require('touragent.session')
  local out = ('◆ %d/%d'):format(s.cur, #s.steps)
  if M.ready then
    out = ('▶ %d/%d ready'):format(s.cur, #s.steps)
  end
  local st = session.agent_state()
  if st == 'waiting' then
    out = out .. ' · your turn'
  elseif st == 'working' then
    out = out .. ' · agent working'
  end
  return out
end

return M
