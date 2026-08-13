-- <leader>p: read a markdown file as rendered text rather than as its source.
--
-- Not a preview in another window or another program: the same buffer, with the
-- markers stopped from being drawn. The cursor keeps its place, the file stays
-- editable, and the colours are the colorscheme's rather than some renderer's
-- idea of them.
--
-- Some of it comes free with 'conceallevel'. Neovim's own markdown queries
-- conceal the code fences and the language annotation, and markdown_inline's
-- conceal emphasis, inline backticks and link brackets. The rest is drawn here:
-- headings, list bullets, quote bars and tables.
--
-- Why here and not by extending the query, which is what it looks like the
-- query language is for. The parser is not consistent about the space after a
-- marker: an atx_hN_marker stops at the last #, while a list marker node runs
-- to the end of the space following it. So concealing the node whole is wrong
-- in a different direction for each, one leaving a stray column and the other
-- closing the gap up into "•item". The query answer is #offset!, which is
-- exactly what Neovim's own bullet conceals use, and they ship commented out
-- (queries/markdown/highlights.scm, "issues with spaces in the list marker
-- nodes"). It cannot work: the directive records metadata[capture].offset and
-- nothing in the treesitter runtime ever reads it back. An extmark takes the
-- range it is handed, so it is the mechanism that can say this at all.
--
-- Tables need more than concealing anyway. Hiding text can only ever make a
-- cell narrower, and aligning a column means making the short ones wider, so
-- they are drawn with inline virtual text as well. What paragraphs do is still
-- not rewrapping: 'linebreak' only stops a wrap falling mid-word.

local M = {}

local ns = vim.api.nvim_create_namespace("markdown_render")
local group = vim.api.nvim_create_augroup("MarkdownRender", { clear = true })

-- Which lines have been taken out of the display, per buffer, so the cursor can
-- step over them. A concealed line is not on the screen anywhere, so a cursor
-- sitting on one is a cursor you cannot see: j through a four row table is four
-- presses that look like nothing happened, and then one that jumps. A rendered
-- table is one thing to read, so it is made one thing to move over.
local spans = {}

local BULLET, QUOTE = "•", "│"
local BAR, CROSS, TEE_LEFT, TEE_RIGHT, DASH = "│", "┼", "├", "┤", "─"

-- Set on the window, so they are restored to whatever they were rather than to
-- a default: a user with conceallevel already up should not lose it on toggle.
local WINDOW = {
	conceallevel = 2,
	concealcursor = "nc", -- but not in insert or visual: editing a line shows its source
	wrap = true,
	linebreak = true,
}

--------------------------------------------------------------------------- --
-- heading levels
--------------------------------------------------------------------------- --

-- Once the # markers are hidden, nothing tells an h1 from an h3: a colorscheme
-- typically defines @markup.heading and leaves the six numbered groups to fall
-- back to it, so every level is drawn identically. catppuccin links the lot to
-- Title. A terminal cannot make a heading bigger, so the level has to be
-- carried by weight and colour instead.
--
-- Both ends are taken from the colorscheme rather than written down here, so
-- this follows whatever it is set to: the heading colour it already chose, and
-- Comment, which is by definition the colour that theme uses for "recede". The
-- levels are steps from one to the other.

local function channels(colour)
	return math.floor(colour / 65536) % 256, math.floor(colour / 256) % 256, colour % 256
end

local function mix(from, to, amount)
	local fr, fg, fb = channels(from)
	local tr, tg, tb = channels(to)
	local at = function(a, b)
		return math.floor(a + (b - a) * amount + 0.5)
	end
	return at(fr, tr) * 65536 + at(fg, tg) * 256 + at(fb, tb)
end

local function set_hl()
	local heading = vim.api.nvim_get_hl(0, { name = "@markup.heading", link = false })
	local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
	if not heading.fg then
		return
	end
	for level = 1, 6 do
		-- Colour alone cannot carry six steps: a theme's heading and comment
		-- colours can be close together, and in catppuccin they are, so six even
		-- steps between them are indistinguishable. The weight does the coarse
		-- half of the work and the colour the fine half. h1 and h2 both keep the
		-- full heading colour and are told apart by the underline, which leaves
		-- the whole of the range to separate h3 from h6 where nothing else is
		-- left to vary.
		local amount = 0
		if comment.fg and level > 2 then
			amount = ((level - 2) / 4) * 0.85 -- never quite Comment: an h6 is still a heading
		end
		vim.api.nvim_set_hl(0, "@markup.heading." .. level, {
			fg = amount > 0 and mix(heading.fg, comment.fg, amount) or heading.fg,
			bold = level <= 3,
			italic = level >= 4,
			underline = level == 1, -- the title, and there is only ever one
		})
	end
end

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

--------------------------------------------------------------------------- --
-- markers
--------------------------------------------------------------------------- --

local markers = nil

local function query()
	if not markers then
		markers = vim.treesitter.query.parse(
			"markdown",
			[[
			[ (atx_h1_marker) (atx_h2_marker) (atx_h3_marker)
			  (atx_h4_marker) (atx_h5_marker) (atx_h6_marker) ] @heading
			[ (list_marker_minus) (list_marker_plus) (list_marker_star) ] @bullet
			(block_quote_marker) @quote
			(pipe_table) @table
			]]
		)
	end
	return markers
end

--------------------------------------------------------------------------- --
-- measuring
--------------------------------------------------------------------------- --

-- A column is only as wide as its cells *look*, and a cell holding `code` or
-- **bold** looks narrower than it is written. Neovim's own queries are what
-- hide those markers, so the widths have to be measured against them: this
-- collects every conceal they ask for, by line.
local function hidden(buf, parser)
	local by_row = {}
	parser:for_each_tree(function(tree, ltree)
		local q = vim.treesitter.query.get(ltree:lang(), "highlights")
		if not q then
			return
		end
		for _, node, meta in q:iter_captures(tree:root(), buf) do
			if meta.conceal ~= nil then
				local row, from, end_row, to = node:range()
				if row == end_row then
					by_row[row] = by_row[row] or {}
					table.insert(by_row[row], { from = from, to = to, text = meta.conceal })
				end
			end
		end
	end)
	return by_row
end

--- How wide line[from..to) will look once those conceals have been drawn.
local function shown_width(line, from, to, conceals)
	local width = vim.fn.strdisplaywidth(line:sub(from + 1, to))
	for _, c in ipairs(conceals or {}) do
		if c.from >= from and c.to <= to then
			width = width - vim.fn.strdisplaywidth(line:sub(c.from + 1, c.to)) + vim.fn.strdisplaywidth(c.text)
		end
	end
	return width
end

--------------------------------------------------------------------------- --
-- tables
--------------------------------------------------------------------------- --

local ROWS = {
	pipe_table_header = true,
	pipe_table_row = true,
	pipe_table_delimiter_row = true,
}

--- The columns a line actually has to be drawn in: the window's width less
--- whatever the number column and the sign column have taken off the front.
local function text_width(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			local info = vim.fn.getwininfo(win)[1]
			return vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
		end
	end
	return vim.o.columns
end

--- The pipes and the cells of one row. Taking the pipes from the tree rather
--- than searching the line for them is what makes the whole span between two of
--- them ours to draw, so how the source happened to be padded stops mattering,
--- and an escaped \| inside a cell is not read as the end of one.
local function parts(row)
	local pipes, cells = {}, {}
	for child in row:iter_children() do
		local kind = child:type()
		local _, from, _, to = child:range()
		if kind == "|" then
			pipes[#pipes + 1] = { from = from, to = to }
		elseif kind == "pipe_table_cell" or kind == "pipe_table_delimiter_cell" then
			cells[#cells + 1] = { node = child, from = from, to = to }
		end
	end
	return pipes, cells
end

--- :--- is left, ---: is right, :---: is both, which is centre.
local function alignment(cell)
	local left, right = false, false
	for child in cell.node:iter_children() do
		left = left or child:type() == "pipe_table_align_left"
		right = right or child:type() == "pipe_table_align_right"
	end
	if left and right then
		return "centre"
	end
	return right and "right" or "left"
end

--- A cell as it will read once the conceals inside it are drawn, trimmed of the
--- padding the source happened to carry. `code` becomes code here, which is
--- both what has to be measured and, when a cell has to be wrapped, what has to
--- be laid out.
local function displayed(line, from, to, conceals)
	local inside = {}
	for _, c in ipairs(conceals or {}) do
		if c.from >= from and c.to <= to then
			inside[#inside + 1] = c
		end
	end
	table.sort(inside, function(a, b)
		return a.from < b.from
	end)
	local out, at = {}, from
	for _, c in ipairs(inside) do
		if c.from >= at then
			out[#out + 1] = line:sub(at + 1, c.from)
			out[#out + 1] = c.text
			at = c.to
		end
	end
	out[#out + 1] = line:sub(at + 1, to)
	return (table.concat(out):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function width_of(text)
	return vim.fn.strdisplaywidth(text)
end

--- Break `text` into pieces no wider than `width`, at spaces where there is
--- one. A word with no break in it wider than the column is cut, since the
--- alternative is a row that silently runs past the edge again.
local function wrapped(text, width)
	local lines, line = {}, ""
	local function flush()
		if line ~= "" then
			lines[#lines + 1] = line
			line = ""
		end
	end
	for word in text:gmatch("%S+") do
		local try = line == "" and word or (line .. " " .. word)
		if width_of(try) <= width then
			line = try
		else
			flush()
			while width_of(word) > width do
				local cut, taken = "", 0
				for _, ch in ipairs(vim.fn.split(word, "\\zs")) do
					if taken + width_of(ch) > width then
						break
					end
					cut, taken = cut .. ch, taken + width_of(ch)
				end
				if cut == "" then
					break
				end
				lines[#lines + 1] = cut
				word = word:sub(#cut + 1)
			end
			line = word
		end
	end
	flush()
	if #lines == 0 then
		lines[1] = ""
	end
	return lines
end

--- Column widths that add up to something that fits. The widest column gives up
--- a column at a time, so a table of one long prose column and several short
--- ones loses width where there is width to lose, rather than everywhere.
local function fitted(natural, budget)
	local width, total = {}, 0
	for i, w in ipairs(natural) do
		width[i], total = w, total + w
	end
	local FLOOR = 6
	while total > budget do
		local widest, at = 0, nil
		for i, w in ipairs(width) do
			if w > widest and w > FLOOR then
				widest, at = w, i
			end
		end
		if not at then
			return width, false -- nothing left to give: too narrow for a table
		end
		width[at], total = width[at] - 1, total - 1
	end
	return width, true
end

local function padded(text, width, align)
	local slack = math.max(0, width - width_of(text))
	if align == "right" then
		return (" "):rep(slack) .. text
	end
	if align == "centre" then
		local before = math.floor(slack / 2)
		return (" "):rep(before) .. text .. (" "):rep(slack - before)
	end
	return text .. (" "):rep(slack)
end

-- A table is drawn as virtual lines, with its source rows removed from the
-- display entirely, and the reason is a property of conceal worth knowing:
-- concealing text hides the characters but does not give back the columns they
-- occupied. The line still wraps where it would have wrapped. So the obvious
-- shape for this, conceal the source and draw the replacement over it, cannot
-- work for any row long enough to need reflowing, which is every row this is
-- for. `conceal_lines` is the one that takes the line out of the display
-- altogether, and virtual lines are then the only thing left to draw into.
--
-- Virtual lines attached to a concealed line are concealed with it, so they
-- hang off the line before the table instead, or the one after it if the table
-- starts the file. A table with neither is left as it was written.
local function decorate_table(buf, node, lines, conceals, room)
	local rows, columns = {}, 0
	for child in node:iter_children() do
		if ROWS[child:type()] then
			local _, cells = parts(child)
			rows[#rows + 1] = { row = (child:range()), kind = child:type(), cells = cells }
			columns = math.max(columns, #cells)
		end
	end
	if columns == 0 or #rows == 0 then
		return
	end

	local first, last = rows[1].row, rows[#rows].row
	local anchor, above
	if first > 0 then
		anchor, above = first - 1, false
	elseif last + 1 < #lines then
		anchor, above = last + 1, true
	else
		return -- nowhere to hang the drawing, so leave the markdown alone
	end

	-- what each cell says, and how wide it would like to be
	local natural, align, text = {}, {}, {}
	for r, row in ipairs(rows) do
		text[r] = {}
		if row.kind == "pipe_table_delimiter_row" then
			for c, cell in ipairs(row.cells) do
				align[c] = alignment(cell)
			end
		else
			local line = lines[row.row + 1] or ""
			for c, cell in ipairs(row.cells) do
				local shown = displayed(line, cell.from, cell.to, conceals[row.row])
				text[r][c] = shown
				natural[c] = math.max(natural[c] or 0, width_of(shown))
			end
		end
	end
	for c = 1, columns do
		natural[c] = natural[c] or 0
	end

	-- the pipes and the space either side of every cell are the fixed cost
	local budget = room - (columns + 1) - 2 * columns
	if budget < columns then
		return -- no window this narrow is going to hold a table
	end
	local width, ok = fitted(natural, budget)
	if not ok then
		return
	end

	local EDGE = "@punctuation.special"
	local drawn = {}

	for r, row in ipairs(rows) do
		if row.kind == "pipe_table_delimiter_row" then
			local chunks = { { TEE_LEFT, EDGE } }
			for i = 1, columns do
				chunks[#chunks + 1] = { DASH:rep(width[i] + 2), EDGE }
				chunks[#chunks + 1] = { i == columns and TEE_RIGHT or CROSS, EDGE }
			end
			drawn[#drawn + 1] = chunks
		else
			local pieces, height = {}, 1
			for i = 1, columns do
				pieces[i] = wrapped(text[r][i] or "", width[i])
				height = math.max(height, #pieces[i])
			end
			for line = 1, height do
				local chunks = { { BAR, EDGE } }
				for i = 1, columns do
					chunks[#chunks + 1] = { " " .. padded(pieces[i][line] or "", width[i], align[i]) .. " " }
					chunks[#chunks + 1] = { BAR, EDGE }
				end
				drawn[#drawn + 1] = chunks
			end
		end
	end

	for _, row in ipairs(rows) do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, row.row, 0, { conceal_lines = "" })
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, anchor, 0, {
		virt_lines = drawn,
		virt_lines_above = above,
	})
	spans[buf] = spans[buf] or {}
	table.insert(spans[buf], { first + 1, last + 1 }) -- 1-based, as the cursor is
end

--------------------------------------------------------------------------- --
-- drawing
--------------------------------------------------------------------------- --

local function decorate(buf)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	spans[buf] = {}

	local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
	if not ok or not parser then
		return
	end
	-- with the injections, since what markdown_inline conceals inside a cell is
	-- part of how wide that cell comes out
	local trees = parser:parse(true)
	if not trees or not trees[1] then
		return
	end

	local conceals = hidden(buf, parser)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local room = text_width(buf)
	local q = query()

	for id, node in q:iter_captures(trees[1]:root(), buf) do
		local name = q.captures[id]
		if name == "table" then
			decorate_table(buf, node, lines, conceals, room)
		else
			local row, from, end_row, to = node:range()
			-- a marker is always within one line; anything else is a parse we do
			-- not understand and would rather leave alone than draw over
			if row == end_row then
				local length = #(lines[row + 1] or "")
				local finish, text
				if name == "heading" then
					-- the marker and the space after it, so the text sits at the margin
					finish, text = math.min(to + 1, length), ""
				else
					-- only the marker character. The space the node also covers is what
					-- keeps the text where it was, and a marker alone on its line has
					-- no space to leave.
					finish, text = math.min(from + 1, length), name == "bullet" and BULLET or QUOTE
				end
				if finish > from then
					vim.api.nvim_buf_set_extmark(buf, ns, row, from, { end_col = finish, conceal = text })
				end
			end
		end
	end
end

--------------------------------------------------------------------------- --
-- toggling
--------------------------------------------------------------------------- --

function M.rendered(buf)
	return vim.b[buf or vim.api.nvim_get_current_buf()].markdown_rendered == true
end

--- Put the cursor back on a line that is actually drawn, carrying on the way it
--- was already going. Landing on one of these from a search or a jump has no
--- direction to carry, so it comes out below, and only above when there is no
--- below to come out of.
local function step_over(buf, win)
	if vim.api.nvim_get_mode().mode:match("[vV\22]") then
		return -- a selection being extended is not ours to move
	end
	local line = vim.api.nvim_win_get_cursor(win)[1]
	local previous = vim.w[win].markdown_line or line
	for _, span in ipairs(spans[buf] or {}) do
		if line >= span[1] and line <= span[2] then
			local count = vim.api.nvim_buf_line_count(buf)
			local target = line < previous and span[1] - 1 or span[2] + 1
			if target < 1 or target > count then
				target = line < previous and span[2] + 1 or span[1] - 1
			end
			if target >= 1 and target <= count then
				pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
				line = target
			end
			break
		end
	end
	vim.w[win].markdown_line = line
end

vim.api.nvim_create_autocmd("CursorMoved", {
	group = group,
	callback = function(ev)
		if M.rendered(ev.buf) then
			step_over(ev.buf, vim.api.nvim_get_current_win())
		end
	end,
})

function M.toggle()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()

	if M.rendered(buf) then
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		vim.b[buf].markdown_rendered = nil
		for opt, value in pairs(vim.w[win].markdown_view or {}) do
			vim.wo[win][opt] = value
		end
		vim.w[win].markdown_view = nil
		return
	end

	local saved = {}
	for opt, value in pairs(WINDOW) do
		saved[opt] = vim.wo[win][opt]
		vim.wo[win][opt] = value
	end
	vim.w[win].markdown_view = saved
	vim.b[buf].markdown_rendered = true
	decorate(buf)
end

-- The markers move as the text does, so while it is on the buffer is redrawn
-- after an edit. Only while it is on: this costs a query over the tree, and
-- there is no reason to pay it for every markdown buffer ever opened.
vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
	group = group,
	callback = function(ev)
		if M.rendered(ev.buf) then
			decorate(ev.buf)
		end
	end,
})

-- A table is laid out to the width it has, so the width changing is a reason to
-- lay it out again: resized narrower, a column that fitted now has to wrap.
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
	group = group,
	callback = function()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local buf = vim.api.nvim_win_get_buf(win)
			if M.rendered(buf) then
				decorate(buf)
			end
		end
	end,
})

vim.api.nvim_create_autocmd("FileType", {
	group = group,
	pattern = "markdown",
	callback = function(ev)
		vim.keymap.set("n", "<leader>p", M.toggle, {
			buffer = ev.buf,
			silent = true,
			desc = "Toggle rendered markdown",
		})
	end,
})

return M
