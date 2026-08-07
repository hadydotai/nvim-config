-- What this configuration needs from the machine it is running on, and how to
-- get it on each of them.
--
-- Two kinds of dependency, and the split matters:
--
--   system   A C compiler, git, curl, node, python. These have to come from the
--            OS package manager and generally want sudo, so the command differs
--            per platform and we cannot keep them inside the config directory.
--
--   local    tree-sitter, lua-language-server, pylsp, tsgo. These are ours, not
--            the system's, so they are fetched straight from upstream into the
--            config directory (see paths.lua) with no sudo and no package
--            manager. That means one recipe for every platform instead of
--            three, and it sidesteps distributions shipping a tree-sitter CLI
--            far older than nvim-treesitter needs: Ubuntu 24.04 still has
--            0.20.7 against a floor of 0.26.1.
--
-- :Deps          show what is present and what is missing
-- :Deps install  install everything missing, in a terminal so sudo can prompt

local M = {}

local DATA = vim.fn.stdpath("data")
local BIN = DATA .. "/bin"

--------------------------------------------------------------------------- --
-- platform
--------------------------------------------------------------------------- --

local function read_os_release()
	local f = io.open("/etc/os-release")
	if not f then
		return ""
	end
	local text = f:read("*a")
	f:close()
	return text
end

local function field(text, key)
	-- anchored to a line start so VERSION_ID cannot answer a query for ID
	return text:match("\n" .. key .. '="?([^"\n]+)') or text:match("^" .. key .. '="?([^"\n]+)')
end

--- "mac", "debian" (also Ubuntu and WSL Ubuntu), "arch" (also CachyOS), or nil.
--- Takes its inputs as arguments so the mapping can be tested from any machine;
--- both default to this one.
--- @param sysname? string value of uname -s
--- @param release? string contents of /etc/os-release
function M.platform(sysname, release)
	sysname = sysname or vim.uv.os_uname().sysname
	if sysname == "Darwin" then
		return "mac"
	end
	if sysname ~= "Linux" then
		return nil
	end
	-- ID_LIKE is what makes derivatives work without naming every one: CachyOS
	-- reports ID=cachyos ID_LIKE=arch, Ubuntu reports ID=ubuntu ID_LIKE=debian.
	release = release or read_os_release()
	local ids = (field(release, "ID") or "") .. " " .. (field(release, "ID_LIKE") or "")
	if ids:find("arch", 1, true) then
		return "arch"
	end
	if ids:find("debian", 1, true) or ids:find("ubuntu", 1, true) then
		return "debian"
	end
	return nil
end

local function cpu()
	local machine = vim.uv.os_uname().machine
	return (machine == "arm64" or machine == "aarch64") and "arm64" or "x64"
end

--------------------------------------------------------------------------- --
-- recipes
--------------------------------------------------------------------------- --

local SYSTEM = {
	mac = {
		build = "xcode-select --install || true",
		node = "brew install node",
		python = "brew install python",
	},
	debian = {
		build = "sudo apt-get update && sudo apt-get install -y build-essential git curl",
		node = "sudo apt-get install -y nodejs npm",
		python = "sudo apt-get install -y python3 python3-venv",
	},
	arch = {
		build = "sudo pacman -S --needed --noconfirm base-devel git curl",
		node = "sudo pacman -S --needed --noconfirm nodejs npm",
		python = "sudo pacman -S --needed --noconfirm python",
	},
}

local function tree_sitter_cmd()
	-- upstream names the darwin builds "macos" here and "darwin" in luals below
	local url = ("https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-%s-%s.gz"):format(
		M.platform() == "mac" and "macos" or "linux",
		cpu()
	)
	return table.concat({
		("mkdir -p %s"):format(BIN),
		("curl -fsSL %s -o %s/tree-sitter.gz"):format(url, BIN),
		("gzip -df %s/tree-sitter.gz"):format(BIN),
		("chmod +x %s/tree-sitter"):format(BIN),
	}, " && ")
end

local function lua_ls_cmd()
	-- The asset name embeds the version, so the tag has to be resolved first.
	local os_name = M.platform() == "mac" and "darwin" or "linux"
	local dir = DATA .. "/lua-language-server"
	return table.concat({
		('tag=$(curl -fsSL https://api.github.com/repos/LuaLS/lua-language-server/releases/latest'
			.. ' | sed -n \'s/.*"tag_name": *"\\([^"]*\\)".*/\\1/p\' | head -1)'),
		("rm -rf %s && mkdir -p %s %s"):format(dir, dir, BIN),
		('curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/'
			.. '$tag/lua-language-server-$tag-%s-%s.tar.gz" -o /tmp/lua-language-server.tar.gz'):format(os_name, cpu()),
		("tar -xzf /tmp/lua-language-server.tar.gz -C %s"):format(dir),
		-- A wrapper rather than a symlink. lua-language-server is a compiled
		-- binary that loads its main.lua from the directory of its own argv[0],
		-- so a symlink in bin/ sends it looking for bin/main.lua and it dies.
		("printf '#!/bin/sh\\nexec \"%s/bin/lua-language-server\" \"$@\"\\n' > %s/lua-language-server"):format(
			dir,
			BIN
		),
		("chmod +x %s/lua-language-server"):format(BIN),
	}, " && ")
end

local function pylsp_cmd()
	return ("python3 -m venv %s/venv && %s/venv/bin/pip install --quiet --upgrade python-lsp-server"):format(DATA, DATA)
end

local function tsgo_cmd()
	return ("mkdir -p %s/node && npm install --silent --prefix %s/node @typescript/native-preview"):format(DATA, DATA)
end

--------------------------------------------------------------------------- --
-- the list
--------------------------------------------------------------------------- --

local DEPS = {
	{ bin = "cc", why = "compiles treesitter parsers", system = "build" },
	{ bin = "git", why = "fetches plugins for vim.pack", system = "build" },
	{ bin = "curl", why = "downloads parsers and language servers", system = "build" },
	{ bin = "npm", why = "installs the typescript language server", system = "node" },
	{ bin = "python3", why = "runs the python language server", system = "python" },
	{ bin = "tree-sitter", why = "builds treesitter parsers", get = tree_sitter_cmd },
	{ bin = "lua-language-server", why = "lua language server", get = lua_ls_cmd },
	{ bin = "pylsp", why = "python language server", get = pylsp_cmd, after = "python3" },
	{ bin = "tsgo", why = "typescript language server", get = tsgo_cmd, after = "npm" },
}

--- Every dependency with an `ok` flag and the command that would provide it.
--- The command is nil when we have no recipe for this platform.
-- bin -> can it actually run, filled in by M.check() and kept for the session
local probed = nil

local function present(bin)
	if probed then
		return probed[bin] == true
	end
	return vim.fn.executable(bin) == 1
end

--- Work out what actually runs, as opposed to what merely resolves on $PATH.
--- The difference is the whole point: a pyenv or asdf shim is executable and
--- exepath() finds it, but running it prints "command not found" and exits 127
--- unless the active version happens to have the tool installed. From the
--- outside that is indistinguishable from a language server dying for no
--- reason, which is exactly the thing this file exists to prevent.
---
--- Asynchronous, because it spawns every dependency once, and cached.
function M.check(done)
	if probed then
		return done(probed)
	end
	local results, left = {}, #DEPS
	local function finish()
		left = left - 1
		if left == 0 then
			probed = results
			-- vim.system calls back from libuv, where most of the API is off
			-- limits, so hand the result to the caller on the main loop
			vim.schedule(function()
				done(results)
			end)
		end
	end
	for _, dep in ipairs(DEPS) do
		if vim.fn.executable(dep.bin) == 0 then
			results[dep.bin] = false
			finish()
		else
			vim.system({ dep.bin, "--version" }, { text = true, timeout = 10000 }, function(out)
				results[dep.bin] = out.code == 0
				finish()
			end)
		end
	end
end

function M.status()
	local platform = M.platform()
	local out = {}
	for _, dep in ipairs(DEPS) do
		local command
		if dep.system then
			command = platform and SYSTEM[platform][dep.system] or nil
		else
			command = dep.get()
		end
		out[#out + 1] = {
			bin = dep.bin,
			why = dep.why,
			ok = present(dep.bin),
			kind = dep.system and "system" or "local",
			after = dep.after,
			command = command,
		}
	end
	return out
end

function M.missing()
	return vim.tbl_filter(function(dep)
		return not dep.ok
	end, M.status())
end

--------------------------------------------------------------------------- --
-- ui
--------------------------------------------------------------------------- --

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "DepsOk", { link = "DiagnosticOk", default = true })
	hl(0, "DepsMissing", { link = "DiagnosticError", default = true })
	hl(0, "DepsName", { link = "Special", default = true })
	hl(0, "DepsWhy", { link = "Comment", default = true })
end

local function show()
	local status = M.status()
	local platform = M.platform() or "unknown"
	local lines, marks = {}, {}

	local width = 0
	for _, dep in ipairs(status) do
		width = math.max(width, #dep.bin)
	end

	lines[1] = ("platform: %s  (%s)"):format(platform, cpu())
	marks[1] = { { 0, #lines[1], "DepsWhy" } }
	lines[2] = ""
	marks[2] = {}

	for _, dep in ipairs(status) do
		local mark = dep.ok and "ok     " or "missing"
		local line = ("  %s  %-" .. width .. "s  %-7s  %s"):format(mark, dep.bin, dep.kind, dep.why)
		lines[#lines + 1] = line
		marks[#lines] = {
			{ 2, 2 + #mark, dep.ok and "DepsOk" or "DepsMissing" },
			{ 11, 11 + #dep.bin, "DepsName" },
			{ #line - #dep.why, #line, "DepsWhy" },
		}
	end

	local gone = M.missing()
	lines[#lines + 1] = ""
	marks[#lines] = {}
	local footer = #gone == 0 and "  everything is present"
		or ("  %d missing, run :Deps install"):format(#gone)
	lines[#lines + 1] = footer
	marks[#lines] = { { 0, #footer, #gone == 0 and "DepsOk" or "DepsMissing" } }

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	local win_width = 0
	for _, l in ipairs(lines) do
		win_width = math.max(win_width, #l + 2)
	end

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = math.min(win_width, vim.o.columns - 4),
		height = #lines,
		row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 2),
		col = math.max(0, math.floor((vim.o.columns - win_width) / 2)),
		style = "minimal",
		border = "rounded",
		title = " Dependencies ",
		footer = " q close ",
		footer_pos = "right",
	})
	vim.wo[win].winhighlight = "Normal:NormalFloat"

	local ns = vim.api.nvim_create_namespace("deps_view")
	for lnum, spans in pairs(marks) do
		for _, span in ipairs(spans) do
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, span[1], {
				end_col = span[2],
				hl_group = span[3],
			})
		end
	end

	for _, lhs in ipairs({ "q", "<Esc>", "<CR>" }) do
		require("keys").untracked("n", lhs, function()
			pcall(vim.api.nvim_win_close, win, true)
		end, { buffer = buf, nowait = true, silent = true })
	end
end

--- Install everything missing, in a terminal so sudo and npm can talk to you.
local function install()
	local gone = M.missing()
	if #gone == 0 then
		vim.notify("deps: nothing missing", vim.log.levels.INFO)
		return
	end

	local script, skipped = {}, {}
	for _, dep in ipairs(gone) do
		if not dep.command then
			skipped[#skipped + 1] = dep.bin
		else
			script[#script + 1] = ("echo '==> %s'"):format(dep.bin)
			script[#script + 1] = dep.command
		end
	end

	if #skipped > 0 then
		-- Say so rather than silently installing a subset.
		vim.notify(
			("deps: no recipe on this platform for %s"):format(table.concat(skipped, ", ")),
			vim.log.levels.WARN
		)
	end
	if #script == 0 then
		return
	end

	script[#script + 1] = "echo '==> done, restart nvim'"
	vim.cmd("botright new")
	vim.fn.jobstart({ "sh", "-c", table.concat(script, "\n") }, { term = true })
	vim.cmd("startinsert")
end

function M.setup()
	set_hl()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("DepsHighlight", { clear = true }),
		callback = set_hl,
	})

	vim.api.nvim_create_user_command("Deps", function(opts)
		-- through check() so both views report what runs, not what resolves
		M.check(function()
			if opts.args == "install" then
				install()
			else
				show()
			end
		end)
	end, {
		nargs = "?",
		complete = function()
			return { "install" }
		end,
		desc = "Show or install this configuration's system dependencies",
	})

	-- One quiet line at startup when something is missing, rather than letting
	-- a language server fail with exit code 127 and no explanation.
	vim.api.nvim_create_autocmd("VimEnter", {
		group = vim.api.nvim_create_augroup("DepsCheck", { clear = true }),
		once = true,
		callback = function()
			vim.defer_fn(function()
				M.check(function()
					local gone = M.missing()
					if #gone == 0 then
						return
					end
					local names = vim.tbl_map(function(dep)
						return dep.bin
					end, gone)
					vim.notify(
						("deps: missing %s -- run :Deps"):format(table.concat(names, ", ")),
						vim.log.levels.WARN
					)
				end)
			end, 200)
		end,
	})
end

return M
