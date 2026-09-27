-- touragent MCP server entry point:  nvim -l mcp/server.lua
-- Speaks MCP over stdio and drives the user's nvim over its msgpack-RPC socket.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.g.touragent_root = root

require('touragent.server.main').run()
