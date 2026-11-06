-- Run: nvim --headless -u NONE -l tests/file_sync.lua
vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
local api = vim.api
local sync = require('file_sync')
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
vim.env.XDG_STATE_HOME = tmp .. '/state'
vim.opt.hidden = true
vim.opt.swapfile = false
local notices = {}
vim.notify = function(msg) notices[#notices + 1] = msg end
local count = 0
local function assert_eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), label .. '\nexpected ' .. vim.inspect(expected) .. '\ngot ' .. vim.inspect(actual))
  count = count + 1
end
local function write(path, raw)
  local f = assert(io.open(path, 'wb')); assert(f:write(raw)); f:close()
end
local function read(path)
  local f = assert(io.open(path, 'rb')); local s = f:read('*a'); f:close(); return s
end
local function text(buf) return table.concat(api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n') .. '\n' end
local function edit(name, raw)
  local path = tmp .. '/' .. name
  if raw then write(path, raw) end
  vim.cmd.edit(vim.fn.fnameescape(path))
  return api.nvim_get_current_buf(), path
end
local function set(buf, row, value) api.nvim_buf_set_lines(buf, row - 1, row, false, { value }) end
local base = 'one\ntwo\nthree\nfour\nfive\nsix\n'
local function run()
  local pre, prepath = edit('already-dirty.txt', base)
  set(pre, 1, 'unsaved before module startup')
  sync.setup()
  assert_eq(sync.check(pre, true), false, 'unknown baseline blocks reconciliation')
  sync.save(pre)
  assert_eq(read(prepath), base, 'unknown baseline never overwrites disk')
  assert_eq(text(pre), base:gsub('one', 'unsaved before module startup'), 'unknown baseline preserves local changes')
  local b, p = edit('clean.txt', base)
  write(p, 'external\n' .. base)
  assert(vim.wait(1800, function() return text(b) == 'external\n' .. base end, 20), 'timer refreshes without cursor activity')
  assert_eq(vim.bo[b].modified, false, 'clean reload stays clean')
  assert_eq(sync.status(b).snapshot ~= nil, true, 'snapshot recorded')
  local snap = sync.status(b).snapshot
  assert_eq(read(snap .. '/base'), base, 'base snapshot')
  assert_eq(read(snap .. '/disk'), 'external\n' .. base, 'disk snapshot')

  b, p = edit('merge.txt', base)
  set(b, 1, 'local')
  api.nvim_win_set_cursor(0, { 1, 2 })
  write(p, base:gsub('six', 'external'))
  assert_eq(sync.check(b, true), true, 'disjoint merge succeeds')
  local merged = base:gsub('one', 'local'):gsub('six', 'external')
  assert_eq(text(b), merged, 'merge includes both changes')
  assert_eq(api.nvim_win_get_cursor(0), { 1, 2 }, 'cursor preserved')
  assert_eq(vim.bo[b].modified, true, 'unsaved local edit remains dirty')
  assert_eq(read(p), base:gsub('six', 'external'), 'merge does not write automatically')
  vim.cmd('undo')
  assert_eq(text(b), base:gsub('one', 'local'), 'undo external merge separately')
  vim.cmd('redo')
  assert_eq(text(b), merged, 'redo merge')
  sync.save(b)
  assert_eq(read(p), merged, 'autosave writes merged result')
  assert_eq(vim.bo[b].modified, false, 'autosave clears dirty flag')
  set(b, 2, 'local twice')
  write(p, merged:gsub('five', 'external twice'))
  vim.cmd('write')
  assert_eq(read(p), merged:gsub('two', 'local twice'):gsub('five', 'external twice'), 'manual write reconciles latest disk')

  b, p = edit('conflict.txt', base)
  set(b, 1, 'mine')
  write(p, base:gsub('one', 'theirs'))
  assert_eq(sync.check(b, true), false, 'overlapping edit blocked')
  assert_eq(text(b), base:gsub('one', 'mine'), 'local buffer preserved')
  assert_eq(read(p), base:gsub('one', 'theirs'), 'disk preserved')
  sync.save(b)
  assert_eq(vim.bo[b].modified, true, 'autosave paused')
  assert_eq(pcall(vim.cmd, 'write!'), false, 'force write also guarded')
  assert_eq(read(p), base:gsub('one', 'theirs'), 'guarded write did not touch disk')
  sync.conflict()
  local review = api.nvim_get_current_buf()
  assert_eq(vim.bo[review].buftype, 'acwrite', 'separate review buffer')
  vim.cmd('SyncApply')
  assert_eq(api.nvim_get_current_buf(), review, 'unresolved markers rejected')
  api.nvim_buf_set_lines(review, 0, -1, false, { 'both', 'two', 'three', 'four', 'five', 'six' })
  vim.cmd('SyncApply')
  assert_eq(api.nvim_get_current_buf(), b, 'apply returns to source')
  assert_eq(text(b), base:gsub('one', 'both'), 'resolution applied to buffer')
  assert_eq(read(p), base:gsub('one', 'theirs'), 'resolution waits for source write')
  vim.cmd('write')
  assert_eq(read(p), base:gsub('one', 'both'), 'resolution saved')

  b, p = edit('stale.txt', base)
  set(b, 1, 'mine'); write(p, base:gsub('one', 'theirs'))
  sync.conflict(); review = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(review, 0, -1, false, { 'resolution' })
  write(p, 'new external\n')
  vim.cmd('SyncApply')
  assert_eq(api.nvim_get_current_buf(), review, 'stale resolution rejected')
  assert_eq(read(p), 'new external\n', 'stale review never overwrites newer disk')
  assert_eq(text(b), base:gsub('one', 'mine'), 'stale review never overwrites source')
  vim.cmd('tabclose!')

  b, p = edit('deleted.txt', base)
  set(b, 1, 'mine'); os.remove(p)
  sync.save(b)
  assert_eq(vim.uv.fs_stat(p), nil, 'deleted file not resurrected')
  assert_eq(text(b), base:gsub('one', 'mine'), 'deleted file local edits retained')
  write(p, base:gsub('six', 'new external'))
  sync.save(b)
  assert_eq(read(p), base:gsub('one', 'mine'):gsub('six', 'new external'), 'reappearing file reconciles')

  b, p = edit('atomic.txt', base)
  write(p .. '.tmp', 'atomic\n' .. base); assert(os.rename(p .. '.tmp', p))
  assert(vim.wait(1800, function() return text(b) == 'atomic\n' .. base end, 20), 'atomic rename picked up')
  assert_eq(vim.bo[b].modified, false, 'atomic reload clean')

  b, p = edit('dos.txt', base:gsub('\n', '\r\n'))
  set(b, 1, 'mine'); write(p, base:gsub('six', 'theirs'):gsub('\n', '\r\n'))
  sync.save(b)
  assert_eq(read(p), base:gsub('one', 'mine'):gsub('six', 'theirs'):gsub('\n', '\r\n'), 'CRLF preserved')

  b, p = edit('noeol.txt', base:sub(1, -2))
  set(b, 1, 'mine'); write(p, base:gsub('six', 'theirs'):sub(1, -2))
  sync.save(b)
  assert_eq(read(p), base:gsub('one', 'mine'):gsub('six', 'theirs'):sub(1, -2), 'missing final newline preserved')

  b, p = edit('new.txt')
  set(b, 1, 'created'); sync.save(b)
  assert_eq(read(p), 'created\n', 'new named file saved')
  b, p = edit('readonly.txt', base)
  vim.bo[b].readonly = true; set(b, 1, 'mine'); sync.save(b)
  assert_eq(read(p), base, 'readonly never autosaved')

  b, p = edit('utf8.txt', '\239\187\191' .. '你好\n二\n三\n四\n五\n六\n')
  set(b, 1, '你好，本地'); write(p, '\239\187\191你好\n二\n三\n四\n五\n外部\n')
  sync.save(b)
  assert_eq(read(p), '\239\187\191你好，本地\n二\n三\n四\n五\n外部\n', 'BOM and UTF-8 preserved')
  -- A second round of external edits must merge against the newest disk base.
  b, p = edit('repeated.txt', base)
  set(b, 1, 'mine')
  write(p, base:gsub('six', 'external 1')); assert(sync.check(b, true))
  write(p, base:gsub('six', 'external 2')); assert(sync.check(b, true))
  assert_eq(text(b), base:gsub('one', 'mine'):gsub('six', 'external 2'), 'successive external changes use newest baseline')
  assert_eq(pcall(vim.cmd, '1,2write!'), false, 'partial overwrite blocked')
  assert_eq(pcall(vim.cmd, 'write >> ' .. vim.fn.fnameescape(p)), false, 'append to source blocked')
  assert_eq(read(p), base:gsub('six', 'external 2'), 'partial/append leaves disk intact')
  local copy = tmp .. '/export copy.txt'
  vim.cmd.write({ args = { copy } })
  assert_eq(read(copy), text(b), 'writing a copy works without resetting source baseline')
  sync.save(b)
  assert_eq(read(p), read(copy), 'source can still save after exporting copy')

  -- Invalid input or a missing merge executable must not replace editable code.
  b, p = edit('invalid.txt', base)
  write(p, string.char(255) .. '\n')
  assert_eq(sync.check(b, true), false, 'invalid UTF-8 rejected')
  assert_eq(text(b), base, 'invalid UTF-8 did not enter buffer')
  write(p, base); assert(sync.check(b, true))

  b, p = edit('stale-local.txt', base)
  set(b, 1, 'mine'); write(p, base:gsub('one', 'theirs'))
  sync.conflict(); review = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(review, 0, -1, false, { 'resolution' })
  set(b, 6, 'new local')
  vim.cmd('SyncApply')
  assert_eq(api.nvim_get_current_buf(), review, 'newer source rejects stale draft')
  assert_eq(text(b), base:gsub('one','mine'):gsub('six','new local'), 'new local edit preserved')
  vim.cmd('tabclose!')

  b, p = edit('empty.txt', '')
  write(p, 'external\n'); assert(sync.check(b, true), vim.inspect(sync.status(b)))
  assert_eq(text(b), 'external\n', 'empty file refreshes')
  write(p, ''); assert(sync.check(b, true))
  assert_eq(vim.bo[b].endofline, false, 'empty external file has no phantom newline')
  assert_eq(vim.bo[b].modified, false, 'empty refresh remains clean')

  b, p = edit('patches.txt', '你好世界\nunchanged\nlast\n')
  api.nvim_win_set_cursor(0, {1, 6})
  write(p, '您好世界\nunchanged\nlast\n'); assert(sync.check(b, true))
  assert_eq(text(b), '您好世界\nunchanged\nlast\n', 'UTF-8 patch boundary valid')
  assert_eq(api.nvim_win_get_cursor(0), {1, 6}, 'UTF-8 cursor in unchanged suffix preserved')
  write(p, '您好世界\nlast\n'); assert(sync.check(b, true))
  assert_eq(text(b), '您好世界\nlast\n', 'whole line deletion')
  write(p, 'start\n您好世界\nlast\nend\n'); assert(sync.check(b, true))
  assert_eq(text(b), 'start\n您好世界\nlast\nend\n', 'insertions at both ends')

  -- Re-running setup must retain a dirty buffer's established baseline.
  b, p = edit('setup.txt', base)
  set(b, 1, 'mine'); sync.setup()
  write(p, base:gsub('six', 'external')); sync.save(b)
  assert_eq(read(p), base:gsub('one','mine'):gsub('six','external'), 'setup preserves known baseline')
  b, p = edit('missing-git.txt', base)
  set(b, 1, 'mine'); write(p, base:gsub('six','theirs'))
  local original_path = vim.env.PATH
  vim.env.PATH = '/nonexistent'
  local merged_ok = sync.check(b, true)
  vim.env.PATH = original_path
  assert_eq(merged_ok, false, 'missing Git blocks merge')
  assert_eq(text(b), base:gsub('one','mine'), 'merge failure preserves local content')
  assert_eq(read(p), base:gsub('six','theirs'), 'merge failure preserves disk')
  assert(sync.check(b, true))
  assert_eq(text(b), base:gsub('one','mine'):gsub('six','theirs'), 'merge recovers when Git returns')

  b, p = edit('review-write.txt', base)
  set(b, 1, 'mine'); write(p, base:gsub('one','theirs'))
  sync.conflict(); review = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(review, 0, -1, false, { 'resolved with write' })
  vim.cmd('write')
  assert_eq(api.nvim_get_current_buf(), b, 'review :w applies and returns')
  assert_eq(text(b), 'resolved with write\n', 'review :w applies edited result')
  assert_eq(read(p), base:gsub('one','theirs'), 'review :w leaves disk unchanged')
  print('PASS: ' .. count .. ' file-sync assertions')
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(tmp, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')
