-- A modal, filterable list of every mapping this configuration installs.
--
-- The point is to see what *we* override, so the list is not built by scanning
-- :map, which is mostly Neovim's own defaults. Instead setup() wraps
-- vim.keymap.set and records each call whose caller lives under the config
-- directory, along with the file and line it came from. Mappings we cause but
-- do not install ourselves (netrw installs the g:Netrw_UserMaps entries on our
-- behalf) are registered with declare().
--
-- Two consequences worth knowing:
--   * keys.setup() has to run before anything that defines a mapping
--   * a mapping made with nvim_set_keymap or :nnoremap is not recorded

local M = {}

local CONFIG = vim.fn.stdpath("config")

-- The unwrapped originals, captured before setup() replaces them. Transient UI
-- goes through untracked() below so its own keys stay out of the list.
local raw = { set = vim.keymap.set, del = vim.keymap.del }

--------------------------------------------------------------------------- --
-- registry
--------------------------------------------------------------------------- --

local records = {}
local index_of = {}

-- Canonical spelling for the <> chunks of an lhs, so <c-w>s and <C-W>s do not
-- show up as two different-looking keys in the list.
local KEY_NAMES = {
	bs = "BS",
	cr = "CR",
	del = "Del",
	down = "Down",
	["end"] = "End",
	enter = "CR",
	esc = "Esc",
	home = "Home",
	insert = "Insert",
	left = "Left",
	nop = "Nop",
	pagedown = "PageDown",
	pageup = "PageUp",
	right = "Right",
	space = "Space",
	tab = "Tab",
	up = "Up",
}

local function normalise(lhs)
	return (lhs:gsub("<([^<>]+)>", function(inner)
		local mods, rest = "", inner
		while true do
			local mod, tail = rest:match("^([cCsSmMaAdD])%-(.*)$")
			if not mod or tail == "" then
				break
			end
			mods, rest = mods .. mod:upper() .. "-", tail
		end
		local named = KEY_NAMES[rest:lower()]
		if named then
			rest = named
		elseif rest:lower():match("^f%d+$") then
			rest = rest:upper()
		elseif mods:find("C%-") and #rest == 1 then
			-- Control takes no notice of case, so <c-r> and <C-R> are one key
			-- and have to be spelled one way, or deleting the mapping made
			-- under one spelling leaves the other in the list.
			rest = rest:upper()
		end
		return "<" .. mods .. rest .. ">"
	end))
end

local function modes_of(mode)
	if type(mode) == "table" then
		return vim.deepcopy(mode)
	end
	return { mode or "n" }
end

-- Where a mapping applies: "" for global, otherwise the kind of buffer it is
-- attached to, which is far more useful than a buffer number that will not
-- mean anything by the time you read the list.
local function scope(buffer)
	if not buffer then
		return ""
	end
	local buf = buffer == true and vim.api.nvim_get_current_buf() or buffer
	local ok, ft = pcall(function()
		return vim.bo[buf].filetype
	end)
	if ok and ft ~= "" then
		return ft
	end
	return "buffer " .. tostring(buf)
end

local function key_of(rec)
	return table.concat(rec.modes, ",") .. "\0" .. rec.lhs .. "\0" .. rec.where
end

local function add(rec)
	local key = key_of(rec)
	local at = index_of[key]
	if at then
		records[at] = rec -- redefining a key replaces it, keeping its position
		return
	end
	records[#records + 1] = rec
	index_of[key] = #records
end

--- The config file and line `level` frames above whoever called this, or nil
--- if that frame did not come from our own configuration. level 1 is the
--- calling function itself, 2 is the function that called it.
local function caller(level)
	local info = debug.getinfo(level + 1, "Sl")
	if not info or info.source:sub(1, 1) ~= "@" then
		return nil
	end
	local file = vim.fn.fnamemodify(info.source:sub(2), ":p")
	if file:sub(1, #CONFIG + 1) ~= CONFIG .. "/" then
		return nil
	end
	return file:sub(#CONFIG + 2), info.currentline
end

--- Register mappings that something else installs on our behalf.
--- Each entry is { lhs = ..., desc = ..., mode = "n", where = "netrw" }.
function M.declare(list)
	local file, line = caller(2)
	for _, item in ipairs(list) do
		add({
			modes = modes_of(item.mode),
			lhs = normalise(item.lhs),
			desc = item.desc,
			where = item.where or "",
			file = file,
			line = item.line or line,
		})
	end
end

--- vim.keymap.set without recording, for throwaway keys inside a transient UI
--- buffer. Those are implementation detail, not part of the key surface this
--- list is meant to describe.
function M.untracked(mode, lhs, rhs, opts)
	return raw.set(mode, lhs, rhs, opts)
end

--- Every recorded mapping, grouped global-first and then by defining file.
function M.list()
	local out = {}
	for _, rec in ipairs(records) do
		if not rec.deleted then
			out[#out + 1] = rec
		end
	end
	table.sort(out, function(a, b)
		if (a.where == "") ~= (b.where == "") then
			return a.where == ""
		end
		if a.where ~= b.where then
			return a.where < b.where
		end
		if a.file ~= b.file then
			return (a.file or "") < (b.file or "")
		end
		if a.line ~= b.line then
			return (a.line or 0) < (b.line or 0)
		end
		return a.lhs < b.lhs
	end)
	return out
end

--------------------------------------------------------------------------- --
-- viewer
--------------------------------------------------------------------------- --

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "KeysMode", { link = "Comment", default = true })
	hl(0, "KeysLhs", { link = "Special", default = true })
	hl(0, "KeysWhere", { link = "Type", default = true })
	hl(0, "KeysDesc", { link = "Normal", default = true })
	hl(0, "KeysMissing", { link = "Comment", default = true })
	hl(0, "KeysSource", { link = "NonText", default = true })
end

-- mode, key, where it applies, what it does, and where we set it. The `where`
-- column measures 0 wide when nothing is buffer-local, and the picker then
-- drops it rather than leaving a stripe of blanks.
local function columns(rec)
	local source = rec.file and (rec.file .. ":" .. tostring(rec.line or 0)) or ""
	return {
		{ text = table.concat(rec.modes, ","), hl = "KeysMode" },
		{ text = rec.lhs, hl = "KeysLhs" },
		{ text = rec.where, hl = "KeysWhere" },
		{ text = rec.desc or "(no description)", hl = rec.desc and "KeysDesc" or "KeysMissing" },
		{ text = source, hl = "KeysSource", right = true },
	}
end

--- <leader>h: open the mapping list.
function M.show()
	local items = M.list()
	if #items == 0 then
		vim.notify("keys: nothing recorded, is keys.setup() running first?", vim.log.levels.WARN)
		return
	end
	require("picker").open({
		title = "Keymaps",
		items = items,
		columns = columns,
		min = { 1, 3, 0, 11, 6 },
		flex = 4, -- the description gives up width before anything else does
	})
end

function M.setup()
	if M.installed then
		return
	end
	M.installed = true

	set_hl()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("KeysHighlight", { clear = true }),
		callback = set_hl,
	})

	vim.keymap.set = function(mode, lhs, rhs, opts)
		raw.set(mode, lhs, rhs, opts) -- let real errors surface before recording
		local file, line = caller(2)
		if not file then
			return
		end
		add({
			modes = modes_of(mode),
			lhs = normalise(lhs),
			desc = opts and opts.desc or nil,
			where = scope(opts and opts.buffer),
			file = file,
			line = line,
		})
	end

	vim.keymap.del = function(mode, lhs, opts)
		raw.del(mode, lhs, opts)
		local gone, where = normalise(lhs), scope(opts and opts.buffer)
		for _, rec in ipairs(records) do
			if rec.lhs == gone and rec.where == where then
				rec.deleted = true
			end
		end
	end
end

return M
