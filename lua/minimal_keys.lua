local M = {}
local api = vim.api
local preview

local function normal(keys)
  local command = api.nvim_replace_termcodes(keys, true, false, true)
  -- Keep Ctrl-I's Tab byte from being parsed as leading whitespace.
  if command:match('^%s') then command = '1' .. command end
  vim.cmd.normal({ args = { command }, bang = true })
end

local function close_float()
  local old = preview
  preview = nil -- Also invalidates requests whose replies have not arrived yet.
  if old and old.win and api.nvim_win_is_valid(old.win) then api.nvim_win_close(old.win, true) end
  return old ~= nil
end

function M.escape()
  if close_float() then return end
  if require('inline_diff').close() then return end
  local diffview = package.loaded['diffview.lib']
  if diffview and diffview.get_current_view() then
    require('diffview').close()
  else
    vim.cmd.nohlsearch()
  end
end

local function has_lsp(method)
  if #vim.lsp.get_clients({ bufnr = 0, method = method }) > 0 then return true end
  vim.notify('当前文件的语言服务尚未就绪或不支持此操作', vim.log.levels.INFO)
  return false
end

function M.definition()
  close_float()
  if has_lsp('textDocument/definition') then vim.lsp.buf.definition() end
end

function M.paste(below)
  close_float()
  local lines = vim.fn.getreg('"', 1, true)
  if #lines == 0 then return end
  api.nvim_put(lines, below and 'l' or 'c', true, true)
end

function M.format()
  close_float()
  local buf = api.nvim_get_current_buf()
  local name = vim.bo[buf].filetype == 'python' and 'ruff' or nil
  local clients = vim.lsp.get_clients({ bufnr = buf, name = name, method = 'textDocument/formatting' })
  if #clients == 0 then
    vim.notify(name and 'Ruff 尚未就绪，暂时无法格式化' or '当前文件没有可用的格式化服务', vim.log.levels.INFO)
    return
  end
  vim.lsp.buf.format({ bufnr = buf, id = clients[1].id, async = false, timeout_ms = 5000 })
end

local function request_preview(kind, method, show)
  if preview and preview.kind == kind then close_float(); return end
  close_float()
  if not has_lsp(method) then return end
  local state = {
    kind = kind, source = api.nvim_get_current_buf(), origin = api.nvim_get_current_win(),
    cursor = api.nvim_win_get_cursor(0),
  }
  preview = state
  vim.lsp.buf_request_all(state.source, method, function(client)
    return vim.lsp.util.make_position_params(state.origin, client.offset_encoding)
  end, function(results)
    if preview ~= state then return end
    if not api.nvim_win_is_valid(state.origin) or api.nvim_get_current_win() ~= state.origin
        or api.nvim_win_get_buf(state.origin) ~= state.source or api.nvim_get_mode().mode ~= 'n'
        or not vim.deep_equal(api.nvim_win_get_cursor(state.origin), state.cursor) then
      close_float(); return
    end
    for _, response in pairs(results) do
      if response.result and not vim.tbl_isempty(response.result) and show(state, response.result) then return end
    end
    close_float()
    vim.notify(kind == 'hover' and '没有可用的文档' or '没有找到定义', vim.log.levels.INFO)
  end)
end

local function open_preview(state, contents, syntax, opts)
  opts = vim.tbl_extend('force', {
    border = 'rounded', focus = false, focusable = false, close_events = {},
    max_width = math.max(20, math.floor(vim.o.columns * 0.8)),
    max_height = math.max(1, math.min(20, vim.o.lines - 6)),
  }, opts or {})
  local _, win = vim.lsp.util.open_floating_preview(contents, syntax, opts)
  state.win = win
  return win
end

function M.hover()
  request_preview('hover', 'textDocument/hover', function(state, result)
    if not result.contents then return false end
    local plaintext = type(result.contents) == 'table' and result.contents.kind == 'plaintext'
    local lines = plaintext and vim.split(result.contents.value or '', '\n')
      or vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    if #lines == 0 or not table.concat(lines):match('%S') then return false end
    open_preview(state, lines, plaintext and 'plaintext' or 'markdown')
    return true
  end)
end

function M.preview_definition()
  request_preview('definition', 'textDocument/definition', function(state, result)
    local location = (result.uri or result.targetUri) and result or result[1]
    if not location then return false end
    local uri = location.targetUri or location.uri
    local range = location.targetSelectionRange or location.range or location.targetRange
    if not uri or not range then return false end
    local target = vim.uri_to_bufnr(uri)
    vim.fn.bufload(target)
    -- Keep the full target text so long definitions can be scrolled without truncation.
    local contents = api.nvim_buf_get_lines(target, 0, -1, false)
    local filetype = vim.bo[target].filetype
    if filetype == '' then filetype = vim.filetype.match({ filename = vim.uri_to_fname(uri) }) or '' end
    local win = open_preview(state, contents, filetype, {
      width = math.max(20, math.floor(vim.o.columns * 0.8)),
      height = math.max(1, math.min(20, #contents, vim.o.lines - 6)),
      title = ' ' .. vim.fn.fnamemodify(vim.uri_to_fname(uri), ':t') .. ':' .. (range.start.line + 1) .. ' ',
      wrap = false,
    })
    vim.wo[win].cursorline = true
    api.nvim_win_set_cursor(win, { math.min(range.start.line + 1, #contents), 0 })
    api.nvim_win_call(win, function() normal('zt') end)
    return true
  end)
end

function M.move(keys)
  close_float()
  normal(keys)
end

function M.vertical(direction)
  if preview and preview.win and api.nvim_win_is_valid(preview.win)
      and api.nvim_get_current_win() == preview.origin then
    api.nvim_win_call(preview.win, function() normal(direction > 0 and '<C-e>' or '<C-y>') end)
  else
    M.move(direction > 0 and 'j' or 'k')
  end
end

function M.navigation(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = 'Minimal: ' .. desc })
  end
  for _, binding in ipairs({ { '<Up>', 'k' }, { '<Down>', 'j' }, { '<Left>', 'h' }, { '<Right>', 'l' },
      { '<C-Left>', 'b' }, { '<C-Right>', 'w' }, { '<Home>', '0' }, { '<End>', '$' },
      { '<PageUp>', '4k' }, { '<PageDown>', '4j' } }) do
    local key, motion = binding[1], binding[2]
    map('n', key, function()
      if key == '<Up>' then M.vertical(-1)
      elseif key == '<Down>' then M.vertical(1)
      else M.move(motion) end
    end, 'Move cursor / scroll preview')
    map('x', key, motion, 'Extend selection')
    local insert = key
    if key == '<PageUp>' then insert = '<Up><Up><Up><Up>'
    elseif key == '<PageDown>' then insert = '<Down><Down><Down><Down>'
    elseif key == '<C-Left>' or key == '<C-Right>' then insert = '<C-o>' .. motion end
    map('i', key, insert, 'Move insertion cursor')
  end
  for _, binding in ipairs({ { 'e', '<C-o>' }, { 'E', '<C-i>' } }) do
    local motion = binding[2]
    map('n', binding[1], function() M.move(motion) end, 'Jump history')
    -- A history jump may leave this file, so finish the selection before jumping.
    map('x', binding[1], function() normal('<Esc>'); M.move(motion) end, 'End selection and jump history')
  end
  map('n', '/', '/', 'Search')
  map('n', 'n', function() M.move('n') end, 'Next search match')
  map('n', 'N', function() M.move('N') end, 'Previous search match')
  map('x', 'n', 'n', 'Next search match')
  map('x', 'N', 'N', 'Previous search match')
end

function M.apply(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].buftype ~= '' then
    if api.nvim_buf_get_name(buf):match('^diffview://') or vim.bo[buf].filetype:match('^Diffview') then
      M.navigation(buf)
    end
    return
  end
  -- Only ordinary editing buffers use this allowlist. Plugin panels keep their controls.
  for _, mapping in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do
    pcall(api.nvim_buf_del_keymap, buf, 'n', mapping.lhs)
  end
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = 'Minimal: ' .. desc })
  end
  local function block(lhs) map(lhs, '<Nop>', 'Disabled') end
  for byte = 32, 126 do
    local char = string.char(byte)
    block(char == '<' and '<lt>' or char)
  end
  for byte = string.byte('a'), string.byte('z') do block('<C-' .. string.char(byte) .. '>') end
  for _, lhs in ipairs({ '<C-@>', '<C-[>', '<C-\\>', '<C-]>', '<C-^>', '<C-_>',
      '<BS>', '<Del>', '<Insert>', '<S-Left>', '<S-Right>', '<S-Up>', '<S-Down>',
      '<C-Up>', '<C-Down>', '<C-Home>', '<C-End>', '<C-PageUp>', '<C-PageDown>', '<C-CR>' }) do block(lhs) end
  for n = 1, 24 do block('<F' .. n .. '>') end
  map('<CR>', M.definition, 'Go to definition')
  map('<kEnter>', M.definition, 'Go to definition')
  map('<Tab>', '>>', 'Indent current line')
  map('<S-Tab>', '<<', 'Unindent current line')
  map('q', M.hover, 'Documentation and types')
  map('Q', M.preview_definition, 'Peek definition source')
  map('i', 'i', 'Insert mode')
  map('z', function() close_float(); normal('v') end, 'Select text')
  map('v', function() M.paste(false) end, 'Paste after cursor')
  map('V', function() M.paste(true) end, 'Paste on new line below')
  for _, key in ipairs({ 'x', 'c' }) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, silent = true, nowait = false,
      desc = 'Minimal: Wait for ' .. key .. key })
  end
  map('xx', function() close_float(); normal('dd') end, 'Cut current line')
  map('cc', function() close_float(); normal('yy') end, 'Copy current line')
  -- Let the second d complete dd while keeping the native delete operator disabled.
  vim.keymap.set('n', 'd', '<Nop>', { buffer = buf, silent = true, nowait = false, desc = 'Minimal: Wait for dd' })
  map('dd', function() close_float(); normal('dd') end, 'Delete current line')
  map('u', function() close_float(); normal('u') end, 'Undo change')
  map('U', function() close_float(); normal('<C-r>') end, 'Redo change')
  map('f', M.format, 'Format current file (Ruff for Python)')
  map('s', function() close_float(); require('project_terminal').open() end, 'Open project terminal')
  map('o', function()
    close_float()
    local path = api.nvim_buf_get_name(0)
    require('oil').open(path ~= '' and vim.fs.dirname(path) or vim.fn.getcwd())
  end, 'Open parent directory in Oil')
  map('[', function() close_float(); pcall(normal, 'zc') end, 'Fold current code block')
  map(']', function() close_float(); pcall(normal, 'zo') end, 'Unfold current code block')
  local function visual(lhs, rhs, desc)
    vim.keymap.set('x', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = 'Minimal: ' .. desc })
  end
  visual('c', 'y', 'Copy selection and return to Normal mode')
  visual('x', 'd', 'Cut selection and return to Normal mode')
  map('g', '<Cmd>GitDiffPeek<CR>', 'Peek current file Git diff')
  map(':', ':', 'Command line')
  map('<Esc>', M.escape, 'Close preview / clear search highlight')
  M.navigation(buf)
end

function M.setup()
  local group = api.nvim_create_augroup('MinimalNormalKeys', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertEnter', 'BufLeave', 'WinLeave' }, {
    group = group,
    callback = function()
      -- Check after temporary nvim_win_call switches have returned to the source window.
      local state = preview
      if not state then return end
      vim.schedule(function()
        if preview ~= state then return end
        if not api.nvim_win_is_valid(state.origin) or api.nvim_get_current_win() ~= state.origin
            or api.nvim_win_get_buf(state.origin) ~= state.source or api.nvim_get_mode().mode ~= 'n'
            or not vim.deep_equal(api.nvim_win_get_cursor(state.origin), state.cursor) then close_float() end
      end)
    end,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      if preview and preview.win == tonumber(args.match) then preview = nil end
    end,
  })
  api.nvim_create_autocmd({ 'BufEnter', 'FileType', 'LspAttach' }, {
    group = group,
    callback = function(args) vim.schedule(function() M.apply(args.buf) end) end,
  })
  vim.schedule(function() M.apply(api.nvim_get_current_buf()) end)
end

return M
