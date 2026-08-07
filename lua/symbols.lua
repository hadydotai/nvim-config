-- <leader>s: a modal, filterable list of the symbols in the current buffer.
--
--   type     narrow the list, fuzzily, against the dotted Container.name path
--   <cr>     outline a target window, hjkl to move, <cr> to jump there
--   <s-cr>   jump in the window you came from, never the netrw sidebar
--
-- The same keys as <leader>f and <leader>b, through the same overlay, so a
-- symbol lands where a file or a buffer would have.
--
-- Servers answer textDocument/documentSymbol in one of two shapes and both are
-- in use here: DocumentSymbol[] nests its children (lua_ls, tsgo), while
-- SymbolInformation[] is flat and names the enclosing scope in containerName
-- (pylsp). Either way collect() turns one symbol into one row carrying a dotted
-- path, so the list reads the same whichever server produced it.

local M = {}

local picker = require("picker")
local win_pick = require("win_pick")

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "SymbolType", { link = "Type", default = true })
	hl(0, "SymbolFunc", { link = "Function", default = true })
	hl(0, "SymbolKind", { link = "Comment", default = true })
	hl(0, "SymbolName", { link = "Normal", default = true })
	hl(0, "SymbolParent", { link = "Comment", default = true })
	hl(0, "SymbolLine", { link = "LineNr", default = true })
end

-- Colour the kind column by what the symbol is, since that is the thing the eye
-- picks out when scanning. Anything not named here stays SymbolKind.
local KIND_HL = {
	Class = "SymbolType",
	Struct = "SymbolType",
	Interface = "SymbolType",
	Enum = "SymbolType",
	TypeParameter = "SymbolType",
	Function = "SymbolFunc",
	Method = "SymbolFunc",
	Constructor = "SymbolFunc",
}

--------------------------------------------------------------------------- --
-- fetching
--------------------------------------------------------------------------- --

-- LSP counts columns in code units of the client's negotiated encoding, which
-- for most servers is UTF-16. Resolved to a byte column here, while the line it
-- refers to is still the one the server was told about.
local function byte_col(buf, lnum, character, encoding)
	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
	if not line then
		return 0
	end
	local ok, col = pcall(vim.str_byteindex, line, encoding, character, false)
	return ok and col or math.min(character, #line)
end

-- Kinds whose insides are not outline material: bodies of code, and values
-- holding one. Whatever is declared in there is a local, and unfiltered a
-- 300-line module lists every caught exception and loop variable it has, which
-- outnumbers the things the list was opened to find. Variable and Property are
-- in here for the sake of `const f = () => {}`, which servers report as a value
-- rather than a function; the cost is that the keys of an object literal go
-- with them, and an outline is no worse for that.
local LOCAL_SCOPE = {
	Function = true,
	Method = true,
	Constructor = true,
	Variable = true,
	Property = true,
	Field = true,
}

--- Kind of each symbol by name, so a flat reply can tell what the scope named
--- in containerName was. Hierarchical replies do not need it: they know their
--- parent by construction.
local function kinds_by_name(result)
	local out = {}
	for _, sym in ipairs(result or {}) do
		if sym.name then
			out[sym.name] = vim.lsp.protocol.SymbolKind[sym.kind]
		end
	end
	return out
end

--- Flatten one server's reply into rows. `prefix` is the dotted path of the
--- enclosing symbols, which only hierarchical replies build up; a flat reply
--- names its one level of scope in containerName instead. `inside` says the
--- enclosing scope was a function, and it sticks: lua_ls nests a `for` or an
--- `if` under the function containing it and hangs the locals off that, so
--- asking only about the immediate parent would let them all back in.
local function collect(result, ctx, out, prefix, inside)
	for _, sym in ipairs(result or {}) do
		-- selectionRange is the name itself and range the whole body; a flat
		-- symbol has neither, and carries a location that also names the file.
		local range = sym.selectionRange or sym.range or (sym.location and sym.location.range)
		if range then
			local container = sym.containerName
			if container == vim.NIL or container == "" then
				container = nil
			end
			local parent = prefix or container
			local kind = vim.lsp.protocol.SymbolKind[sym.kind] or "Unknown"
			local path = parent and (parent .. "." .. sym.name) or sym.name
			local lnum = range.start.line + 1
			local local_scope = inside or (container and LOCAL_SCOPE[ctx.kinds[container]]) or false

			if not local_scope then
				out[#out + 1] = {
					kind = kind,
					path = path,
					-- bytes of `path` that are the enclosing scope, dimmed on the
					-- way out so the name itself still reads first
					prefix_len = parent and (#parent + 1) or 0,
					lnum = lnum,
					col = byte_col(ctx.buf, lnum, range.start.character, ctx.encoding),
				}
			end
			collect(sym.children, ctx, out, path, local_scope or LOCAL_SCOPE[kind] or false)
		end
	end
	return out
end

local function request(buf, done)
	local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
	vim.lsp.buf_request_all(buf, "textDocument/documentSymbol", params, function(results)
		local out = {}
		for id, res in pairs(results) do
			local client = vim.lsp.get_client_by_id(id)
			if res.result and client then
				collect(res.result, {
					buf = buf,
					encoding = client.offset_encoding,
					kinds = kinds_by_name(res.result),
				}, out)
			end
		end
		-- source order, so the list reads down the file. Servers mostly return
		-- them that way already, but two of them answering at once would not.
		table.sort(out, function(a, b)
			if a.lnum ~= b.lnum then
				return a.lnum < b.lnum
			end
			if a.col ~= b.col then
				return a.col < b.col
			end
			return a.path < b.path
		end)
		done(out)
	end)
end

--------------------------------------------------------------------------- --
-- showing
--------------------------------------------------------------------------- --

-- kind, dotted path, line. The path column flexes, since it is the one worth
-- reading in full and the other two have a fixed size.
local function columns(item)
	local name = { text = item.path, hl = "SymbolName" }
	if item.prefix_len > 0 then
		name.spans = { { 0, item.prefix_len, "SymbolParent" } }
	end
	return {
		{ text = item.kind, hl = KIND_HL[item.kind] or "SymbolKind" },
		name,
		{ text = tostring(item.lnum), hl = "SymbolLine", right = true },
	}
end

local function jump(buf, win, item)
	if not vim.api.nvim_buf_is_valid(buf) then
		return -- wiped out from under us while the request was in flight
	end
	win_pick.focus(win)
	if vim.api.nvim_get_current_buf() ~= buf then
		vim.cmd("buffer " .. buf)
	end
	vim.cmd("normal! m'") -- leave a jumplist entry, so <C-o> comes back
	local last = vim.api.nvim_buf_line_count(buf)
	pcall(vim.api.nvim_win_set_cursor, 0, { math.min(item.lnum, last), item.col })
	vim.cmd("normal! zz")
end

function M.show()
	local buf = vim.api.nvim_get_current_buf()
	if #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentSymbol" }) == 0 then
		vim.notify("symbols: no language server is attached here", vim.log.levels.WARN)
		return
	end

	request(buf, function(items)
		if #items == 0 then
			vim.notify("symbols: none reported for this buffer", vim.log.levels.WARN)
			return
		end
		picker.open({
			title = "Symbols",
			items = items,
			columns = columns,
			search = function(item)
				return item.path
			end,
			fuzzy = true,
			flex = 2, -- the path takes the leftover width, not the line number
			min = { 6, 11, 3 },
			footer = win_pick.FOOTER,
			-- The request is async, but nothing has taken focus yet, so this
			-- still sees the layout the user was looking at.
			actions = win_pick.actions(function(win, item)
				jump(buf, win, item)
			end),
		})
	end)
end

--------------------------------------------------------------------------- --
-- across the workspace
--------------------------------------------------------------------------- --

-- Every server that answers workspace/symbol, not only the ones attached to
-- this buffer, so <leader>S works from netrw or a scratch buffer too.
local function searchers()
	return vim.lsp.get_clients({ method = "workspace/symbol" })
end

-- Unlike documentSymbol, the query goes to the server: matching is its own, it
-- is the only thing that has the whole workspace indexed, and what it knows
-- about grows as it loads more of the project. So this is asked again on every
-- keystroke rather than fetched once and narrowed here.
local function search(query, done)
	local clients = searchers()
	local out, left = {}, #clients
	if left == 0 then
		return done(out)
	end
	for _, client in ipairs(clients) do
		client:request("workspace/symbol", { query = query }, function(_, result)
			for _, sym in ipairs(result or {}) do
				local loc = sym.location
				-- A WorkspaceSymbol may carry a uri with no range, meaning "ask
				-- workspaceSymbol/resolve for it". Opening the file at the top is
				-- a fair answer and saves a second round trip.
				if loc and loc.uri then
					local container = sym.containerName
					if container == vim.NIL or container == "" then
						container = nil
					end
					local start = loc.range and loc.range.start
					out[#out + 1] = {
						kind = vim.lsp.protocol.SymbolKind[sym.kind] or "Unknown",
						path = container and (container .. "." .. sym.name) or sym.name,
						prefix_len = container and (#container + 1) or 0,
						file = vim.uri_to_fname(loc.uri),
						lnum = start and start.line + 1 or 1,
						character = start and start.character or 0,
						encoding = client.offset_encoding,
					}
				end
			end
			left = left - 1
			if left == 0 then
				done(out)
			end
		end)
	end
end

local WHERE_WIDTH = 36 -- columns the file:line field is allowed

-- Cut the head off, not the tail. Results reach outside the project (a server
-- indexes its own runtime too), and the front of those paths is the part that
-- says nothing while the end is the file you are choosing between.
local function shorten(text, width)
	local chars = vim.fn.strchars(text)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	return "..." .. vim.fn.strcharpart(text, chars - (width - 3))
end

-- kind, dotted path, where it lives. The path flexes; the file is capped so one
-- deeply buried result cannot squeeze every name off the screen.
local function ws_columns(item)
	local name = { text = item.path, hl = "SymbolName" }
	if item.prefix_len > 0 then
		name.spans = { { 0, item.prefix_len, "SymbolParent" } }
	end
	local where = vim.fn.fnamemodify(item.file, ":~:.") .. ":" .. item.lnum
	return {
		{ text = item.kind, hl = KIND_HL[item.kind] or "SymbolKind" },
		name,
		{ text = shorten(where, WHERE_WIDTH), hl = "SymbolLine", right = true },
	}
end

local function ws_jump(win, item)
	win_pick.focus(win)
	vim.cmd("normal! m'") -- leave a jumplist entry, so <C-o> comes back
	vim.cmd("edit " .. vim.fn.fnameescape(item.file))
	local buf = vim.api.nvim_get_current_buf()
	local last = vim.api.nvim_buf_line_count(buf)
	local lnum = math.min(item.lnum, last)
	pcall(vim.api.nvim_win_set_cursor, 0, { lnum, byte_col(buf, lnum, item.character, item.encoding) })
	vim.cmd("normal! zz")
end

function M.workspace()
	if #searchers() == 0 then
		vim.notify(
			"symbols: no attached language server answers workspace/symbol (pylsp does not)",
			vim.log.levels.WARN
		)
		return
	end

	search("", function(items)
		if #items == 0 then
			vim.notify("symbols: the workspace index is empty so far", vim.log.levels.WARN)
			return
		end
		picker.open({
			title = "Workspace symbols",
			items = items,
			columns = ws_columns,
			search = function(item)
				return item.path
			end,
			flex = 2,
			min = { 6, 11, 8 },
			max = { [3] = WHERE_WIDTH },
			footer = win_pick.FOOTER,
			query = search,
			actions = win_pick.actions(ws_jump),
		})
	end)
end

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

vim.keymap.set("n", "<leader>s", M.show, {
	silent = true,
	desc = "List symbols in this buffer: <CR> chooses a window, <S-CR> jumps here",
})
vim.keymap.set("n", "<leader>S", M.workspace, {
	silent = true,
	desc = "Search symbols across the workspace, the server matching as you type",
})

return M
