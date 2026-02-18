-- === General Options ===

local opt = {}



-- Basic settings

vim.opt.expandtab = true       -- Convert tabs to spaces

vim.opt.tabstop = 4            -- Number of spaces that a <Tab> counts for

vim.opt.softtabstop = 4        -- Number of spaces for editing operations (like Tab/Backspace)

vim.opt.shiftwidth = 4         -- Number of spaces for auto-indent (used by >>, <<, ==)

vim.opt.smarttab = true        -- Makes <Tab> insert spaces according to shiftwidth

vim.opt.autoindent = true      -- Copy indent from the current line when starting a new line

vim.opt.smartindent = true     -- Smart auto-indentation on new lines

vim.opt.wrap = true            -- Enable line wrapping
vim.opt.linebreak = true       -- Wrap at word boundaries, not mid-word

-- Clipboard settings

vim.opt.clipboard = "unnamedplus"  -- Use system clipboard for all operations

-- Disable unused providers (suppress warnings in :checkhealth)

vim.g.loaded_perl_provider = 0    -- Disable Perl provider

vim.g.loaded_ruby_provider = 0    -- Disable Ruby provider

vim.g.loaded_node_provider = 0    -- Disable Node.js provider

vim.g.loaded_python3_provider = 0 -- Disable Python provider (not needed for LSP)



-- Bootstrap lazy.nvim

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not (vim.uv or vim.loop).fs_stat(lazypath) then

  local lazyrepo = "https://github.com/folke/lazy.nvim.git"

  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })

  if vim.v.shell_error ~= 0 then

    vim.api.nvim_echo({

      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },

      { out, "WarningMsg" },

      { "\nPress any key to exit..." },

    }, true, {})

    vim.fn.getchar()

    os.exit(1)

  end

end

vim.opt.rtp:prepend(lazypath)



-- === Plugins Setup ===

local plugins = require("plugins")  -- Loading from lua/plugins.lua



-- === Lazy.nvim Setup ===

require("lazy").setup(plugins, {
  rocks = {
    enabled = false,  -- Disable luarocks support (not needed)
  },
})



-- === Options Configuration ===

local opt_config = {}



-- Set leader keys

vim.g.mapleader = " "  -- Space as global leader key

vim.g.maplocalleader = "\\"  -- Backslash as local leader key



-- Keymaps for Telescope

local builtin = require("telescope.builtin")

vim.keymap.set('n', '<C-f>', builtin.find_files, {})

vim.keymap.set('n', '<C-l>', builtin.live_grep, {})

vim.keymap.set('n', '<C-p>', ':Neotree filesystem reveal left<CR>', {})

