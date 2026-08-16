-- A filterable list, as a modal float or as a panel in a split.
--
-- Type to narrow, <C-n>/<C-p> to move, <Esc> to close, and whatever else the
-- caller binds through `actions` to act on the highlighted row. Callers hand
-- over their items plus a function turning one into columns; widths are
-- measured once over the whole list so the table does not reflow while you
-- type, and the query is highlighted wherever it matched.
--
-- <C-o> projects the list into a window, and <C-o> there puts it back. A
-- projected list is the same list with a prompt of its own, but it stays while
-- you work: the reason to want one is an outline of the file you are editing
-- beside the file, rather than a list you dismiss to use what it told you. It
-- goes into a window you point at, or into a vertical split when there is only
-- one window to point at.
--
-- A picker that says how to rebuild itself (`source`) also follows: the panel
-- watches one window, relists when the buffer there changes or is edited, and
-- `r` points it at a different window. Pointing is the same overlay as opening
-- a file, in a different colour, since it is a different question.
--
-- <leader>h (lua/keys.lua) and <leader>f (lua/find.lua) are both this.

local M = {}

local ns = vim.api.nvim_create_namespace("picker")

--- The modal, while one is open. There is at most one: it takes focus, and a
--- second would have nowhere to put it.
local view = nil

local hl_group

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "PickerMatch", { link = "Search", default = true })
	hl(0, "PickerSelected", { link = "CursorLine", default = true })
	hl(0, "PickerPrompt", { link = "Special", default = true })
	hl(0, "PickerEmpty", { link = "Comment", default = true })
	hl(0, "PickerPanel", { link = "Title", default = true })
	hl(0, "PickerPanelMeta", { link = "Comment", default = true })
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
--
-- `room` is how wide the list may be: the screen for a float, the window for a
-- panel. `fill` takes all of it whether or not the rows need it, which is what
-- a panel wants (it is as wide as its window however little is in it) and what
-- a list re-asked for on every keystroke wants (what comes back next is
-- nothing like what was measured, so it must not resize under the cursor).
local function layout(items, opts, footer, room, fill)
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
	local fixed = 2 * math.max(0, #keep - 1)
	for _, i in ipairs(keep) do
		if i ~= flex then
			fixed = fixed + width[i]
		end
	end
	local min_flex = (opts.min and opts.min[flex]) or 1
	width[flex] = math.max(min_flex, math.min(width[flex] or 0, room - fixed))

	if fill or opts.query then
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

--- How wide this instance's list may be, and whether it takes all of it.
local function room_for(v)
	if v.kind == "panel" and vim.api.nvim_win_is_valid(v.list_win) then
		return vim.api.nvim_win_get_width(v.list_win), true
	end
	return math.min(vim.o.columns - 8, MAX_WIDTH), false
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

--- Only a list that follows a window has anything to re-point, so only one of
--- those says so. A file list is about the repository, not about whichever
--- window you happen to be looking at, and offering to aim it somewhere would
--- be offering something that does not mean anything.
local function panel_keys(v)
	if v.opts.source then
		return "%#PickerPanelMeta# <CR> open   <S-CR> elsewhere   r retarget   <C-o> detach   q close"
	end
	return "%#PickerPanelMeta# <CR> pick window   <S-CR> open here   <C-o> detach   q close"
end

--- The panel's winbar: what this list is, how much of it is showing, and what
--- it is pointed at. In the winbar rather than the buffer for the same reason
--- the dashboard puts it there: a legend on line one would put every row one
--- line further down than the list says it is.
local function winbar(v, count)
	local parts = { "%#PickerPanel# " .. v.title .. " " .. count }
	-- Which file this is about, for a list that is about one. A file list
	-- naming a buffer would be claiming a relationship it does not have.
	if v.opts.source and v.target_buf and vim.api.nvim_buf_is_valid(v.target_buf) then
		local name = vim.api.nvim_buf_get_name(v.target_buf)
		name = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
		parts[#parts + 1] = "%#PickerPanelMeta#  " .. name
	end
	parts[#parts + 1] = panel_keys(v)
	-- Statusline syntax, so a per cent in a file name is not a format item.
	return (table.concat(parts):gsub("%%(%a)", "%%%%%1"):gsub("%%$", "%%%%"))
end

local function draw(v)
	if not v or v.closed then
		return
	end
	local buf, lines, all = v.list_buf, {}, {}
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

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
		-- A panel has 'cursorline' and a cursor of its own to show which row is
		-- current, so painting a second selection over it would only disagree
		-- with it the moment you move.
		if i == v.index and v.kind ~= "panel" then
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
	local count = shown == total and string.format("(%d)", total) or string.format("(%d/%d)", shown, total)
	if v.kind == "panel" then
		vim.wo[v.list_win].winbar = winbar(v, count)
	else
		local cfg = vim.api.nvim_win_get_config(v.list_win)
		cfg.title = string.format(" %s %s ", v.title, count)
		vim.api.nvim_win_set_config(v.list_win, cfg)
	end
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

--- Re-measure and redraw, for when the room changed rather than the list:
--- a panel is as wide as its window, and its window can be resized.
local function relayout(v)
	if v.closed then
		return
	end
	local room, fill = room_for(v)
	v.lay = layout(v.items, v.opts, v.footer, room, fill)
	draw(v)
end

-- Everything, in the order it arrived. `toks` is only for highlighting here:
-- the list has already been narrowed by whoever produced it.
local function show_all(v, toks)
	v.shown, v.toks = {}, toks or {}
	for i, it in ipairs(v.items) do
		v.shown[i] = { item = it }
	end
	v.index = #v.shown > 0 and 1 or 0
	draw(v)
end

local DEBOUNCE = 120 -- ms of quiet before a query goes out

local function query_text(v)
	if not vim.api.nvim_buf_is_valid(v.prompt_buf) then
		return ""
	end
	return vim.api.nvim_buf_get_lines(v.prompt_buf, 0, 1, false)[1] or ""
end

-- Ask the caller's query function again and swap the whole list for the answer.
-- Replies can land out of order, so a generation counter drops any that a later
-- keystroke has already superseded.
local function refetch(v, text)
	v.generation = v.generation + 1
	local gen = v.generation
	v.opts.query(text, function(values)
		if v.closed or gen ~= v.generation then
			return
		end
		v.items = prepare(values or {}, v.opts)
		show_all(v, tokens(text))
	end)
end

local function filter(v)
	if not v or v.closed then
		return
	end
	local query = query_text(v)

	-- With a query function the matching belongs to whoever answers it. A
	-- language server matches its own way, and narrowing its reply again here
	-- would only throw away rows it meant to return.
	if v.opts.query then
		v.pending = v.pending + 1
		local seq = v.pending
		vim.defer_fn(function()
			if not v.closed and v.pending == seq then
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
	draw(v)
end

local function move(v, delta)
	if not v or v.closed or #v.shown == 0 then
		return
	end
	v.index = (v.index - 1 + delta) % #v.shown + 1 -- wrap at both ends
	draw(v)
end

local function chosen_value(v)
	local row = v.shown[v.index]
	return row and row.item.value or nil
end

--------------------------------------------------------------------------- --
-- following a window
--------------------------------------------------------------------------- --

--- Ordinary windows, minus this panel's own two. A panel must never point at
--- itself, and the prompt is not somewhere a file could be either.
local function elsewhere(v)
	local win_pick = require("win_pick")
	return win_pick.targets({ v.list_win, v.prompt_win })
end

--- Ask the caller for the list again, for whatever the panel is pointed at.
--- Only pickers that gave a `source` can do this; the rest keep what they were
--- projected with, which is still a list worth having in a window.
local function resource(v)
	if v.closed or not v.opts.source or not v.target_win then
		return
	end
	if not vim.api.nvim_win_is_valid(v.target_win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(v.target_win)
	v.target_buf = buf
	v.source_gen = v.source_gen + 1
	local gen = v.source_gen
	v.opts.source(v.target_win, buf, function(values)
		if v.closed or gen ~= v.source_gen then
			return -- pointed somewhere else since, so this answer is about the past
		end
		v.items = prepare(values or {}, v.opts)
		relayout(v)
		filter(v) -- the query survives a relist: it is what you were looking for
	end)
end

--- Relist after a pause. Typing in the followed buffer fires on every keystroke
--- and a language server has better things to do.
local function resource_soon(v)
	v.following = (v.following or 0) + 1
	local seq = v.following
	vim.defer_fn(function()
		if not v.closed and v.following == seq then
			resource(v)
		end
	end, 300)
end

--------------------------------------------------------------------------- --
-- windows
--------------------------------------------------------------------------- --

local function scratch(name)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	if name then
		pcall(vim.api.nvim_buf_set_name, buf, name)
	end
	return buf
end

--- Close the floats or the split pair without firing WinClosed and friends:
--- these are internal UI, and an unrelated autocmd erroring here would
--- propagate straight out of nvim_win_close.
local function close(v)
	if not v or v.closed then
		return
	end
	v.closed = true
	if view == v then
		view = nil
	end

	pcall(vim.api.nvim_del_augroup_by_id, v.group)
	if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end

	local keep = vim.o.eventignore
	vim.o.eventignore = "all"

	-- The prompt is always ours and always goes. The list window may not be:
	-- a panel offered an existing window takes it over rather than making one,
	-- and handing it back means putting the buffer that was there back into
	-- it. Closing it instead would leave you one window short of the layout
	-- you had before you looked at a list.
	if v.prompt_win and vim.api.nvim_win_is_valid(v.prompt_win) then
		pcall(vim.api.nvim_win_close, v.prompt_win, true)
	end
	local give_back = v.was_buf and vim.api.nvim_buf_is_valid(v.was_buf)
	if give_back and vim.api.nvim_win_is_valid(v.list_win) then
		pcall(vim.api.nvim_win_set_buf, v.list_win, v.was_buf)
	elseif v.list_win and vim.api.nvim_win_is_valid(v.list_win) then
		pcall(vim.api.nvim_win_close, v.list_win, true)
	end

	for _, buf in ipairs({ v.prompt_buf, v.list_buf }) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	vim.o.eventignore = keep

	local back = v.kind == "panel" and v.target_win or v.from
	if back and vim.api.nvim_win_is_valid(back) then
		pcall(vim.api.nvim_set_current_win, back)
	end
end

--- What a panel or modal knows about itself that outlives its windows, so the
--- other kind can be built from it. The query goes along: projecting a list you
--- have already narrowed should not throw the narrowing away.
local function snapshot(v)
	return {
		items = v.items,
		query = query_text(v),
		index = v.index,
		target_win = v.target_win,
		target_buf = v.target_buf,
	}
end

--------------------------------------------------------------------------- --
-- keys
--------------------------------------------------------------------------- --

local open_panel, detach

--- Where a row opens from a panel: the window it is pointed at, else anywhere
--- else, else nowhere, which callers take as "make a split".
local function target_or_any(v)
	if v.target_win and vim.api.nvim_win_is_valid(v.target_win) then
		return v.target_win
	end
	return elsewhere(v)[1]
end

--- Point the panel at a different window. Only reachable for a list that
--- follows one: the rest are not about a window, so there is nothing to aim.
local function retarget(v)
	local win_pick = require("win_pick")
	local wins = elsewhere(v)
	if #wins == 0 then
		vim.notify("picker: no other window to point at", vim.log.levels.WARN)
		return
	end
	local chosen = #wins == 1 and wins[1] or win_pick.select(v.list_win, wins, v.target_win, win_pick.LOOK.show)
	if not chosen then
		return
	end
	v.target_win = chosen
	resource(v)
end

--- Mappings for one instance. They live and die with its buffers, so they go
--- in through keys.untracked: implementation detail rather than part of the key
--- surface <leader>h is meant to describe.
local function bind(v)
	local keys = require("keys")
	local map = function(modes, lhs, fn, buf)
		keys.untracked(modes, lhs, fn, { buffer = buf or v.prompt_buf, nowait = true, silent = true })
	end
	--- On the prompt in both modes, and on the list too when there is one you
	--- can put the cursor in. For keys that cannot be typed into a query.
	local both = function(lhs, fn)
		map({ "i", "n" }, lhs, fn)
		if v.kind == "panel" then
			map("n", lhs, fn, v.list_buf)
		end
	end
	--- Normal mode only, on both halves. A letter in the prompt is the query
	--- being typed, and a panel that closed itself because you searched for
	--- "queue" would be a poor thing to have built.
	local plain = function(lhs, fn)
		map("n", lhs, fn)
		if v.kind == "panel" then
			map("n", lhs, fn, v.list_buf)
		end
	end

	for _, lhs in ipairs({ "<C-n>", "<C-j>", "<Down>" }) do
		map({ "i", "n" }, lhs, function()
			move(v, 1)
		end)
	end
	for _, lhs in ipairs({ "<C-p>", "<C-k>", "<Up>" }) do
		map({ "i", "n" }, lhs, function()
			move(v, -1)
		end)
	end
	map({ "i", "n" }, "<C-d>", function()
		move(v, math.floor(v.height / 2))
	end)
	map({ "i", "n" }, "<C-u>", function()
		move(v, -math.floor(v.height / 2))
	end)

	-- Whichever this is, <C-o> makes it the other one.
	both("<C-o>", function()
		if v.kind == "panel" then
			detach(v)
		else
			open_panel(v)
		end
	end)

	if v.kind == "panel" then
		if v.opts.source then
			plain("r", function()
				retarget(v)
			end)
		end
		plain("q", function()
			close(v)
		end)
		-- Esc steps out rather than closing: a panel is not modal, and the way
		-- out of a filter you are done with is the file you were reading.
		map({ "i", "n" }, "<Esc>", function()
			if vim.api.nvim_win_is_valid(v.list_win) then
				vim.cmd("stopinsert")
				vim.api.nvim_set_current_win(v.list_win)
			end
		end)
		map("n", "<Esc>", function()
			local back = target_or_any(v)
			if back then
				vim.api.nvim_set_current_win(back)
			end
		end, v.list_buf)
	else
		for _, lhs in ipairs({ "<Esc>", "<C-c>" }) do
			map({ "i", "n" }, lhs, function()
				close(v)
			end)
		end
		map("n", "q", function()
			close(v)
		end)
	end

	--- An action acts on the highlighted row. In the modal the list is in the
	--- way of whatever it is about to do, so it closes first; a panel is the
	--- point and stays.
	local action = function(lhs, run)
		both(lhs, function()
			local item = chosen_value(v)
			if not item then
				return
			end
			if v.kind == "panel" then
				vim.schedule(function()
					run(item)
				end)
				return
			end
			close(v)
			-- after the floats are gone and insert mode is off, so the action
			-- is free to open windows or read keys of its own
			vim.schedule(function()
				run(item)
			end)
		end)
	end

	-- Rows that open into a window. Which key means "ask" depends on whether
	-- the list is about a window: a symbol belongs to the file the panel is
	-- pointed at, so <CR> puts it back there without asking, while a file from
	-- a list of every file in the repository has no such home and <CR> asks
	-- the same way the float does.
	if v.opts.open then
		if v.kind == "panel" then
			local ask = function(item)
				local win_pick = require("win_pick")
				local wins = elsewhere(v)
				local chosen = #wins < 2 and wins[1] or win_pick.select(v.list_win, wins, target_or_any(v))
				if chosen then
					v.opts.open(chosen, item)
				end
			end
			local here = function(item)
				v.opts.open(target_or_any(v), item)
			end
			action("<CR>", v.opts.source and here or ask)
			action("<S-CR>", v.opts.source and ask or here)
		else
			for lhs, run in pairs(v.opening or {}) do
				action(lhs, run)
			end
		end
	end

	for lhs, run in pairs(v.opts.actions or {}) do
		action(lhs, run)
	end
	if not (v.opts.actions and v.opts.actions["<CR>"]) and not v.opts.open then
		if v.kind ~= "panel" then
			map({ "i", "n" }, "<CR>", function()
				close(v)
			end)
		end
	end

	-- About the list rather than a row in it, so unlike an action these fire
	-- with nothing highlighted: the reason to reach for one is frequently that
	-- what you were looking for is not here. They are handed everything on
	-- screen, which is what makes "send this list somewhere" expressible.
	for lhs, run in pairs(v.opts.commands or {}) do
		both(lhs, function()
			local shown = {}
			for i, row in ipairs(v.shown) do
				shown[i] = row.item.value
			end
			if v.kind ~= "panel" then
				close(v)
			end
			vim.schedule(function()
				run(shown)
			end)
		end)
	end
end

--------------------------------------------------------------------------- --
-- the modal
--------------------------------------------------------------------------- --

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
---   commands map of lhs to function(shown); like actions but about the list
---            rather than a row in it, so it fires with nothing highlighted
---            too, and is given every item currently on screen
---   query    function(text, done); when given, typing re-asks it for the whole
---            list instead of narrowing `items`, which stay the first answer
---   open     function(win, item); rows that open into a window. The modal
---            binds <CR>/<S-CR> through win_pick, and a panel opens into the
---            window it is pointed at. Prefer this to wiring win_pick.actions
---            into `actions`, which a panel cannot re-point
---   source   function(win, buf, done); how to rebuild the list for a window,
---            which is also what says this list is about one. A panel with it
---            follows that window, offers `r` to aim it at another, and opens
---            a row back into it on <CR>. A panel without it keeps the list it
---            was projected with, has no `r`, and asks with the overlay on
---            <CR>, since a list of every file in the repository has no window
---            it belongs to
function M.open(opts, seed)
	if view then
		return
	end
	if not hl_group then
		hl_group = vim.api.nvim_create_augroup("PickerHighlight", { clear = true })
		vim.api.nvim_create_autocmd("ColorScheme", { group = hl_group, callback = set_hl })
	end
	set_hl()

	local items = seed and seed.items or prepare(opts.items, opts)
	if #items == 0 then
		vim.notify("picker: nothing to show", vim.log.levels.WARN)
		return
	end

	local from = vim.api.nvim_get_current_win()
	-- Built before the floats exist, because it captures the window you are in
	-- and the one before that. A moment later the window you are in is the
	-- prompt, which is a float, which is nowhere to open a file: "open here"
	-- would then mean whichever window happened to be listed first.
	local opening = opts.open and require("win_pick").actions(opts.open) or nil
	local footer = opts.footer or " <C-n>/<C-p> move   <C-o> panel   <Esc> close "
	local lay = layout(items, opts, footer, math.min(vim.o.columns - 8, MAX_WIDTH), false)
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
		kind = "modal",
		title = opts.title,
		items = items,
		shown = {},
		toks = {},
		fuzzy = opts.fuzzy,
		opts = opts,
		footer = footer,
		generation = 0, -- replies older than this one are stale
		pending = 0, -- keystrokes waiting out the debounce
		source_gen = 0,
		index = 1,
		height = height,
		lay = lay,
		list_buf = list_buf,
		list_win = list_win,
		prompt_buf = prompt_buf,
		prompt_win = prompt_win,
		from = from,
		opening = opening,
		target_win = seed and seed.target_win or from,
		target_buf = seed and seed.target_buf or vim.api.nvim_win_get_buf(from),
		group = vim.api.nvim_create_augroup("PickerView", { clear = true }),
	}
	local v = view
	bind(v)

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		group = v.group,
		buffer = prompt_buf,
		callback = function()
			filter(v)
		end,
	})
	-- clicking or jumping away closes it, which is what makes it modal
	vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
		group = v.group,
		buffer = prompt_buf,
		callback = function()
			vim.schedule(function()
				close(v)
			end)
		end,
	})

	if seed and seed.query ~= "" then
		vim.api.nvim_buf_set_lines(prompt_buf, 0, 1, false, { seed.query })
	end
	if opts.query and not seed then
		show_all(v, {}) -- opts.items is already the answer to the empty query
	else
		filter(v)
	end
	vim.cmd("startinsert!")
end

--------------------------------------------------------------------------- --
-- the panel
--------------------------------------------------------------------------- --

--- Put a list in a window: the one you point at, or a new vertical split when
--- there is only one window and pointing at it would mean covering the thing
--- the list is about.
--- Returns the window and the buffer that was in it, which is nil when the
--- window was made for this and so is ours to close again.
local function place(from)
	local win_pick = require("win_pick")
	local wins = win_pick.targets()
	if #wins >= 2 then
		local chosen = win_pick.select(from, wins, from, win_pick.LOOK.panel)
		if not chosen then
			return nil
		end
		vim.api.nvim_set_current_win(chosen)
		return chosen, vim.api.nvim_win_get_buf(chosen)
	end
	-- To the right, where an outline goes, and without disturbing what the one
	-- window is showing.
	vim.cmd("belowright vsplit")
	return vim.api.nvim_get_current_win(), nil
end

--- Build a panel from what a modal was showing. Called after the modal has
--- closed, so the overlay has a screen to draw on and the windows it offers
--- are the real ones.
local function build(opts, seed, from)
	local list_win, was_buf = place(from)
	if not list_win then
		return
	end

	local list_buf = scratch("picker://" .. opts.title)
	vim.api.nvim_win_set_buf(list_win, list_buf)

	-- The prompt is a real window under the list rather than a float over it,
	-- so it moves and resizes with the panel and cannot end up somewhere the
	-- panel is not.
	vim.api.nvim_set_current_win(list_win)
	vim.cmd("belowright 1split")
	local prompt_win = vim.api.nvim_get_current_win()
	local prompt_buf = scratch()
	vim.api.nvim_win_set_buf(prompt_win, prompt_buf)
	vim.wo[prompt_win].winfixheight = true

	for _, win in ipairs({ list_win, prompt_win }) do
		vim.wo[win].wrap = false
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].foldcolumn = "0"
		vim.wo[win].list = false
	end
	vim.wo[list_win].cursorline = true
	vim.wo[list_win].scrolloff = 1
	vim.bo[list_buf].filetype = "picker"
	vim.bo[prompt_buf].filetype = "pickerprompt"

	vim.api.nvim_buf_set_extmark(prompt_buf, ns, 0, 0, {
		virt_text = { { "> ", "PickerPrompt" } },
		virt_text_pos = "inline",
		right_gravity = false,
	})

	local v = {
		kind = "panel",
		title = opts.title,
		items = seed.items,
		shown = {},
		toks = {},
		fuzzy = opts.fuzzy,
		opts = opts,
		footer = "",
		generation = 0,
		pending = 0,
		source_gen = 0,
		following = 0,
		index = seed.index or 1,
		height = math.max(1, vim.api.nvim_win_get_height(list_win)),
		list_buf = list_buf,
		list_win = list_win,
		prompt_buf = prompt_buf,
		prompt_win = prompt_win,
		was_buf = was_buf,
		group = vim.api.nvim_create_augroup("PickerPanel" .. list_win, { clear = true }),
	}

	-- What it points at. The window the list came from is the obvious answer,
	-- unless the panel has just taken that window over, in which case anywhere
	-- else showing the same buffer, and failing that any other window at all.
	local want = seed.target_win
	if not (want and vim.api.nvim_win_is_valid(want)) or want == list_win or want == prompt_win then
		want = nil
		for _, win in ipairs(elsewhere(v)) do
			if seed.target_buf and vim.api.nvim_win_get_buf(win) == seed.target_buf then
				want = win
				break
			end
			want = want or win
		end
	end
	v.target_win = want
	v.target_buf = want and vim.api.nvim_win_get_buf(want) or seed.target_buf

	bind(v)
	relayout(v)

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		group = v.group,
		buffer = prompt_buf,
		callback = function()
			filter(v)
		end,
	})
	-- Typing is what the prompt is for, so landing in it starts insert mode and
	-- leaving it ends it. Without this the prompt is a one-line buffer whose
	-- keys do vim things.
	vim.api.nvim_create_autocmd("WinEnter", {
		group = v.group,
		callback = function()
			if vim.api.nvim_get_current_win() == v.prompt_win then
				vim.cmd("startinsert!")
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinLeave", {
		group = v.group,
		callback = function()
			if vim.api.nvim_get_current_win() == v.prompt_win then
				vim.cmd("stopinsert")
			end
		end,
	})
	-- The cursor is the selection in a panel, so whatever moved it decides
	-- which row an action is about: <C-n> from the prompt, or j in the list.
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = v.group,
		buffer = list_buf,
		callback = function()
			if not v.closed and #v.shown > 0 then
				v.index = math.min(vim.api.nvim_win_get_cursor(v.list_win)[1], #v.shown)
			end
		end,
	})
	-- As wide as its window, whatever that becomes.
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = v.group,
		callback = function()
			if not v.closed and vim.api.nvim_win_is_valid(v.list_win) then
				v.height = math.max(1, vim.api.nvim_win_get_height(v.list_win))
				relayout(v)
			end
		end,
	})
	-- Either half closing takes the other with it: half a panel is a scratch
	-- buffer nobody asked for.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = v.group,
		callback = function(ev)
			local win = tonumber(ev.match)
			if win == v.list_win or win == v.prompt_win then
				vim.schedule(function()
					close(v)
				end)
			end
		end,
	})

	if v.opts.source then
		-- Follow the window it points at: a different buffer shown there, or
		-- an edit to the one already there, and the list is about to be wrong.
		vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "InsertLeave" }, {
			group = v.group,
			callback = function()
				if v.closed or not v.target_win or not vim.api.nvim_win_is_valid(v.target_win) then
					return
				end
				if vim.api.nvim_get_current_win() ~= v.target_win then
					return
				end
				resource_soon(v)
			end,
		})
	end

	if seed.query and seed.query ~= "" then
		vim.api.nvim_buf_set_lines(prompt_buf, 0, 1, false, { seed.query })
	end
	filter(v)
	if seed.index and seed.index > 0 and seed.index <= #v.shown then
		v.index = seed.index
		draw(v)
	end
	vim.api.nvim_set_current_win(v.prompt_win)
	vim.cmd("startinsert!")
end

--- Modal to panel. The modal goes first: the window overlay has to draw on the
--- screen the panel will live in, and the floats are in the way of it.
open_panel = function(v)
	local opts, seed = v.opts, snapshot(v)
	local from = v.from
	close(v)
	vim.schedule(function()
		build(opts, seed, from and vim.api.nvim_win_is_valid(from) and from or vim.api.nvim_get_current_win())
	end)
end

--- Panel back to modal, keeping the list and the query.
detach = function(v)
	local opts, seed = v.opts, snapshot(v)
	close(v)
	vim.schedule(function()
		M.open(opts, seed)
	end)
end

return M
