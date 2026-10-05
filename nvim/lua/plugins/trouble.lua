return {
  "folke/trouble.nvim",
  cmd = "Trouble",
  keys = {
    { "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", desc = "Workspace Diagnostics" },
    { "<leader>xd", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>", desc = "Buffer Diagnostics" },
    { "<leader>xl", "<cmd>Trouble loclist toggle<cr>", desc = "Location List" },
    { "<leader>xq", "<cmd>Trouble quickfix toggle<cr>", desc = "Quickfix List" },
  },
  opts = {},
}
