-- MCP stdio framing: newline-delimited JSON-RPC 2.0 messages.
local M = {}

local decode_opts = { luanil = { object = true, array = true } }

--- Incremental decoder. feed() returns the complete messages decoded so far; malformed
--- lines are returned as { __parse_error = msg }.
function M.decoder()
  local buf = ''
  return {
    feed = function(data)
      buf = buf .. data
      local out = {}
      while true do
        local nl = buf:find('\n', 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1):gsub('\r$', '')
        buf = buf:sub(nl + 1)
        if line:find('%S') then
          local ok, msg = pcall(vim.json.decode, line, decode_opts)
          out[#out + 1] = ok and msg or { __parse_error = tostring(msg) }
        end
      end
      return out
    end,
  }
end

function M.encode(msg)
  msg.jsonrpc = '2.0'
  return vim.json.encode(msg) .. '\n'
end

function M.response(id, result)
  return { id = id, result = result }
end

function M.error(id, code, message)
  return { id = id == nil and vim.NIL or id, error = { code = code, message = message } }
end

return M
