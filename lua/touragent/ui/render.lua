-- Native renderer for the tour panel: turns the panel's markdown into plain text plus
-- highlights. Markup is hidden, fenced code is highlighted by treesitter in its own
-- language, and text is hard-wrapped with hanging indents, so it reads like code
-- without depending on a markdown plugin.
local M = {}

M.ns = vim.api.nvim_create_namespace('touragent.render')

-- Language of the code being toured: untagged fences and inline code use it.
local ctx_lang = nil ---@type string|nil
local inline_code_hls -- defined below code_highlights()

-- Panel highlight groups → default links (defined by marks.setup_highlights).
M.groups = {
  TourAgentTitle = '@markup.heading.1',
  TourAgentHeading = '@markup.heading.2',
  TourAgentSection = '@markup.heading.3',
  TourAgentStrong = '@markup.strong',
  TourAgentEmph = '@markup.italic',
  TourAgentCode = '@markup.raw',
  TourAgentLink = '@markup.link',
  TourAgentBullet = '@markup.list',
  TourAgentCodeBlock = 'CursorLine',
  TourAgentMuted = 'Comment',
  TourAgentRule = 'WinSeparator',
  TourAgentYou = 'DiagnosticInfo',
  TourAgentAgent = 'DiagnosticOk',
  TourAgentWarn = 'DiagnosticWarn',
  TourAgentKey = 'Special',
  TourAgentCurrent = 'DiagnosticWarn',
  TourAgentCurrentLine = 'CursorLine',
  TourAgentDone = 'DiagnosticOk',
  TourAgentStateWaiting = 'DiagnosticWarn',
  TourAgentStateWorking = 'DiagnosticInfo',
  TourAgentStateOff = 'DiagnosticError',
}

local callouts = {
  QUESTION = 'TourAgentYou',
  NOTE = 'TourAgentAgent',
  WARNING = 'TourAgentWarn',
}

--- Split inline markdown into segments { text, hl, atomic? }.
---@param s string
---@param base? string highlight group for plain text
---@return table[]
local function inline(s, base)
  local out, plain = {}, {}
  local function flush()
    if #plain > 0 then
      out[#out + 1] = { text = table.concat(plain), hl = base }
      plain = {}
    end
  end
  local function nested(inner, hl)
    flush()
    vim.list_extend(out, inline(inner, hl))
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local two = s:sub(i, i + 1)
    local handled = false
    if c == '`' then
      local ticks = s:match('^`+', i)
      local close = s:find(ticks, i + #ticks, true)
      if close then
        flush()
        local code = s:sub(i + #ticks, close - 1)
        if #ticks > 1 then
          code = vim.trim(code)
        end
        out[#out + 1] = { text = code, hl = 'TourAgentCode', atomic = true, code = true }
        i, handled = close + #ticks, true
      end
    elseif two == '**' or two == '__' then
      local close = s:find(two, i + 2, true)
      if close and close > i + 2 then
        nested(s:sub(i + 2, close - 1), 'TourAgentStrong')
        i, handled = close + 2, true
      end
    elseif c == '*' or c == '_' then
      local close = s:find(c, i + 1, true)
      local prev = i > 1 and s:sub(i - 1, i - 1) or ' '
      local word_inner = c == '_' and prev:match('%w')
      if close and close > i + 1 and not s:sub(i + 1, i + 1):match('%s') and not word_inner then
        nested(s:sub(i + 1, close - 1), 'TourAgentEmph')
        i, handled = close + 1, true
      end
    elseif c == '[' then
      local text, after = s:match('^%[([^%]]+)%]%([^)]+%)()', i)
      if text then
        flush()
        out[#out + 1] = { text = text, hl = 'TourAgentLink' }
        i, handled = after, true
      end
    end
    if not handled then
      plain[#plain + 1] = c
      i = i + 1
    end
  end
  flush()
  return out
end

--- Words (runs of non-space across segments) as lists of { text, hl } pieces.
local function words(segments)
  local out, cur = {}, nil
  local function piece(text, hl, code)
    if not cur then
      cur = {}
      out[#out + 1] = cur
    end
    cur[#cur + 1] = { text = text, hl = hl, code = code }
  end
  for _, seg in ipairs(segments) do
    if seg.atomic then
      piece(seg.text, seg.hl, seg.code)
    else
      for space, word in seg.text:gmatch('(%s*)(%S*)') do
        if space ~= '' then
          cur = nil
        end
        if word ~= '' then
          piece(word, seg.hl)
        end
      end
    end
  end
  return out
end

local function word_width(w)
  local n = 0
  for _, p in ipairs(w) do
    n = n + vim.fn.strdisplaywidth(p.text)
  end
  return n
end

--- Fill `segments` into lines of at most `width` cells.
---@return { text: string, hls: table[] }[]
local function wrap(segments, width, first_prefix, next_prefix, prefix_hl)
  local lines = {}
  local line
  local function new_line(prefix)
    line = { parts = {}, width = vim.fn.strdisplaywidth(prefix), empty = true }
    if prefix ~= '' then
      line.parts[1] = { text = prefix, hl = prefix_hl }
    end
    lines[#lines + 1] = line
  end
  new_line(first_prefix)
  for _, w in ipairs(words(segments)) do
    local ww = word_width(w)
    if not line.empty and line.width + 1 + ww > width then
      new_line(next_prefix)
    end
    if not line.empty then
      line.parts[#line.parts + 1] = { text = ' ' }
      line.width = line.width + 1
    end
    vim.list_extend(line.parts, w)
    line.width = line.width + ww
    line.empty = false
  end
  local out = {}
  for _, l in ipairs(lines) do
    local text, hls, col = {}, {}, 0
    for _, p in ipairs(l.parts) do
      text[#text + 1] = p.text
      local syntax = p.code and inline_code_hls(p.text, ctx_lang)
      if syntax then
        -- inline code in the tour's language: its own syntax colours over the code colour
        hls[#hls + 1] = { col, col + #p.text, p.hl, 90 }
        for _, h in ipairs(syntax) do
          hls[#hls + 1] = { col + h[1], col + h[2], h[3], h[4] }
        end
      elseif p.hl then
        hls[#hls + 1] = { col, col + #p.text, p.hl }
      end
      col = col + #p.text
    end
    out[#out + 1] = { text = table.concat(text), hls = hls }
  end
  return out
end

--- Treesitter highlights for a code block, as { row, col, end_col, hl, priority }.
---@param clean? boolean return nil unless the code parses without errors
local function code_highlights(code, lang, clean)
  local hls = {}
  lang = vim.treesitter.language.get_lang(lang) or lang
  if lang == '' or not pcall(vim.treesitter.language.add, lang) then
    return not clean and hls or nil
  end
  local src = table.concat(code, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
  if not ok or not parser then
    return not clean and hls or nil
  end
  local parsed, trees = pcall(parser.parse, parser, true)
  if clean and not (parsed and trees and trees[1] and not trees[1]:root():has_error()) then
    return nil
  end
  local count = 0
  parser:for_each_tree(function(tree, ltree)
    local query = vim.treesitter.query.get(ltree:lang(), 'highlights')
    if not query then
      return
    end
    for id, node in query:iter_captures(tree:root(), src) do
      local name = query.captures[id]
      if not name:match('^_') and name ~= 'spell' and name ~= 'nospell' and name ~= 'conceal' then
        -- Later captures of the same node are more specific: give them higher priority.
        count = count + 1
        local sr, sc, er, ec = node:range()
        for r = sr, er do
          local s = r == sr and sc or 0
          local e = r == er and ec or #(code[r + 1] or '')
          if e > s then
            hls[#hls + 1] = { r, s, e, '@' .. name .. '.' .. ltree:lang(), 100 + math.min(count, 20000) }
          end
        end
      end
    end
  end)
  return hls
end

local inline_cache = {}

--- Treesitter highlights for an inline code span, or nil when it isn't code in `lang`
--- (file paths, prose). Tries the span as is, as a statement, and as an expression.
inline_code_hls = function(text, lang)
  if not lang or text == '' then
    return nil
  end
  local key = lang .. '\0' .. text
  if inline_cache[key] == nil then
    inline_cache[key] = false
    for _, w in ipairs({ { '', '' }, { '', ';' }, { '_ = ', '' } }) do
      local hls = code_highlights({ w[1] .. text .. w[2] }, lang, true)
      if hls then
        local out = {}
        for _, h in ipairs(hls) do
          local s, e = math.max(h[2] - #w[1], 0), math.min(h[3] - #w[1], #text)
          -- plain variables keep the inline-code colour so the span still reads as code
          if e > s and not h[4]:match('^@variable%.[%w_]+$') then
            out[#out + 1] = { s, e, h[4], h[5] }
          end
        end
        inline_cache[key] = out
        break
      end
    end
  end
  return inline_cache[key] or nil
end

--- Render panel markdown to display lines.
---@param md string[]
---@param width integer
---@return string[] lines
---@return table[] hls { row, col, end_col, hl, priority? } — end_col = -1 means whole-line background
---@param lang? string language of the toured code (default for untagged fences, inline code)
function M.render(md, width, lang)
  local outer_lang = ctx_lang
  ctx_lang = lang
  width = math.max(width, 20)
  local lines, hls = {}, {}
  local function emit(text, line_hls)
    lines[#lines + 1] = text
    for _, h in ipairs(line_hls or {}) do
      hls[#hls + 1] = { #lines - 1, h[1], h[2], h[3], h[4] }
    end
  end
  local function emit_wrapped(segments, first_prefix, next_prefix, prefix_hl)
    for _, l in ipairs(wrap(segments, width, first_prefix, next_prefix, prefix_hl)) do
      emit(l.text, l.hls)
    end
  end

  local i = 1
  while i <= #md do
    local l = md[i]
    -- Pre-styled row from the panel ({ text, hls = { {col, end_col, hl} } }) is kept as is.
    local rich = type(l) == 'table' and l or nil
    local fence_lang = not rich and l:match('^%s*```%s*([%w_+-]*)')
    if rich then
      emit(rich.text, rich.hls)
    elseif fence_lang then
      local code = {}
      i = i + 1
      while i <= #md and not (type(md[i]) == 'table' or md[i]:match('^%s*```')) do
        code[#code + 1] = md[i]
        i = i + 1
      end
      local first = #lines
      for _, c in ipairs(code) do
        emit('  ' .. c)
        hls[#hls + 1] = { #lines - 1, 0, -1, 'TourAgentCodeBlock' }
      end
      for _, h in ipairs(code_highlights(code, fence_lang ~= '' and fence_lang or lang or '')) do
        hls[#hls + 1] = { first + h[1], h[2] + 2, h[3] + 2, h[4], h[5] }
      end
    elseif l:match('^>') then
      -- Blockquote / callout: render the inner block, then prefix it with a bar.
      local inner = {}
      while i <= #md and type(md[i]) == 'string' and md[i]:match('^>') do
        inner[#inner + 1] = md[i]:gsub('^> ?', '')
        i = i + 1
      end
      i = i - 1
      local bar_hl = 'TourAgentMuted'
      local kind, header = (inner[1] or ''):match('^%[!(%u+)%]%s*(.*)')
      if kind then
        bar_hl = callouts[kind] or bar_hl
        inner[1] = header ~= '' and ('**' .. header .. '**') or ''
      end
      local sub_lines, sub_hls = M.render(inner, width - 2, lang)
      local base = #lines
      for _, s in ipairs(sub_lines) do
        emit('▍ ' .. s, { { 0, #'▍', bar_hl } })
      end
      local shift = #'▍ '
      for _, h in ipairs(sub_hls) do
        local row, col, end_col = h[1] + base, h[2] + shift, h[3]
        if end_col ~= -1 then
          end_col = end_col + shift
        end
        hls[#hls + 1] = { row, col, end_col, h[4], h[5] }
      end
      if kind then
        -- Colour the callout header in the thread's colour.
        hls[#hls + 1] = { base, shift, #lines[base + 1], bar_hl }
      end
    elseif l:match('^#+%s') then
      local level, text = l:match('^(#+)%s+(.*)')
      local hl = (#level == 1 and 'TourAgentTitle')
        or (#level == 2 and 'TourAgentHeading')
        or 'TourAgentSection'
      emit_wrapped(inline(text, hl), '', '')
    elseif l:match('^%s*[-*+]%s') then
      local indent, text = l:match('^(%s*)[-*+]%s+(.*)')
      emit_wrapped(inline(text), indent .. '• ', indent .. '  ', 'TourAgentBullet')
    elseif l:match('^%s*%d+[.)]%s') then
      local indent, num, text = l:match('^(%s*)(%d+[.)])%s+(.*)')
      emit_wrapped(inline(text), indent .. num .. ' ', indent .. (' '):rep(#num + 1), 'TourAgentBullet')
    elseif l:match('^%s*[-*_][-*_][-*_]+%s*$') then
      emit(('─'):rep(width), { { 0, #('─'):rep(width), 'TourAgentRule' } })
    elseif l:match('^%s*|') then
      emit(l, { { 0, #l, 'TourAgentMuted' } })
    elseif l:match('^%s*$') then
      emit('')
    else
      emit_wrapped(inline(l), '', '')
    end
    i = i + 1
  end
  ctx_lang = outer_lang
  return lines, hls
end

--- Render `md` into `buf` (replacing its contents and highlights).
function M.apply(buf, md, width, lang)
  local lines, hls = M.render(md, width, lang)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, h in ipairs(hls) do
    local row, col, end_col, hl, prio = h[1], h[2], h[3], h[4], h[5]
    local opts = end_col == -1 and { line_hl_group = hl, priority = 10 }
      or { end_col = end_col, hl_group = hl, priority = prio or 200 }
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, end_col == -1 and 0 or col, opts)
  end
end

return M
