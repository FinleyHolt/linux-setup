return {
  "saghen/blink.cmp",
  dependencies = {
    "rafamadriz/friendly-snippets",
  },
  version = "*",
  opts = {
    keymap = { preset = "default" },  -- Ctrl-y accepts, Ctrl-n/Ctrl-p move, Ctrl-e dismisses; Enter is a plain newline
    appearance = {
      use_nvim_cmp_as_default = true,
      nerd_font_variant = "mono",
    },
    sources = {
      default = { "lsp", "path", "snippets", "buffer" },
    },
    completion = {
      menu = {
        border = "rounded",
        -- Below the cursor; above only when there's no room (the : command line).
        -- scrolloff in init.lua keeps room below while editing.
        direction_priority = { "s", "n" },
      },
    },
    signature = { enabled = false },
  },
}
