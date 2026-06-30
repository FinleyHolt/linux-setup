return {
    "3rd/image.nvim",
    ft = { "markdown", "norg" },
    event = "BufReadPre *.png,*.jpg,*.jpeg,*.gif,*.webp",
    opts = {
        backend = "kitty",
        processor = "magick_cli",
        integrations = {
            markdown = { enabled = true },
        },
        max_width = 100,
        max_height = 40,
        max_height_window_percentage = 50,
        max_width_window_percentage = 70,
    },
}
