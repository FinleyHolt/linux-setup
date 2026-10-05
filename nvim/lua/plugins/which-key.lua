return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  opts = {
    spec = {
      { "<leader>c", group = "Code/CMake" },
      { "<leader>d", group = "Debug" },
      { "<leader>g", group = "Git" },
      { "<leader>m", group = "Markdown" },
      { "<leader>t", group = "Terminal" },
      { "<leader>x", group = "Diagnostics" },
      { "<leader>f", group = "Find" },
      { "<leader>a", group = "AI/Claude" },
    },
  },
}
