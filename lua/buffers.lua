-- <leader>b: a modal, filterable list of the buffers that are open.
--
--   type     narrow the list, fuzzily, against the whole relative path
--   <cr>     outline a target window, hjkl to move, <cr> to open there
--   <s-cr>   open in the window you came from, never the netrw sidebar
--
-- The same keys as <leader>f and netrw's <cr>, through the same overlay, so a
-- buffer lands exactly where a file would have.

local M = {}

local picker = require("picker")
local win_pick = require("win_pick")

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "BufferNumber", { link = "Number", default = true })
	hl(0, "BufferFlags", { link = "Special", default = true })
	hl(0, "BufferPath", { link = "Normal", default = true })
	hl(0, "BufferDir", { link = "Comment", default = true })
	hl(0, "BufferNoName", { link = "Comment", default = true })
end

-- What to call the buffer in the list. Relative to the working directory where
-- that says anything, and terminals cut down to the command they are running:
-- their real name is a term:// URL with a pid and an absolute path to the shell
-- in it, which is a lot of line for one word of information.
local function label(buf, name)
	if vim.bo[buf].buftype == "terminal" then
		return "term://" .. vim.fn.fnamemodify(name:match(":([^:]*)$") or name, ":t")
	end
	if name == "" then
		return "[No Name]"
	end
	return vim.fn.fnamemodify(name, ":~:.")
end

-- Everything :ls would show, most recently used first, except that the buffer
-- you are in goes last: it is already on screen, so the row worth landing on by
-- default is the one you were in before it. 'lastused' only has one-second
-- resolution, hence the buffer number as a tiebreak.
local function buffers()
	local current = vim.api.nvim_get_current_buf()
	local out = {}
	for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
		out[#out + 1] = {
			bufnr = info.bufnr,
			name = label(info.bufnr, info.name),
			named = info.name ~= "",
			modified = info.changed == 1,
			current = info.bufnr == current,
			alternate = info.bufnr == vim.fn.bufnr("#"),
			lastused = info.lastused,
		}
	end
	table.sort(out, function(a, b)
		if a.current ~= b.current then
			return b.current
		end
		if a.lastused ~= b.lastused then
			return a.lastused > b.lastused
		end
		return a.bufnr < b.bufnr
	end)
	return out
end

-- number, markers, path. % and # are the ones :ls uses for the current and
-- alternate buffer, + for unsaved changes.
local function columns(item)
	local flags = (item.current and "%" or item.alternate and "#" or "") .. (item.modified and "+" or "")
	local path = { text = item.name, hl = item.named and "BufferPath" or "BufferNoName" }
	local slash = item.named and item.name:match("^.*()/")
	if slash then
		path.spans = { { 0, slash, "BufferDir" } }
	end
	return {
		{ text = tostring(item.bufnr), hl = "BufferNumber", right = true },
		{ text = flags, hl = "BufferFlags" },
		path,
	}
end

function M.show()
	local items = buffers()
	if #items == 0 then
		vim.notify("buffers: nothing is open", vim.log.levels.WARN)
		return
	end

	picker.open({
		title = "Buffers",
		items = items,
		columns = columns,
		search = function(item)
			return item.name
		end,
		fuzzy = true,
		min = { 2, 0, 11 }, -- no markers anywhere means no marker column
		footer = win_pick.FOOTER,
		open = function(win, item)
			if not vim.api.nvim_buf_is_valid(item.bufnr) then
				return -- wiped out from under us while the list was open
			end
			win_pick.focus(win)
			vim.cmd("buffer " .. item.bufnr)
		end,
	})
end

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

vim.keymap.set("n", "<leader>b", M.show, {
	silent = true,
	desc = "List buffers: <CR> chooses a window, <S-CR> opens here",
})

return M
