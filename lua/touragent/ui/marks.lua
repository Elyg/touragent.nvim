-- Extmarks for the current step (range highlight, sign, anchor tag, change overlay) and for
-- comment tags.
local M = {}

M.ns = vim.api.nvim_create_namespace('touragent')
M.ns_comments = vim.api.nvim_create_namespace('touragent_comments')

function M.setup_highlights()
  local links = {
    TourAgentRange = 'CursorLine',
    TourAgentSign = 'DiagnosticInfo',
    TourAgentTag = 'DiagnosticVirtualTextInfo',
    TourAgentAdd = 'DiffAdd',
    TourAgentDelete = 'DiffDelete',
    TourAgentConflict = 'DiagnosticVirtualTextWarn',
    TourAgentComment = 'DiagnosticVirtualTextHint',
  }
  links = vim.tbl_extend('force', links, require('touragent.ui.render').groups)
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  -- User overrides from setup({ highlights = … }); re-applied on every ColorScheme.
  for name, spec in pairs(require('touragent.config').options.highlights or {}) do
    vim.api.nvim_set_hl(0, name, type(spec) == 'string' and { link = spec } or spec)
  end
end

function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    end
  end
end

function M.clear_comments()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns_comments, 0, -1)
    end
  end
end

local function clamp(buf, line)
  return math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf)))
end

---@param step touragent.Step
---@param buf integer
function M.show(step, buf)
  M.clear()
  local tl = require('touragent.timeline')
  local idx = tl.index_of(step.id) or 0
  local s, e = clamp(buf, step.range[1]), clamp(buf, step.range[2])

  local added = {}
  if step.diff then
    for _, h in ipairs(step.diff.hunks) do
      for l = h.new_start, h.new_start + h.new_count - 1 do
        added[l] = true
      end
    end
  end

  for l = s, e do
    if not added[l] then
      vim.api.nvim_buf_set_extmark(buf, M.ns, l - 1, 0, { line_hl_group = 'TourAgentRange', priority = 10 })
    end
  end

  if step.diff then
    local width = 200
    for _, h in ipairs(step.diff.hunks) do
      for l = h.new_start, h.new_start + h.new_count - 1 do
        if l >= 1 and l <= vim.api.nvim_buf_line_count(buf) then
          vim.api.nvim_buf_set_extmark(buf, M.ns, l - 1, 0, { line_hl_group = 'TourAgentAdd', priority = 11 })
        end
      end
      if h.old_count > 0 then
        local virt = {}
        for i = h.old_start, h.old_start + h.old_count - 1 do
          local text = (step.diff.old[i] or ''):gsub('\t', '    ')
          virt[#virt + 1] = { { text .. string.rep(' ', math.max(0, width - #text)), 'TourAgentDelete' } }
        end
        local row, above
        if h.new_count > 0 then
          row, above = h.new_start - 1, true
        elseif h.new_start == 0 then
          row, above = 0, true
        else
          row, above = h.new_start - 1, false
        end
        row = math.max(0, math.min(row, vim.api.nvim_buf_line_count(buf) - 1))
        vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, { virt_lines = virt, virt_lines_above = above })
      end
    end
  end

  local label = ('◆ %d/%d'):format(idx, #tl.state.steps)
  if step.title ~= '' then
    label = label .. ' · ' .. step.title
  end
  local chunks = {}
  if step.conflict then
    chunks[#chunks + 1] = { '⚠ unsaved edits — agent change not loaded ', 'TourAgentConflict' }
  end
  chunks[#chunks + 1] = { ' ' .. label .. ' ', 'TourAgentTag' }
  vim.api.nvim_buf_set_extmark(buf, M.ns, s - 1, 0, {
    virt_text = chunks,
    virt_text_pos = 'eol',
    sign_text = '▶',
    sign_hl_group = 'TourAgentSign',
    priority = 20,
  })
end

function M.comment_tag(c)
  local buf = require('touragent.util').load(c.abs or c.file)
  local line = clamp(buf, c.range[1])
  vim.api.nvim_buf_set_extmark(buf, M.ns_comments, line - 1, 0, {
    virt_text = { { (' ✎ #%d '):format(c.id), 'TourAgentComment' } },
    virt_text_pos = 'eol',
    priority = 15,
  })
end

return M
