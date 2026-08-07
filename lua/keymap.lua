vim.g.mapleader = " "
vim.keymap.set(
	"n", "<leader>e",
	function()
		require("netrw_tree").toggle()
	end,
	{
		silent = true,
		desc = "Toggle netrw sidebar, keeping tree state",
	}
)
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

vim.keymap.set(
	"n", "<leader>h",
	function()
		require("keys").show()
	end,
	{
		silent = true,
		desc = "List the mappings this configuration sets",
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
