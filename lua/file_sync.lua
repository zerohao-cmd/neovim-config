-- Local-disk synchronization. The baseline is the last reconciled disk version,
-- never Git HEAD. This is optimistic reconciliation, not a multi-writer lock.
local M = {}
local api, uv = vim.api, vim.uv
local states, busy, timer = {}, {}, nil
local ns = api.nvim_create_namespace('EditingFileSync')
local limit = 2 * 1024 * 1024
local serial = 0
local write_group

local function guarded_write(args)
  local buf = args.buf
  local path = api.nvim_buf_get_name(buf)
  local same = vim.fn.fnamemodify(args.file, ':p') == path
  local forced = vim.v.cmdbang == 1
  if same then
    if vim.bo[buf].readonly and not forced then error('文件只读') end
    if uv.fs_stat(path) and not uv.fs_access(path, 'W') and not forced then error('文件没有写权限') end
    if not M.check(buf, true) then error('文件同步阻止写入：请先处理冲突或查看 :SyncStatus') end
  end
  if vim.v.cmdarg ~= '' then error('同步文件暂不支持 ++ 写入选项；请先导出到其他文件') end
  local ignored = vim.o.eventignore
  vim.opt.eventignore:append('BufWriteCmd')
  -- The content guard replaces the stale timestamp check. All other native write
  -- behavior and BufWritePre/Post hooks remain active, including the final guard.
  local ok, err = pcall(vim.cmd.write, { bang = same or forced, args = { args.file } })
  vim.o.eventignore = ignored
  if not ok then error(err) end
end

local function ordinary(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == '' and api.nvim_buf_get_name(buf) ~= ''
end

local function read(path)
  local stat, err, code = uv.fs_stat(path)
  if not stat then
    if code == 'ENOENT' then return false end
    return nil, err
  end
  if stat.type ~= 'file' then return nil, '目标不是普通文件' end
  if stat.size > limit then return nil, '文件超过 2 MiB' end
  local f, message = io.open(path, 'rb')
  if not f then return nil, message end
  local raw = f:read(limit + 1)
  f:close()
  if raw == nil and stat.size == 0 then raw = '' end
  if not raw or #raw > limit then return nil, '读取失败或文件超过 2 MiB' end
  return raw
end

local function decode(raw)
  if raw:find('\0', 1, true) then return nil, '不支持二进制文件' end
  local bomb = raw:sub(1, 3) == '\239\187\191'
  local text = bomb and raw:sub(4) or raw
  local ok, converted = pcall(function()
    return vim.iconv(vim.iconv(text, 'utf-8', 'utf-16le'), 'utf-16le', 'utf-8')
  end)
  if not ok or converted ~= text then return nil, '只支持 UTF-8 文本' end
  local dos = text:find('\r\n', 1, true) ~= nil
  if dos then text = text:gsub('\r\n', '\n') end
  if text:find('\r', 1, true) then return nil, '不支持混合或 Mac 换行符' end
  if dos and raw:gsub('\r\n', ''):find('\n', 1, true) then return nil, '不支持混合换行符' end
  local eol = text:sub(-1) == '\n'
  if eol then text = text:sub(1, -2) end
  return { lines = vim.split(text, '\n', { plain = true }), eol = eol, bomb = bomb,
    format = dos and 'dos' or 'unix' }
end

local function contents(buf)
  local sep = vim.bo[buf].fileformat == 'dos' and '\r\n' or '\n'
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), sep)
  if vim.bo[buf].endofline then text = text .. sep end
  if vim.bo[buf].bomb then text = '\239\187\191' .. text end
  return text
end

local function warn(state, message)
  state.blocked = message
  if state.warned ~= message then
    state.warned = message
    vim.notify('文件同步暂停：' .. vim.fn.fnamemodify(state.path, ':t') .. '\n' .. message,
      vim.log.levels.WARN)
  end
end

local function write_private(path, text)
  local fd, err = uv.fs_open(path, 'w', 384)
  assert(fd, err)
  local written, message = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  assert(written == #text, message or '快照写入不完整')
end

local function snapshot(state, ours, disk)
  serial = serial + 1
  local root = vim.fn.stdpath('state') .. '/file-sync/' .. vim.fn.sha256(state.path):sub(1, 20)
  vim.fn.mkdir(root, 'p', 448)
  local dir = root .. '/' .. os.date('!%Y%m%dT%H%M%S') .. '-' .. uv.os_getpid() .. '-' .. serial
  vim.fn.mkdir(dir, 'p', 448)
  write_private(dir .. '/base', state.base or '')
  write_private(dir .. '/local', ours)
  write_private(dir .. '/disk', disk or '')
  write_private(dir .. '/meta.json', vim.json.encode({ path = state.path,
    disk_exists = disk ~= false, baseline_exists = state.exists, time = os.date('!%FT%TZ') }))
  state.snapshot = dir
  -- Keep the most recent 20 reconciliation points per path, across sessions.
  local dirs = vim.fn.glob(root .. '/*', false, true)
  table.sort(dirs, function(a, b)
    local sa, sb = uv.fs_stat(a), uv.fs_stat(b)
    if sa.mtime.sec == sb.mtime.sec then return sa.mtime.nsec < sb.mtime.nsec end
    return sa.mtime.sec < sb.mtime.sec
  end)
  for i = 1, #dirs - 20 do vim.fn.delete(dirs[i], 'rf') end
  return dir
end

local function replace(buf, raw, clean)
  local decoded, err = decode(raw)
  if not decoded then error(err) end
  local before = api.nvim_buf_get_lines(buf, 0, -1, false)
  local hunks = vim.text.diff(table.concat(before, '\n') .. '\n',
    table.concat(decoded.lines, '\n') .. '\n', { result_type = 'indices', algorithm = 'histogram' })
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local pos = api.nvim_win_get_cursor(win)
    cursors[win] = api.nvim_buf_set_extmark(buf, ns, pos[1] - 1, pos[2], { right_gravity = true })
  end
  api.nvim_buf_call(buf, function()
    -- An external patch is its own undo step, separate from typed text.
    vim.bo[buf].undolevels = vim.bo[buf].undolevels
    for i = #hunks, 1, -1 do
      local h = hunks[i]
      local start = h[2] == 0 and h[1] or h[1] - 1
      local lines = {}
      for j = h[3], h[3] + h[4] - 1 do lines[#lines + 1] = decoded.lines[j] end
      if i < #hunks then vim.cmd('undojoin') end
      -- Keep unchanged prefix/suffix within replacement lines (including cursor columns).
      if h[2] > 0 and h[4] > 0 then
        local first, last = before[start + 1], before[start + h[2]]
        local prefix, suffix = 0, 0
        while prefix < math.min(#first, #lines[1]) and first:byte(prefix + 1) == lines[1]:byte(prefix + 1) do
          prefix = prefix + 1
        end
        -- Avoid splitting a UTF-8 codepoint at the patch boundary.
        while prefix > 0 and first:byte(prefix + 1) and first:byte(prefix + 1) >= 128
            and first:byte(prefix + 1) < 192 do prefix = prefix - 1 end
        local maxsuffix = math.min(#last, #lines[#lines])
        if h[2] == 1 then maxsuffix = math.min(maxsuffix, #last - prefix) end
        if h[4] == 1 then maxsuffix = math.min(maxsuffix, #lines[#lines] - prefix) end
        while suffix < maxsuffix and last:byte(#last - suffix) == lines[#lines]:byte(#lines[#lines] - suffix) do
          suffix = suffix + 1
        end
        while suffix > 0 and last:byte(#last - suffix + 1) >= 128
            and last:byte(#last - suffix + 1) < 192 do suffix = suffix - 1 end
        lines[#lines] = lines[#lines]:sub(1, #lines[#lines] - suffix)
        lines[1] = lines[1]:sub(prefix + 1)
        api.nvim_buf_set_text(buf, start, prefix, start + h[2] - 1, #last - suffix, lines)
      else
        api.nvim_buf_set_lines(buf, start, start + h[2], false, lines)
      end
    end
    vim.bo[buf].endofline, vim.bo[buf].bomb = decoded.eol, decoded.bomb
    vim.bo[buf].fileformat = decoded.format
    -- Preserve a missing final newline on subsequent :write.
    vim.bo[buf].fixendofline = false
    vim.bo[buf].modified = not clean
    vim.bo[buf].undolevels = vim.bo[buf].undolevels
  end)
  for win, mark in pairs(cursors) do
    local pos = api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    if api.nvim_win_is_valid(win) and #pos > 0 then
      pcall(api.nvim_win_set_cursor, win, { math.min(pos[1] + 1, api.nvim_buf_line_count(buf)), pos[2] })
    end
    api.nvim_buf_del_extmark(buf, ns, mark)
  end
  local marks = {}
  for _, h in ipairs(hunks) do
    for row = math.max(h[3] - 1, 0), math.min(h[3] + math.max(h[4], 1) - 2, api.nvim_buf_line_count(buf) - 1) do
      marks[#marks + 1] = api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = 'DiffChange', priority = 80 })
    end
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      for _, mark in ipairs(marks) do pcall(api.nvim_buf_del_extmark, buf, ns, mark) end
    end
  end, 1200)
end

local function remember(buf, trusted)
  if not ordinary(buf) then return end
  local path = api.nvim_buf_get_name(buf)
  local disk, err = read(path)
  local encoding = vim.bo[buf].fileencoding
  local supported = disk ~= nil and not vim.bo[buf].binary
    and (encoding == '' or encoding == 'utf-8') and (disk == false or decode(disk) ~= nil)
  api.nvim_clear_autocmds({ group = write_group, buffer = buf })
  if not supported then
    vim.bo[buf].autoread = true
    states[buf] = { path = path, disabled = err or '仅同步 UTF-8、LF/CRLF、非二进制且不超过 2 MiB 的文件' }
    return
  end
  -- A running session with dirty buffers but no baseline cannot be merged safely.
  if not trusted and vim.bo[buf].modified then
    states[buf] = { path = path, unknown = true }
    vim.bo[buf].autoread = false
    api.nvim_create_autocmd('BufWriteCmd', { group = write_group, buffer = buf, nested = true, callback = guarded_write })
    return
  end
  -- Baseline comes from what Neovim actually read/wrote, not a newer racing disk read.
  local base = contents(buf)
  if disk == '' and base == '\n' and not vim.bo[buf].modified then
    vim.bo[buf].endofline = false
    base = ''
  end
  local existed = trusted == 'read' or trusted == 'write' or disk ~= false
  if not existed then base = '' end
  states[buf] = { path = path, base = base, exists = existed }
  vim.bo[buf].autoread = false -- All reloads must pass through the same baseline tracking.
  api.nvim_create_autocmd('BufWriteCmd', { group = write_group, buffer = buf, nested = true, callback = guarded_write })
end

local function reconcile(buf, immediate)
  if not ordinary(buf) then return true end
  local state = states[buf]
  if not state or state.path ~= api.nvim_buf_get_name(buf) then remember(buf); state = states[buf] end
  if state.disabled then return false end
  if state.unknown then
    warn(state, '没有可信的同步基线；先用 :w 其他路径 保存副本，再重新打开原文件。')
    return false
  end
  local disk, err = read(state.path)
  if disk == nil then warn(state, err); return false end
  if disk == false and state.exists then
    if state.blocked ~= '磁盘文件已删除；保留编辑器内容，等待文件恢复。' then
      local ok, message = pcall(snapshot, state, contents(buf), false)
      if not ok then warn(state, '无法创建恢复快照：' .. tostring(message)); return false end
    end
    warn(state, '磁盘文件已删除；保留编辑器内容，等待文件恢复。')
    return false
  end
  if (disk == false and not state.exists) or (disk == state.base and state.exists) then
    state.blocked, state.warned, state.pending, state.conflict = nil, nil, nil, nil
    return true
  end
  -- Wait for two identical reads before background reconciliation (atomic renames work too).
  if not immediate and state.pending ~= disk then state.pending = disk; return false end
  state.pending = nil
  if not vim.bo[buf].modifiable then warn(state, '缓冲区不可修改'); return false end
  if not decode(disk) then warn(state, '外部版本不是支持的 UTF-8 文本'); return false end
  local ours = contents(buf)
  if #ours > limit then warn(state, '本地修改超过 2 MiB，无法自动合并'); return false end
  local tick = api.nvim_buf_get_changedtick(buf)
  if state.conflict and state.conflict.ours == ours and state.conflict.disk == disk and state.conflict.tick == tick then return false end
  local ok, dir = pcall(snapshot, state, ours, disk)
  if not ok then warn(state, '无法创建恢复快照：' .. tostring(dir)); return false end
  local merged = disk
  if vim.bo[buf].modified and ours ~= state.base and ours ~= disk then
    local result = vim.system({ 'git', 'merge-file', '-p', '--diff3',
      '-L', 'NVIM_LOCAL', '-L', 'SYNC_BASE', '-L', 'DISK_EXTERNAL',
      dir .. '/local', dir .. '/base', dir .. '/disk' }):wait(2000)
    if result.code ~= 0 then
      if result.code > 0 and result.code <= 127 and result.stdout and result.stdout:find('<<<<<<< NVIM_LOCAL', 1, true) then
        state.conflict = { ours = ours, disk = disk, merged = result.stdout, tick = tick }
        warn(state, '双方修改重叠；已保留双方版本。用 :SyncConflict 处理，期间禁止写入原文件。')
      else
        warn(state, '三方合并失败：' .. (result.stderr or tostring(result.code)))
      end
      return false
    end
    merged = result.stdout
  end
  -- A subprocess can yield. Never apply a stale result.
  if states[buf] ~= state or not ordinary(buf) or api.nvim_buf_get_changedtick(buf) ~= tick or read(state.path) ~= disk then
    return false
  end
  local replaced, message = pcall(replace, buf, merged, merged == disk)
  if not replaced then warn(state, '应用合并失败：' .. tostring(message)); return false end
  state.base, state.exists = disk, true
  state.blocked, state.warned, state.conflict = nil, nil, nil
  return true
end

function M.check(buf, immediate)
  buf = (not buf or buf == 0) and api.nvim_get_current_buf() or buf
  if busy[buf] then return false end
  busy[buf] = true
  local ok, result = pcall(reconcile, buf, immediate)
  busy[buf] = nil
  if not ok then
    if states[buf] then warn(states[buf], '同步失败：' .. tostring(result)) end
    return false
  end
  return result
end

function M.save(buf)
  if not ordinary(buf) or not vim.bo[buf].modifiable or vim.bo[buf].readonly then return end
  if not M.check(buf, true) or not vim.bo[buf].modified then return end
  local ok, message = pcall(api.nvim_buf_call, buf, function() vim.cmd('silent update') end)
  if not ok then vim.notify('自动保存失败：' .. tostring(message), vim.log.levels.ERROR) end
end

function M.status(buf)
  local state = states[buf or api.nvim_get_current_buf()]
  if not state then return { message = '当前缓冲区不参与文件同步' } end
  return { message = state.disabled or state.blocked or '同步运行中（每 500ms 检查，稳定两次后合并）',
    snapshot = state.snapshot, conflict = state.conflict ~= nil, path = state.path }
end

function M.conflict()
  local buf = api.nvim_get_current_buf()
  M.check(buf, true)
  local state = states[buf]
  if not state or not state.conflict then vim.notify('当前文件没有可处理的文本冲突'); return end
  require('sync_review').open(buf, state.conflict, function(review, conflict)
    if not ordinary(buf) or states[buf] ~= state or state.conflict ~= conflict
        or api.nvim_buf_get_changedtick(buf) ~= conflict.tick or contents(buf) ~= conflict.ours
        or read(state.path) ~= conflict.disk then
      error('源文件或磁盘已有新变化；本草稿仍保留，请返回源文件重新 :SyncConflict')
    end
    local raw = contents(review)
    if raw:match('<<<<<<< NVIM_LOCAL') or raw:match('||||||| SYNC_BASE')
        or raw:match('>>>>>>> DISK_EXTERNAL') or raw:match('\n=======\r?\n') or raw:match('^=======\r?\n')
        or raw:match('\n=======\r?$') or raw == '=======' then
      error('请先处理全部冲突并删除冲突标记')
    end
    snapshot(state, contents(buf), conflict.disk)
    replace(buf, raw, raw == conflict.disk)
    state.base, state.exists, state.conflict, state.blocked, state.warned = conflict.disk, true, nil, nil, nil
    -- Applying the review updates only the source buffer. The next explicit write is guarded again.
  end)
end

function M.setup()
  if timer then timer:stop(); timer:close() end
  vim.opt.autoread = true
  write_group = api.nvim_create_augroup('EditingFileSyncWrite', { clear = true })
  local group = api.nvim_create_augroup('EditingFileSync', { clear = true })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group, callback = function(args) remember(args.buf, args.event == 'BufNewFile' and 'new' or 'read') end,
  })
  api.nvim_create_autocmd('BufWritePre', { group = group, nested = true, callback = function(args)
    if not ordinary(args.buf) or vim.fn.fnamemodify(args.file, ':p') ~= api.nvim_buf_get_name(args.buf) then return end
    local state = states[args.buf]
    if state and state.disabled then return end -- Native write checks still apply to unsupported files.
    if not M.check(args.buf, true) then error('文件同步阻止写入：请先处理冲突或查看 :SyncStatus') end
    -- This is also run inside guarded_write, immediately before the native write.
  end })
  api.nvim_create_autocmd({ 'FileWritePre', 'FileAppendPre' }, { group = group, callback = function(args)
    local state = states[args.buf]
    if state and not state.disabled and vim.fn.fnamemodify(args.file, ':p') == api.nvim_buf_get_name(args.buf) then
      error('同步文件请使用完整 :w；不支持向原文件写入选区或追加')
    end
  end })
  api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(args)
    if ordinary(args.buf) and vim.fn.fnamemodify(args.file, ':p') == api.nvim_buf_get_name(args.buf) then
      local previous = states[args.buf]
      remember(args.buf, 'write')
      if previous then states[args.buf].snapshot = previous.snapshot end
    end
  end })
  api.nvim_create_autocmd('FileChangedShell', { group = group, callback = function(args)
    local state = states[args.buf]
    if state and not state.disabled then
      vim.v.fcs_choice = ''
      vim.schedule(function() M.check(args.buf) end)
    else vim.v.fcs_choice = 'ask' end
  end })
  api.nvim_create_autocmd('InsertLeave', { group = group, nested = true,
    callback = function(args) M.save(args.buf) end })
  api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, { group = group,
    callback = function(args) M.check(args.buf) end })
  api.nvim_create_autocmd('BufWipeout', { group = group, callback = function(args) states[args.buf] = nil end })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if ordinary(buf) then
      if states[buf] and not states[buf].disabled then
        api.nvim_create_autocmd('BufWriteCmd', { group = write_group, buffer = buf, nested = true, callback = guarded_write })
      else remember(buf) end
    end
  end
  local queued = false
  timer = uv.new_timer()
  timer:start(500, 500, function()
    if queued then return end
    queued = true
    vim.schedule(function()
      queued = false
      if vim.fn.getcmdwintype() ~= '' then return end
      for buf in pairs(states) do
        local ok, err = pcall(M.check, buf)
        if not ok and states[buf] then warn(states[buf], tostring(err)) end
      end
    end)
  end)
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    if timer and not timer:is_closing() then timer:stop(); timer:close(); timer = nil end
  end })
  api.nvim_create_user_command('SyncConflict', M.conflict, {})
  api.nvim_create_user_command('SyncStatus', function() vim.notify(vim.inspect(M.status())) end, {})
  api.nvim_create_user_command('SyncCheck', function() M.check(api.nvim_get_current_buf(), true) end, {})
end

return M
