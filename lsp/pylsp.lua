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
--- gets its own client pointed at its own .venv, falling back to the nearest
--- one above it but never past the directory nvim was started in.
---
--- Configuration options are documented [here](https://github.com/python-lsp/python-lsp-server/blob/develop/CONFIGURATION.md).

--------------------------------------------------------------------------- --
-- docstring escaping
--------------------------------------------------------------------------- --

-- pylsp runs every docstring through docstring-to-markdown, and when that does
-- not recognise the format, which plain prose does not count as, _utils
-- .format_docstring falls back to escape_markdown: a blanket backslash in front
-- of \ * _ # [ ], plus every run of two spaces swapped for U+00A0. Neovim
-- renders the Markdown source as it is given, highlighting fenced blocks
-- without interpreting inline markup, so read\_file stays on screen and, worse,
-- comes out of the float that way when you copy it.
local ESCAPED = "\\([\\*_#%[%]])" -- exactly the set escape_markdown escapes
local NBSP = "\194\160"

-- Line by line, and never inside a fence: the signature pylsp puts in a
-- ```python block never went through the escaping, and a backslash in there is
-- code that means it.
local function unescape(text)
	local out, fenced = {}, false
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		if line:match("^%s*```") then
			fenced = not fenced
		elseif not fenced then
			line = line:gsub(ESCAPED, "%1"):gsub(NBSP, " ")
		end
		out[#out + 1] = line
	end
	return table.concat(out, "\n")
end

--- Rewrite a MarkupContent in place. Anything else is left alone: only pylsp's
--- markdown goes through the escaping, and a MarkedString from some other
--- server has no business being touched here.
local function clean(content)
	if type(content) == "table" and content.kind == "markdown" and type(content.value) == "string" then
		content.value = unescape(content.value)
	end
end

-- The replies worth cleaning, which are the ones format_docstring feeds. The
-- third caller is completion documentation, left as it comes: that is a preview
-- read in passing rather than something copied out of.
local SCRUB = {
	["textDocument/hover"] = function(result)
		if result then
			clean(result.contents)
		end
	end,
	["textDocument/signatureHelp"] = function(result)
		for _, sig in ipairs(result and result.signatures or {}) do
			clean(sig.documentation)
			for _, param in ipairs(sig.parameters or {}) do
				clean(param.documentation)
			end
		end
	end,
}

--- Clean these replies on the way back, for this client only.
---
--- Not through the config's `handlers` table, which would be the obvious place:
--- vim.lsp.buf.hover() hands its own handler straight to client:request, so a
--- handler registered for the method never gets a look in. The client's own
--- request method is the one point every caller has to come through.
local function intercept(client)
	local request = client.request
	client.request = function(self, method, params, handler, bufnr)
		local scrub = SCRUB[method]
		if scrub and handler then
			local inner = handler
			handler = function(err, result, ...)
				scrub(result)
				return inner(err, result, ...)
			end
		end
		return request(self, method, params, handler, bufnr)
	end
end

--- How far up the search for a .venv is allowed to go: the directory nvim was
--- started in. Unbounded it runs all the way to /, so a stray .venv anywhere
--- above the project quietly becomes its environment, and a stale one whose
--- interpreter has been deleted takes hover, completion and imports down with
--- it while looking for all the world like a broken server.
---
--- A project root can sit above the directory you started in, when you open
--- nvim inside a package rather than at the top of it. Nothing above that root
--- is worth reaching for either, so there the root is its own ceiling.
local function ceiling(root)
	local start = require("lsp").start_dir
	if start and (root == start or vim.startswith(root, start .. "/")) then
		return start
	end
	return root
end

--- The virtualenv a project belongs to: an activated one wins, then the
--- nearest .venv between the project root and the tree you opened.
local function venv_for(root)
	if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
		return vim.env.VIRTUAL_ENV
	end
	if not root then
		return nil
	end
	root = vim.fs.normalize(root)
	local found = vim.fs.find(".venv", {
		path = root,
		upward = true,
		type = "directory",
		limit = 1,
		-- `stop` is exclusive, so it gets the parent: the ceiling itself is part
		-- of the project and has to stay searchable.
		stop = vim.fs.dirname(ceiling(root)),
	})
	return found[1]
end

--- The pylsp to run: the project's own if it has one, since that is the only
--- one whose plugins (ruff, mypy) are the project's own too, then the one
--- lua/deps.lua installs for us. Nil when there is neither.
---
--- There used to be a bare "pylsp" on the end as a last resort, and on a
--- machine with pyenv it was worse than having nothing. The shim is executable,
--- so it was always chosen; it is then run with the project as its cwd, reads
--- that project's .python-version, and exits 1 saying the version is not
--- installed. What you see of that is a single line in the LSP log and a
--- language server that is quietly absent. A last resort that cannot be
--- trusted to run is not one, and saying so here names the fix instead of
--- burying it.
local function command(venv)
	local candidates = {}
	if venv then
		candidates[#candidates + 1] = venv .. "/bin/pylsp"
	end
	candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/venv/bin/pylsp"
	for _, path in ipairs(candidates) do
		if vim.fn.executable(path) == 1 then
			return path
		end
	end
	return nil
end

---@type vim.lsp.Config
return {
	-- A function so it can see config.root_dir, which is only resolved once a
	-- buffer has been matched to a project.
	cmd = function(dispatchers, config)
		local root = config.root_dir
		local exe = command(venv_for(root))
		if not exe then
			-- Raised rather than notified: nvim reports a cmd that throws as the
			-- reason this client did not start, which puts the sentence where you
			-- are already looking when you wonder where the server went.
			error(
				("pylsp: none found for %s. Either :Deps install, which puts one in %s/venv, or install python-lsp-server into the project's own .venv"):format(
					root or "this project",
					vim.fn.stdpath("data")
				),
				0
			)
		end
		return vim.lsp.rpc.start({ exe }, dispatchers, { cwd = root })
	end,
	-- on_init rather than before_init: the client copies config.settings when it
	-- is constructed, so mutating them any later than this changes a table
	-- nobody reads. Here we can set them on the client itself and resend, and it
	-- still lands before the first file is opened.
	on_init = function(client)
		intercept(client)
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
