-- What to hand an agent along with the question: where you are, what you had
-- selected, what is broken on this line.
--
-- The bias throughout is to point rather than to paste. An agent can open a
-- file faster than you can copy one into its prompt, and a path with a line
-- number is something it can act on, so most of these send a reference and let
-- it read. The exception is a selection, where the point is usually "this
-- exact text" and the surrounding file may be beside the point.
--
-- Paths are relative to the project when they are inside it, because that is
-- how you refer to them out loud and how the agent will report back.

local M = {}

--- A path as it should appear in a prompt: relative to `root` when it is
--- underneath it, absolute when it is not.
local function relative(path, root)
	if not path or path == "" then
		return nil
	end
	local full = vim.fn.fnamemodify(path, ":p")
	if root and root ~= "" and full:sub(1, #root + 1) == root .. "/" then
		return full:sub(#root + 2)
	end
	return full
end

local function fence(lines, filetype)
	local out = { "```" .. (filetype or "") }
	vim.list_extend(out, lines)
	out[#out + 1] = "```"
	return out
end

--- The visual selection, as lines, or nil. Read from the marks rather than the
--- registers so nothing is clobbered, and so it works after the mode has
--- already been left, which it has by the time a mapping runs.
local function selection(buf)
	local from = vim.api.nvim_buf_get_mark(buf, "<")
	local to = vim.api.nvim_buf_get_mark(buf, ">")
	if from[1] == 0 or to[1] == 0 then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(buf, from[1] - 1, to[1], false)
	if #lines == 0 then
		return nil
	end
	return lines, from[1], to[1]
end

--------------------------------------------------------------------------- --
-- the sources
--------------------------------------------------------------------------- --

--- Each returns nil when it has nothing to say, so the picker can offer only
--- the ones that apply: "the selection" is not a choice when nothing is
--- selected.
M.sources = {
	{
		name = "nothing",
		label = "Nothing, just ask",
		build = function()
			return ""
		end,
	},

	{
		name = "file",
		label = "This file",
		build = function(ctx)
			if not ctx.path then
				return nil
			end
			return ("In %s:"):format(ctx.path)
		end,
	},

	{
		name = "location",
		label = "This line",
		build = function(ctx)
			if not ctx.path then
				return nil
			end
			local line = vim.api.nvim_buf_get_lines(ctx.buf, ctx.line - 1, ctx.line, false)[1]
			if not line then
				return nil
			end
			return table.concat({
				("At %s:%d:"):format(ctx.path, ctx.line),
				"",
				table.concat(fence({ vim.trim(line) }, ctx.filetype), "\n"),
			}, "\n")
		end,
	},

	{
		name = "selection",
		label = "The selection",
		build = function(ctx)
			local lines, from, to = selection(ctx.buf)
			if not lines then
				return nil
			end
			return table.concat({
				("In %s, lines %d to %d:"):format(ctx.path or "this buffer", from, to),
				"",
				table.concat(fence(lines, ctx.filetype), "\n"),
			}, "\n")
		end,
	},

	{
		name = "diagnostics",
		label = "The diagnostics here",
		build = function(ctx)
			local items = vim.diagnostic.get(ctx.buf)
			if #items == 0 then
				return nil
			end
			-- Sorted and capped: a buffer mid-edit can have hundreds, and a
			-- prompt that is mostly a diagnostic dump buries the question.
			table.sort(items, function(a, b)
				if a.severity ~= b.severity then
					return a.severity < b.severity
				end
				return a.lnum < b.lnum
			end)
			local lines = {}
			for i, item in ipairs(items) do
				if i > 20 then
					lines[#lines + 1] = ("... and %d more"):format(#items - 20)
					break
				end
				lines[#lines + 1] = ("%s:%d: %s"):format(ctx.path or "buffer", item.lnum + 1, vim.trim(item.message))
			end
			return table.concat({
				("%d problem%s in %s:"):format(#items, #items == 1 and "" or "s", ctx.path or "this buffer"),
				"",
				table.concat(fence(lines), "\n"),
			}, "\n")
		end,
	},
}

--- Where the cursor is, as the sources need it. Captured before any dialog
--- opens, since opening one moves the cursor out of the buffer you meant.
function M.here(root)
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
	local name = vim.api.nvim_buf_get_name(buf)
	return {
		buf = buf,
		line = ok and cursor[1] or 1,
		path = vim.bo[buf].buftype == "" and relative(name, root) or nil,
		filetype = vim.bo[buf].filetype,
	}
end

--- The sources that have something to offer for `ctx`, each with the text it
--- would contribute already built, so the dialog can show it and nothing is
--- computed twice.
function M.offered(ctx)
	local out = {}
	for _, source in ipairs(M.sources) do
		local ok, text = pcall(source.build, ctx)
		if ok and text then
			out[#out + 1] = { name = source.name, label = source.label, text = text }
		end
	end
	return out
end

--- The prompt as the agent receives it: what you are pointing at, then what
--- you asked. Context first because it reads as a sentence that way, and
--- because the question is the part you want it to end on.
function M.prompt(context, question)
	if not context or context == "" then
		return question
	end
	if not question or question == "" then
		return context
	end
	return context .. "\n\n" .. question
end

return M
