-- Files that .gitignore hides and you want back, per repository.
--
-- <leader>f lists what `git ls-files --exclude-standard` says, which is right
-- nearly always and wrong for the handful of ignored files you actually work
-- with: a generated client, a vendored directory, the .env you keep editing.
-- <C-.> in that dialog edits the list of exceptions for the repository you are
-- in, and it is remembered.
--
-- The patterns are git pathspecs, comma separated, so they mean on this prompt
-- what they would mean on a git command line rather than following a scheme
-- invented here. Two consequences worth knowing: a bare name matches at any
-- depth, and `*` on its own is therefore "show everything ignored".
--
-- Kept in .state/, keyed by the repository root, so nothing is written into the
-- project itself and nothing follows the config to another machine where the
-- paths would mean nothing.

local M = {}

local FILE = vim.fn.stdpath("state") .. "/unignore.json"

--- The repository the file list is taken from, or nil.
---
--- This is the same test find.lua makes before asking git for the listing at
--- all, and deliberately the same one rather than `rev-parse --show-toplevel`:
--- from a subdirectory git is not consulted, so nothing is being hidden and
--- there is correspondingly nothing to unhide. Defining it once is what stops
--- the two from ever disagreeing about which repository this is.
function M.root()
	if vim.fn.isdirectory(".git") == 0 or vim.fn.executable("git") == 0 then
		return nil
	end
	return vim.fn.getcwd()
end

local function split(text)
	local out = {}
	for pat in text:gmatch("[^,]+") do
		pat = vim.trim(pat)
		if pat ~= "" then
			out[#out + 1] = pat
		end
	end
	return out
end

--------------------------------------------------------------------------- --
-- storage
--------------------------------------------------------------------------- --

local store = nil -- the whole file, read once

local function load()
	if store then
		return store
	end
	store = {}
	local f = io.open(FILE, "r")
	if f then
		local text = f:read("*a")
		f:close()
		-- A file we cannot parse is treated as empty rather than as an error to
		-- report on every keystroke: the worst case is that ignored files stay
		-- hidden, which is what they would be without any of this.
		local ok, decoded = pcall(vim.json.decode, text)
		if ok and type(decoded) == "table" then
			store = decoded
		end
	end
	return store
end

--- The saved pattern text for this repository, "" when there is none.
function M.text()
	local root = M.root()
	return root and load()[root] or ""
end

function M.save(text)
	local root = M.root()
	if not root then
		return
	end
	local all = load()
	-- normalised on the way in: trimmed, empties dropped, so the text that comes
	-- back out is the text the prompt should show next time
	local patterns = table.concat(split(text), ",")
	all[root] = patterns ~= "" and patterns or nil

	local f = io.open(FILE, "w")
	if not f then
		vim.notify("unignore: cannot write " .. FILE, vim.log.levels.ERROR)
		return
	end
	f:write(vim.json.encode(all))
	f:close()
end

--------------------------------------------------------------------------- --
-- listing
--------------------------------------------------------------------------- --

--- The ignored files this repository's patterns ask for, to be added to the
--- listing find.lua already has. Empty and free when there are no patterns,
--- which is the usual case and matters because :find asks on every keystroke.
function M.files()
	local patterns = split(M.text())
	if #patterns == 0 then
		return {}
	end

	local cmd = {
		"git",
		"-c",
		"core.quotePath=false", -- as in find.lua: octal-escaped paths cannot be opened
		"ls-files",
		"--others", -- untracked, since a tracked file was never ignored
		"--ignored", -- and only the ignored ones, so this cannot repeat the main list
		"--exclude-standard",
		"--", -- everything after this is a path, never an option
	}
	vim.list_extend(cmd, patterns)

	local out = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("unignore: git rejected the patterns", vim.log.levels.WARN)
		return {}
	end
	-- git lists an ignored directory it will not descend into as one entry with
	-- a trailing slash, and a name it knows about may have gone from the disk.
	-- Neither can be opened, so neither belongs in a list of files to open.
	return vim.tbl_filter(function(f)
		return f ~= "" and vim.fn.filereadable(f) == 1
	end, out)
end

--------------------------------------------------------------------------- --
-- editing
--------------------------------------------------------------------------- --

--- Prompt for this repository's patterns, prefilled with what is saved, and
--- call `done` once something has been written.
function M.edit(done)
	if not M.root() then
		vim.notify("unignore: not at the root of a git repository", vim.log.levels.WARN)
		return
	end
	vim.ui.input({
		prompt = "unignore (comma separated git pathspecs): ",
		default = M.text(),
	}, function(text)
		if text == nil then
			return -- cancelled, so leave whatever was there alone
		end
		M.save(text)
		if done then
			done()
		end
	end)
end

return M
