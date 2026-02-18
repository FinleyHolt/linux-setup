-- lua/plugins.lua

return {

  require('plugins.telescope'),         -- Telescope plugin config
  require('plugins.neotree'),           -- Nvim Tree plugin config
  require('plugins.lualine'),           -- Lualine plugin config
  require('plugins.catppuccin'),        -- Catppuccin plugin config
  require('plugins.treesitter'),        -- Treesitter plugin config
  require('plugins.mason'),             -- Mason and LSP config
  require('plugins.statuscol'),         -- StatusCol plugin config

  -- Autocompletion & snippets
  require('plugins.blink-cmp'),         -- Autocompletion with LSP/path/snippets/buffer

  -- Editor enhancements
  require('plugins.autopairs'),         -- Auto-close brackets/parens/quotes
  require('plugins.indent-blankline'),  -- Visual indent guides
  require('plugins.which-key'),         -- Keybinding popup
  require('plugins.toggleterm'),        -- Integrated terminal

  -- Git
  require('plugins.gitsigns'),          -- Inline git hunks, blame, staging

  -- Formatting
  require('plugins.conform'),           -- Format-on-save with mason-tool-installer

  -- Debugging
  require('plugins.dap-ui'),            -- Visual debug UI

  -- Diagnostics
  require('plugins.trouble'),           -- Better diagnostics/quickfix list
  require('plugins.todo-comments'),     -- Highlight and search TODO/FIXME comments

  -- Language-specific
  require('plugins.cmake-tools'),       -- CMake generate/build/run
  require('plugins.markdown-preview'),  -- Live markdown preview in browser

}
