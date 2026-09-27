-- Read-only LSP queries on the user's configured language servers, for the agent's `lsp`
-- and `diagnostics` tools. Async: results are delivered through the done() callback.
local M = {}

local MAX_RESULTS = 100

local methods = {
  definition = 'textDocument/definition',
  type_definition = 'textDocument/typeDefinition',
  implementation = 'textDocument/implementation',
  references = 'textDocument/references',
  hover = 'textDocument/hover',
  symbols = 'textDocument/documentSymbol',
  incoming_calls = 'textDocument/prepareCallHierarchy',
  outgoing_calls = 'textDocument/prepareCallHierarchy',
}

M.kinds = vim.tbl_keys(methods)
table.sort(M.kinds)

local function rel(path)
  return require('touragent.timeline').relpath(path)
end

local line_cache = {}
local function line_text(path, lnum)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ''
  end
  line_cache[path] = line_cache[path] or (vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {})
  return line_cache[path][lnum] or ''
end

local function loc(uri, range)
  local path = vim.uri_to_fname(uri)
  local l = range.start.line + 1
  return { file = rel(path), line = l, col = range.start.character + 1, text = vim.trim(line_text(path, l)) }
end

local function locations(result)
  local out = {}
  if not result then
    return out
  end
  if result.uri or result.targetUri then
    result = { result }
  end
  for _, r in ipairs(result) do
    if #out >= MAX_RESULTS then
      break
    end
    out[#out + 1] = loc(r.uri or r.targetUri, r.range or r.targetSelectionRange)
  end
  return out
end

local symbol_kinds = vim.lsp.protocol.SymbolKind
-- Nested locals/literals are noise for an outline (some servers report every local and
-- `if` block); keep them only at the top level.
local nested_noise =
  { Variable = true, Constant = true, Package = true, String = true, Number = true, Boolean = true }

local function symbols(result, depth, out)
  out = out or {}
  for _, s in ipairs(result or {}) do
    if #out >= 300 then
      break
    end
    local range = s.range or (s.location and s.location.range)
    local kind = symbol_kinds[s.kind] or s.kind
    if not ((depth or 0) > 0 and nested_noise[kind]) then
      out[#out + 1] = {
        name = s.name,
        kind = kind,
        depth = depth or 0,
        start_line = range and range.start.line + 1,
        end_line = range and range['end'].line + 1,
      }
      if s.children then
        symbols(s.children, (depth or 0) + 1, out)
      end
    end
  end
  return out
end

local function wait_for_clients(buf, cb, tries)
  local clients = vim.lsp.get_clients({ bufnr = buf })
  local ready = #clients > 0 and vim.iter(clients):any(function(c)
    return c.initialized
  end)
  if ready or tries <= 0 then
    return cb(clients)
  end
  vim.defer_fn(function()
    wait_for_clients(buf, cb, tries - 1)
  end, 100)
end

local function position_for(buf, args)
  local lnum = math.max(1, math.floor(args.line or 1))
  local text = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ''
  local col0
  if args.symbol and args.symbol ~= '' then
    local s = text:find(args.symbol, 1, true)
    col0 = s and (s - 1) or nil
  end
  if not col0 and args.col then
    col0 = math.max(0, math.floor(args.col) - 1)
  end
  col0 = col0 or ((text:find('%S') or 1) - 1)
  return lnum - 1, col0, text
end

---@param args { kind: string, file: string, line?: integer, col?: integer, symbol?: string }
---@param done fun(result: table)
function M.query(args, done)
  local method = methods[args.kind]
  if not method then
    return done({
      error = ('unknown kind %q; one of: %s'):format(tostring(args.kind), table.concat(M.kinds, ', ')),
    })
  end
  local path = require('touragent.timeline').abspath(args.file)
  if vim.fn.filereadable(path) == 0 then
    return done({ error = 'file not found: ' .. args.file })
  end
  local buf = require('touragent.util').load(path)
  if vim.bo[buf].filetype == '' then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('filetype detect')
    end)
  end

  wait_for_clients(buf, function(clients)
    if #clients == 0 then
      return done({
        error = ('no language server attached to %s (filetype %q)'):format(args.file, vim.bo[buf].filetype),
      })
    end
    local row, col0, text = position_for(buf, args)
    local params = function(client)
      local character = vim.str_utfindex(text, client.offset_encoding or 'utf-16', col0, false)
      local p = {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = row, character = character },
      }
      if args.kind == 'references' then
        p.context = { includeDeclaration = false }
      elseif args.kind == 'symbols' then
        p.position = nil
      end
      return p
    end

    vim.lsp.buf_request_all(buf, method, params, function(results)
      local first_err
      for client_id, r in pairs(results) do
        if r.err then
          first_err = first_err or r.err.message
        elseif r.result and not vim.tbl_isempty(r.result) then
          local client = vim.lsp.get_client_by_id(client_id)
          return M.finish(args, r.result, client, buf, done)
        end
      end
      done({ kind = args.kind, results = {}, note = first_err or 'no results' })
    end)
  end, 50)
end

function M.finish(args, result, client, buf, done)
  local kind = args.kind
  if kind == 'hover' then
    local contents = result.contents
    local value = type(contents) == 'string' and contents
      or contents.value
      or table.concat(
        vim.tbl_map(function(c)
          return type(c) == 'string' and c or c.value
        end, contents),
        '\n'
      )
    return done({ kind = kind, hover = value })
  elseif kind == 'symbols' then
    return done({ kind = kind, symbols = symbols(result) })
  elseif kind == 'incoming_calls' or kind == 'outgoing_calls' then
    local item = result[1]
    local m = kind == 'incoming_calls' and 'callHierarchy/incomingCalls' or 'callHierarchy/outgoingCalls'
    client:request(m, { item = item }, function(err, calls)
      if err then
        return done({ error = err.message })
      end
      local out = {}
      for _, c in ipairs(calls or {}) do
        if #out >= MAX_RESULTS then
          break
        end
        local peer = c.from or c.to
        local l = loc(peer.uri, peer.selectionRange or peer.range)
        l.name = peer.name
        l.kind = symbol_kinds[peer.kind] or peer.kind
        out[#out + 1] = l
      end
      done({ kind = kind, symbol = item.name, calls = out })
    end, buf)
    return
  end
  done({ kind = kind, results = locations(result) })
end

---@param args { file?: string }
function M.diagnostics(args)
  local buf
  if args.file and args.file ~= '' then
    local path = require('touragent.timeline').abspath(args.file)
    buf = vim.fn.bufnr(path)
    if buf == -1 then
      return { diagnostics = {}, note = 'file not loaded in nvim; open it (e.g. via a tour step) first' }
    end
  end
  local sev = vim.diagnostic.severity
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if #out >= 200 then
      break
    end
    out[#out + 1] = {
      file = rel(vim.api.nvim_buf_get_name(d.bufnr)),
      line = d.lnum + 1,
      col = d.col + 1,
      severity = sev[d.severity],
      source = d.source,
      message = d.message,
    }
  end
  return { diagnostics = out }
end

return M
