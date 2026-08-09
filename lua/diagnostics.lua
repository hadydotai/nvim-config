-- Diagnostics: the list of them, and the whole text of one.
--
--   <leader>q  this buffer's diagnostics in the quickfix list
--   <leader>Q  every buffer's, as far as the servers have looked
--   <C-w>d     the ones under the cursor in full, in a float. Neovim's own
--              mapping; a second press focuses the float so it can be
--              scrolled, and q closes it, the same way K does for hover
--   K          in the quickfix window, that float for the entry under the
--              cursor, or the entry's own text when it is not a diagnostic
--
-- The last two exist because a quickfix line is one line and a diagnostic
-- frequently is not. rustc writes several lines and hangs the locations it
-- refers to off the side of them, clippy puts the address of the lint in the
-- message, and pylsp will hand over a paragraph. Flattened into the list all
-- of that runs off the right edge with nothing to scroll, so the list carries
-- the first line and says there is more, and the float carries the rest.

local M = {}

local TITLE = { buffer = "Diagnostics (this buffer)", all = "Diagnostics (all buffers)" }

vim.diagnostic.config({
	virtual_text = true,
	float = {
		-- The border the picker and the window overlay use.
		border = "rounded",
		-- The default header spends the first line of the float saying
		-- "Diagnostics:", which is not news inside a diagnostic float.
		header = "",
		-- Only when a buffer has diagnostics from more than one of them, which
		-- is a real case rather than a hypothetical one: a Rust file gets
		-- compiler errors from rustc and lints from clippy at the same time,
		-- and which of the two is talking changes what you do about it.
		source = "if_many",
	},
})

--------------------------------------------------------------------------- --
-- the quickfix list
--------------------------------------------------------------------------- --

--- One line of a diagnostic for the list: the first line of the message, said
--- to be the first when it is not the only one, and whatever the server calls
--- it. The code is worth the width; it is the thing you search the web for.
local function summary(diagnostic)
	local first, rest = diagnostic.message:match("^([^\n]*)\n?(.*)$")
	local out = rest ~= "" and (first .. " ...") or first
	local tag = {}
	if diagnostic.source then
		tag[#tag + 1] = diagnostic.source
	end
	if diagnostic.code then
		tag[#tag + 1] = tostring(diagnostic.code)
	end
	if #tag > 0 then
		out = out .. " [" .. table.concat(tag, " ") .. "]"
	end
	return out
end

--- Quickfix items, in file order.
---
--- Through toqflist rather than by hand so the sorting and the severity-to-
--- type mapping stay Neovim's, with the message rewritten on a copy first,
--- which is how the runtime applies its own `format` option too.
local function items(diagnostics)
	return vim.diagnostic.toqflist(vim.tbl_map(function(d)
		return vim.tbl_extend("force", d, { message = summary(d) })
	end, diagnostics))
end

-- Which list is on screen, so DiagnosticChanged below knows whether there is
-- anything of ours to keep up to date, and for the buffer-scoped one, which
-- buffer it was about.
local showing = nil

local function build(scope, bufnr, action)
	local diagnostics = vim.diagnostic.get(scope == "buffer" and bufnr or nil)
	vim.fn.setqflist({}, action, { title = TITLE[scope], items = items(diagnostics) })
	return #diagnostics
end

--- @param scope "buffer"|"all"
function M.list(scope)
	local bufnr = vim.api.nvim_get_current_buf()
	if build(scope, bufnr, " ") == 0 then
		vim.notify(
			scope == "buffer" and "diagnostics: none in this buffer" or "diagnostics: none anywhere yet",
			vim.log.levels.INFO
		)
		return
	end
	showing = { scope = scope, bufnr = bufnr }
	vim.cmd("botright copen")
end

--- Keep the list current while it is open, so fixing something takes it off
--- the list rather than leaving a row that jumps to a line where nothing is
--- wrong any more. Only ever the list we put there, recognised by its title:
--- a `grep` you ran since is not ours to overwrite.
local function refresh()
	if not showing or vim.fn.getqflist({ winid = 0 }).winid == 0 then
		return
	end
	if vim.fn.getqflist({ title = 0 }).title ~= TITLE[showing.scope] then
		showing = nil -- something else owns the list now
		return
	end
	if showing.scope == "buffer" and not vim.api.nvim_buf_is_valid(showing.bufnr) then
		return
	end
	-- "r" replaces the current list in place rather than pushing a new one, so
	-- the quickfix history does not fill up with a copy per keystroke and the
	-- open window keeps its position.
	build(showing.scope, showing.bufnr, "r")
end

--------------------------------------------------------------------------- --
-- the whole text of one
--------------------------------------------------------------------------- --

local FLOAT = { border = "rounded", focusable = true }

--- The quickfix entry under the cursor, from whichever kind of list this
--- window is showing.
local function entry_under_cursor()
	local win = vim.api.nvim_get_current_win()
	local loclist = vim.fn.getwininfo(win)[1].loclist == 1
	local list = loclist and vim.fn.getloclist(win) or vim.fn.getqflist()
	return list[vim.fn.line(".")]
end

--- K in the quickfix window.
---
--- The float comes from vim.diagnostic itself, pointed at the entry's buffer
--- and line rather than at the cursor, which is sitting in the quickfix
--- window and knows nothing. Scope "line" and not "cursor" on purpose: cursor
--- scope reads the line's text to compare columns, and the buffer the entry
--- points at may never have been loaded.
function M.detail()
	local item = entry_under_cursor()
	if not item then
		return
	end

	if item.bufnr and item.bufnr ~= 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
		local float = vim.diagnostic.open_float(vim.tbl_extend("force", FLOAT, {
			bufnr = item.bufnr,
			pos = item.lnum - 1,
			scope = "line",
		}))
		if float then
			return
		end
	end

	-- Not a diagnostic list, or the diagnostic has been fixed since. The
	-- entry's own text is still worth unfolding: a :grep hit off the right
	-- edge is the same problem.
	local text = vim.trim(item.text or "")
	if text == "" then
		return
	end
	vim.lsp.util.open_floating_preview(
		vim.split(text, "\n", { plain = true }),
		"plaintext",
		vim.tbl_extend("force", FLOAT, { focus_id = "qf_detail", wrap = true })
	)
end

--------------------------------------------------------------------------- --
-- wiring
--------------------------------------------------------------------------- --

local keys = require("keys")

vim.keymap.set("n", "<leader>q", function()
	M.list("buffer")
end, { silent = true, desc = "This buffer's diagnostics in the quickfix list" })

vim.keymap.set("n", "<leader>Q", function()
	M.list("all")
end, { silent = true, desc = "Every buffer's diagnostics in the quickfix list" })

local group = vim.api.nvim_create_augroup("Diagnostics", { clear = true })

vim.api.nvim_create_autocmd("DiagnosticChanged", { group = group, callback = refresh })

vim.api.nvim_create_autocmd("FileType", {
	group = group,
	pattern = "qf",
	callback = function(ev)
		keys.untracked("n", "K", M.detail, {
			buffer = ev.buf,
			silent = true,
			desc = "Show this entry in full",
		})
	end,
})

-- Declared rather than left to be recorded when the first quickfix window
-- opens, so <leader>h can say the key exists before you have been anywhere it
-- works. <C-w>d is Neovim's own, set in $VIMRUNTIME/lua/vim/_core/defaults.lua.
keys.declare({
	{
		lhs = "<C-w>d",
		desc = "The diagnostics on this line in full; again to focus and scroll it, q closes",
	},
	{
		lhs = "K",
		where = "qf",
		desc = "The entry under the cursor in full, diagnostic or not",
	},
})

return M
