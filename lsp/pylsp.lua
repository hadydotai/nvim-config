---@brief
---
--- https://github.com/python-lsp/python-lsp-server
---
--- A Python 3.6+ implementation of the Language Server Protocol.
---
--- Which interpreter it runs against is worked out per project rather than
--- taken from $PATH. Two reasons:
---
---   * `pylsp` on $PATH is a lie on any machine with pyenv installed: the shim
---     exists and is executable, so vim.fn.executable() says yes, but running
---     it prints "pyenv: pylsp: command not found" and exits 127 unless the
---     active version happens to have pylsp in it.
---   * jedi resolves imports out of the interpreter it is told about, not the
---     one the file belongs to. Without pointing it at the project's venv,
---     every third-party import in the file is reported as unresolved.
---
--- In a monorepo the root is the package, not the checkout, because
--- pyproject.toml comes before .git in root_markers below. So each package
--- gets its own client pointed at its own .venv.
---
--- Configuration options are documented [here](https://github.com/python-lsp/python-lsp-server/blob/develop/CONFIGURATION.md).

--- The virtualenv a project belongs to: an activated one wins, then the
--- nearest .venv at or above the project root.
local function venv_for(root)
	if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
		return vim.env.VIRTUAL_ENV
	end
	if not root then
		return nil
	end
	local found = vim.fs.find(".venv", { path = root, upward = true, type = "directory", limit = 1 })
	return found[1]
end

--- The pylsp to run: the project's own if it has one, since that is the only
--- one whose plugins (ruff, mypy) are the project's own too, then the one
--- lua/deps.lua installs for us. Bare "pylsp" is the last resort on purpose.
local function command(venv)
	local candidates = {}
	if venv then
		candidates[#candidates + 1] = venv .. "/bin/pylsp"
	end
	candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/venv/bin/pylsp"
	for _, path in ipairs(candidates) do
		if vim.fn.executable(path) == 1 then
			return { path }
		end
	end
	return { "pylsp" }
end

---@type vim.lsp.Config
return {
	-- A function so it can see config.root_dir, which is only resolved once a
	-- buffer has been matched to a project.
	cmd = function(dispatchers, config)
		return vim.lsp.rpc.start(command(venv_for(config.root_dir)), dispatchers, {
			cwd = config.root_dir,
		})
	end,
	-- on_init rather than before_init: the client copies config.settings when it
	-- is constructed, so mutating them any later than this changes a table
	-- nobody reads. Here we can set them on the client itself and resend, and it
	-- still lands before the first file is opened.
	on_init = function(client)
		local venv = venv_for(client.root_dir)
		if not venv then
			return
		end
		client.settings = vim.tbl_deep_extend("force", client.settings or {}, {
			pylsp = { plugins = { jedi = { environment = venv } } },
		})
		client:notify("workspace/didChangeConfiguration", { settings = client.settings })
	end,
	settings = {
		pylsp = {
			plugins = {
				-- Otherwise every `from x import Y` shows up in the document
				-- symbol list as a symbol of its own, so <leader>s in a file with
				-- a dozen imports opens on a dozen rows that are not in it.
				jedi_symbols = { include_import_symbols = false },
			},
		},
	},
	filetypes = { "python" },
	root_markers = {
		"pyproject.toml",
		"setup.py",
		"setup.cfg",
		"requirements.txt",
		"Pipfile",
		".git",
	},
}
