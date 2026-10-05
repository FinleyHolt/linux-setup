 -- lua/plugins/telescope.lua



return {

  "nvim-telescope/telescope.nvim",

  tag = "0.1.8",

  dependencies = { "nvim-lua/plenary.nvim" },

  config = function()

    -- Telescope specific keymaps and settings

    local builtin = require("telescope.builtin")



    -- Keymaps for Telescope functions

    vim.keymap.set('n', '<C-f>', builtin.find_files, {})

    vim.keymap.set('n', '<C-l>', builtin.live_grep, {})

    vim.keymap.set('n', '<C-p>', ':Neotree filesystem reveal left<CR>', {})

  end

}

