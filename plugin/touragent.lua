if vim.g.loaded_touragent or vim.fn.has('nvim-0.12') == 0 then
  return
end
vim.g.loaded_touragent = true

require('touragent')._auto()
