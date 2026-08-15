-- Jump to a window by its number, the way tmux jumps to a pane.
--
-- `<C-w>` draws each window's number over it and waits. A digit goes to that
-- window; anything else is handed straight back to whatever `<C-w>` and that
-- key already meant, so every other window command works exactly as it did.
--
--   <C-w>        show the numbers
--   <C-w>{1-9}   focus that window
--
-- The numbers are Vim's own, from `winnr()`, so `<C-w>2` and `2<C-w>w` are the
-- same window and the number over a pane is the one every other window command
-- already means. A tenth window is unlabelled rather than renumbered; there is
-- no second digit to press, and `{count}<C-w>w` still reaches it.
--
-- Nothing is drawn when the next key is already waiting, so `<C-w>v` typed at
-- speed does not flash a number over every window on the way past. Pausing is
-- what asks for them, and pausing costs 'timeoutlen' first: `<C-w>H` and the
-- other two-key window commands are mappings of their own, and Vim waits to
-- see which of the two you are typing.

local M = {}

local LABELS = 9

local floats = {}

local function set_hl()
	vim.api.nvim_set_hl(0, "WinNumber", { link = "DiagnosticWarn", default = true })
end

local function hide()
	for _, win in ipairs(floats) do
		pcall(vim.api.nvim_win_close, win, true)
	end
	floats = {}
end

--- A label in the middle of each window. Middle rather than a corner because a
--- corner is where the things you are reading are: a filename, a line number,
--- the first word of a paragraph.
local function show()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local ok, config = pcall(vim.api.nvim_win_get_config, win)
		local number = vim.api.nvim_win_get_number(win)
		if ok and config.relative == "" and number <= LABELS then
			local text = (" %d "):format(number)
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })

			local height = vim.api.nvim_win_get_height(win)
			local width = vim.api.nvim_win_get_width(win)
			local float = vim.api.nvim_open_win(buf, false, {
				relative = "win",
				win = win,
				row = math.max(0, math.floor((height - 1) / 2)),
				col = math.max(0, math.floor((width - #text) / 2)),
				width = math.min(#text, width),
				height = 1,
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

--- Hand `key` back to whatever `<C-w>` and it meant before this file existed:
--- a mapping if there is one, and Vim's own window command otherwise. Going
--- through the mapping rather than replaying the keys is what keeps this from
--- either losing `<C-w>H` or looping back into itself.
local function passthrough(count, key)
	local lhs = vim.keycode("<C-w>") .. key
	local map = vim.fn.maparg(lhs, "n", false, true)

	if type(map) == "table" and not vim.tbl_isempty(map) then
		if map.callback then
			return map.callback()
		end
		local rhs = map.rhs or ""
		if rhs == "" or rhs:lower() == "<nop>" then
			return
		end
		return vim.api.nvim_feedkeys(vim.keycode(rhs), map.noremap == 1 and "n" or "m", false)
	end

	vim.api.nvim_feedkeys(count .. lhs, "n", false)
end

--- `<C-w>`: the numbers, then one key.
function M.prefix()
	-- Read before anything else: getcharstr() below is a whole other keypress,
	-- and v:count belongs to this one.
	local count = vim.v.count > 0 and tostring(vim.v.count) or ""

	if vim.fn.getchar(1) == 0 then
		set_hl()
		show()
		vim.cmd("redraw")
	end

	local ok, key = pcall(vim.fn.getcharstr)
	hide()
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

	passthrough(count, key)
end

vim.keymap.set("n", "<C-w>", M.prefix, { silent = true, desc = "Window commands, with the panes numbered" })

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

return M
