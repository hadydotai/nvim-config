require("paths") -- first: redirects stdpath() into this directory
require("keys").setup() -- then: it records the mappings everything below sets
require("deps").setup()
require("options")
require("lsp")
require("colorscheme")
require("treesitter")
require("folding")
require("netrw_pick").setup()
require("netrw_sidebar").setup()
require("netrw_tree").setup()
require("keymap")
require("pairs")
require("find")
require("buffers")
require("symbols")
require("diagnostics") -- after keymap.lua: mapleader has to be set before <leader>q
require("lspstatus").setup()
require("statusline")
