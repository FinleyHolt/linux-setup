return {
  "Civitasv/cmake-tools.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  ft = { "cmake", "cpp", "c" },
  keys = {
    { "<leader>cg", "<cmd>CMakeGenerate<cr>", desc = "CMake Generate" },
    { "<leader>cb", "<cmd>CMakeBuild<cr>", desc = "CMake Build" },
    { "<leader>cr", "<cmd>CMakeRun<cr>", desc = "CMake Run" },
    { "<leader>ct", "<cmd>CMakeSelectBuildTarget<cr>", desc = "Select Target" },
  },
  opts = {
    cmake_generate_options = { "-DCMAKE_EXPORT_COMPILE_COMMANDS=1" },
  },
}
