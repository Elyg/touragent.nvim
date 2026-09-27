-- Validate the Claude Code plugin packaging: manifests parse, referenced files exist,
-- skills have frontmatter. Run with: nvim -l scripts/validate-plugin.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local errors = {}
local function fail(msg)
  errors[#errors + 1] = msg
end

local function json(path)
  local f = io.open(root .. '/' .. path, 'r')
  if not f then
    fail('missing ' .. path)
    return nil
  end
  local ok, data = pcall(vim.json.decode, f:read('*a'))
  f:close()
  if not ok then
    fail(('%s: invalid JSON (%s)'):format(path, data))
    return nil
  end
  return data
end

local function exists(rel)
  return vim.uv.fs_stat(root .. '/' .. rel) ~= nil
end

local plugin = json('.claude-plugin/plugin.json')
if plugin then
  if plugin.name ~= 'touragent' then
    fail('plugin.json: name must be "touragent"')
  end
  if plugin.version then
    fail('plugin.json: no version field — versions come from git tags')
  end
  for name, srv in pairs(plugin.mcpServers or {}) do
    for _, a in ipairs(srv.args or {}) do
      local rel = a:match('^%${CLAUDE_PLUGIN_ROOT}/(.+)$')
      if rel and not exists(rel) then
        fail(('plugin.json: mcpServers.%s references missing %s'):format(name, rel))
      end
    end
  end
  if not (plugin.mcpServers and plugin.mcpServers.touragent) then
    fail('plugin.json: mcpServers.touragent missing')
  end
end

local market = json('.claude-plugin/marketplace.json')
if market and not (market.plugins and market.plugins[1] and market.plugins[1].name == 'touragent') then
  fail('marketplace.json: must list the touragent plugin')
end

local hooks = json('hooks/hooks.json')
if hooks then
  for _, group in ipairs((hooks.hooks or {}).PreToolUse or {}) do
    for _, h in ipairs(group.hooks or {}) do
      local rel = h.command and h.command:match('%${CLAUDE_PLUGIN_ROOT}/([^"%s]+)')
      if rel and not exists(rel) then
        fail('hooks.json references missing ' .. rel)
      end
    end
  end
end

for name, kind in vim.fs.dir(root .. '/skills') do
  if kind == 'directory' then
    local f = io.open(root .. '/skills/' .. name .. '/SKILL.md', 'r')
    local text = f and f:read('*a') or ''
    if f then
      f:close()
    end
    local fm = text:match('^%-%-%-\n(.-)\n%-%-%-')
    if not fm then
      fail(('skills/%s/SKILL.md: missing frontmatter'):format(name))
    elseif not fm:match('name:%s*' .. name .. '\n') or not fm:match('description:%s*%S') then
      fail(('skills/%s/SKILL.md: frontmatter needs name: %s and a description'):format(name, name))
    end
  end
end

if #errors > 0 then
  io.stderr:write('plugin validation failed:\n  ' .. table.concat(errors, '\n  ') .. '\n')
  os.exit(1)
end
io.stdout:write('plugin packaging OK\n')
