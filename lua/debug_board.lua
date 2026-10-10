-- The Debugger column from here, when this Neovim is on an Orven board and
-- the runner's Debugger brings its Neovim package: breakpoints set from the
-- line you are on, the program driven from the keyboard, and a Debugger
-- opened on a command or a process without leaving the editor.
--
-- The package does the work and draws the rest by itself: breakpoint signs
-- (set, or why the debugger could not), the line the program is paused at,
-- followed as it moves. The stack, the variables and evaluating stay in the
-- column, which is built for them.
--
-- Its own keys are under <leader>d, which this configuration gives to
-- diagnostics, so they are off (vim.g.orven_keys, in agent_board.lua) and
-- these are the same letters under <leader>x:
--
--   <leader>xb   a breakpoint on this line, or none
--   <leader>xB   one that stops only if a condition holds
--   <leader>xl   one that logs a message instead of stopping
--   <leader>xc   go on            <leader>xn   step over
--   <leader>xi   step into        <leader>xo   step out
--   <leader>xp   pause            <leader>xS   stop
--   <leader>xR   restart
--   <leader>xd   debug a command, in a Debugger column
--   <leader>xs   show this line in it
--
-- Off a board, or on a runner whose Debugger brings no package, none of
-- these are mapped.

local M = {}

function M.setup()
  if not require("agent_board").on() then
    return false
  end
  local ok, debug = pcall(require, "orven.plugin.debug")
  if not ok then
    return false
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      fn()
    end, { silent = true, desc = "Debugger: " .. desc })
  end
  map("<leader>xb", debug.toggle, "a breakpoint on this line, or none")
  map("<leader>xB", debug.condition, "a breakpoint that stops only if")
  map("<leader>xl", debug.log_point, "a log point on this line")
  map("<leader>xc", debug.continue, "go on")
  map("<leader>xn", debug.next, "step over")
  map("<leader>xi", debug.step, "step into")
  map("<leader>xo", debug.out, "step out")
  map("<leader>xp", debug.pause, "pause")
  map("<leader>xS", debug.stop, "stop")
  map("<leader>xR", debug.restart, "restart")
  map("<leader>xd", debug.open, "debug a command")
  map("<leader>xs", debug.show, "show this line in it")
  return true
end

return M
