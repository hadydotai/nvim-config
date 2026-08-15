-- Jump to a window by its number, the way tmux jumps to a pane.
--
-- `<C-w>` puts a large number over every window, and `1` to `9` goes there.
--
--   <C-w>        show the numbers
--   <C-w>{1-9}   focus that window
--
-- The numbers are Vim's own, from `winnr()`, so `<C-w>2` and `2<C-w>w` are the
-- same window and the number over a pane is the one every other window command
-- already means. A tenth window is unlabelled rather than renumbered; there is
-- no second digit to press, and `{count}<C-w>w` still reaches it.
--
-- Why this owns the whole prefix rather than mapping only `<C-w>1` to
-- `<C-w>9`: the numbers have to appear while Vim waits for the second key of
-- `<C-w>`, and Vim does not repaint in that state. It is waiting on input, not
-- running a loop, so a float created there - from vim.on_key, from a timer,
-- from anything - exists and never reaches the screen. `:redraw!` and
-- `nvim__redraw{flush=true}` were both tried against a real terminal, and
-- neither pushes a frame out.
--
-- A mapping does paint, because it runs. But a mapping only fires at once if
-- nothing longer starts with it, which is why every other `<C-w>` mapping is
-- adopted below and deleted rather than left to compete: with `<C-w>H` still
-- mapped, Vim would sit out 'timeoutlen' before either could run and the
-- numbers would arrive a second late. What is adopted is kept and dispatched
-- from here, so those keys still do exactly what they did.

local M = {}

local LABELS = 9

-- Five rows of three, the shape a seven-segment digit wants, and each cell
-- drawn two columns wide so it comes out square rather than a thin stripe.
-- Big because the point of putting the number over the pane is not hunting.
local GLYPHS = {
	["1"] = { " # ", "## ", " # ", " # ", "###" },
	["2"] = { "###", "  #", "###", "#  ", "###" },
	["3"] = { "###", "  #", "###", "  #", "###" },
	["4"] = { "# #", "# #", "###", "  #", "  #" },
	["5"] = { "###", "#  ", "###", "  #", "###" },
	["6"] = { "###", "#  ", "###", "# #", "###" },
	["7"] = { "###", "  #", "  #", "  #", "  #" },
	["8"] = { "###", "# #", "###", "# #", "###" },
	["9"] = { "###", "# #", "###", "  #", "###" },
}

local ON, OFF = "██", "  "

local floats = {}

local function set_hl()
	vim.api.nvim_set_hl(0, "WinNumber", { link = "DiagnosticWarn", default = true })
end

--- The digit as lines, or a plain label when the window is too small to hold
--- one. A split three rows high should still say which window it is.
local function drawing(number, height, width)
	local glyph = GLYPHS[tostring(number)]
	if not glyph or height < #glyph or width < #glyph[1] * 2 then
		return { (" %d "):format(number) }
	end
	local lines = {}
	for i, row in ipairs(glyph) do
		lines[i] = (row:gsub("#", ON):gsub(" ", OFF))
	end
	return lines
end

local function hide()
	for _, win in ipairs(floats) do
		pcall(vim.api.nvim_win_close, win, true)
	end
	floats = {}
end

--- A number in the middle of each window. Middle rather than a corner because
--- a corner is where the things you are reading are: a filename, a line
--- number, the first word of a paragraph.
local function show()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local ok, config = pcall(vim.api.nvim_win_get_config, win)
		local number = vim.api.nvim_win_get_number(win)
		if ok and config.relative == "" and number <= LABELS then
			local height = vim.api.nvim_win_get_height(win)
			local width = vim.api.nvim_win_get_width(win)
			local lines = drawing(number, height, width)
			local drawn = vim.fn.strdisplaywidth(lines[1])

			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			local float = vim.api.nvim_open_win(buf, false, {
				relative = "win",
				win = win,
				row = math.max(0, math.floor((height - #lines) / 2)),
				col = math.max(0, math.floor((width - drawn) / 2)),
				width = math.min(drawn, width),
				height = math.min(#lines, height),
				style = "minimal",
				focusable = false,
				noautocmd = true,
				zindex = 250,
			})
			vim.wo[float].winhighlight = "Normal:WinNumber"
			floats[#floats + 1] = float
		end
	end
end

--------------------------------------------------------------------------- --
-- the key after the prefix
--------------------------------------------------------------------------- --

local CTRL_W = vim.keycode("<C-w>")

--- The key after `<C-w>` to what it does, for everything that used to be a
--- mapping of its own.
M.keys = {}

--- How many mappings have been re-homed under a <Plug> name, below.
local plugs = 0

--- The same, for one buffer, so a buffer's own window command still wins:
--- netrw's `<C-w>s` opens the file under the cursor rather than splitting
--- where you stand. Emptied when the buffer goes, since these are keyed by
--- buffer number and a number is never collected on its own.
M.buffer = {}

--- Give one buffer its own key after `<C-w>`. The way to have a window command
--- of your own without mapping `<C-w>x` and putting the wait back.
function M.on_buffer(buf, key, fn, desc)
	buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
	M.buffer[buf] = M.buffer[buf] or {}
	M.buffer[buf][key] = fn
	if desc then
		-- Recorded against the kind of buffer it belongs to, which is how the
		-- netrw keys already read in <leader>h.
		require("keys").declare({ { lhs = "<C-w>" .. key, where = vim.bo[buf].filetype, desc = desc } })
	end
end

--- Take `<C-w>x` over from whoever mapped it: run it from here, and delete the
--- mapping so the prefix is unambiguous again.
---
--- Adopting rather than reimplementing is what makes this safe to point at
--- Neovim's own defaults and at the netrw sidebar's window moves: the callback
--- that ran before is the callback that runs now.
local function adopt(map, into)
	local rest = vim.keycode(map.lhs):sub(#CTRL_W + 1)
	-- Nothing here has a two-key tail today. One would still work; it would
	-- just cost the wait back on that one key, so it is left alone.
	if rest == "" or #rest > 1 then
		return
	end

	if map.callback then
		into[rest] = map.callback
	elseif map.rhs and map.rhs ~= "" and map.rhs:lower() ~= "<nop>" then
		-- Re-mapped under a name nothing types, rather than replayed as
		-- keystrokes: an rhs can hold <SNR> and other things that mean
		-- something only to the mapping they were defined in, and typing one
		-- out gets you the text on the command line instead of the command.
		plugs = plugs + 1
		local plug = ("<Plug>(win_number_%d)"):format(plugs)
		vim.keymap.set("n", plug, map.rhs, {
			noremap = map.noremap == 1,
			silent = map.silent == 1,
			expr = map.expr == 1,
			nowait = true,
		})
		into[rest] = function()
			vim.api.nvim_feedkeys(vim.keycode(plug), "m", false)
		end
	else
		-- An explicit <Nop>: netrw disables rotate and exchange, and the key is
		-- meant to keep doing nothing.
		into[rest] = function() end
	end

	-- Deleted by the lhs as it was written rather than as keycodes: keymap.del
	-- matches the spelling, and a raw <C-w> byte is "no such mapping".
	pcall(vim.keymap.del, "n", map.lhs, map.buffer and { buffer = map.buffer } or nil)
	require("keys").declare({
		{ lhs = "<C-w>" .. rest, desc = map.desc, where = map.buffer and "buffer" or "" },
	})
end

--- Every `<C-w>x` mapping there is, taken over at once. Public, because
--- anything that maps one after this file has loaded can hand it over the same
--- way rather than putting the wait back for everyone.
function M.adopt(buf)
	local maps = buf and vim.api.nvim_buf_get_keymap(buf, "n") or vim.api.nvim_get_keymap("n")
	local into = M.keys
	if buf then
		M.buffer[buf] = M.buffer[buf] or {}
		into = M.buffer[buf]
	end
	for _, map in ipairs(maps) do
		local lhs = vim.keycode(map.lhs)
		if #lhs > #CTRL_W and lhs:sub(1, #CTRL_W) == CTRL_W then
			adopt({
				lhs = map.lhs,
				rhs = map.rhs,
				callback = map.callback,
				noremap = map.noremap,
				desc = map.desc,
				buffer = buf,
			}, into)
		end
	end
end

--- `<C-w>`: the numbers, then one key.
function M.prefix()
	-- Read first: getcharstr() below is another keypress, and v:count belongs
	-- to this one.
	local count = vim.v.count > 0 and tostring(vim.v.count) or ""

	-- Nothing is drawn when the next key is already waiting, so `<C-w>v` typed
	-- at speed does not flash a number over every window on the way past.
	if vim.fn.getchar(1) == 0 then
		show()
		vim.cmd("redraw")
	end

	local ok, key = pcall(vim.fn.getcharstr)
	if #floats > 0 then
		hide()
		vim.cmd("redraw")
	end
	if not ok or key == "" or key == vim.keycode("<Esc>") then
		return
	end

	local number = key:match("^[1-9]$")
	if number then
		local target = vim.fn.win_getid(tonumber(number))
		if target ~= 0 then
			vim.api.nvim_set_current_win(target)
		end
		return
	end

	local mine = M.buffer[vim.api.nvim_get_current_buf()]
	local run = (mine and mine[key]) or M.keys[key]
	if run then
		return run()
	end

	vim.api.nvim_feedkeys(count .. CTRL_W .. key, "n", false)
end

M.adopt()
vim.keymap.set("n", "<C-w>", M.prefix, { silent = true, desc = "Window commands, with the panes numbered" })

vim.api.nvim_create_autocmd("BufWipeout", {
	group = vim.api.nvim_create_augroup("WinNumber", { clear = true }),
	callback = function(ev)
		M.buffer[ev.buf] = nil
	end,
})

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

return M
