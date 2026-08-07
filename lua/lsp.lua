-- Language server setup, and the keys that drive it.
--
-- Neovim maps most of the LSP verbs itself (grn, gra, grr, gri, grt, gO, K),
-- so the only one added here is gd. The rest are declared at the bottom, not
-- mapped, purely so <leader>h can list them.

local M = {}

-- Named here rather than passed inline so lspstatus.lua can tell which servers
-- were meant to attach to a buffer, and mark the ones that did not.
M.servers = { "lua_ls", "pylsp", "tsgo" }

vim.lsp.enable(M.servers)
vim.diagnostic.config({ virtual_text = true })

vim.api.nvim_create_autocmd("LspAttach", {
	callback = function(ev)
		local client = vim.lsp.get_client_by_id(ev.data.client_id)
		if client ~= nil and client:supports_method("textDocument/completion") then
			vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
		end
	end,
})

vim.cmd("set completeopt+=noselect")

--------------------------------------------------------------------------- --
-- keys
--------------------------------------------------------------------------- --

-- Neovim maps most of the LSP verbs itself but leaves out the one people reach
-- for first. Plain gd is a much older key: "go to local declaration", a
-- backwards keyword search inside the current function, which in Python lands
-- on whatever happened to match textually rather than on the definition.
-- Mapped the way Neovim maps the rest of them, unconditionally, so it behaves
-- the same whether or not a server has attached yet: with none, it says so.
vim.keymap.set("n", "gd", function()
	vim.lsp.buf.definition()
end, { silent = true, desc = "Go to definition" })

-- Neovim's own LSP mappings, listed so <leader>h describes the whole set rather
-- than only the part this configuration adds. They are set in
-- $VIMRUNTIME/lua/vim/_core/defaults.lua, which has already run by the time
-- keys.setup() could have watched for them, and K is attached per buffer when a
-- server that answers hover connects.
require("keys").declare({
	{ lhs = "K", desc = "Documentation for the symbol under the cursor (Neovim default)" },
	{ lhs = "grn", desc = "Rename the symbol under the cursor (Neovim default)" },
	{ lhs = "gra", mode = { "n", "x" }, desc = "Code actions (Neovim default)" },
	{ lhs = "grr", desc = "References, in the quickfix list (Neovim default)" },
	{ lhs = "gri", desc = "Go to implementation (Neovim default)" },
	{ lhs = "grt", desc = "Go to type definition (Neovim default)" },
	{ lhs = "grx", desc = "Run the code lens under the cursor (Neovim default)" },
	{ lhs = "gO", desc = "Symbols in the quickfix list; <leader>s is the same list as a dialog" },
	{ lhs = "<C-s>", mode = { "i", "s" }, desc = "Signature help (Neovim default)" },
	{ lhs = "<C-]>", desc = "Go to definition through 'tagfunc' (Neovim default)" },
})

return M
