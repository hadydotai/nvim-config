---@brief
---
--- https://pkg.go.dev/golang.org/x/tools/gopls
---
--- The Go language server, installed into .data/bin by `:Deps install`.
---
--- Worth knowing, because it looks like a broken server rather than a missing
--- one: with nothing attached, K in a Go buffer runs `go doc` in a terminal
--- split instead of opening a hover float. That is Neovim's own
--- ftplugin/go.vim setting 'keywordprg' to :GoKeywordPrg, and K falling
--- through to it because no client has mapped K to hover. Attaching is the
--- whole fix; Neovim treats an option set by a runtime ftplugin as still
--- default and maps K over it.
---
--- Configuration options are documented [here](https://github.com/golang/tools/blob/master/gopls/doc/settings.md).

local TIMEOUT = 1000 -- ms to wait for gopls during a write

--- Apply the import block gopls would write.
---
--- Imports are a code action and not formatting, which is where LSP puts
--- them: `source.organizeImports` both drops what is unused and adds what is
--- missing, the way goimports does. Go makes an unused import a compile
--- error, so without this every write leaves work to do by hand.
---
--- Synchronous, because the write is already under way and an edit that
--- arrived after it would be applied to a buffer that had already gone to
--- disk, leaving the file and the buffer disagreeing.
local function organize_imports(client, bufnr)
	local params = vim.lsp.util.make_range_params(0, client.offset_encoding)
	--- @diagnostic disable-next-line: inject-field
	params.context = { only = { "source.organizeImports" }, diagnostics = {} }

	local response = client:request_sync("textDocument/codeAction", params, TIMEOUT, bufnr)
	for _, action in ipairs(response and response.result or {}) do
		local edit = action.edit
		-- gopls hands over the edit with the action, but the protocol allows a
		-- server to answer with a title and make you ask for the rest.
		if not edit and action.data then
			local resolved = client:request_sync("codeAction/resolve", action, TIMEOUT, bufnr)
			edit = resolved and resolved.result and resolved.result.edit
		end
		if edit then
			vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
		end
	end
end

local group = vim.api.nvim_create_augroup("Gopls", { clear = true })

---@type vim.lsp.Config
return {
	cmd = { "gopls" },
	filetypes = { "go", "gomod", "gowork", "gotmpl" },
	-- In priority order rather than one flat list, so a go.work anywhere above
	-- the file beats the go.mod of the module it happens to sit in: a Go
	-- workspace is several modules that gopls is meant to see at once, and
	-- rooted at one of them the others are just directories to it.
	root_markers = { { "go.work" }, { "go.mod" }, { ".git" } },
	settings = {
		gopls = {
			-- staticcheck's analyses on top of the ones gopls runs by default.
			-- The same trade as clippy for Rust: more said about the code than
			-- the compiler alone would say, from a tool that comes with the
			-- server rather than one that might not be installed.
			staticcheck = true,
		},
	},
	on_attach = function(client, bufnr)
		-- Cleared first: a buffer can attach more than once over its life, and
		-- two copies of this would organize imports twice per write.
		vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = group,
			buffer = bufnr,
			desc = "gopls: organize imports and format",
			callback = function()
				organize_imports(client, bufnr)
				vim.lsp.buf.format({ bufnr = bufnr, id = client.id, async = false })
			end,
		})
	end,
}
