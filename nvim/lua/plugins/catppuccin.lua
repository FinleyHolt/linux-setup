-- lua/plugins/catppuccin.lua



return {

  "catppuccin/nvim",  -- Plugin name

  name = "catppuccin",  -- Plugin's local name

  priority = 1000,  -- To make sure it loads early

  config = function()

    -- Set colorscheme when the plugin is loaded

    vim.cmd.colorscheme("catppuccin")



    -- Additional highlight settings can be moved here

    vim.cmd("highlight Normal ctermbg=none guibg=none")

    vim.cmd("highlight NonText ctermbg=none guibg=none")

    vim.cmd("highlight StatusLine ctermbg=none guibg=none")

    vim.cmd("highlight LineNr ctermbg=none guibg=none")

  end

}

