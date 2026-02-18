return {
  "folke/todo-comments.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  event = { "BufReadPre", "BufNewFile" },
  keys = {
    { "<leader>xt", "<cmd>Trouble todo toggle<cr>", desc = "TODOs (Trouble)" },
    { "<leader>ft", "<cmd>TodoTelescope<cr>", desc = "Find TODOs" },
  },
  opts = {},
}
