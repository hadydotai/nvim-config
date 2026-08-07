-- Keep the :Lexplore sidebar pinned as a full-height column on the left.
--
--   <c-w>H/J/K/L  ignored inside netrw; from elsewhere the move happens and the
--                 sidebar is put back afterwards
--   <c-w>s / v    inside netrw these split the editing area instead of the
--                 sidebar, with the cursor following the new split
--   M.focus()     toggle between the sidebar and the window you came from
--                 (mapped to <leader>E in keymap.lua)

local M = {}

-- Only the Lexplore sidebar, identified by the buffer number Lexplore records.
-- A netrw buffer opened some other way (`nvim .`, :Explore) is a normal window
-- and should stay movable.
local function sidebar()
	local bufnr = vim.t.netrw_lexbufnr
	if not bufnr then
		return nil
	end
	local win = vim.fn.bufwinid(bufnr)
	if win == -1 or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	return win
end

-- A window to hand focus back to: the one we last came from, else any ordinary
-- window that is not the sidebar.
local function editing_win(side)
	local remembered = vim.t.netrw_sidebar_return
	if
		remembered
		and remembered ~= side
		and vim.api.nvim_win_is_valid(remembered)
		and vim.api.nvim_win_get_config(remembered).relative == ""
	then
		return remembered
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= side and vim.api.nvim_win_get_config(win).relative == "" then
			return win
		end
	end
	return nil
end

-- The width to restore the sidebar to. Its current width is only meaningful
-- when something else is sharing the screen: a lone sidebar has stretched to
-- fill, so fall back to the size :Lexplore would have given it.
local function target_width(side)
	local others = 0
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= side and vim.api.nvim_win_get_config(win).relative == "" then
			others = others + 1
		end
	end
	if others > 0 then
		return vim.api.nvim_win_get_width(side)
	end
	local winsize = vim.g.netrw_winsize or 25
	if winsize > 0 then
		return math.floor(vim.api.nvim_win_get_width(side) * winsize / 100)
	end
	return -winsize
end

-- The width :Lexplore should have opened it at. netrw reads g:netrw_winsize as
-- a percentage of the window it happens to be splitting, so opening the sidebar
-- from an already split editing area gives you a fraction of a fraction: a
-- quarter of half the screen is an eighth. It is meant to be a share of the
-- screen, and not to depend on which window you were in at the time.
local function initial_width()
	local winsize = vim.g.netrw_winsize or 25
	if winsize > 0 then
		return math.max(1, math.floor(vim.o.columns * winsize / 100))
	end
	return -winsize -- a negative winsize is an absolute column count
end

-- Put the sidebar back on the left at `width`, leaving the cursor where it was.
-- Re-asserted unconditionally rather than only when column 0 is lost: <c-w>J
-- keeps the sidebar at column 0 but spans the moved window across the full
-- width, halving its height. `wincmd H` fixes both and is a no-op when the
-- sidebar is already a full-height left column.
local function pin(side, width)
	if not (side and vim.api.nvim_win_is_valid(side)) then
		return
	end

	local landed = vim.api.nvim_get_current_win()
	local previous = vim.fn.win_getid(vim.fn.winnr("#"))

	vim.api.nvim_set_current_win(side)
	vim.cmd("wincmd H")
	vim.api.nvim_win_set_width(side, width)
	-- rebalance the rest the way 'equalalways' would have; Lexplore sets
	-- winfixwidth on the sidebar, so this leaves its width alone
	vim.cmd("wincmd =")

	-- restore the previous-window pointer too: netrw's browse_split=4 means
	-- literally "open in the previous window", so leaving it pointing at the
	-- sidebar would make <s-cr> open files into netrw itself
	if
		previous ~= 0
		and previous ~= landed
		and previous ~= side
		and vim.api.nvim_win_is_valid(previous)
	then
		vim.api.nvim_set_current_win(previous)
	end
	if vim.api.nvim_win_is_valid(landed) then
		vim.api.nvim_set_current_win(landed)
	end
end

local function move(dir)
	local side = sidebar()
	if side and side == vim.api.nvim_get_current_win() then
		return -- the sidebar stays where it is
	end
	local width = side and target_width(side)
	vim.cmd("wincmd " .. dir)
	pin(side, width)
end

-- Split the editing area rather than the sidebar, and return the window that
-- was created. Focus is left in it. netrw_pick uses the return value to open a
-- file into the new pane.
function M.new_editing_split(cmd)
	local side = sidebar()
	local width = side and target_width(side)

	if side and side == vim.api.nvim_get_current_win() then
		local target = editing_win(side)
		if target then
			vim.api.nvim_set_current_win(target)
			vim.cmd(cmd)
		else
			-- sidebar is the only window; make an empty one beside it rather
			-- than cloning netrw into a second pane. Matched rather than
			-- compared, so callers can pass modifiers ("belowright split").
			vim.cmd(cmd:match("vsplit") and "belowright vnew" or "belowright new")
		end
	else
		vim.cmd(cmd)
	end

	local created = vim.api.nvim_get_current_win()
	pin(side, width)
	return created
end

-- the Lexplore sidebar window, or nil
function M.window()
	return sidebar()
end

--- Open the sidebar at the width it was meant to have, and return its window.
--- Every caller goes through here rather than :Lexplore directly, so the
--- sidebar comes up the same size whatever the layout was beforehand.
function M.open()
	vim.cmd("Lexplore")
	local side = sidebar()
	if side then
		pin(side, initial_width())
	end
	return side
end

function M.focus()
	local side = sidebar()
	if not side then
		M.open()
		return
	end

	local current = vim.api.nvim_get_current_win()
	if current ~= side then
		vim.t.netrw_sidebar_return = current
		vim.api.nvim_set_current_win(side)
		return
	end

	local back = editing_win(side)
	if back then
		vim.api.nvim_set_current_win(back)
	end
end

function M.setup()
	vim.g.netrw_liststyle = 3 -- tree view
	vim.g.netrw_banner = 0 -- hide the top banner
	vim.g.netrw_winsize = 25 -- fix the left split width
	vim.g.netrw_browse_split = 4 -- open files in the previous window
	vim.g.netrw_altfile = 1 -- keep the alternate file correct

	for _, dir in ipairs({ "H", "J", "K", "L" }) do
		vim.keymap.set("n", "<c-w>" .. dir, function()
			move(dir)
		end, { silent = true, desc = "Move window " .. dir .. ", keeping netrw left" })
	end

	-- Rotate and exchange throw the sidebar out of the left column whenever the
	-- editing area is a single window, so they are disabled outright. <c-w><c-r>
	-- and <c-w><c-x> are documented aliases for r and x, so cover them too.
	for _, key in ipairs({ "r", "<c-r>", "R", "x", "<c-x>" }) do
		vim.keymap.set("n", "<c-w>" .. key, "<Nop>", {
			silent = true,
			desc = "Disabled: rotate/exchange would displace netrw",
		})
	end

	-- Inside a netrw buffer these are shadowed by buffer-local maps from
	-- netrw_pick, which open the file under the cursor into the new split.
	vim.keymap.set("n", "<c-w>s", function()
		M.new_editing_split("split")
	end, { silent = true, desc = "Split, never splitting netrw" })
	vim.keymap.set("n", "<c-w>v", function()
		M.new_editing_split("vsplit")
	end, { silent = true, desc = "Vertical split, never splitting netrw" })
end

return M
