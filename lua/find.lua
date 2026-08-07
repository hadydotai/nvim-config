-- <leader>f: a modal, filterable list of the files under the current directory.
--
--   type     narrow the list, fuzzily, against the whole relative path
--   <cr>     outline a target window, hjkl to move, <cr> to open there
--   <s-cr>   open in the window you came from, never the netrw sidebar
--
-- The same two-key split as netrw's <cr>/<s-cr>, and the same outline overlay,
-- so wherever you pick a file from it lands the same way.
--
-- The listing is taken once when the dialog opens and filtered in memory
-- afterwards, so typing costs nothing. 'findfunc' is still set as well, which
-- is what makes plain :find complete the same set of paths.

local M = {}

local picker = require("picker")
local win_pick = require("win_pick")

local ignore_patterns = {
	"node_modules",
	".venv",
	"%.git",
	"%.cache",
	"dist",
	"build",
	"%.tmp",
	"%.log",
}

local function ignored(path)
	for _, pat in ipairs(ignore_patterns) do
		if path:match(pat) then
			return true
		end
	end
	return false
end

-- Every file below the current directory, cheapest way first. git knows the
-- answer already and knows it without walking .gitignore'd trees, which on any
-- real repository is the difference between instant and several seconds; the
-- glob is the fallback for directories git has never heard of.
local function scan()
	if vim.fn.isdirectory(".git") == 1 and vim.fn.executable("git") == 1 then
		local out = vim.fn.systemlist({
			"git",
			-- otherwise anything non-ASCII comes back octal-escaped and quoted,
			-- which is a path that cannot be opened
			"-c",
			"core.quotePath=false",
			"ls-files",
			"--cached", -- tracked
			"--others", -- and untracked, minus
			"--exclude-standard", -- whatever .gitignore rules out
		})
		if vim.v.shell_error == 0 then
			-- --cached still lists files deleted from the worktree
			return vim.tbl_filter(function(f)
				return f ~= "" and vim.fn.filereadable(f) == 1
			end, out)
		end
	end

	local out = {}
	for _, f in ipairs(vim.fn.glob("**/*", true, true)) do
		if vim.fn.isdirectory(f) == 0 and not ignored(f) then
			out[#out + 1] = f
		end
	end
	return out
end

function _G.native_find(text, _)
	return vim.fn.matchfuzzy(scan(), text)
end

--------------------------------------------------------------------------- --
-- opening
--------------------------------------------------------------------------- --

local function set_hl()
	vim.api.nvim_set_hl(0, "FindPath", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "FindDir", { link = "Comment", default = true })
end

-- The whole path on one line, with the directory part dimmed so the file name
-- reads first. Matching still runs over the whole thing, which is the point of
-- listing paths rather than names.
local function columns(path)
	local col = { text = path, hl = "FindPath" }
	local slash = path:match("^.*()/")
	if slash then
		col.spans = { { 0, slash, "FindDir" } }
	end
	return { col }
end

local function edit(win, path)
	if win then
		vim.api.nvim_set_current_win(win)
	else
		-- nothing but the sidebar on screen, so make somewhere to put it
		require("netrw_sidebar").new_editing_split("vsplit")
	end
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

-- Where <s-cr> puts the file: the window <leader>f was pressed in, else the one
-- before that, else any other ordinary window. win_pick.targets() never returns
-- a netrw window, so pressing <leader>f in the sidebar opens into the editing
-- area instead of replacing the tree.
local function default_win(from, previous)
	local wins = win_pick.targets()
	for _, win in ipairs({ from, previous }) do
		if vim.tbl_contains(wins, win) then
			return win
		end
	end
	return wins[1] -- nil when the sidebar is the only window
end

function M.show()
	-- captured before the float takes focus, since it displaces both
	local from = vim.api.nvim_get_current_win()
	local previous = vim.fn.win_getid(vim.fn.winnr("#"))

	local files = scan()
	if #files == 0 then
		vim.notify("find: no files under " .. vim.fn.getcwd(), vim.log.levels.WARN)
		return
	end

	picker.open({
		title = "Files",
		items = files,
		columns = columns,
		search = function(path)
			return path
		end,
		fuzzy = true,
		footer = " <CR> pick window   <S-CR> open here   <Esc> close ",
		actions = {
			["<CR>"] = function(path)
				local wins = win_pick.targets()
				if #wins < 2 then
					return edit(wins[1], path)
				end
				local chosen = win_pick.select(from, wins, default_win(from, previous))
				if chosen then
					edit(chosen, path)
				end
			end,
			["<S-CR>"] = function(path)
				edit(default_win(from, previous), path)
			end,
		},
	})
end

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

vim.opt.findfunc = "v:lua.native_find"
vim.keymap.set("n", "<leader>f", M.show, {
	silent = true,
	desc = "Find a file: <CR> chooses a window, <S-CR> opens here",
})

return M
