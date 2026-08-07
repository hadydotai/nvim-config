vim.g.mapleader = " "
vim.keymap.set("n", "<leader>e", ":Lexplore<cr>", { silent = true })
vim.keymap.set(
	"n", "<leader>E",
	function()
		require("netrw_sidebar").focus()
	end,
	{
		silent = true,
		desc = "Toggle focus between netrw and the last window",
	}
)

vim.keymap.set("n", "<C-b>", "<C-^>", { silent = true, desc = "Alternate buffer" })

vim.keymap.set(
	"n", "<leader>d",
	function()
		vim.diagnostic.jump({ count = 1 })
	end,
	{
		silent = true,
		desc = "Next diagnostic",
	}
)

vim.keymap.set(
	"n", "<leader>D",
	function()
		vim.diagnostic.jump({ count = -1 })
	end,
	{
		silent = true,
		desc = "Previous diagnostic",
	}
)
