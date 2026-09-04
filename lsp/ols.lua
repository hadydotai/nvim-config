---@brief
---
--- https://github.com/DanielGavin/ols
---
--- The Odin language server, installed into .data/bin by `:Deps install`.
---
--- Every setting it takes is listed in
--- [ols.schema.json](https://github.com/DanielGavin/ols/blob/master/misc/ols.schema.json).
--- A project can set the same fields in an `ols.json` at its root, which is
--- also the file to reach for when a project needs `collections` or a
--- per-platform `profile`; neither belongs in an editor config.
---
--- Worth knowing, because it looks like a server that never attached rather
--- than a server that is failing: ols is a front end to the Odin compiler, not
--- a self-contained analyzer. It shells out to `odin root` for the base, core
--- and vendor collections, and to `odin check` for diagnostics. With no odin
--- to run it starts anyway, answers every request, and answers nothing.
--- Measured here against ols dev-2026-08 with PATH=/usr/bin:/bin:
---
---     hover                           -> null
---     hover, with odin_command sent   -> fmt.println :: proc(args: ..any, ..)
---
--- Nothing is logged in the first case, which is why the compiler is located
--- below rather than left to $PATH. Neovim inherits PATH from whatever started
--- it, and odin lives in ~/.local/bin (see lua/deps.lua), which a launcher that
--- is not a login shell has no reason to have on it.

local group = vim.api.nvim_create_augroup("LspOls", { clear = true })

--- The odin binary ols should shell out to.
---
--- $PATH first, so a machine or a direnv that puts a particular compiler in
--- front keeps it: ols reads the collections out of whichever odin it runs, and
--- a hover that describes a different version of core is worse than no hover.
--- The install location is only the fallback, and nil, meaning "say nothing and
--- let ols look for itself", is the honest answer when there is no compiler at
--- all. `:Deps` is where that gets reported.
local function odin_command()
	local found = vim.fn.exepath("odin")
	if found ~= "" then
		return found
	end
	-- the path lua/deps.lua installs to, on every platform
	local installed = vim.fs.normalize("~/.local/bin/odin")
	if vim.fn.executable(installed) == 1 then
		return installed
	end
	return nil
end

return {
	cmd = { "ols" },
	filetypes = { "odin" },
	-- Nearest marker wins, so an ols.json deep in a tree roots the server at the
	-- project that declared its collections rather than at the repository that
	-- happens to contain it. odinfmt.json is listed for the same reason: it is
	-- the other file that only exists because somebody decided this directory is
	-- a project.
	root_markers = { "ols.json", "odinfmt.json", ".git" },
	init_options = {
		odin_command = odin_command(),
		-- The same trade as staticcheck for Go: more said about the code than
		-- the compiler alone would say, by a tool that is already here. `odin
		-- check` on its own is quiet about a variable that is declared and
		-- never read; with -vet it is an error, and the checker only runs on
		-- write, so this does not fire while a line is half typed.
		checker_args = "-vet",
	},
	--- odinfmt on write, through the server rather than by shelling out. ols
	--- formats in process, so this works whether or not the odinfmt binary is
	--- on PATH, and it reads the project's odinfmt.json either way.
	---
	--- Formatting only. The Go file next door also organizes imports on write:
	--- that is not an omission here. ols does offer source.organizeImports, but
	--- Odin does not make an unused import an error the way Go does, so
	--- removing one is an edit you should be asked about rather than one a
	--- write should perform.
	---
	--- Synchronous, for the reason gopls and rust-analyzer are: the write is
	--- already under way, and an edit arriving after it would be applied to a
	--- buffer that had already gone to disk, leaving the file and the buffer
	--- disagreeing.
	on_attach = function(client, bufnr)
		-- Cleared first: a buffer can attach more than once over its life, and
		-- two copies of this would format twice per write.
		vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = group,
			buffer = bufnr,
			desc = "ols: format",
			callback = function()
				vim.lsp.buf.format({ bufnr = bufnr, id = client.id, async = false })
			end,
		})
	end,
}
