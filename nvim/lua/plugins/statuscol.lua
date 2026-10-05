-- lua/plugins/statuscol.lua

return {

    "luukvbaal/statuscol.nvim",  -- StatusCol plugin

    config = function()

      require("statuscol").setup({

        -- Status column configuration

        segments = {

          -- Left: Relative line number column

          { text = { require("statuscol.builtin").rel_lnumfunc }, click = "v:lua.ScLa" },



          -- Right: Absolute line number column

          { text = { require("statuscol.builtin").lnumfunc }, click = "v:lua.ScLa" },

        },

      })



      -- Enable absolute line numbers globally for the current line

      vim.opt.number = true          -- Show absolute line number for the current line

      vim.opt.relativenumber = true  -- Show relative line numbers for other lines

    end,

  }

