-- Claude Code PreToolUse hook (Edit|Write|MultiEdit): snapshot the file before the agent
-- edits it, so the change step can diff against the exact pre-edit content.
-- Invoked as `nvim -l hooks/snapshot.lua` with the hook JSON on stdin. Never blocks the
-- edit: any failure is swallowed and we always exit 0.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)

pcall(function()
  local ev = vim.json.decode(io.stdin:read('*a'), { luanil = { object = true, array = true } })
  local input = ev.tool_input or {}
  local path = input.file_path or input.notebook_path
  if type(path) ~= 'string' or path == '' then
    return
  end
  if not vim.startswith(path, '/') then
    path = (ev.cwd or vim.uv.cwd()) .. '/' .. path
  end
  require('touragent.snapshots').take(vim.fs.normalize(path))
end)
os.exit(0)
