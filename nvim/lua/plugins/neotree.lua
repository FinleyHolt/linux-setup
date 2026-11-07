-- lua/plugins/neotree.lua
-- The file panel on the left. One click opens a file or a folder, as in an
-- IDE; Neo-tree's own default wants a double click.

-- A click opens the entry under the mouse. A drag of the panel's edge also ends
-- in a release, there with the mouse off the text (line 0), and opens nothing.
local function open_clicked(state)
  local pos = vim.fn.getmousepos()
  if pos.winid ~= vim.api.nvim_get_current_win() or pos.line == 0 then return end
  require("neo-tree.sources." .. state.name .. ".commands").open(state)
end

return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    "MunifTanjim/nui.nvim",
  },
  config = function()
    require("neo-tree").setup({
      window = {
        mappings = {
          ["<LeftRelease>"] = { open_clicked, desc = "open (click)" },
        },
      },
      filesystem = {
        -- The panel marks the open file and unfolds its folder
        follow_current_file = { enabled = true },
      },
    })
  end,
}
