local M = {}

---@class touragent.Config
M.defaults = {
  -- Auto-jump to new steps (follow mode). Toggle at runtime with :TourFollow.
  follow = true,
  -- Don't steal focus if the user typed within this many ms (or is in insert mode).
  idle_ms = 3000,
  panel = {
    width = 60,
    -- Open the tour panel automatically when the first step of a timeline arrives.
    auto_open = true,
    -- 'native': plain text with highlights (markup hidden, code blocks highlighted by
    -- treesitter). 'markdown': raw markdown buffer for render-markdown & co.
    style = 'native',
    -- Timeline rows shown at the top of the panel (scrolls to keep the current step in view).
    timeline_max = 6,
  },
  -- Deliver kickoffs (:TourAsk) and idle-time comments to the agent's tmux pane.
  tmux_push = true,
  -- Message typed into the agent pane by :TourAsk. {loc} = file:range, {question} = input.
  -- Plain language triggers the tour skill in Claude Code and works with any agent; use
  -- e.g. '/touragent:tour {loc} {question}' to call the skill explicitly.
  ask_template = 'Use touragent to walk me through {loc} in nvim. {question}',
  -- :TourAgent — the agent command and the tmux pane size it opens in.
  agent = { cmd = 'claude', size = '45%' },
  -- Save tours to stdpath('state')/touragent/tours/ so :TourResume can reopen them.
  persist = true,
  -- Highlight overrides, e.g. { TourAgentRange = { bg = '#2a2f3a' }, TourAgentTag = 'Visual' }
  -- (a table is an nvim_set_hl spec, a string links to that group). See README → Highlights.
  highlights = {},
  -- Where info messages go: 'panel' shows them in the tour panel's status line while it
  -- is open (warnings still use vim.notify); 'notify' always uses vim.notify.
  messages = 'panel',
  -- Global keymaps; set to false to disable them all, or set any single one to false.
  keys = {
    ask = '<leader>aa',
    next = '<leader>an',
    prev = '<leader>ap',
    comment = '<leader>ac',
    go = '<leader>ag',
    panel = '<leader>at',
    follow = '<leader>af',
    stop = '<leader>aq',
    btw = '<leader>ab',
    wake = '<leader>aw',
    resume = '<leader>ar',
    agent = '<leader>ao',
  },
  -- Buffer-local keys inside the tour panel.
  panel_keys = {
    next = 'n',
    prev = 'p',
    comment = 'c',
    stop = 'q',
    go = '<CR>',
    btw = 'b',
    wake = 'w',
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.set(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  if opts and opts.keys == false then
    M.options.keys = false
  end
  return M.options
end

return M
