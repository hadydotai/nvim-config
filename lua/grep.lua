-- <leader>g: every line in the project matching what you type.
--
--   type     re-runs the search, debounced; the pattern goes to ripgrep
--   <cr>     outline a target window, hjkl to move, <cr> to open there
--   <s-cr>   open in the window you came from
--   <c-q>    put everything on screen in the quickfix list
--
-- The same dialog and the same two-key split as <leader>f, so a match lands
-- where a file does. It is the <leader>S shape rather than the <leader>f one:
-- the typing goes to ripgrep, not to the filter, since only ripgrep has read
-- the files. The list is replaced on every keystroke and picker.lua's
-- generation counter drops replies a later keystroke has already superseded.
--
-- The pattern is ripgrep's, which is to say a regular expression, with
-- --smart-case: lowercase matches anything, a capital makes it case sensitive.
-- Half-typed regular expressions are normal while typing, so the error that
-- comes back from an unclosed bracket is treated as "no matches yet" rather
-- than reported.

local M = {}

local picker = require("picker")
local win_pick = require("win_pick")

-- Enough to find what you are looking for, few enough that a search matching
-- most of the tree does not spend a second rendering. Said in the title when it
-- bites, rather than quietly showing a prefix of the answer.
local LIMIT = 1000

local running = nil

local function set_hl()
	vim.api.nvim_set_hl(0, "GrepWhere", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "GrepFile", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "GrepLine", { link = "Normal", default = true })
end

--- file:line, with the directory dimmed so the file name reads first, then the
--- matching line with its indentation trimmed off.
local function columns(hit)
	local where = hit.file .. ":" .. hit.lnum
	local col = { text = where, hl = "GrepFile" }
	local slash = hit.file:match("^.*()/")
	if slash then
		col.spans = { { 0, slash, "GrepWhere" } }
	end
	return { col, { text = hit.text, hl = "GrepLine" } }
end

local function parse(out)
	local hits, seen = {}, {}
	for line in out:gmatch("[^\n]+") do
		-- --vimgrep is file:line:col:text, and a path can contain a colon, so
		-- the file is the shortest prefix that leaves three fields behind it
		local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
		if file then
			-- One row per line, not per match. --vimgrep reports every match, so
			-- a line matching three times arrives three times, and since a row
			-- here is the line and where it is, those would be three rows that
			-- look identical. The column of the first match is kept, which is
			-- where the cursor lands.
			local where = file .. ":" .. lnum
			if not seen[where] then
				seen[where] = true
				hits[#hits + 1] = {
					file = file,
					lnum = tonumber(lnum),
					col = tonumber(col),
					text = vim.trim(text),
				}
				if #hits >= LIMIT then
					break
				end
			end
		end
	end
	return hits
end

--- Ask ripgrep, and hand the answer back on the main loop.
local function search(text, done)
	-- The reply this supersedes is not just ignored, it is stopped: typing a
	-- word is one search per keystroke, and a search of a large tree that
	-- nobody is waiting for any more is still reading the disk.
	if running then
		pcall(function()
			running:kill("sigterm")
		end)
		running = nil
	end
	if text:match("^%s*$") then
		return done({})
	end

	running = vim.system({
		"rg",
		"--vimgrep", -- file:line:col:text, one match per line
		"--smart-case",
		"--color=never",
		"--", -- a pattern starting with - is a pattern, not a flag
		text,
	}, { text = true }, function(out)
		running = nil
		-- 0 matched, 1 matched nothing, 2 and up is ripgrep complaining, which
		-- while typing usually means the regular expression is half written
		local hits = out.code > 1 and {} or parse(out.stdout or "")
		vim.schedule(function()
			done(hits)
		end)
	end)
end

local function to_quickfix(hits)
	if #hits == 0 then
		return
	end
	vim.fn.setqflist({}, " ", {
		title = "Grep",
		items = vim.tbl_map(function(hit)
			return { filename = hit.file, lnum = hit.lnum, col = hit.col, text = hit.text }
		end, hits),
	})
	vim.cmd("copen")
end

local FOOTER = win_pick.FOOTER:gsub("%s+$", "") .. "   <C-q> quickfix "

function M.show()
	if vim.fn.executable("rg") == 0 then
		vim.notify("grep: ripgrep is not installed, run :Deps install", vim.log.levels.WARN)
		return
	end

	-- The dialog needs something to open with, and the empty pattern has no
	-- answer, so it opens on the last thing it was asked. A first run has
	-- nothing, and the picker will not open on an empty list, so it starts on
	-- the word under the cursor, which is the search you were about to type.
	local seed = vim.fn.expand("<cword>")
	search(seed, function(hits)
		if #hits == 0 then
			hits = { { file = "", lnum = 0, col = 0, text = "type to search" } }
		end
		picker.open({
			title = "Grep",
			items = hits,
			columns = columns,
			max = { 60, 200 },
			flex = 2,
			footer = FOOTER,
			query = search,
			open = function(win, hit)
				if hit.file == "" then
					return
				end
				win_pick.focus(win)
				vim.cmd("edit " .. vim.fn.fnameescape(hit.file))
				pcall(vim.api.nvim_win_set_cursor, 0, { hit.lnum, math.max(0, hit.col - 1) })
				vim.cmd("normal! zz")
			end,
			commands = { ["<C-q>"] = to_quickfix },
		})
	end)
end

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

vim.keymap.set("n", "<leader>g", M.show, {
	silent = true,
	desc = "Grep the project: <CR> chooses a window, <C-q> to the quickfix list",
})

return M
