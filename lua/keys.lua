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

-- The unwrapped originals, captured before setup() replaces them. The viewer
-- maps its own keys through these so its internals stay out of the list.
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

local ns = vim.api.nvim_create_namespace("keys_view")
local view = nil

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "KeysMode", { link = "Comment", default = true })
	hl(0, "KeysLhs", { link = "Special", default = true })
	hl(0, "KeysWhere", { link = "Type", default = true })
	hl(0, "KeysDesc", { link = "Normal", default = true })
	hl(0, "KeysMissing", { link = "Comment", default = true })
	hl(0, "KeysSource", { link = "NonText", default = true })
	hl(0, "KeysMatch", { link = "Search", default = true })
	hl(0, "KeysSelected", { link = "CursorLine", default = true })
	hl(0, "KeysPrompt", { link = "Special", default = true })
end

local function fit(text, width, right)
	local w = vim.fn.strdisplaywidth(text)
	if w > width then
		text = vim.fn.strcharpart(text, 0, math.max(0, width - 3)) .. "..."
		w = vim.fn.strdisplaywidth(text)
	end
	local pad = string.rep(" ", math.max(0, width - w))
	return right and (pad .. text) or (text .. pad)
end

-- Tokens are AND-ed and matched with smart case, so `<leader>d` and `<leader>D`
-- stay tellable apart while a lowercase query still matches anything.
local function tokens(query)
	local out = {}
	for word in query:gmatch("%S+") do
		out[#out + 1] = { text = word, exact = word:lower() ~= word }
	end
	return out
end

local function matches(item, toks)
	for _, tok in ipairs(toks) do
		local hay = tok.exact and item.hay or item.hay_lower
		local needle = tok.exact and tok.text or tok.text:lower()
		if not hay:find(needle, 1, true) then
			return false
		end
	end
	return true
end

local function prepare(items)
	local out = {}
	for _, rec in ipairs(items) do
		local source = rec.file and (rec.file .. ":" .. tostring(rec.line or 0)) or ""
		local it = {
			modes = table.concat(rec.modes, ","),
			lhs = rec.lhs,
			where = rec.where,
			desc = rec.desc or "(no description)",
			has_desc = rec.desc ~= nil,
			source = source,
		}
		it.hay = table.concat({ it.modes, it.lhs, it.where, it.desc, it.source }, " ")
		it.hay_lower = it.hay:lower()
		out[#out + 1] = it
	end
	return out
end

-- Column widths are measured once, over every item, so the table does not
-- reflow while you type.
local function layout(items)
	local col = { modes = 1, lhs = 3, where = 0, desc = 11, source = 6 }
	for _, it in ipairs(items) do
		col.modes = math.max(col.modes, #it.modes)
		col.lhs = math.max(col.lhs, #it.lhs)
		col.where = math.max(col.where, #it.where)
		col.desc = math.max(col.desc, #it.desc)
		col.source = math.max(col.source, #it.source)
	end

	local gaps = 2 * (col.where > 0 and 4 or 3)
	local fixed = col.modes + col.lhs + col.where + col.source + gaps
	local room = math.min(vim.o.columns - 8, 120)
	col.desc = math.max(11, math.min(col.desc, room - fixed))
	col.width = fixed + col.desc
	return col
end

local function render_line(it, col)
	local fields = {
		{ it.modes, col.modes, "KeysMode" },
		{ it.lhs, col.lhs, "KeysLhs" },
	}
	if col.where > 0 then
		fields[#fields + 1] = { it.where, col.where, "KeysWhere" }
	end
	fields[#fields + 1] = { it.desc, col.desc, it.has_desc and "KeysDesc" or "KeysMissing" }
	fields[#fields + 1] = { it.source, col.source, "KeysSource", true }

	local line, spans = "", {}
	for i, f in ipairs(fields) do
		if i > 1 then
			line = line .. "  "
		end
		local start = #line
		line = line .. fit(f[1], f[2], f[4])
		spans[#spans + 1] = { start, #line, f[3] }
	end
	return line, spans
end

local function draw()
	local v = view
	if not v then
		return
	end
	local buf, lines, all_spans = v.list_buf, {}, {}

	if #v.shown == 0 then
		lines[1] = "  no matches"
		all_spans[1] = { { 0, #lines[1], "KeysMissing" } }
	else
		for i, it in ipairs(v.shown) do
			lines[i], all_spans[i] = render_line(it, v.col)
		end
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	for i, spans in ipairs(all_spans) do
		if i == v.index then
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "KeysSelected" })
		end
		for _, span in ipairs(spans) do
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, span[1], {
				end_col = span[2],
				hl_group = span[3],
			})
		end
		-- highlight what the query actually matched, on top of the columns
		for _, tok in ipairs(v.toks) do
			local hay = tok.exact and lines[i] or lines[i]:lower()
			local needle = tok.exact and tok.text or tok.text:lower()
			local from = 1
			while true do
				local s, e = hay:find(needle, from, true)
				if not s then
					break
				end
				vim.api.nvim_buf_set_extmark(buf, ns, i - 1, s - 1, {
					end_col = e,
					hl_group = "KeysMatch",
				})
				from = e + 1
			end
		end
	end

	if v.index > 0 and vim.api.nvim_win_is_valid(v.list_win) then
		pcall(vim.api.nvim_win_set_cursor, v.list_win, { v.index, 0 })
	end

	if vim.api.nvim_win_is_valid(v.list_win) then
		local shown, total = #v.shown, #v.items
		local title = shown == total and string.format(" Keymaps (%d) ", total)
			or string.format(" Keymaps (%d/%d) ", shown, total)
		local cfg = vim.api.nvim_win_get_config(v.list_win)
		cfg.title = title
		vim.api.nvim_win_set_config(v.list_win, cfg)
	end
end

local function filter()
	local v = view
	if not v then
		return
	end
	local query = vim.api.nvim_buf_get_lines(v.prompt_buf, 0, 1, false)[1] or ""
	v.toks = tokens(query)
	v.shown = {}
	for _, it in ipairs(v.items) do
		if matches(it, v.toks) then
			v.shown[#v.shown + 1] = it
		end
	end
	v.index = #v.shown > 0 and 1 or 0
	draw()
end

local function move(delta)
	local v = view
	if not v or #v.shown == 0 then
		return
	end
	v.index = (v.index - 1 + delta) % #v.shown + 1 -- wrap at both ends
	draw()
end

local function close()
	local v = view
	if not v then
		return
	end
	view = nil

	pcall(vim.api.nvim_del_augroup_by_id, v.group)
	if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end

	-- Close the floats without firing WinClosed and friends: these are internal
	-- UI, and an unrelated autocmd erroring here would propagate straight out of
	-- nvim_win_close.
	local keep = vim.o.eventignore
	vim.o.eventignore = "all"
	for _, win in ipairs({ v.prompt_win, v.list_win }) do
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	for _, buf in ipairs({ v.prompt_buf, v.list_buf }) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	vim.o.eventignore = keep

	if v.from and vim.api.nvim_win_is_valid(v.from) then
		pcall(vim.api.nvim_set_current_win, v.from)
	end
end

local function scratch()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	return buf
end

--- <leader>h: open the mapping list.
function M.show()
	if view then
		return
	end

	local items = prepare(M.list())
	if #items == 0 then
		vim.notify("keys: nothing recorded, is keys.setup() running first?", vim.log.levels.WARN)
		return
	end

	local from = vim.api.nvim_get_current_win()
	local col = layout(items)
	-- 5 rows of chrome (two borders plus the prompt line) and a little margin,
	-- so a list that fits is shown whole rather than capped at some fraction
	local room = math.max(3, vim.o.lines - 5 - 4)
	local height = math.max(1, math.min(#items, room))

	local row = math.max(0, math.floor((vim.o.lines - (height + 5)) / 2))
	local left = math.max(0, math.floor((vim.o.columns - col.width) / 2))

	local list_buf, prompt_buf = scratch(), scratch()
	local list_win = vim.api.nvim_open_win(list_buf, false, {
		relative = "editor",
		row = row,
		col = left,
		width = col.width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Keymaps ",
		title_pos = "left",
		footer = " <C-n>/<C-p> move   <Esc> close ",
		footer_pos = "right",
		noautocmd = true,
		zindex = 200,
	})
	local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
		relative = "editor",
		row = row + height + 2,
		col = left,
		width = col.width,
		height = 1,
		style = "minimal",
		border = "rounded",
		noautocmd = true,
		zindex = 200,
	})

	for _, win in ipairs({ list_win, prompt_win }) do
		vim.wo[win].wrap = false
		vim.wo[win].winhighlight = "Normal:NormalFloat,NormalNC:NormalFloat"
	end
	vim.wo[list_win].scrolloff = 1

	vim.api.nvim_buf_set_extmark(prompt_buf, ns, 0, 0, {
		virt_text = { { "> ", "KeysPrompt" } },
		virt_text_pos = "inline",
		right_gravity = false,
	})

	view = {
		items = items,
		shown = items,
		toks = {},
		index = 1,
		col = col,
		list_buf = list_buf,
		list_win = list_win,
		prompt_buf = prompt_buf,
		prompt_win = prompt_win,
		from = from,
		group = vim.api.nvim_create_augroup("KeysView", { clear = true }),
	}

	local map = function(modes, lhs, fn)
		raw.set(modes, lhs, fn, { buffer = prompt_buf, nowait = true, silent = true })
	end
	for _, lhs in ipairs({ "<C-n>", "<C-j>", "<Down>" }) do
		map({ "i", "n" }, lhs, function()
			move(1)
		end)
	end
	for _, lhs in ipairs({ "<C-p>", "<C-k>", "<Up>" }) do
		map({ "i", "n" }, lhs, function()
			move(-1)
		end)
	end
	map({ "i", "n" }, "<C-d>", function()
		move(math.floor(height / 2))
	end)
	map({ "i", "n" }, "<C-u>", function()
		move(-math.floor(height / 2))
	end)
	for _, lhs in ipairs({ "<CR>", "<Esc>", "<C-c>" }) do
		map({ "i", "n" }, lhs, close)
	end
	map("n", "q", close)

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		group = view.group,
		buffer = prompt_buf,
		callback = filter,
	})
	-- clicking or jumping away closes it, which is what makes it modal
	vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
		group = view.group,
		buffer = prompt_buf,
		callback = function()
			vim.schedule(close)
		end,
	})

	draw()
	vim.cmd("startinsert")
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
