-- lsp setup
--

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

return M
