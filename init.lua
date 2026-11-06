-- WSL Rust/Python setup. Normal-mode allowlist: lua/minimal_keys.lua.
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '
local home = vim.env.HOME
vim.env.PATH = home .. '/.local/bin:' .. home .. '/.cargo/bin:' .. vim.env.PATH
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.signcolumn = 'yes'
vim.opt.cursorline = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.smartindent = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.splitbelow = true
vim.opt.splitright = true
vim.opt.scrolloff = 6
vim.opt.updatetime = 250
vim.opt.timeoutlen = 400
vim.opt.undofile = true
vim.opt.mouse = 'a'
vim.opt.foldmethod = 'expr'
vim.opt.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
vim.opt.foldlevel = 99
vim.opt.foldlevelstart = 99
vim.opt.completeopt = { 'menu', 'menuone', 'noselect' }
vim.opt.diffopt:append({ 'algorithm:histogram', 'linematch:60' })

local map = vim.keymap.set
map('n', '<Esc>', function() require('minimal_keys').escape() end, { desc = 'Close preview / clear search highlight' })
vim.diagnostic.config({ virtual_text = { spacing = 2 }, severity_sort = true, float = { border = 'rounded' } })

local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.uv.fs_stat(lazypath) then
  local result = vim.fn.system({ 'git', 'clone', '--filter=blob:none', '--branch=stable',
    'https://github.com/folke/lazy.nvim.git', lazypath })
  if vim.v.shell_error ~= 0 then error('Cannot install lazy.nvim: ' .. result) end
end
vim.opt.rtp:prepend(lazypath)

require('lazy').setup({
  {
    'folke/tokyonight.nvim', lazy = false, priority = 1000,
    config = function()
      require('tokyonight').setup({ style = 'night', styles = { comments = { italic = false } } })
      vim.cmd.colorscheme('tokyonight')
    end,
  },
  {
    'nvim-treesitter/nvim-treesitter', branch = 'main', lazy = false, build = ':TSUpdate',
    config = function()
      require('nvim-treesitter').setup({})
      vim.api.nvim_create_autocmd('FileType', {
        pattern = { 'rust', 'python', 'lua', 'toml', 'json', 'bash', 'sh', 'markdown' },
        callback = function(args) pcall(vim.treesitter.start, args.buf) end,
      })
    end,
  },
  {
    'hrsh7th/nvim-cmp',
    dependencies = { 'hrsh7th/cmp-nvim-lsp', 'hrsh7th/cmp-buffer', 'hrsh7th/cmp-path' },
    config = function()
      local cmp = require('cmp')
      cmp.setup({
        completion = { autocomplete = { cmp.TriggerEvent.TextChanged } },
        snippet = { expand = function(args) vim.snippet.expand(args.body) end },
        mapping = cmp.mapping.preset.insert({
          ['<Up>'] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.abort() end
            fallback()
          end, { 'i' }),
          ['<Down>'] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.abort() end
            fallback()
          end, { 'i' }),
          ['<C-Space>'] = cmp.mapping(function() end, { 'i' }),
          ['<C-x>'] = cmp.mapping(function() end, { 'i' }),
          ['<C-n>'] = cmp.mapping(function()
            if cmp.visible() then cmp.select_next_item() end
          end, { 'i' }),
          ['<C-p>'] = cmp.mapping(function()
            if cmp.visible() then cmp.select_prev_item() end
          end, { 'i' }),
          ['<C-e>'] = cmp.mapping.abort(),
          ['<CR>'] = cmp.mapping.confirm({ select = false }),
          ['<Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_next_item()
            elseif vim.snippet.active({ direction = 1 }) then vim.snippet.jump(1)
            else fallback() end
          end, { 'i', 's' }),
          ['<S-Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then cmp.select_prev_item()
            elseif vim.snippet.active({ direction = -1 }) then vim.snippet.jump(-1)
            else fallback() end
          end, { 'i', 's' }),
        }),
        sources = cmp.config.sources({ { name = 'nvim_lsp' }, { name = 'path' } }, { { name = 'buffer' } }),
        window = { completion = cmp.config.window.bordered(), documentation = cmp.config.window.bordered() },
      })
      map('i', '<C-s>', '<Nop>', { desc = 'Use normal mode for signature help' })
    end,
  },
  {
    'neovim/nvim-lspconfig', dependencies = { 'hrsh7th/cmp-nvim-lsp' },
    config = function()
      local capabilities = require('cmp_nvim_lsp').default_capabilities()
      vim.lsp.config('rust_analyzer', {
        capabilities = capabilities,
        settings = { ['rust-analyzer'] = {
          procMacro = { enable = true },
          check = { command = 'check' },
        } },
      })
      vim.lsp.config('pyright', {
        capabilities = capabilities,
        before_init = function(_, config)
          local root = config.root_dir or vim.fn.getcwd()
          local python = vim.env.VIRTUAL_ENV and (vim.env.VIRTUAL_ENV .. '/bin/python')
          if not python and vim.env.CONDA_PREFIX then python = vim.env.CONDA_PREFIX .. '/bin/python' end
          if not python then
            for _, name in ipairs({ '.venv', 'venv' }) do
              local candidate = root .. '/' .. name .. '/bin/python'
              if vim.fn.executable(candidate) == 1 then python = candidate; break end
            end
          end
          config.settings.python.pythonPath = python or vim.fn.exepath('python3')
        end,
        settings = { python = { analysis = { autoSearchPaths = true, useLibraryCodeForTypes = true,
          diagnosticMode = 'openFilesOnly', typeCheckingMode = 'basic' } } },
      })
      vim.lsp.config('ruff', {
        capabilities = capabilities,
        on_attach = function(client)
          client.server_capabilities.hoverProvider = false
        end,
      })
      vim.lsp.enable({ 'rust_analyzer', 'pyright', 'ruff' })
    end,
  },
  {
    'stevearc/oil.nvim', lazy = false,
    opts = { columns = { 'permissions', 'size' }, view_options = { show_hidden = true },
      delete_to_trash = false, skip_confirm_for_simple_edits = false,
      keymaps = { ['q'] = 'actions.close' } },
  },
  {
    'sindrets/diffview.nvim', dependencies = { 'nvim-lua/plenary.nvim' },
    opts = { use_icons = false, enhanced_diff_hl = true,
      hooks = {
        diff_buf_win_enter = function(buf)
          require('minimal_keys').navigation(buf)
        end,
      },
    },
    config = function(_, opts)
      require('diffview').setup(opts)
      -- Interpret an interactive :q as closing the entire Diffview tab.
      -- Outside Diffview, Enter and :q retain their normal behavior.
      map('c', '<CR>', function()
        local command = vim.fn.getcmdline():match('^%s*(.-)%s*$')
        if vim.fn.getcmdtype() == ':' and (command == 'q' or command == 'quit') then
          if require('inline_diff').active() then return '<C-e><C-u>GitDiffPeekClose<CR>' end
          if require('diffview.lib').get_current_view() then return '<C-e><C-u>DiffviewClose<CR>' end
        end
        return '<CR>'
      end, { expr = true, desc = 'Close diff review with :q' })
    end,
  },
  {
    'lewis6991/gitsigns.nvim',
    opts = {},
  },
  {
    'nvim-lualine/lualine.nvim',
    opts = { options = { theme = 'tokyonight', icons_enabled = false,
      component_separators = '|', section_separators = '' } },
  },
}, {
  checker = { enabled = false }, change_detection = { notify = false },
  rocks = { enabled = false },
})

vim.api.nvim_create_user_command('NvimGuide', function()
  vim.cmd('view ' .. vim.fn.fnameescape(vim.fn.stdpath('config') .. '/README.md'))
end, {})
require('minimal_keys').setup()
require('inline_diff').setup()
require('file_sync').setup()
