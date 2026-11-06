local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('CurrentFileInlineDiff')
local state

local function split(text)
  if text == '' then return {} end
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  for i, line in ipairs(lines) do lines[i] = line:gsub('\r$', '') end
  return lines
end

-- Retain every unchanged line and insert removed lines before their replacements.
function M.render(before, after)
  local old, new = split(before), split(after)
  local rows, changes, positions = {}, {}, {}
  local old_pos, new_pos = 1, 1
  local function append(line, kind)
    rows[#rows + 1] = line
    if kind then changes[#changes + 1] = { row = #rows, kind = kind } end
    if kind ~= 'delete' then positions[new_pos] = #rows; new_pos = new_pos + 1 end
  end
  -- Normalize line endings, but retain whether the last line has a newline.
  before, after = before:gsub('\r\n', '\n'), after:gsub('\r\n', '\n')
  for _, hunk in ipairs(vim.text.diff(before, after, { result_type = 'indices', algorithm = 'histogram' })) do
    local start = hunk[1] + (hunk[2] == 0 and 1 or 0)
    while old_pos < start do append(old[old_pos]); old_pos = old_pos + 1 end
    for i = start, start + hunk[2] - 1 do append(old[i], 'delete') end
    for i = hunk[3], hunk[3] + hunk[4] - 1 do append(new[i], 'add') end
    old_pos = start + hunk[2]
  end
  while old_pos <= #old do append(old[old_pos]); old_pos = old_pos + 1 end
  if #rows == 0 then rows = { '' } end
  return rows, changes, positions
end

function M.active()
  return state ~= nil and api.nvim_tabpage_is_valid(state.tab) and api.nvim_get_current_tabpage() == state.tab
end

function M.close()
  if not M.active() then return false end
  local old = state
  state = nil
  vim.cmd.tabclose()
  if api.nvim_win_is_valid(old.origin) then api.nvim_set_current_win(old.origin) end
  return true
end

local function git(root, args)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { text = true }):wait()
end

function M.open()
  if M.close() then return end
  local source, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local path = api.nvim_buf_get_name(source)
  if path == '' or vim.bo[source].buftype ~= '' then
    vim.notify('请先打开需要查看差异的文件', vim.log.levels.WARN); return
  end
  local root = git(vim.fs.dirname(path), { 'rev-parse', '--show-toplevel' })
  if root.code ~= 0 then vim.notify('当前文件不在 Git 仓库中', vim.log.levels.WARN); return end
  root = root.stdout:gsub('[\r\n]+$', '')
  local relative = vim.fs.relpath(root, path)
  local baseline = git(root, { 'show', ':' .. relative })
  if baseline.code ~= 0 then
    local tracked = git(root, { 'ls-files', '--error-unmatch', '--', relative })
    if tracked.code ~= 1 then
      vim.notify('无法读取 Git 暂存区版本：' .. baseline.stderr, vim.log.levels.ERROR); return
    end
    baseline.stdout = '' -- Untracked files are entirely new.
  end
  local current = table.concat(api.nvim_buf_get_lines(source, 0, -1, false), '\n')
  if vim.bo[source].endofline and not (api.nvim_buf_line_count(source) == 1 and current == '') then
    current = current .. '\n'
  end
  if baseline.stdout:find('\0', 1, true) or current:find('\0', 1, true) then
    vim.notify('二进制文件无法显示为文本差异', vim.log.levels.WARN); return
  end
  local rows, changes, positions = M.render(baseline.stdout, current)
  local cursor = api.nvim_win_get_cursor(origin)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_name(buf, 'inline-diff://' .. source .. '/' .. relative)
  api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = vim.bo[source].filetype
  for _, change in ipairs(changes) do
    local group = change.kind == 'add' and 'InlineDiffAdd' or 'InlineDiffDelete'
    api.nvim_buf_set_extmark(buf, ns, change.row - 1, 0, {
      end_row = change.row, hl_group = group, hl_eol = true, line_hl_group = group,
      priority = 200, sign_text = change.kind == 'add' and '+' or '-', sign_hl_group = group,
    })
  end
  vim.cmd.tabnew()
  local win = api.nvim_get_current_win()
  state = { tab = api.nvim_get_current_tabpage(), origin = origin, buf = buf }
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].foldenable = false
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'yes:1'
  vim.wo[win].cursorline = false
  vim.wo[win].winbar = ''
  vim.cmd.clearjumps()
  require('minimal_keys').navigation(buf)
  for _, key in ipairs({ '<Esc>', 'g' }) do
    vim.keymap.set('n', key, M.close, { buffer = buf, silent = true, nowait = true })
  end
  vim.keymap.set('n', 'z', 'v', { buffer = buf, silent = true })
  vim.keymap.set('x', 'c', 'y', { buffer = buf, silent = true })
  api.nvim_win_set_cursor(win, { positions[cursor[1]] or 1, cursor[2] })
end

function M.setup()
  local function colors()
    api.nvim_set_hl(0, 'InlineDiffAdd', { fg = '#9ece6a', bg = '#203c2b' })
    api.nvim_set_hl(0, 'InlineDiffDelete', { fg = '#f7768e', bg = '#482832' })
  end
  colors()
  local group = api.nvim_create_augroup('CurrentFileInlineDiff', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = colors })
  api.nvim_create_autocmd('BufWipeout', { group = group, callback = function(args)
    if state and state.buf == args.buf then state = nil end
  end })
  api.nvim_create_user_command('GitDiffPeek', M.open, { force = true })
  api.nvim_create_user_command('GitDiffPeekClose', M.close, { force = true })
end

return M
