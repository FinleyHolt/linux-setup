-- lua/filetree.lua
-- Open or close the Neo-tree file panel. The Files button in the statusline and
-- the right-click menu both call this, so the panel needs no shortcut.

local M = {}

function M.toggle()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
      vim.cmd("Neotree close")
      return
    end
  end
  vim.cmd("Neotree filesystem reveal left")
end

return M
