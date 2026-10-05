return {
  "akinsho/toggleterm.nvim",
  version = "*",
  keys = {
    { [[<C-\>]], desc = "Toggle Terminal" },
    { "<leader>tf", function()
      require("toggleterm").toggle(0, nil, nil, "float")
    end, desc = "Float Terminal" },
    { "<leader>th", function()
      require("toggleterm").toggle(0, 15, nil, "horizontal")
    end, desc = "Horizontal Terminal" },
    { "<leader>tv", function()
      require("toggleterm").toggle(0, nil, nil, "vertical")
    end, desc = "Vertical Terminal" },
  },
  opts = {
    open_mapping = [[<C-\>]],
    direction = "float",
    float_opts = {
      border = "curved",
    },
  },
}
