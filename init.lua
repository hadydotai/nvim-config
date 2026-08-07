require("paths") -- first: redirects stdpath() into this directory
require("keys").setup() -- then: it records the mappings everything below sets
require("options")
require("lsp")
require("colorscheme")
require("treesitter")
require("folding")
require("netrw_pick").setup()
require("netrw_sidebar").setup()
require("netrw_tree").setup()
require("keymap")
require("find")
require("statusline")
