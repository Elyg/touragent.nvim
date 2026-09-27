-- Pre-edit file snapshots written by the Claude PreToolUse hook (hooks/snapshot.lua):
--   <registry dir>/snapshots/<sha256(abs path)>/<unix ns timestamp>
-- Shared by the hook process (nvim -l) and the plugin.
local M = {}

function M.dir_for(path)
  return require('touragent.registry').dir() .. '/snapshots/' .. vim.fn.sha256(path)
end

--- Snapshot files for `path`, oldest first.
---@return string[]
function M.list(path)
  local dir = M.dir_for(path)
  local names = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name:match('^%d+$') then
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b)
    return #a == #b and a < b or #a < #b
  end)
  for i, n in ipairs(names) do
    names[i] = dir .. '/' .. n
  end
  return names
end

--- Copy the current on-disk content of `path` into a new snapshot (used by the hook).
function M.take(path)
  local src = io.open(path, 'rb')
  if not src then
    return nil -- new file: nothing to snapshot, baseline will be empty
  end
  local data = src:read('*a')
  src:close()
  local dir = M.dir_for(path)
  vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  local sec, usec = vim.uv.gettimeofday()
  local target = ('%s/%d%06d'):format(dir, sec, usec)
  local f = io.open(target, 'wb')
  if not f then
    return nil
  end
  f:write(data)
  f:close()
  return target
end

--- Oldest snapshot content (lines) for `path`, or nil.
function M.oldest(path)
  local files = M.list(path)
  if #files == 0 then
    return nil
  end
  return vim.fn.readfile(files[1])
end

--- Drop all snapshots for `path` (after a change step consumed them).
function M.consume(path)
  for _, f in ipairs(M.list(path)) do
    os.remove(f)
  end
  vim.uv.fs_rmdir(M.dir_for(path))
end

return M
