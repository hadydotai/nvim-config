-- Parsers and queries for the languages Neovim does not bundle.
--
-- Neovim ships parsers for c, lua, markdown, query, vim and vimdoc, and its own
-- ftplugins start treesitter for those. Anything else needs two things: a
-- parser, and query files telling Neovim what the tree means (highlights.scm,
-- folds.scm). nvim-treesitter supplies both, kept at versions that match each
-- other, which is the part that is genuinely awkward to maintain by hand.
--
-- It is fetched with vim.pack, Neovim's own package manager, into this
-- directory rather than ~/.local/share (see paths.lua).
--
-- Installing or updating a parser shells out to the tree-sitter CLI, so that
-- has to be on PATH: brew install tree-sitter-cli. Nothing needs it to read a
-- file, only to build one.

local LANGUAGES = { "python", "typescript", "tsx", "javascript", "go", "rust" }

vim.pack.add({
	{
		src = "https://github.com/nvim-treesitter/nvim-treesitter",
		version = "main", -- master is a different, frozen plugin, not an older one
	},
})

-- Covers both the parsers Neovim bundles and the ones we installed, since both
-- sit on the runtimepath.
local function installed(lang)
	return #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".so", false) > 0
end

local missing = vim.tbl_filter(function(lang)
	return not installed(lang)
end, LANGUAGES)

if #missing > 0 then
	require("nvim-treesitter").install(missing)
end

vim.api.nvim_create_autocmd("FileType", {
	group = vim.api.nvim_create_augroup("Treesitter", { clear = true }),
	callback = function(ev)
		-- The lua/markdown/help/query ftplugins start treesitter themselves, and
		-- vim.treesitter.start() stacks a second highlighter rather than noticing
		-- one is already running.
		if vim.treesitter.highlighter.active[ev.buf] then
			return
		end
		local lang = vim.treesitter.language.get_lang(ev.match)
		if lang and installed(lang) then
			pcall(vim.treesitter.start, ev.buf, lang)
		end
	end,
})
