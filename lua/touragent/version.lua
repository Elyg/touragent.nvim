-- Wire-protocol version shared by the nvim plugin and the MCP server. Bump on any breaking
-- change to rpc.lua's dispatch surface so mismatched copies (Claude plugin cache vs. the
-- nvim pack dir) are detected at link time. Release versions come from git tags only.
return {
  PROTOCOL_VERSION = 1,
}
