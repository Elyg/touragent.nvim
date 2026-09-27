local M = {}

--- bufadd + bufload that tolerates errors from the user's FileType autocmds (a broken
--- ftplugin or parser must not abort a tour step; the buffer is loaded before they run).
---@param path string
---@return integer buf
function M.load(path)
  local buf = vim.fn.bufadd(path)
  if not vim.api.nvim_buf_is_loaded(buf) then
    pcall(vim.fn.bufload, buf)
  end
  return buf
end

--- User-facing message. Info goes to the tour panel's status line when it is open (and
--- `messages = 'panel'`); warnings/errors, or no panel, fall back to vim.notify.
---@param msg string
---@param level? integer vim.log.levels
function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  local panel = require('touragent.ui.panel')
  if
    level < vim.log.levels.WARN
    and require('touragent.config').options.messages == 'panel'
    and panel.is_open()
  then
    return panel.set_message(msg)
  end
  vim.notify('[touragent] ' .. msg, level)
end

local key_names = {
  cr = 'Enter',
  enter = 'Enter',
  ['return'] = 'Enter',
  esc = 'Esc',
  tab = 'Tab',
  bs = 'Backspace',
  space = 'Space',
  leader = 'Leader',
  up = 'Up',
  down = 'Down',
  left = 'Left',
  right = 'Right',
}
local modifiers = { c = 'Ctrl', s = 'Shift', m = 'Alt', a = 'Alt', d = 'Cmd' }

--- Human-readable label for a key in Vim notation: '<CR>' → 'Enter', '<C-s>' → 'Ctrl-s',
--- '<leader>an' → 'Leader an'.
---@param lhs string
---@return string
function M.key_label(lhs)
  return (
    lhs
      :gsub('<([^<>]+)>', function(inner)
        local parts = vim.split(inner, '-', { plain = true })
        local key = parts[#parts]
        local out = {}
        for i = 1, #parts - 1 do
          out[#out + 1] = modifiers[parts[i]:lower()] or parts[i]
        end
        out[#out + 1] = key_names[key:lower()] or key
        return table.concat(out, '-') .. ' '
      end)
      :gsub('%s+$', '')
  )
end

return M
