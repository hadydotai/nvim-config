-- What you see when nvim is opened with nothing to open.
--
-- Neovim's own intro screen is a donation appeal and a list of help topics for
-- an editor you have already configured. This replaces it with the name of the
-- place, where you are, and the handful of keys worth having in front of you
-- on the way in.
--
-- The legend is the real mappings rather than a menu of its own. A start screen
-- that invents single letter shortcuts teaches you keys that stop working the
-- moment you open a file, so this one presses nothing: every key drawn below
-- works here because it works everywhere, and reading it is practice.
--
-- It is shown only when nvim was given nothing else to do, and it is wiped the
-- moment the window holding it shows anything at all, so it never has to be
-- dismissed.

local M = {}

--------------------------------------------------------------------------- --
-- the drawing
--------------------------------------------------------------------------- --

local ART = {
	"██╗  ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗    ██╗      █████╗ ██████╗ ",
	"██║  ██║██╔══██╗██╔══██╗╚██╗ ██╔╝╚═╝██╔════╝    ██║     ██╔══██╗██╔══██╗",
	"███████║███████║██║  ██║ ╚████╔╝    ███████╗    ██║     ███████║██████╔╝",
	"██╔══██║██╔══██║██║  ██║  ╚██╔╝     ╚════██║    ██║     ██╔══██║██╔══██╗",
	"██║  ██║██║  ██║██████╔╝   ██║      ███████║    ███████╗██║  ██║██████╔╝",
	"╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝    ╚═╝      ╚══════╝    ╚══════╝╚═╝  ╚═╝╚═════╝ ",
}

-- For a window too narrow to hold the block letters. Drawn small rather than
-- drawn wrapped: six rows of a broken banner say less than one line of type.
local SMALL = {
	"H A D Y ' S   L A B",
}

-- Ten, in one list, laid out as two columns when there is room and one when
-- there is not. The order is the split: the first half is the editor and the
-- second half is the agents, so the two columns each mean something rather
-- than being the same list cut in half.
local MENU = {
	{ "<leader>f", "find a file" },
	{ "<leader>g", "grep the project" },
	{ "<leader>e", "the file tree" },
	{ "<leader>b", "the buffer list" },
	{ "<leader>s", "symbols in this file" },
	{ "<leader>aa", "start an agent" },
	{ "<leader>ad", "the agent dashboard" },
	{ "<leader>ar", "read what changed" },
	{ "<leader>h", "every mapping" },
	{ "<leader>H", "the guide" },
}

local function set_hl()
	local set = function(name, spec)
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
	end
	-- The face of the letters and the shadow behind them, so the block reads as
	-- lit from one side rather than as a solid slab.
	set("StartLogo", { link = "Function" })
	set("StartLogoShade", { link = "NonText" })
	set("StartKey", { link = "Special" })
	set("StartText", { link = "Normal" })
	set("StartDim", { link = "Comment" })
end

--- Where the solid parts of a line of the banner are, so they can be coloured
--- apart from the shadow. Walked by codepoint because every character in it is
--- three bytes, and a column is a byte offset.
local function faces(text, offset)
	local spans, from, kind = {}, nil, nil
	local starts = vim.str_utf_pos(text)
	for i, at in ipairs(starts) do
		local stop = (starts[i + 1] or #text + 1) - 1
		local char = text:sub(at, stop)
		local hl = char == "█" and "StartLogo" or (char ~= " " and "StartLogoShade" or nil)
		if hl ~= kind then
			if from then
				spans[#spans + 1] = { offset + from, offset + at - 1, kind }
			end
			from, kind = hl and (at - 1) or nil, hl
		end
	end
	if from then
		spans[#spans + 1] = { offset + from, offset + #text, kind }
	end
	return spans
end

--- One indent for a whole block, taken from its widest line, so the block
--- stays a block. Centring each line on its own would make a ragged legend of
--- a square one.
local function indent(width, block)
	local widest = 0
	for _, line in ipairs(block) do
		widest = math.max(widest, vim.fn.strdisplaywidth(line))
	end
	return math.max(0, math.floor((width - widest) / 2))
end

--- One legend row, and the columns to colour in it. Takes a key and a meaning,
--- or two of each. Everything here is ASCII, so a byte is a column and the
--- padding can be counted rather than measured.
local function legend(row, pad)
	local text, spans = string.rep(" ", pad), {}
	local put = function(part, hl, room)
		local at = #text
		text = text .. part
		spans[#spans + 1] = { at, #text, hl }
		if room then
			text = text .. string.rep(" ", math.max(1, room - #part))
		end
	end
	for i = 1, #row, 2 do
		put(row[i], "StartKey", 13)
		-- the last meaning on the line is not padded, so the row measures what
		-- it actually occupies and the block can be centred on that
		put(row[i + 1], "StartText", i + 1 < #row and 22 or nil)
	end
	return text, spans
end

--- The legend, in two columns where they fit and one where they do not. Tried
--- rather than predicted: the widths are in here, and asking the layout how
--- wide it came out cannot disagree with itself.
local function legend_rows(width)
	local half = math.floor(#MENU / 2)
	local rows, widest = {}, 0
	for i = 1, half do
		rows[i] = { MENU[i][1], MENU[i][2], MENU[i + half][1], MENU[i + half][2] }
		widest = math.max(widest, #(legend(rows[i], 0)))
	end
	if widest + 4 <= width then
		return rows
	end
	rows = {}
	for i, item in ipairs(MENU) do
		rows[i] = { item[1], item[2] }
	end
	return rows
end

--- Everything to draw, and where the colour goes. Separated from putting it in
--- the buffer so a resize is the same call with a different width.
local function compose(width, height)
	local lines, marks = {}, {}
	local function add(text, spans)
		lines[#lines + 1] = text
		for _, span in ipairs(spans or {}) do
			marks[#marks + 1] = { #lines - 1, span[1], span[2], span[3] }
		end
	end
	local function blank(n)
		for _ = 1, n do
			add("")
		end
	end

	local art = width >= vim.fn.strdisplaywidth(ART[1]) + 4 and ART or SMALL
	local pad = indent(width, art)

	local body = {}
	local function later(text, spans)
		body[#body + 1] = { text, spans }
	end

	for _, line in ipairs(art) do
		later(string.rep(" ", pad) .. line, faces(line, pad))
	end

	local where = { vim.fn.fnamemodify(vim.fn.getcwd(), ":~") }
	local at = indent(width, where)
	later("", nil)
	later(string.rep(" ", at) .. where[1], { { at, at + #where[1], "StartDim" } })

	local rows = legend_rows(width)
	local drawn = {}
	for i, row in ipairs(rows) do
		drawn[i] = (legend(row, 0))
	end
	local menu_pad = indent(width, drawn)
	later("", nil)
	later("", nil)
	for _, row in ipairs(rows) do
		later(legend(row, menu_pad))
	end

	local version = vim.version()
	local nvim = ("nvim %d.%d.%d"):format(version.major, version.minor, version.patch)
	local long = nvim .. "      :Deps for what it needs      :q to leave"
	local foot = { #long + 4 <= width and long or nvim }
	local foot_pad = indent(width, foot)
	later("", nil)
	later("", nil)
	later(string.rep(" ", foot_pad) .. foot[1], { { foot_pad, foot_pad + #foot[1], "StartDim" } })

	-- Slightly above the middle rather than in it. A block centred exactly sits
	-- low, because the eye puts the centre of a page above its middle.
	blank(math.max(0, math.floor((height - #body) / 2) - 1))
	for _, entry in ipairs(body) do
		add(entry[1], entry[2])
	end
	return lines, marks
end

--------------------------------------------------------------------------- --
-- the buffer
--------------------------------------------------------------------------- --

local ns = vim.api.nvim_create_namespace("start")
local buf = nil

local function draw()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return
	end

	local lines, marks = compose(vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win))
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, mark in ipairs(marks) do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark[1], mark[2], {
			end_col = mark[3],
			hl_group = mark[4],
		})
	end
	pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

--- Whether there is anything to replace. Every condition here is a way of
--- being asked to do something other than sit there: a file on the command
--- line, text arriving on stdin, a session being restored, a window somebody
--- has already split. Getting this wrong is worse than having no start screen
--- at all, since it would land on top of the thing you asked for.
local function eligible()
	if #vim.api.nvim_list_uis() == 0 then
		return false -- headless, and nobody is looking
	end
	if vim.fn.argc(-1) > 0 or vim.g.start_stdin or vim.g.SessionLoad then
		return false
	end
	if #vim.api.nvim_list_wins() > 1 or #vim.api.nvim_list_tabpages() > 1 then
		return false
	end
	local into = vim.api.nvim_get_current_buf()
	if vim.api.nvim_buf_get_name(into) ~= "" then
		return false
	end
	if vim.bo[into].buftype ~= "" or vim.bo[into].filetype ~= "" or vim.bo[into].modified then
		return false
	end
	return vim.api.nvim_buf_line_count(into) == 1 and vim.api.nvim_buf_get_lines(into, 0, 1, false)[1] == ""
end

function M.show()
	set_hl()
	local win = vim.api.nvim_get_current_win()
	local before = vim.api.nvim_get_current_buf()

	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	-- Wiped rather than hidden, which is what makes this need no dismissing:
	-- opening anything in this window is the end of it, and there is no stale
	-- copy left behind to come back to.
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "start"
	pcall(vim.api.nvim_buf_set_name, buf, "nvim://start")

	vim.api.nvim_win_set_buf(win, buf)
	if before ~= buf and vim.api.nvim_buf_is_valid(before) then
		pcall(vim.api.nvim_buf_delete, before, { force = true })
	end

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = false
	vim.wo[win].list = false
	vim.wo[win].wrap = false
	-- The tildes down the left are a file's end, and this is not a file.
	vim.wo[win].fillchars = "eob: "

	draw()
end

vim.api.nvim_create_autocmd("StdinReadPre", {
	group = vim.api.nvim_create_augroup("StartScreen", { clear = true }),
	callback = function()
		vim.g.start_stdin = true
	end,
})

vim.api.nvim_create_autocmd("VimEnter", {
	group = "StartScreen",
	callback = function()
		if eligible() then
			M.show()
		end
	end,
})

-- Laid out to the width it had, so a change of width is a reason to lay it out
-- again rather than leave the block sitting off to one side.
vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
	group = "StartScreen",
	callback = draw,
})

vim.api.nvim_create_autocmd("ColorScheme", { group = "StartScreen", callback = set_hl })

set_hl()

return M
