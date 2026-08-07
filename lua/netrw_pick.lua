-- Choose which split a netrw file opens into.
--
--   <cr>   on a file: outline a target window, hjkl to move, <cr> again to open
--   <s-cr> on a file: netrw's default (open in the previous window)
--
-- Directories keep netrw's usual behaviour, and so does <cr> when there is at
-- most one candidate window, since there is nothing to disambiguate.
--
-- Path resolution is left entirely to netrw: we only set g:netrw_chgwin and let
-- netrw's own browse functions do the edit. The maps are installed through
-- g:Netrw_UserMaps rather than a FileType autocmd, because netrw reinstalls its
-- own maps on every listing refresh and would otherwise take <cr> back.

local M = {}

local BORDER_HL = "DiagnosticWarn" -- change this to recolour the selection outline

local overlay_win, overlay_buf

local function set_hl()
	vim.api.nvim_set_hl(0, "NetrwPickBorder", { link = BORDER_HL })
end

local function word_under_cursor()
	local ok, word = pcall(vim.fn["netrw#Call"], "NetrwGetWord")
	if ok and type(word) == "string" then
		return word
	end
end

-- run netrw's normal <cr> action for whatever is under the cursor
local function browse(islocal, word)
	local dir = vim.fn["netrw#Call"]("NetrwBrowseChgDir", islocal, word, 1)
	if islocal == 1 then
		vim.fn["netrw#LocalBrowseCheck"](dir)
	else
		vim.fn["netrw#Call"]("NetrwBrowse", 0, dir)
	end
end

local function targets(exclude)
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
		vim.api.nvim_win_close(overlay_win, true)
	end
	overlay_win = nil
end

-- modal loop: hjkl moves the outline, <cr> confirms, <esc>/q cancels
local function select_window(from, wins)
	-- start on whatever netrw would have used, so <cr><cr> matches <s-cr>
	local selected = vim.fn.win_getid(vim.fn.winnr("#"))
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

function M.default(islocal)
	local word = word_under_cursor()
	if word then
		browse(islocal, word)
	end
end

function M.choose(islocal)
	local word = word_under_cursor()
	if not word then
		return
	end

	local netrw_win = vim.api.nvim_get_current_win()
	local wins = targets(netrw_win)

	-- directories just expand or collapse, and a single candidate is unambiguous
	if word:sub(-1) == "/" or #wins < 2 then
		return browse(islocal, word)
	end

	local chosen = select_window(netrw_win, wins)
	if not chosen then
		return
	end

	local keep_split, keep_chgwin = vim.g.netrw_browse_split, vim.g.netrw_chgwin
	vim.g.netrw_browse_split = 0
	vim.g.netrw_chgwin = vim.api.nvim_win_get_number(chosen)
	local ok, err = pcall(browse, islocal, word)
	vim.g.netrw_browse_split = keep_split
	vim.g.netrw_chgwin = keep_chgwin or -1
	if not ok then
		error(err)
	end
end

function M.setup()
	set_hl()
	vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

	-- netrw calls these by name through s:UserMaps(), so they have to be global
	-- Vimscript functions; returning "" tells netrw there is nothing to :exe
	vim.cmd([[
		function! NetrwPickChoose(islocal) abort
			call luaeval('require("netrw_pick").choose(_A)', a:islocal)
			return ""
		endfunction
		function! NetrwPickDefault(islocal) abort
			call luaeval('require("netrw_pick").default(_A)', a:islocal)
			return ""
		endfunction
	]])

	vim.g.Netrw_UserMaps = {
		{ "<cr>", "NetrwPickChoose" },
		{ "<s-cr>", "NetrwPickDefault" },
	}
end

return M
