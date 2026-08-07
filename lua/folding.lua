-- Folding along the syntax tree, on everywhere.
--
-- Set globally rather than per filetype, which is what nvim-treesitter's docs
-- suggest. Those docs assume an ftplugin, and window-local options set from a
-- FileType autocmd only reach the window the buffer first opened in: split
-- afterwards and the new window has no folds. Global avoids that entirely.
--
-- Buffers with no parser cost nothing. vim.treesitter.foldexpr() returns 0 for
-- every line, measured at roughly a microsecond per line, and netrw and other
-- special buffers just come out unfolded.

vim.o.foldmethod = "expr"
vim.o.foldexpr = "v:lua.vim.treesitter.foldexpr()"

-- Files open with everything unfolded. Folding is then something you reach for
-- (za toggles one, zc closes, zR opens all, zM closes all) rather than a state
-- you have to undo on every file you open.
vim.o.foldlevelstart = 99

-- An empty 'foldtext' draws the fold's own first line with its real
-- highlighting, instead of replacing it with a plain "+-- 12 lines:" summary
-- that would throw away everything treesitter just worked out.
vim.o.foldtext = ""
vim.opt.fillchars:append({ fold = " " })
