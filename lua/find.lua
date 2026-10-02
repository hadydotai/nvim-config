-- <leader>f: a modal, filterable list of the files in the repository.
--
-- The whole repository, from its top, wherever in it nvim was started or has
-- since :cd'd to; outside one, the current directory. The title says which:
-- "Files in ~/code/thing". <leader>g greps the same tree, through M.base().
--
--   type     narrow the list, fuzzily, against the whole relative path
--   <cr>     outline a target window, hjkl to move, <cr> to open there
--   <s-cr>   open in the window you came from, never the netrw sidebar
--   <c-.>    edit which .gitignore'd files this repository shows anyway
--
-- The same two-key split as netrw's <cr>/<s-cr> and <leader>b's, through the
-- same overlay, so wherever you pick a file from it lands the same way.
--
-- The listing is taken once when the dialog opens and filtered in memory
-- afterwards, so typing costs nothing. 'findfunc' is still set as well, which
-- is what makes plain :find complete the same set of paths.

local M = {}

local picker = require("picker")
local win_pick = require("win_pick")
local unignore = require("unignore")

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

--- The directory listed here and grepped by <leader>g: the repository's top,
--- or the current directory when there is no repository to ask.
---
--- unignore.root() is what answers it, defined once over there so the listing
--- and the exceptions to it can never disagree about which repository they
--- mean.
function M.base()
	return unignore.root() or vim.fn.getcwd()
end

-- Long enough for ~/code/org/project/package; anything deeper keeps its tail,
-- which is the part that tells two checkouts apart.
local WHERE_WIDTH = 40

--- M.base() for a title, home as ~ and the front cut off when it is long.
function M.where()
	local dir = vim.fn.fnamemodify(M.base(), ":~")
	if vim.fn.strchars(dir) > WHERE_WIDTH then
		dir = "..." .. vim.fn.strcharpart(dir, vim.fn.strchars(dir) - WHERE_WIDTH + 3)
	end
	return dir
end

-- Every file under M.base(), relative to it, cheapest way first. git knows the
-- answer already and knows it without walking .gitignore'd trees, which on any
-- real repository is the difference between instant and several seconds; the
-- glob is the fallback for directories git has never heard of.
local function scan()
	local root = unignore.root()
	if root then
		local out = vim.fn.systemlist({
			"git",
			-- from the top, so a subdirectory lists the whole repository and
			-- every path comes back relative to the top rather than to here
			"-C",
			root,
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
			local files = vim.tbl_filter(function(f)
				return f ~= "" and vim.fn.filereadable(vim.fs.joinpath(root, f)) == 1
			end, out)
			-- and back on the end, the ignored ones asked for by name
			vim.list_extend(files, unignore.files())
			return files
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

-- :find edits what it is given relative to the current directory, and the
-- listing is relative to the top, so the matches go back as paths from here:
-- relative under the current directory, whole outside it.
function _G.native_find(text, _)
	local base = M.base()
	return vim.tbl_map(function(f)
		return vim.fn.fnamemodify(vim.fs.joinpath(base, f), ":.")
	end, vim.fn.matchfuzzy(scan(), text))
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

-- Say so in the border when the list is not just what git would tell you, so a
-- node_modules that turns up in it reads as something you asked for rather than
-- as the filter having quietly broken. Capped, since the title sets a floor on
-- how wide the float has to be.
local function title()
	local name = "Files in " .. M.where()
	local patterns = unignore.text()
	if patterns == "" then
		return name
	end
	if #patterns > 30 then
		patterns = patterns:sub(1, 27) .. "..."
	end
	return name .. " +" .. patterns
end

local FOOTER = win_pick.FOOTER:gsub("%s+$", "") .. "   <C-.> unignore "

function M.show()
	local files = scan()
	if #files == 0 then
		vim.notify("find: no files under " .. M.base(), vim.log.levels.WARN)
		return
	end

	picker.open({
		title = title(),
		items = files,
		columns = columns,
		search = function(path)
			return path
		end,
		fuzzy = true,
		footer = FOOTER,
		-- reopened rather than refreshed in place: the listing is measured once
		-- when the dialog opens, and it has just changed underneath it
		commands = {
			["<C-.>"] = function()
				unignore.edit(M.show)
			end,
		},
		open = function(win, path)
			win_pick.focus(win)
			vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(M.base(), path)))
		end,
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
