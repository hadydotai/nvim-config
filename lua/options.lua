-- general configs
--

vim.o.number = true
vim.o.relativenumber = true
vim.o.tabstop = 2
vim.o.softtabstop = 2
vim.o.shiftwidth = 2
vim.o.signcolumn = "yes"
vim.o.undofile = true
vim.o.autoread = true
vim.o.laststatus = 3
vim.o.cmdheight = 0

-- Every yank, delete and paste goes through the system clipboard, so y and p
-- cross the editor boundary without reaching for "+ each time. The cost is that
-- d, c and x clobber the clipboard too; "0 is the way back, holding the last
-- thing yanked and nothing that was merely deleted.
vim.o.clipboard = "unnamedplus"

