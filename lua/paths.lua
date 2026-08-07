-- Keep everything Neovim installs or generates inside this directory.
--
-- Redirecting the XDG variables is what does the real work: vim.fn.stdpath()
-- re-reads them on every call, so from here on every caller resolves inside
-- the config directory, including code we did not write. vim.pack in
-- particular hardcodes stdpath("data").."/site/pack/core/opt" with no way to
-- override it, so this is the only lever.
--
-- The options below then have to be re-pointed by hand: Neovim worked them out
-- at startup, before init.lua ran, from the old locations.

local config = vim.fn.stdpath("config")

vim.env.XDG_DATA_HOME = config .. "/.data"
vim.env.XDG_STATE_HOME = config .. "/.state"
vim.env.XDG_CACHE_HOME = config .. "/.cache"

local data = vim.fn.stdpath("data")
local state = vim.fn.stdpath("state")

-- Packages land under the new data directory, which is not on either path yet.
-- Prepended rather than appended, which is what nvim-treesitter asks for so its
-- queries win over the ones bundled with Neovim.
local site = data .. "/site"
vim.opt.runtimepath:prepend(site)
vim.opt.packpath:prepend(site)

-- The trailing // on undo/swap/backup makes the saved file names include the
-- full path, so two files with the same basename cannot collide.
vim.o.undodir = state .. "/undo//"
vim.o.directory = state .. "/swap//"
vim.o.backupdir = state .. "/backup//"
vim.o.viewdir = state .. "/view"
vim.o.shadafile = state .. "/shada/main.shada"

-- Tools we install ourselves rather than through a package manager live here
-- too, so they travel with the config and need no sudo (see lua/deps.lua).
vim.env.PATH = table.concat({
	data .. "/bin", -- single binaries: tree-sitter, lua-language-server
	data .. "/venv/bin", -- python virtualenv: pylsp
	data .. "/node/node_modules/.bin", -- npm prefix: tsgo
	vim.env.PATH,
}, ":")

for _, dir in ipairs({
	site,
	data .. "/bin",
	state .. "/undo",
	state .. "/swap",
	state .. "/backup",
	state .. "/view",
	state .. "/shada",
}) do
	vim.fn.mkdir(dir, "p")
end
