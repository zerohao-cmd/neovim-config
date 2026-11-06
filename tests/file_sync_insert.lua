-- Run with the actual config: nvim --headless -u ./init.lua -c 'luafile tests/file_sync_insert.lua'
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.env.XDG_STATE_HOME = dir .. '/state'
local path = dir .. '/typing.txt'
local base = 'first\nsecond\nthird\nfourth\nfifth\nsixth\n'
local function write(raw) local f=assert(io.open(path,'wb')); f:write(raw); f:close() end
local function read() local f=assert(io.open(path,'rb')); local r=f:read('*a'); f:close(); return r end
local function text() return table.concat(api.nvim_buf_get_lines(0,0,-1,false),'\n')..'\n' end
local function input(keys) api.nvim_input(api.nvim_replace_termcodes(keys,true,false,true)) end
local function later(ms, fn)
  vim.defer_fn(function()
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then io.stderr:write(err..'\n'); vim.cmd('cquit 1') end
  end, ms)
end
write(base)
vim.cmd.edit(vim.fn.fnameescape(path))
later(100, function()
  api.nvim_win_set_cursor(0, {3, 0})
  input('iLOCAL')
  later(100, function()
    assert(api.nvim_get_mode().mode == 'i', 'must really be in Insert mode')
    assert(text() == base:gsub('third', 'LOCALthird'), 'typed input missing')
    write('external header\n' .. base:gsub('sixth', 'external sixth'))
    later(1400, function()
      assert(api.nvim_get_mode().mode == 'i', 'sync left Insert mode')
      assert(api.nvim_win_get_cursor(0)[1] == 4, 'cursor did not follow insertion above')
      assert(api.nvim_win_get_cursor(0)[2] == 5, 'insert column moved')
      assert(text() == 'external header\n' .. base:gsub('third', 'LOCALthird'):gsub('sixth', 'external sixth'), 'live merge during Insert failed')
      input('NEXT<Esc>')
      later(200, function()
        assert(api.nvim_get_mode().mode == 'n', 'Esc did not exit Insert')
        assert(read() == 'external header\n' .. base:gsub('third', 'LOCALNEXTthird'):gsub('sixth','external sixth'), 'Esc save did not retain both edits')
        assert(not vim.bo.modified, 'buffer remains dirty after save')
        input('iMINE')
        later(100, function()
          write(read():gsub('LOCALNEXTthird', 'THEIRS'))
          later(1400, function()
            assert(api.nvim_get_mode().mode == 'i', 'conflict stole input focus')
            assert(require('file_sync').status().conflict, 'conflict not reported')
            input('<Esc>')
            later(200, function()
              assert(read():find('THEIRS',1,true), 'Esc overwrote conflicting disk')
              assert(vim.bo.modified, 'conflicting local edits lost')
              print('PASS: actual Insert input, live merge, cursor tracking, Esc save, conflict without focus stealing')
              vim.fn.delete(dir,'rf')
              vim.cmd('qa!')
            end)
          end)
        end)
      end)
    end)
  end)
end)
later(10000, function() error('integration test timeout') end)
