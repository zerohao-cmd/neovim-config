-- Conflict drafts are separate buffers; markers never enter the source implicitly.
local M = {}
local api = vim.api
local reviews = {}

function M.open(source, conflict, apply)
  local previous = reviews[source]
  if previous and previous.conflict == conflict and api.nvim_buf_is_valid(previous.buf) then
    vim.cmd('tab split')
    api.nvim_win_set_buf(0, previous.buf)
    return
  end
  local origin = api.nvim_get_current_win()
  local buf = api.nvim_create_buf(true, false)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'diff'
  local raw = conflict.merged
  local dos = raw:find('\r\n', 1, true) ~= nil
  if dos then raw = raw:gsub('\r\n', '\n') end
  vim.bo[buf].fileformat = dos and 'dos' or 'unix'
  vim.bo[buf].bomb = raw:sub(1, 3) == '\239\187\191'
  if vim.bo[buf].bomb then raw = raw:sub(4) end
  vim.bo[buf].endofline = raw:sub(-1) == '\n'
  if vim.bo[buf].endofline then raw = raw:sub(1, -2) end
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(raw, '\n', { plain = true }))
  api.nvim_buf_set_name(buf, 'sync-review://' .. buf .. '/' .. vim.fn.fnamemodify(api.nvim_buf_get_name(source), ':t'))
  vim.bo[buf].modified = false
  reviews[source] = { buf = buf, conflict = conflict }
  vim.cmd('tab split')
  api.nvim_win_set_buf(0, buf)
  vim.wo.foldenable = false
  local function close()
    if api.nvim_get_current_buf() == buf and #api.nvim_list_wins() > 1 then
      api.nvim_win_close(0, true) -- bufhidden=hide keeps the draft, including unsaved edits.
    end
    if api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
  end
  local function submit()
    local ok, err = pcall(apply, buf, conflict)
    if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
    vim.bo[buf].modified = false
    close()
    if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
    reviews[source] = nil
    vim.notify('已把冲突处理结果放回源文件；检查后用 :w 保存。')
  end
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function(args)
    if vim.fn.fnamemodify(args.file, ':p') ~= vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ':p') then
      error('冲突草稿请使用 :SyncApply；:w 仅用于应用到源缓冲区')
    end
    submit()
  end })
  api.nvim_buf_create_user_command(buf, 'SyncApply', submit, {})
  local keys = require('minimal_keys')
  keys.navigation(buf)
  for lhs, rhs in pairs({ i = 'i', z = 'v', cc = 'yy', xx = 'dd', dd = 'dd', u = 'u', U = '<C-r>',
      ['<Tab>'] = '>>', ['<S-Tab>'] = '<<', [':'] = ':' }) do
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true })
  end
  vim.keymap.set('n', 'v', function() keys.paste(false) end, { buffer = buf })
  vim.keymap.set('n', 'V', function() keys.paste(true) end, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
  vim.keymap.set('x', 'c', 'y', { buffer = buf })
  vim.keymap.set('x', 'x', 'd', { buffer = buf })
  vim.notify('处理冲突标记后 :SyncApply（或 :w）返回源文件；Esc 隐藏并保留草稿。')
end

return M
