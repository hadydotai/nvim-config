-- A modal, filterable list: a floating list with a prompt underneath it.
--
-- Type to narrow, <C-n>/<C-p> to move, <Esc> to close, and whatever else the
-- caller binds through `actions` to act on the highlighted row. Callers hand
-- over their items plus a function turning one into columns; widths are
-- measured once over the whole list so the table does not reflow while you
-- type, and the query is highlighted wherever it matched.
--
-- <leader>h (lua/keys.lua) and <leader>f (lua/find.lua) are both this.

local M = {}

local ns = vim.api.nvim_create_namespace("picker")
local view = nil
local hl_group

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "PickerMatch", { link = "Search", default = true })
	hl(0, "PickerSelected", { link = "CursorLine", default = true })
	hl(0, "PickerPrompt", { link = "Special", default = true })
	hl(0, "PickerEmpty", { link = "Comment", default = true })
end

--------------------------------------------------------------------------- --
-- filtering
--------------------------------------------------------------------------- --

-- Tokens are AND-ed and matched with smart case, so `<leader>d` and `<leader>D`
-- stay tellable apart while a lowercase query still matches anything.
local function tokens(query)
	local out = {}
	for word in query:gmatch("%S+") do
		out[#out + 1] = { text = word, exact = word:lower() ~= word }
	end
	return out
end

local function matches(it, toks)
	for _, tok in ipairs(toks) do
		local hay = tok.exact and it.hay or it.hay_lower
		local needle = tok.exact and tok.text or tok.text:lower()
		if not hay:find(needle, 1, true) then
			return false
		end
	end
	return true
end

local function by_tokens(items, query)
	local toks, out = tokens(query), {}
	for _, it in ipairs(items) do
		if matches(it, toks) then
			out[#out + 1] = { item = it }
		end
	end
	return out, toks
end

-- matchfuzzypos ranks and reports which characters it matched, which is what
-- makes the highlighting below possible. It is fed a list of dictionaries so
-- each result carries its index back, and returns them best-first.
local function by_fuzzy(items, query)
	local hays = {}
	for i, it in ipairs(items) do
		hays[i] = { hay = it.hay, i = i }
	end
	local res = vim.fn.matchfuzzypos(hays, query, { key = "hay", matchseq = true })
	local out = {}
	for k, entry in ipairs(res[1]) do
		out[k] = { item = items[entry.i], pos = res[2][k] }
	end
	return out, {}
end

--------------------------------------------------------------------------- --
-- layout
--------------------------------------------------------------------------- --

local function fit(text, width, right)
	local w = vim.fn.strdisplaywidth(text)
	if w > width then
		text = vim.fn.strcharpart(text, 0, math.max(0, width - 3)) .. "..."
		w = vim.fn.strdisplaywidth(text)
	end
	local pad = string.rep(" ", math.max(0, width - w))
	return right and (pad .. text) or (text .. pad)
end

local MAX_WIDTH = 120

-- Measure every column over every item. A column that comes out empty for all
-- of them is dropped rather than left as a stripe of blanks, and the flexible
-- column then takes whatever room is left over.
local function layout(items, opts, footer)
	local width, keep = {}, {}
	for _, it in ipairs(items) do
		for i, c in ipairs(it.cols) do
			width[i] = math.max(width[i] or (opts.min and opts.min[i]) or 0, vim.fn.strdisplaywidth(c.text))
		end
	end
	for i = 1, #width do
		if opts.max and opts.max[i] then
			width[i] = math.min(width[i], opts.max[i])
		end
		if width[i] > 0 then
			keep[#keep + 1] = i
		end
	end

	local flex = opts.flex or keep[#keep]
	local room = math.min(vim.o.columns - 8, MAX_WIDTH)
	local fixed = 2 * math.max(0, #keep - 1)
	for _, i in ipairs(keep) do
		if i ~= flex then
			fixed = fixed + width[i]
		end
	end
	local min_flex = (opts.min and opts.min[flex]) or 1
	width[flex] = math.max(min_flex, math.min(width[flex] or 0, room - fixed))

	-- A list that is re-asked for on every keystroke cannot be measured ahead:
	-- what comes back next is nothing like what was measured. Take all the room
	-- there is, once, so the float never resizes under the cursor.
	if opts.query then
		width[flex] = math.max(min_flex, room - fixed)
	end

	-- Never narrower than the chrome. The title and footer are part of the UI,
	-- and a list of short rows would otherwise clip them off the border.
	local chrome = math.max(
		vim.fn.strdisplaywidth(footer),
		vim.fn.strdisplaywidth(opts.title) + 10 -- room for the " (12/340) " count
	)
	if fixed + width[flex] < chrome then
		width[flex] = math.min(chrome, room) - fixed
	end

	return { width = width, keep = keep, flex = flex, total = fixed + width[flex] }
end

local function render(it, lay)
	local line, spans = "", {}
	for _, i in ipairs(lay.keep) do
		if #line > 0 then
			line = line .. "  "
		end
		local c, start = it.cols[i], #line
		line = line .. fit(c.text, lay.width[i], c.right)
		if c.hl then
			spans[#spans + 1] = { start, #line, c.hl }
		end
		-- sub-ranges inside one field, e.g. the directory part of a path
		for _, s in ipairs(c.spans or {}) do
			spans[#spans + 1] = { start + s[1], math.min(start + s[2], #line), s[3] }
		end
	end
	return line, spans
end

--------------------------------------------------------------------------- --
-- drawing
--------------------------------------------------------------------------- --

-- Where `hay` sits inside the rendered line, so fuzzy match positions (which
-- are indices into the haystack) can be drawn on top of the columns.
local function match_spans(line, row)
	local spans = {}
	if not row.pos then
		return spans
	end
	local at = line:find(row.item.hay, 1, true)
	if not at then
		return spans
	end
	for _, p in ipairs(row.pos) do
		local from = vim.fn.byteidx(row.item.hay, p)
		local to = vim.fn.byteidx(row.item.hay, p + 1)
		if from >= 0 then
			to = to < 0 and #row.item.hay or to
			spans[#spans + 1] = { at - 1 + from, at - 1 + to, "PickerMatch" }
		end
	end
	return spans
end

local function token_spans(line, toks)
	local spans = {}
	for _, tok in ipairs(toks) do
		local hay = tok.exact and line or line:lower()
		local needle = tok.exact and tok.text or tok.text:lower()
		local from = 1
		while true do
			local s, e = hay:find(needle, from, true)
			if not s then
				break
			end
			spans[#spans + 1] = { s - 1, e, "PickerMatch" }
			from = e + 1
		end
	end
	return spans
end

local function draw()
	local v = view
	if not v then
		return
	end
	local buf, lines, all = v.list_buf, {}, {}

	if #v.shown == 0 then
		lines[1] = "  no matches"
		all[1] = { { 0, #lines[1], "PickerEmpty" } }
	else
		for i, row in ipairs(v.shown) do
			local line, spans = render(row.item, v.lay)
			lines[i] = line
			vim.list_extend(spans, v.toks and #v.toks > 0 and token_spans(line, v.toks) or match_spans(line, row))
			all[i] = spans
		end
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	for i, spans in ipairs(all) do
		if i == v.index then
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "PickerSelected" })
		end
		for _, span in ipairs(spans) do
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, span[1], { end_col = span[2], hl_group = span[3] })
		end
	end

	if not vim.api.nvim_win_is_valid(v.list_win) then
		return
	end
	if v.index > 0 then
		pcall(vim.api.nvim_win_set_cursor, v.list_win, { v.index, 0 })
	end

	local shown, total = #v.shown, #v.items
	local cfg = vim.api.nvim_win_get_config(v.list_win)
	cfg.title = shown == total and string.format(" %s (%d) ", v.title, total)
		or string.format(" %s (%d/%d) ", v.title, shown, total)
	vim.api.nvim_win_set_config(v.list_win, cfg)
end

--- Turn caller values into rows: columns rendered once, haystack computed once.
local function prepare(values, opts)
	local items = {}
	for i, value in ipairs(values) do
		local cols = opts.columns(value)
		local hay = opts.search and opts.search(value)
		if not hay then
			local parts = {}
			for _, c in ipairs(cols) do
				parts[#parts + 1] = c.text
			end
			hay = table.concat(parts, " ")
		end
		items[i] = { value = value, cols = cols, hay = hay, hay_lower = hay:lower() }
	end
	return items
end

-- Everything, in the order it arrived. `toks` is only for highlighting here:
-- the list has already been narrowed by whoever produced it.
local function show_all(v, toks)
	v.shown, v.toks = {}, toks or {}
	for i, it in ipairs(v.items) do
		v.shown[i] = { item = it }
	end
	v.index = #v.shown > 0 and 1 or 0
	draw()
end

local DEBOUNCE = 120 -- ms of quiet before a query goes out

-- Ask the caller's query function again and swap the whole list for the answer.
-- Replies can land out of order, so a generation counter drops any that a later
-- keystroke has already superseded.
local function refetch(v, text)
	v.generation = v.generation + 1
	local gen = v.generation
	v.opts.query(text, function(values)
		if view ~= v or gen ~= v.generation then
			return
		end
		v.items = prepare(values or {}, v.opts)
		show_all(v, tokens(text))
	end)
end

local function filter()
	local v = view
	if not v then
		return
	end
	local query = vim.api.nvim_buf_get_lines(v.prompt_buf, 0, 1, false)[1] or ""

	-- With a query function the matching belongs to whoever answers it. A
	-- language server matches its own way, and narrowing its reply again here
	-- would only throw away rows it meant to return.
	if v.opts.query then
		v.pending = v.pending + 1
		local seq = v.pending
		vim.defer_fn(function()
			if view == v and v.pending == seq then
				refetch(v, query)
			end
		end, DEBOUNCE)
		return
	end

	if query:match("^%s*$") then
		v.shown, v.toks = {}, {}
		for i, it in ipairs(v.items) do
			v.shown[i] = { item = it }
		end
	elseif v.fuzzy then
		v.shown, v.toks = by_fuzzy(v.items, query)
	else
		v.shown, v.toks = by_tokens(v.items, query)
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

--------------------------------------------------------------------------- --
-- window
--------------------------------------------------------------------------- --

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

--- Open the list. `opts`:
---   title    text in the border, followed by a live match count
---   items    array of anything; whatever `columns` and `search` understand
---   columns  function(item) -> { { text, hl, right, spans }, ... }
---   search   function(item) -> the string the query is matched against
---   min      minimum width per column; a column that stays 0 is dropped
---   max      maximum width per column, for one that could be arbitrarily long
---   flex     which column absorbs the leftover width (default: the last one)
---   fuzzy    match with matchfuzzypos instead of AND-ed substrings
---   footer   right-aligned hint text
---   actions  map of lhs to function(item); the list closes before it runs
---   commands map of lhs to function(); like actions but about the list rather
---            than a row in it, so it fires with nothing highlighted too
---   query    function(text, done); when given, typing re-asks it for the whole
---            list instead of narrowing `items`, which stay the first answer
function M.open(opts)
	if view then
		return
	end
	if not hl_group then
		hl_group = vim.api.nvim_create_augroup("PickerHighlight", { clear = true })
		vim.api.nvim_create_autocmd("ColorScheme", { group = hl_group, callback = set_hl })
	end
	set_hl()

	local items = prepare(opts.items, opts)
	if #items == 0 then
		vim.notify("picker: nothing to show", vim.log.levels.WARN)
		return
	end

	local from = vim.api.nvim_get_current_win()
	local footer = opts.footer or " <C-n>/<C-p> move   <Esc> close "
	local lay = layout(items, opts, footer)
	-- 5 rows of chrome (two borders plus the prompt line) and a little margin,
	-- so a list that fits is shown whole rather than capped at some fraction
	local room = math.max(3, vim.o.lines - 5 - 4)
	local height = math.max(1, math.min(#items, room))

	local row = math.max(0, math.floor((vim.o.lines - (height + 5)) / 2))
	local left = math.max(0, math.floor((vim.o.columns - lay.total) / 2))

	local list_buf, prompt_buf = scratch(), scratch()
	local list_win = vim.api.nvim_open_win(list_buf, false, {
		relative = "editor",
		row = row,
		col = left,
		width = lay.total,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. opts.title .. " ",
		title_pos = "left",
		footer = footer,
		footer_pos = "right",
		noautocmd = true,
		zindex = 200,
	})
	local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
		relative = "editor",
		row = row + height + 2,
		col = left,
		width = lay.total,
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
		virt_text = { { "> ", "PickerPrompt" } },
		virt_text_pos = "inline",
		right_gravity = false,
	})

	view = {
		title = opts.title,
		items = items,
		shown = {},
		toks = {},
		fuzzy = opts.fuzzy,
		opts = opts,
		generation = 0, -- replies older than this one are stale
		pending = 0, -- keystrokes waiting out the debounce
		index = 1,
		lay = lay,
		list_buf = list_buf,
		list_win = list_win,
		prompt_buf = prompt_buf,
		prompt_win = prompt_win,
		from = from,
		group = vim.api.nvim_create_augroup("PickerView", { clear = true }),
	}

	-- Mapped through keys.untracked: these live and die with this buffer, so
	-- they are implementation detail rather than part of the key surface
	-- <leader>h is meant to describe.
	local map = function(modes, lhs, fn)
		require("keys").untracked(modes, lhs, fn, { buffer = prompt_buf, nowait = true, silent = true })
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
	for _, lhs in ipairs({ "<Esc>", "<C-c>" }) do
		map({ "i", "n" }, lhs, close)
	end
	map("n", "q", close)

	for lhs, run in pairs(opts.actions or {}) do
		map({ "i", "n" }, lhs, function()
			local v = view
			local chosen = v and v.shown[v.index] and v.shown[v.index].item.value
			close()
			if chosen then
				-- after the floats are gone and insert mode is off, so the action
				-- is free to open windows or read keys of its own
				vim.schedule(function()
					run(chosen)
				end)
			end
		end)
	end
	if not (opts.actions and opts.actions["<CR>"]) then
		map({ "i", "n" }, "<CR>", close)
	end

	-- About the list rather than a row in it, so unlike an action these fire
	-- with nothing highlighted: the reason to reach for one is frequently that
	-- what you were looking for is not here.
	for lhs, run in pairs(opts.commands or {}) do
		map({ "i", "n" }, lhs, function()
			close()
			vim.schedule(run)
		end)
	end

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

	if opts.query then
		show_all(view, {}) -- opts.items is already the answer to the empty query
	else
		filter()
	end
	vim.cmd("startinsert")
end

return M
