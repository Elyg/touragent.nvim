-- The server-facing API. The MCP server (nvim -l) calls
--   nvim_exec_lua('return require("touragent.rpc").dispatch(...)', { method, params, token })
-- Handlers must return quickly; anything that waits (user input, LSP) returns
-- { __async = true } and later answers through session.resolve(token, result).
local session = require('touragent.session')
local timeline = require('touragent.timeline')
local M = {}

local function status()
  local follow = require('touragent.follow')
  local win = follow.tour_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    win = vim.api.nvim_get_current_win()
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)
  -- nvim_win_call returns only the first value, so pack both.
  local view = vim.api.nvim_win_call(win, function()
    return { vim.fn.line('w0'), vim.fn.line('w$') }
  end)
  local first, last = view[1], view[2]

  local selection = vim.NIL
  local vs, ve = vim.api.nvim_buf_get_mark(buf, '<'), vim.api.nvim_buf_get_mark(buf, '>')
  if vs[1] > 0 and ve[1] >= vs[1] then
    local lines = vim.api.nvim_buf_get_lines(buf, vs[1] - 1, math.min(ve[1], vs[1] + 199), false)
    selection = { range = { vs[1], ve[1] }, text = table.concat(lines, '\n') }
  end

  local buffers = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if #buffers >= 50 then
      break
    end
    if vim.bo[b].buflisted and vim.bo[b].buftype == '' and vim.api.nvim_buf_get_name(b) ~= '' then
      buffers[#buffers + 1] = {
        file = timeline.relpath(vim.api.nvim_buf_get_name(b)),
        modified = vim.bo[b].modified,
      }
    end
  end

  return {
    file = name ~= '' and timeline.relpath(name) or vim.NIL,
    filetype = vim.bo[buf].filetype,
    cursor = { line = cursor[1], col = cursor[2] + 1 },
    visible = { first = first, last = last },
    last_visual_selection = selection,
    buffers = buffers,
    timeline = timeline.summary(),
    follow = follow.is_enabled(),
    cwd = vim.uv.cwd(),
    git_root = timeline.root(),
    pid = vim.uv.os_getpid(),
  }
end

--- Short self-description, so an agent choosing between several nvims can tell the user
--- which is which. Read-only and cheap; works without a link.
local function describe()
  local follow = require('touragent.follow')
  local win = follow.tour_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    win = vim.api.nvim_get_current_win()
  end
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  local s = timeline.state
  return {
    file = name ~= '' and timeline.relpath(name) or vim.NIL,
    tour = #s.steps > 0 and { title = s.title or vim.NIL, mode = s.mode, cur = s.cur, total = #s.steps }
      or vim.NIL,
    linked_agent = session.link and (session.link.agent.name or 'agent') or vim.NIL,
  }
end

local handlers = {
  describe = describe,
  hello = function(p)
    return session.hello(p)
  end,
  bye = function()
    return session.bye()
  end,
  status = status,
  timeline_new = function(p)
    return timeline.new(p.title, p.mode)
  end,
  timeline_push = function(p)
    return timeline.push(p.steps)
  end,
  wait = function(_, token)
    return session.wait(token)
  end,
  cancel = function(p)
    return session.cancel(p.token)
  end,
  reply = function(p)
    return session.reply(p.comment_id, p.markdown)
  end,
  get_feedback = function()
    return { comments = session.drain() }
  end,
  diagnostics = function(p)
    return require('touragent.lsp').diagnostics(p)
  end,
  lsp = function(p, token)
    require('touragent.lsp').query(p, function(result)
      session.resolve(token, result)
    end)
    return { __async = true }
  end,
}

-- Results that already carry the user's comments (or must not drain them).
local no_piggyback =
  { hello = true, bye = true, wait = true, cancel = true, get_feedback = true, describe = true }

---@param method string
---@param params table|nil
---@param token string|nil
function M.dispatch(method, params, token)
  local h = handlers[method]
  if method ~= 'bye' and method ~= 'cancel' and method ~= 'describe' then
    session.touch()
  end
  if not h then
    return { error = 'unknown method: ' .. tostring(method) }
  end
  if params == vim.NIL or params == nil then
    params = {}
  end
  if token == vim.NIL then
    token = nil
  end
  local ok, res = pcall(h, params, token)
  if not ok then
    return { error = tostring(res):gsub('^[^:]+:%d+: ', '') }
  end
  res = res or {}
  if not res.__async and not no_piggyback[method] then
    res.pending_user_messages = session.drain()
  end
  return res
end

return M
