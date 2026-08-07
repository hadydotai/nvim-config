-- Auto-closing brackets and quotes.
--
--   ( [ {    insert the closing half and sit between them
--   ) ] }    step over a closer that is already there rather than doubling it
--   " ' `    both of the above, when the quote reads as opening a string rather
--            than ending a word or escaping itself
--   """ '''  the third one lays down the closing fence too
--   <BS>     between an empty pair, take both halves
--   <CR>     between a pair, open a line and leave the closer below it
--
-- Every one of these is an expr mapping that only reads the current line, so
-- the decision comes from what is under the cursor at the time and there is no
-- state to keep between keystrokes: undo, macros and repeat all behave because
-- nothing was remembered that could go stale.
--
-- Nothing happens in a buffer that is not a file, which is what keeps the
-- picker prompt in lua/picker.lua an ordinary line to type in.

local M = {}

local OPEN = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local CLOSE = { [")"] = true, ["]"] = true, ["}"] = true }
local QUOTE = { ['"'] = true, ["'"] = true, ["`"] = true }

-- Only these double up into a docstring fence. ``` in Markdown wants a language
-- after it and its closer three lines down, not one against the cursor.
local TRIPLE = { ['"'] = true, ["'"] = true }

local WORD = "[%w_]"

--- The current line either side of the cursor.
local function around()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2] -- bytes before the cursor
	return line:sub(1, col), line:sub(col + 1)
end

local function editing()
	return vim.bo.buftype == ""
end

--- Whether a quote typed here would be escaped by what sits behind it. An odd
--- run of backslashes escapes the quote; an even one is backslashes escaping
--- each other, which leaves the quote a quote.
local function escaped(before)
	return #before:match("(\\*)$") % 2 == 1
end

--------------------------------------------------------------------------- --
-- the keys
--------------------------------------------------------------------------- --

local function open(char)
	if not editing() then
		return char
	end
	local _, after = around()
	-- A closer in front of a word is in the way rather than helpful: typing (
	-- before foo is how you wrap it, and the ) belongs after foo, not here.
	if after:match("^" .. WORD) then
		return char
	end
	return char .. OPEN[char] .. "<Left>"
end

local function close(char)
	if not editing() then
		return char
	end
	local _, after = around()
	if after:sub(1, 1) == char then
		return "<Right>"
	end
	return char
end

local function quote(char)
	if not editing() then
		return char
	end
	local before, after = around()

	-- Before the step-over below, not after it: inside "a\" the quote ahead of
	-- the cursor is ours, but an escaped quote is a character in the string
	-- rather than the end of it, and stepping over would leave the string open.
	if escaped(before) then
		return char
	end
	if after:sub(1, 1) == char then
		return "<Right>" -- ours already, step over it
	end

	-- Two behind the cursor is a docstring being opened, so the third keystroke
	-- finishes the opening fence and lays the closing one down as well. Guarded
	-- against a full fence already being there, which only happens if the pair
	-- was typed some other way.
	if TRIPLE[char] and before:sub(-2) == char:rep(2) and before:sub(-3) ~= char:rep(3) then
		return char:rep(4) .. "<Left><Left><Left>"
	end

	-- Up against a word on either side it is an apostrophe, a prefix or a
	-- suffix, and never the start of a string.
	if before:match(WORD .. "$") or after:match("^" .. WORD) then
		return char
	end

	return char .. char .. "<Left>"
end

--- True when the cursor sits between the two halves of an empty pair.
local function inside_empty()
	local before, after = around()
	local o, c = before:sub(-1), after:sub(1, 1)
	if c == "" then
		return false
	end
	return OPEN[o] == c or (QUOTE[o] and o == c)
end

local function backspace()
	if editing() and inside_empty() then
		return "<BS><Del>"
	end
	return "<BS>"
end

local function enter()
	-- The popup owns <CR> while it is up, whatever is around the cursor.
	if not editing() or vim.fn.pumvisible() == 1 then
		return "<CR>"
	end
	local before, after = around()
	if OPEN[before:sub(-1)] ~= nil and OPEN[before:sub(-1)] == after:sub(1, 1) then
		-- Out of insert for exactly one command: O opens the line with the
		-- filetype's own indent applied, and working that out by hand from an
		-- expr mapping would be reimplementing 'indentexpr' badly.
		return "<CR><Esc>O"
	end
	return "<CR>"
end

--------------------------------------------------------------------------- --
-- wiring
--------------------------------------------------------------------------- --

local keys = require("keys")

-- Mapped untracked and summarised below instead: eleven rows of "inserts the
-- other half" would crowd <leader>h out without saying anything the four lines
-- of description do not.
local function map(lhs, fn)
	keys.untracked("i", lhs, fn, { expr = true, silent = true })
end

for char in pairs(OPEN) do
	map(char, function()
		return open(char)
	end)
end
for char in pairs(CLOSE) do
	map(char, function()
		return close(char)
	end)
end
for char in pairs(QUOTE) do
	map(char, function()
		return quote(char)
	end)
end
map("<BS>", backspace)
map("<CR>", enter)

keys.declare({
	{ mode = "i", lhs = "( [ {", desc = "Insert the closing half, unless a word is in the way" },
	{ mode = "i", lhs = ") ] }", desc = "Step over the closer already there rather than doubling it" },
	{ mode = "i", lhs = "\" ' `", desc = "Open or close a string; a third one fences a docstring" },
	{ mode = "i", lhs = "<BS>", desc = "Between an empty pair, delete both halves" },
	{ mode = "i", lhs = "<CR>", desc = "Between a pair, open a line and leave the closer below" },
})

return M
