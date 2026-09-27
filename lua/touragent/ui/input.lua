-- Floating multi-line input used for comments. <C-s> (or <CR> in normal mode) submits,
-- q / <Esc> in normal mode cancels.
local M = {}

---@param opts { title: string, on_submit: fun(text: string) }
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local width = math.min(80, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = 5,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. opts.title .. ' ',
    footer = ' Ctrl-s send · q cancel ',
    footer_pos = 'right',
  })
  vim.wo[win].wrap = true

  local done = false
  local function close()
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd('stopinsert')
  end
  local function submit()
    if done then
      return
    end
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    close()
    if text ~= '' then
      opts.on_submit(text)
    end
  end
  local o = { buffer = buf, nowait = true }
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, o)
  vim.keymap.set('n', '<CR>', submit, o)
  vim.keymap.set('n', 'q', close, o)
  vim.keymap.set('n', '<Esc>', close, o)
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })
  vim.cmd('startinsert')
  return buf, win
end

return M
