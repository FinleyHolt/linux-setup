-- lua/plugins/treesitter.lua

return {
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
  opts = {
    ensure_installed = {
      "c", "cpp", "lua", "vim", "vimdoc", "python",
      "bash", "markdown", "markdown_inline", "cmake",
      "json", "yaml", "toml", "dockerfile",
    },
    sync_install = false,
    highlight = { enable = true },
    indent = { enable = true },
  }
}

