local M = {}
local api = vim.api
local terminals = {}

local function resize(win)
  local available = vim.o.lines - vim.o.cmdheight
    - (vim.o.laststatus > 0 and 1 or 0)
    - ((vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1)) and 1 or 0)
  api.nvim_win_set_height(win, math.max(1, math.floor((available - 1) * 0.6)))
end

local function configure(buf)
  require('minimal_keys').navigation(buf)
  vim.keymap.set('n', 's', M.hide, { buffer = buf, silent = true, nowait = true, desc = 'Hide terminal' })
  vim.keymap.set('n', '<Esc>', M.hide, { buffer = buf, silent = true, nowait = true, desc = 'Return to code' })
  vim.keymap.set('t', '<Esc>', '<C-\\><C-n><Cmd>lua require("project_terminal").hide()<CR>',
    { buffer = buf, silent = true, nowait = true, desc = 'Leave terminal and return to code' })
  vim.keymap.set('n', 'i', '<Cmd>startinsert<CR>', { buffer = buf, silent = true })
  vim.keymap.set('n', 'z', 'v', { buffer = buf, silent = true })
  vim.keymap.set('x', 'c', 'y', { buffer = buf, silent = true })
end

function M.hide()
  local buf = api.nvim_get_current_buf()
  local record
  for _, item in pairs(terminals) do if item.buf == buf then record = item; break end end
  if not record then return end
  local tab = api.nvim_get_current_tabpage()
  if #api.nvim_tabpage_list_wins(tab) > 1 then
    api.nvim_win_close(0, false)
  elseif api.nvim_buf_is_valid(record.source) then
    api.nvim_win_set_buf(0, record.source)
  else
    vim.cmd.enew()
  end
  if api.nvim_win_is_valid(record.origin) and api.nvim_win_get_tabpage(record.origin) == tab then
    api.nvim_set_current_win(record.origin)
  end
end

function M.open()
  if vim.bo.buftype == 'terminal' then M.hide(); return end
  local origin, source = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local path = api.nvim_buf_get_name(source)
  local directory = path ~= '' and vim.fs.dirname(path) or vim.fn.getcwd()
  local root = vim.fs.root(directory, '.git')
    or vim.fs.root(directory, { 'pyproject.toml', 'Cargo.toml' }) or directory
  local record = terminals[root]
  local reuse = record and api.nvim_buf_is_valid(record.buf) and not record.exited
  if reuse then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == record.buf then
        record.origin, record.source = origin, source
        api.nvim_set_current_win(win)
        resize(win)
        vim.cmd.startinsert()
        return
      end
    end
  end
  vim.cmd('botright split')
  resize(api.nvim_get_current_win())
  if not reuse then
    record = { buf = api.nvim_create_buf(false, true) }
    terminals[root] = record
  end
  record.origin, record.source = origin, source
  api.nvim_win_set_buf(0, record.buf)
  if not reuse then
    record.job = vim.fn.jobstart({ vim.o.shell }, {
      term = true, cwd = root,
      on_exit = function() record.exited = true end,
    })
    if record.job <= 0 then
      record.exited = true
      M.hide()
      vim.notify('无法启动终端：' .. vim.o.shell, vim.log.levels.ERROR)
      return
    end
    vim.bo[record.buf].bufhidden = 'hide'
    configure(record.buf)
  end
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = 'no'
  vim.wo.foldenable = false
  vim.wo.winbar = ''
  vim.cmd.startinsert()
end

return M
