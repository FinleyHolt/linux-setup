return {
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    keys = {
      { "<leader>cf", function() require("conform").format({ async = true }) end, desc = "Format Buffer" },
    },
    opts = {
      formatters_by_ft = {
        python = { "isort", "black" },
        c = { "clang-format" },
        cpp = { "clang-format" },
        sh = { "shfmt" },
        bash = { "shfmt" },
        zsh = { "shfmt" },
        markdown = { "prettier" },
        json = { "prettier" },
        yaml = { "prettier" },
      },
      format_on_save = {
        timeout_ms = 3000,
        lsp_format = "fallback",
      },
    },
  },
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    dependencies = { "williamboman/mason.nvim" },
    opts = {
      ensure_installed = {
        "black",
        "isort",
        "clang-format",
        "shfmt",
        "prettier",
        "debugpy",
      },
    },
  },
}
