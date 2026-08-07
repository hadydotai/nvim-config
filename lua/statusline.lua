vim.api.nvim_create_autocmd("BufEnter", {
	callback = function()
		local root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("%s+$", "")
		if root ~= "" then
			vim.b.git_branch = vim.fn.system("git branch --show-current 2>/dev/null"):gsub("%s+$", "")
			vim.b.rel_path = vim.fn.expand("%:p"):sub(#root + 2)
		else
			vim.b.git_branch = nil
			vim.b.rel_path = vim.fn.expand("%:p:~")
		end
	end,
})

vim.o.statusline = "%{get(b:,'git_branch','')} %f"
