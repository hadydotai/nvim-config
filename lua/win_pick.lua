-- Choose a window by pointing at it: an outline is drawn over the candidate,
-- hjkl moves it, <cr> confirms, <esc>/q cancels.
--
-- Used wherever something has to open a file and there is more than one place
-- it could go: <cr> in netrw (lua/netrw_pick.lua) and <cr> in the file finder
-- (lua/find.lua).

local M = {}

local BORDER_HL = "DiagnosticWarn" -- change this to recolour the selection outline

local overlay_win, overlay_buf

local function set_hl()
	vim.api.nvim_set_hl(0, "NetrwPickBorder", { link = BORDER_HL })
end

--- Ordinary windows a file could be opened into: no floats, and never netrw,
--- so the sidebar is not offered as a place to put a file.
--- `exclude` drops one more window, whatever it is.
function M.targets(exclude)
	local out = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if
			win ~= exclude
			and vim.api.nvim_win_get_config(win).relative == ""
			and vim.bo[buf].filetype ~= "netrw"
		then
			out[#out + 1] = win
		end
	end
	return out
end

local function geom(win)
	local pos = vim.api.nvim_win_get_position(win)
	return {
		row = pos[1],
		col = pos[2],
		height = vim.api.nvim_win_get_height(win),
		width = vim.api.nvim_win_get_width(win),
	}
end

-- Nearest candidate in a direction, computed from screen geometry. Deliberately
-- not `wincmd h/j/k/l` inside nvim_win_call: that really does switch windows and
-- clobbers the previous-window pointer, which is exactly what netrw's
-- browse_split=4 ("open previous window") relies on.
local function neighbour(from, dir, wins)
	local a = geom(from)
	local best, best_gap
	for _, win in ipairs(wins) do
		if win ~= from then
			local b = geom(win)
			local gap, aligned
			if dir == "l" then
				gap = b.col - (a.col + a.width)
				aligned = b.row < a.row + a.height and a.row < b.row + b.height
			elseif dir == "h" then
				gap = a.col - (b.col + b.width)
				aligned = b.row < a.row + a.height and a.row < b.row + b.height
			elseif dir == "j" then
				gap = b.row - (a.row + a.height)
				aligned = b.col < a.col + a.width and a.col < b.col + b.width
			else
				gap = a.row - (b.row + b.height)
				aligned = b.col < a.col + a.width and a.col < b.col + b.width
			end
			if aligned and gap >= 0 and (not best_gap or gap < best_gap) then
				best, best_gap = win, gap
			end
		end
	end
	return best
end

local function show(win)
	local cfg = {
		relative = "win",
		win = win,
		row = 0,
		col = 0,
		width = math.max(1, vim.api.nvim_win_get_width(win) - 2),
		height = math.max(1, vim.api.nvim_win_get_height(win) - 2),
		focusable = false,
		style = "minimal",
		border = "rounded",
		-- U+00A0 rather than plain spaces: at winblend=100 a blank float cell is
		-- fully transparent and leaks the text underneath into the title
		title = "\194\160open\194\160here\194\160",
		title_pos = "center",
		zindex = 250,
		noautocmd = true,
	}
	if overlay_win and vim.api.nvim_win_is_valid(overlay_win) then
		vim.api.nvim_win_set_config(overlay_win, cfg)
		return
	end
	if not (overlay_buf and vim.api.nvim_buf_is_valid(overlay_buf)) then
		overlay_buf = vim.api.nvim_create_buf(false, true)
	end
	overlay_win = vim.api.nvim_open_win(overlay_buf, false, cfg)
	-- winblend keeps the interior see-through so only the outline reads as UI
	vim.wo[overlay_win].winblend = 100
	vim.wo[overlay_win].winhighlight = "FloatBorder:NetrwPickBorder,FloatTitle:NetrwPickBorder"
end

local function hide()
	if overlay_win and vim.api.nvim_win_is_valid(overlay_win) then
		-- The overlay is internal UI, so close it without firing WinClosed and
		-- friends: autocmd errors would otherwise propagate straight out of
		-- nvim_win_close and abort the picker mid-cancel.
		local keep = vim.o.eventignore
		vim.o.eventignore = "all"
		pcall(vim.api.nvim_win_close, overlay_win, true)
		vim.o.eventignore = keep
	end
	overlay_win = nil
end

--- Modal loop: hjkl moves the outline, <cr> confirms, <esc>/q cancels.
--- Returns the chosen window, or nil. `from` is where the movement starts out
--- from, `start` the window to highlight first (default: the previous window,
--- which is what netrw would have opened into anyway).
function M.select(from, wins, start)
	local selected = start or vim.fn.win_getid(vim.fn.winnr("#"))
	if not vim.tbl_contains(wins, selected) then
		selected = neighbour(from, "l", wins) or wins[1]
	end

	local chosen
	while true do
		show(selected)
		vim.cmd("redraw")
		local ok, key = pcall(vim.fn.getcharstr)
		if not ok then
			break
		end
		if key == "h" or key == "j" or key == "k" or key == "l" then
			selected = neighbour(selected, key, wins) or selected
		elseif key == "\r" then
			chosen = selected
			break
		elseif key == "\27" or key == "q" then
			break
		end
	end

	hide()
	vim.cmd("redraw")
	return chosen
end

function M.setup()
	set_hl()
	vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })
end

return M
