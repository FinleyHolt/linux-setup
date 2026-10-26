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

    -- Completion menu: no fill, so Ghostty's transparency shows through like the
    -- editor; a rounded border marks the edge. The selected row keeps its highlight.
    local p = require("catppuccin.palettes").get_palette()
    vim.api.nvim_set_hl(0, "BlinkCmpMenu", { fg = p.text, bg = "NONE" })
    vim.api.nvim_set_hl(0, "BlinkCmpMenuBorder", { fg = p.overlay0, bg = "NONE" })
    vim.api.nvim_set_hl(0, "BlinkCmpDoc", { fg = p.text, bg = "NONE" })
    vim.api.nvim_set_hl(0, "BlinkCmpDocBorder", { fg = p.overlay0, bg = "NONE" })

  end

}

