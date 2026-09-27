-- tmux push: type text into the agent's pane (kickoff + idle-time comments).
local M = {}

---@param pane string tmux pane id (e.g. %12)
---@param text string
---@return boolean ok
function M.send(pane, text)
  if not pane or pane == '' or vim.fn.executable('tmux') == 0 then
    return false
  end
  -- One line only: a newline would submit a partial prompt in most agent TUIs.
  text = text:gsub('\r?\n', ' ')
  local res = vim.system({ 'tmux', 'send-keys', '-t', pane, '-l', text }):wait()
  if res.code ~= 0 then
    return false
  end
  -- Separate Enter after a short pause so the TUI treats it as submit, not pasted newline.
  vim.defer_fn(function()
    vim.system({ 'tmux', 'send-keys', '-t', pane, 'Enter' })
  end, 150)
  return true
end

--- Open a pane next to nvim's running `cmd` in `cwd` with extra environment.
---@param opts { cmd: string, cwd: string, env: table<string, string>, size: string }
---@return string|nil pane id of the new pane
function M.split(opts)
  if not vim.env.TMUX or vim.fn.executable('tmux') == 0 then
    return nil
  end
  local args = { 'tmux', 'split-window', '-h', '-P', '-F', '#{pane_id}', '-l', opts.size, '-c', opts.cwd }
  if vim.env.TMUX_PANE then
    vim.list_extend(args, { '-t', vim.env.TMUX_PANE })
  end
  for k, v in pairs(opts.env) do
    vim.list_extend(args, { '-e', k .. '=' .. v })
  end
  args[#args + 1] = opts.cmd
  local res = vim.system(args, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout)
end

function M.focus(pane)
  return vim.system({ 'tmux', 'select-pane', '-t', pane }):wait().code == 0
end

return M
