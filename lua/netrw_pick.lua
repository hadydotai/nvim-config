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
--
-- The target outline itself is generic and lives in lua/win_pick.lua, since the
-- file finder reuses it for exactly the same choice.

local M = {}

local win_pick = require("win_pick")

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

local function is_sidebar(win)
	local lex = vim.t.netrw_lexbufnr
	return lex ~= nil and vim.api.nvim_win_get_buf(win) == lex
end

-- Open into the current window instead of splitting. netrw_browse_split=4 means
-- "open in the previous window", and with no other window netrw splits to invent
-- one, which is why `nvim .` + <cr> used to push the file into a new pane above.
-- A plain netrw should just take over its own window like stock netrw does; the
-- sidebar is the exception, since replacing it would destroy it.
local function browse_here(islocal, word)
	local keep_split, keep_chgwin = vim.g.netrw_browse_split, vim.g.netrw_chgwin
	vim.g.netrw_browse_split = 0
	vim.g.netrw_chgwin = -1
	local ok, err = pcall(browse, islocal, word)
	vim.g.netrw_browse_split = keep_split
	vim.g.netrw_chgwin = keep_chgwin or -1
	if not ok then
		error(err)
	end
end

-- start on whatever netrw would have used, so <cr><cr> matches <s-cr>
local function select_window(from, wins)
	return win_pick.select(from, wins)
end

local targets = win_pick.targets

-- Open the file under the cursor into a freshly made editing split, leaving
-- netrw itself where it is. new_editing_split re-pins the sidebar afterwards,
-- which is the whole reason to make the window ourselves rather than let netrw
-- do it.
local function browse_in_new_split(islocal, word, cmd)
	local netrw_win = vim.api.nvim_get_current_win()
	local created = require("netrw_sidebar").new_editing_split(cmd)
	if not (created and vim.api.nvim_win_is_valid(created)) then
		return
	end

	vim.api.nvim_set_current_win(netrw_win)
	local keep_split, keep_chgwin = vim.g.netrw_browse_split, vim.g.netrw_chgwin
	vim.g.netrw_browse_split = 0
	-- window numbers can shift when the sidebar is re-pinned, so resolve this
	-- after the split has settled
	vim.g.netrw_chgwin = vim.api.nvim_win_get_number(created)
	local ok, err = pcall(browse, islocal, word)
	vim.g.netrw_browse_split = keep_split
	vim.g.netrw_chgwin = keep_chgwin or -1
	if not ok then
		error(err)
	end
end

-- netrw's own behaviour for the current window layout
local function open_default(islocal, word)
	local win = vim.api.nvim_get_current_win()
	if #targets(win) > 0 then
		return browse(islocal, word)
	end

	-- Nothing to open into. netrw must not be left to sort this out itself:
	-- browse_split=4 means "the previous window", and with none to be had netrw
	-- invents one by splitting horizontally, which drops the file in a pane
	-- above and leaves the sidebar stretched along the full width underneath.
	if not is_sidebar(win) then
		return browse_here(islocal, word) -- a plain netrw window takes the file
	end
	return browse_in_new_split(islocal, word, "vsplit")
end

function M.default(islocal)
	local word = word_under_cursor()
	if word then
		open_default(islocal, word)
	end
end

-- <c-w>s / <c-w>v inside netrw: open the file under the cursor in a fresh split
-- of the editing area. netrw's own o/v keys do this by splitting the netrw
-- window itself, which tears the sidebar apart.
function M.split_open(islocal, cmd)
	local word = word_under_cursor()
	if not word then
		return
	end
	if word:sub(-1) == "/" then
		return browse(islocal, word) -- directories keep expanding as usual
	end
	browse_in_new_split(islocal, word, cmd)
end

-- The directory a new file should land in. In tree view NetrwTreeDir tracks the
-- cursor, so pointing inside an expanded subdirectory creates the file there.
local function base_dir(islocal)
	if vim.g.netrw_liststyle == 3 then
		local ok, dir = pcall(vim.fn["netrw#Call"], "NetrwTreeDir", islocal)
		if ok and type(dir) == "string" and dir ~= "" then
			return (dir:gsub("/$", ""))
		end
	end
	local curdir = vim.b.netrw_curdir
	return curdir and (curdir:gsub("/$", "")) or nil
end

local function refresh(islocal)
	local dir = vim.fn["netrw#Call"]("NetrwBrowseChgDir", islocal, "./", 0)
	vim.fn["netrw#Call"]("NetrwRefresh", islocal, dir)
end

-- Where a newly created file should be opened. Returns a window, or the string
-- "split" when the sidebar needs a fresh editing pane made for it, or nil if the
-- user cancelled the picker.
local function destination(netrw_win)
	local wins = targets(netrw_win)
	if #wins >= 2 then
		return select_window(netrw_win, wins)
	end
	if #wins == 1 then
		return wins[1]
	end
	return is_sidebar(netrw_win) and "split" or netrw_win
end

-- `%` in netrw: netrw's own version does `:e dir/name` in the netrw window
-- itself, leaving an unsaved buffer where the listing used to be. This creates
-- the file on disk, refreshes the listing, and opens it in a real editing window.
function M.create(islocal)
	local dir = base_dir(islocal)
	if not dir or dir == "" then
		return
	end

	-- vim.ui.input rather than vim.fn.input: netrw's own `%` wraps input() in
	-- inputsave(), which drops pending typeahead, and this keeps the prompt
	-- swappable for any ui override
	vim.ui.input({ prompt = "New file: " }, function(name)
		if name == nil or name == "" then
			return
		end
		M.create_at(islocal, dir, name)
	end)
end

function M.create_at(islocal, dir, name)
	local path = name:sub(1, 1) == "/" and name or (dir .. "/" .. name)

	-- a trailing slash means "make me a directory"; netrw's own `d` does this
	if path:sub(-1) == "/" then
		vim.fn.mkdir(path, "p")
		refresh(islocal)
		return
	end

	local netrw_win = vim.api.nvim_get_current_win()
	local target = destination(netrw_win)
	if not target then
		return -- picker cancelled, so nothing is created
	end

	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	if vim.fn.filereadable(path) == 0 then
		-- never truncate: an existing file is just opened
		vim.fn.writefile({}, path)
	end
	refresh(islocal)

	if target == "split" then
		require("netrw_sidebar").new_editing_split("vsplit")
	else
		vim.api.nvim_set_current_win(target)
	end
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.choose(islocal)
	local word = word_under_cursor()
	if not word then
		return
	end

	local netrw_win = vim.api.nvim_get_current_win()
	local wins = targets(netrw_win)

	-- directories just expand or collapse, and a single candidate is unambiguous
	if word:sub(-1) == "/" then
		return browse(islocal, word)
	end
	if #wins < 2 then
		return open_default(islocal, word)
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
	win_pick.setup()

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
		function! NetrwPickSplit(islocal) abort
			call luaeval('require("netrw_pick").split_open(_A, "split")', a:islocal)
			return ""
		endfunction
		function! NetrwPickVsplit(islocal) abort
			call luaeval('require("netrw_pick").split_open(_A, "vsplit")', a:islocal)
			return ""
		endfunction
		function! NetrwPickNew(islocal) abort
			call luaeval('require("netrw_pick").create(_A)', a:islocal)
			return ""
		endfunction
	]])

	vim.g.Netrw_UserMaps = {
		{ "<cr>", "NetrwPickChoose" },
		{ "<s-cr>", "NetrwPickDefault" },
		{ "<c-w>s", "NetrwPickSplit" },
		{ "<c-w>v", "NetrwPickVsplit" },
		{ "%", "NetrwPickNew" },
	}

	-- netrw installs the maps above itself, so keys.lua never sees them go by
	require("keys").declare({
		{ lhs = "<cr>", where = "netrw", desc = "Outline a target window, hjkl to move, <CR> to open there" },
		{ lhs = "<s-cr>", where = "netrw", desc = "Open the file in the previous window (netrw's default)" },
		{ lhs = "<c-w>s", where = "netrw", desc = "Open the file under the cursor in a new horizontal split" },
		{ lhs = "<c-w>v", where = "netrw", desc = "Open the file under the cursor in a new vertical split" },
		{ lhs = "%", where = "netrw", desc = "Create a file on disk, then choose where to open it" },
	})
end

return M
