return {

  -- Mason plugin
  {
    "williamboman/mason.nvim",
    config = function()
      require("mason").setup()
    end,
  },

  -- Mason LSPconfig plugin (to integrate Mason with LSPconfig)
  {
    "williamboman/mason-lspconfig.nvim",
    config = function()
      require("mason-lspconfig").setup({
        ensure_installed = { "pyright", "ruff", "clangd", "bashls" },
      })
    end,
  },

  -- LSP Config (Pyright, Ruff, Clangd, Bashls)
  {
    "neovim/nvim-lspconfig",
    config = function()
      -- Pyright setup for Python
      vim.lsp.config('pyright', {
        cmd = { 'pyright-langserver', '--stdio' },
        filetypes = { 'python' },
        root_markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile', '.git' },
        settings = {
          python = {
            analysis = {
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              diagnosticMode = 'workspace',
            },
          },
        },
      })
      vim.lsp.enable('pyright')

      -- Clangd setup for C/C++
      vim.lsp.config('clangd', {
        cmd = { 'clangd', '--background-index', '--clang-tidy' },
        filetypes = { 'c', 'cpp', 'objc', 'objcpp' },
        root_markers = { 'compile_commands.json', 'compile_flags.txt', '.clangd', '.git' },
      })
      vim.lsp.enable('clangd')

      -- Bash Language Server
      vim.lsp.config('bashls', {
        cmd = { 'bash-language-server', 'start' },
        filetypes = { 'sh', 'bash', 'zsh' },
        root_markers = { '.git' },
      })
      vim.lsp.enable('bashls')
    end
  },

  -- Mason Debug Adapter Protocol (DAP) setup for Python
  {
    "mfussenegger/nvim-dap",
    config = function()
      local dap = require("dap")

      -- Python Debug Adapter (using debugpy)
      dap.adapters.python = {
        type = "executable",
        command = "python3",
        args = { "-m", "debugpy.adapter" },
      }

      dap.configurations.python = {
        {
          type = "python",
          request = "launch",
          name = "Launch file",
          program = "${file}",
        },
      }
    end
  },

  -- Neotest integration for Python testing
  {
    "nvim-neotest/neotest",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
      "nvim-neotest/nvim-nio",
      "nvim-neotest/neotest-python",
    },
    config = function()
      require("neotest").setup({
        adapters = {
          require("neotest-python")({
            dap = { justMyCode = false },
          }),
        },
      })
    end
  },
}
