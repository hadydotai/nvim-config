-- Choose a window by pointing at it: an outline is drawn over the candidate,
-- hjkl moves it, <cr> confirms, <esc>/q cancels.
--
-- Used wherever something has to open a file and there is more than one place
-- it could go: <cr> in netrw (lua/netrw_pick.lua) and <cr> in the file finder
-- (lua/find.lua).

local M = {}

local BORDER_HL = "DiagnosticWarn" -- change this to recolour the selection outline
local SHOW_HL = "DiagnosticInfo" -- and this one for pointing rather than opening

local overlay_win, overlay_buf

local function set_hl()
	vim.api.nvim_set_hl(0, "NetrwPickBorder", { link = BORDER_HL })
	vim.api.nvim_set_hl(0, "WinPickShowBorder", { link = SHOW_HL })
end

--- What the outline says and what colour it is. Opening something into a
--- window and pointing a panel at one are different questions, and answering
--- the wrong one is easy when they look the same.
---
--- U+00A0 rather than plain spaces: at winblend=100 a blank float cell is
--- fully transparent and leaks the text underneath into the title.
M.LOOK = {
	open = { title = "\194\160open\194\160here\194\160", hl = "NetrwPickBorder" },
	panel = { title = "\194\160panel\194\160here\194\160", hl = "NetrwPickBorder" },
	show = { title = "\194\160show\194\160this\194\160", hl = "WinPickShowBorder" },
}

--- Windows that are UI rather than somewhere to put a file: the netrw tree,
--- and either half of a projected list. A panel is a thing you read beside
--- your work, so opening a file into one would take away the list that sent
--- you to the file.
local function furniture(win)
	local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
	return ft == "netrw" or ft == "picker" or ft == "pickerprompt"
end

--- Ordinary windows a file could be opened into: no floats, and nothing that
--- is itself UI.
--- `exclude` drops one more window, or several when given a list.
function M.targets(exclude)
	local skip = {}
	if type(exclude) == "table" then
		for _, win in ipairs(exclude) do
			skip[win] = true
		end
	elseif exclude then
		skip[exclude] = true
	end

	local out = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if not skip[win] and vim.api.nvim_win_get_config(win).relative == "" and not furniture(win) then
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

local function show(win, look)
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
		title = look.title,
		title_pos = "center",
		zindex = 250,
		noautocmd = true,
	}
	local paint = ("FloatBorder:%s,FloatTitle:%s"):format(look.hl, look.hl)
	if overlay_win and vim.api.nvim_win_is_valid(overlay_win) then
		vim.api.nvim_win_set_config(overlay_win, cfg)
		vim.wo[overlay_win].winhighlight = paint
		return
	end
	if not (overlay_buf and vim.api.nvim_buf_is_valid(overlay_buf)) then
		overlay_buf = vim.api.nvim_create_buf(false, true)
	end
	overlay_win = vim.api.nvim_open_win(overlay_buf, false, cfg)
	-- winblend keeps the interior see-through so only the outline reads as UI
	vim.wo[overlay_win].winblend = 100
	vim.wo[overlay_win].winhighlight = paint
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
--- which is what netrw would have opened into anyway), and `look` what the
--- outline says and what colour it is (default: opening something here).
function M.select(from, wins, start, look)
	look = look or M.LOOK.open
	local selected = start or vim.fn.win_getid(vim.fn.winnr("#"))
	if not vim.tbl_contains(wins, selected) then
		selected = neighbour(from, "l", wins) or wins[1]
	end

	local chosen
	while true do
		show(selected, look)
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

-- Only the :Lexplore sidebar, identified by the buffer number Lexplore records.
-- A netrw buffer opened some other way (`nvim .`, :Explore) is an ordinary
-- window that happens to be showing a directory.
local function is_sidebar(win)
	local lex = vim.t.netrw_lexbufnr
	return lex ~= nil and vim.api.nvim_win_get_buf(win) == lex
end

--- Windows that may be taken over when there is no editing window at all.
--- Wider than `targets`: netrw counts, because stock netrw replaces itself on
--- <cr> and `nvim .` then opening something has always felt that way. The
--- pinned sidebar and a projected list are the two worth keeping, being the
--- two you arranged deliberately and would have to arrange again.
local function takeable(exclude)
	local out = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
		if
			win ~= exclude
			and vim.api.nvim_win_get_config(win).relative == ""
			and not is_sidebar(win)
			and ft ~= "picker"
			and ft ~= "pickerprompt"
		then
			out[#out + 1] = win
		end
	end
	return out
end

--- Where "just open it, do not ask" goes: the window whoever is asking started
--- out in, else the one before that, else any other ordinary window, else a
--- directory listing to take over. nil means there is nowhere to put it and one
--- has to be made.
---
--- `exclude` is for a caller that is itself a window: the dashboard must never
--- answer "where should this go" with itself, and a `from` that is the
--- dashboard is not a place to open anything.
local function fallback(from, previous, exclude)
	local wins = M.targets(exclude)
	for _, win in ipairs({ from, previous }) do
		if vim.tbl_contains(wins, win) then
			return win
		end
	end
	if wins[1] then
		return wins[1]
	end
	local over = takeable(exclude)
	if from and vim.tbl_contains(over, from) then
		return from
	end
	return over[1]
end

--- Focus `win`, or make an editing split when there is none. By the time this
--- gets a nil the only window on screen is the pinned sidebar, which is the one
--- thing that must not be replaced.
function M.focus(win)
	if win then
		vim.api.nvim_set_current_win(win)
	else
		require("netrw_sidebar").new_editing_split("vsplit")
	end
end

--- The <cr>/<s-cr> pair for a picker that opens something into a window: <cr>
--- outlines a target unless there is only one, <s-cr> takes the obvious one
--- without asking. `open(win, item)` does the opening and may get a nil window.
--- Call this while building the picker, so it still sees where you came from.
---
--- `exclude` is a window that is not a candidate, for a caller that lives in a
--- window of its own rather than in a float.
function M.actions(open, exclude)
	local from = vim.api.nvim_get_current_win()
	local previous = vim.fn.win_getid(vim.fn.winnr("#"))
	return {
		["<CR>"] = function(item)
			local wins = M.targets(exclude)
			if #wins < 2 then
				-- nothing to disambiguate, so <cr> is <s-cr>
				return open(fallback(from, previous, exclude), item)
			end
			local chosen = M.select(from, wins, fallback(from, previous, exclude))
			if chosen then
				open(chosen, item)
			end
		end,
		["<S-CR>"] = function(item)
			open(fallback(from, previous, exclude), item)
		end,
	}
end

M.FOOTER = " <CR> pick window   <S-CR> open here   <C-o> panel   <Esc> close "

function M.setup()
	set_hl()
	vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })
end

return M
