-- Minimal init for the headless test suite. Puts this checkout and mini.nvim on 'rtp'.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local mini = vim.env.TOURAGENT_MINI_PATH
if not mini or mini == '' then
  -- Outside the nix devShell: fetch mini.nvim once into the gitignored .tests/ dir.
  mini = root .. '/.tests/mini.nvim'
  if vim.fn.isdirectory(mini) == 0 then
    vim.fn.system({ 'git', 'clone', '--depth=1', 'https://github.com/echasnovski/mini.nvim', mini })
  end
end

-- Isolated runtimepath: drop the developer's config/site dirs (their plugins and parsers)
-- but keep whatever the nvim build itself ships (e.g. nix wrapper parser dirs).
local user_dirs = { vim.fn.stdpath('config'), vim.fn.stdpath('data'), vim.fn.stdpath('state') }
local rtp = { root, mini }
for _, p in ipairs(vim.opt.rtp:get()) do
  local user = false
  for _, d in ipairs(user_dirs) do
    user = user or vim.startswith(p, d)
  end
  if not user then
    rtp[#rtp + 1] = p
  end
end
vim.opt.rtp = rtp
vim.opt.packpath = {}
vim.opt.swapfile = false
vim.g.touragent_root = root

require('mini.test').setup({
  collect = {
    find_files = function()
      return vim.fn.globpath(root .. '/tests', '**/test_*.lua', true, true)
    end,
  },
})
