-- lua/plugins/neotree.lua



return {

  "nvim-neo-tree/neo-tree.nvim",

  branch = "v3.x",

  dependencies = {

    "nvim-lua/plenary.nvim",

    "nvim-tree/nvim-web-devicons",

    "MunifTanjim/nui.nvim",

  },

  config = function()

    -- NeoTree specific setup

    require("neo-tree").setup({

      -- Your NeoTree settings here

    })

  end

}
