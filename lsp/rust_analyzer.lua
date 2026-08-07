---@brief
---
--- https://rust-analyzer.github.io/
---
--- The Rust language server. Installed by `:Deps install` as a rustup
--- component, for the reasons in lua/deps.lua.
---
--- The two decisions here are which directory it is rooted at and which
--- toolchain it runs under, and they are the mirror image of the Python ones
--- next door. pylsp is rooted at the package because each package has its own
--- virtualenv; rust-analyzer is rooted at the cargo *workspace*, because cargo
--- resolves every member crate against one Cargo.lock and the analyzer wants
--- the whole graph in one process.
---
--- Configuration options are documented [here](https://rust-analyzer.github.io/book/configuration.html).

--- A root already in use that this file sits under.
---
--- root_dir runs for every buffer that gets a client, and the answer below
--- costs a `cargo metadata` each time. Once one crate of a workspace is open
--- the rest of it is already answered, so opening the twentieth file does not
--- spawn a twentieth cargo.
local function running_root(fname)
	for _, client in ipairs(vim.lsp.get_clients({ name = "rust_analyzer" })) do
		if client.root_dir and vim.fs.relpath(client.root_dir, fname) then
			return client.root_dir
		end
	end
end

--- Where the workspace this file belongs to starts.
---
--- The nearest Cargo.toml is the wrong answer in a workspace: a member crate
--- has one of its own, and rooting there gives every member its own analyzer
--- process, each holding its own copy of the dependency graph and none of them
--- able to follow a path into a sibling. Cargo.lock only sits at the top, but
--- it is gitignored by convention in libraries, so a fresh checkout would not
--- have one to find. `cargo metadata` is the authoritative answer and is the
--- only one that survives both cases; the crate itself is the fallback, for a
--- manifest too broken to read, where being rooted somewhere beats not
--- starting.
local function workspace_root(crate, on_dir)
	vim.system(
		{ "cargo", "metadata", "--no-deps", "--format-version", "1" },
		{ cwd = crate, text = true, timeout = 10000 },
		function(out)
			local root
			if out.code == 0 then
				local ok, meta = pcall(vim.json.decode, out.stdout)
				if ok and type(meta) == "table" and type(meta.workspace_root) == "string" then
					root = vim.fs.normalize(meta.workspace_root)
				end
			end
			-- vim.system calls back from libuv, where most of the API is off
			-- limits, and on_dir goes straight on to start a client.
			vim.schedule(function()
				on_dir(root or crate)
			end)
		end
	)
end

---@type vim.lsp.Config
return {
	-- rust-analyzer on $PATH is a rustup proxy, and a proxy picks its toolchain
	-- from the rust-toolchain.toml nearest its *working directory*. Started
	-- without one it inherits nvim's, so a project pinning a toolchain gets
	-- analyzed by whichever one the directory you happened to launch from
	-- implies. A function, because config.root_dir is only resolved once a
	-- buffer has been matched to a project.
	cmd = function(dispatchers, config)
		return vim.lsp.rpc.start({ "rust-analyzer" }, dispatchers, { cwd = config.root_dir })
	end,
	filetypes = { "rust" },
	root_dir = function(bufnr, on_dir)
		local fname = vim.api.nvim_buf_get_name(bufnr)
		local reused = running_root(fname)
		if reused then
			return on_dir(reused)
		end

		local crate = vim.fs.root(bufnr, { "Cargo.toml" })
		if crate then
			return workspace_root(crate, on_dir)
		end

		-- rust-project.json is how a build system that is not cargo describes
		-- the crate graph, and is the only other thing rust-analyzer can read.
		local described = vim.fs.root(bufnr, { "rust-project.json" })
		if described then
			return on_dir(described)
		end

		-- Neither, so no project, and nothing to do here: not calling on_dir is
		-- how a config declines a buffer. Started anyway, rust-analyzer has no
		-- crate graph to work from and says so in an error popup, repeatedly,
		-- while answering nothing. There is no single-file mode left to fall
		-- back on either: rust-analyzer.detachedFiles was removed. A .rs file
		-- outside a cargo project keeps its treesitter highlighting, and the
		-- statusline shows rust_analyzer! for a server that is not there.
	end,
	settings = {
		["rust-analyzer"] = {
			cargo = {
				-- Its own target directory, at target/rust-analyzer. Sharing one
				-- with the terminal means whichever of the two got there first
				-- holds the lock, so a check on save leaves `cargo run` sitting on
				-- "Blocking waiting for file lock on build directory" and the other
				-- way round. The cost is a second set of artifacts on disk and the
				-- first check after a change being a cold one.
				targetDir = true,
			},
			check = {
				-- clippy is a superset of what plain `cargo check` reports, and it
				-- is one of the components lua/deps.lua installs, so this is not
				-- reaching for something that might not be there.
				command = "clippy",
			},
		},
	},
}
