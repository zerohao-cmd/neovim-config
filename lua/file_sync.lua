local M = {}
local api = vim.api
local baselines = {}
local warned = {}

local function ordinary(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == '' and api.nvim_buf_get_name(buf) ~= ''
end

local function stamp(buf)
  local stat, err, code = vim.uv.fs_stat(api.nvim_buf_get_name(buf))
  if not stat then
    if code == 'ENOENT' then return { exists = false } end
    return nil, err
  end
  if stat.type ~= 'file' then return nil, '目标不是普通文件' end
  return { exists = true, size = stat.size, mtime = stat.mtime, ctime = stat.ctime, ino = stat.ino }
end

local function remember(buf)
  if ordinary(buf) then baselines[buf] = stamp(buf); warned[buf] = nil end
end

function M.check(buf)
  if not ordinary(buf) or vim.bo[buf].modified then return end
  -- Checktime reloads clean buffers through autoread. Dirty buffers are left alone.
  pcall(vim.cmd, 'checktime ' .. buf)
end

function M.save(buf)
  if not ordinary(buf) or not vim.bo[buf].modified or not vim.bo[buf].modifiable or vim.bo[buf].readonly then return end
  local current, err = stamp(buf)
  if not current or not baselines[buf] or not vim.deep_equal(current, baselines[buf]) then
    if not warned[buf] then
      warned[buf] = true
      vim.notify('已暂停自动保存：' .. vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ':t')
        .. ' 的磁盘版本发生变化或无法确认。你的修改仍在编辑器中，请检查后手动保存。'
        .. (err and ('\n' .. err) or ''), vim.log.levels.WARN)
    end
    return
  end
  -- Never force-write: Neovim retains its own final timestamp/permission checks.
  local ok, message = pcall(api.nvim_buf_call, buf, function() vim.cmd('silent update') end)
  if not ok then vim.notify('自动保存失败：' .. tostring(message), vim.log.levels.ERROR) end
end

function M.setup()
  vim.opt.autoread = true
  local group = api.nvim_create_augroup('EditingFileSync', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufWritePost' }, {
    group = group, callback = function(args) remember(args.buf) end,
  })
  api.nvim_create_autocmd('InsertLeave', {
    group = group, nested = true, callback = function(args) M.save(args.buf); M.check(args.buf) end,
  })
  api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold', 'InsertEnter' }, {
    group = group, nested = true, callback = function(args) M.check(args.buf) end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group, callback = function(args) baselines[args.buf] = nil; warned[args.buf] = nil end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if ordinary(buf) and not vim.bo[buf].modified then remember(buf) end
  end
end

return M
