-- What this configuration needs from the machine it is running on, and how to
-- get it on each of them.
--
-- Two kinds of dependency, and the split matters:
--
--   system   A C compiler, git, curl, node, python. These have to come from the
--            OS package manager and generally want sudo, so the command differs
--            per platform and we cannot keep them inside the config directory.
--
--   local    tree-sitter, lua-language-server, pylsp, tsgo, gopls,
--            rust-analyzer.
--            These are ours, not the system's, so they are fetched straight
--            from upstream into the config directory (see paths.lua) with no
--            sudo and no package manager. That means one recipe for every
--            platform instead of three, and it sidesteps distributions
--            shipping a tree-sitter CLI far older than nvim-treesitter needs:
--            Ubuntu 24.04 still has 0.20.7 against a floor of 0.26.1.
--            rust-analyzer is the one exception to the "into this directory"
--            half of that; the comment above its recipe says why.
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

-- Matched in order, so a distribution naming several of these in ID_LIKE gets
-- the first that fits rather than whichever the table happened to iterate to.
local FAMILIES = {
	{ "arch", { "arch" } },
	{ "debian", { "debian", "ubuntu" } },
	{ "fedora", { "fedora", "rhel", "centos" } },
	{ "suse", { "suse" } },
	{ "alpine", { "alpine" } },
}

--- "mac", or the Linux family: "debian" (also Ubuntu and WSL Ubuntu), "arch"
--- (also CachyOS), "fedora" (also RHEL and CentOS), "suse", "alpine". nil when
--- it is something we have no recipes for.
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
	for _, family in ipairs(FAMILIES) do
		for _, id in ipairs(family[2]) do
			if ids:find(id, 1, true) then
				return family[1]
			end
		end
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

-- Every mac recipe below goes through Homebrew, which a mac does not come
-- with. Without this the first thing :Deps install does on a new machine is
-- print "brew: command not found" three times and call it a day. The second
-- line is not redundant: the installer does not put brew on the PATH of the
-- shell that ran it, so a fresh install is still invisible to the next command.
local BREW = table.concat({
	'command -v brew >/dev/null 2>&1 ||'
		.. ' /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/brew/HEAD/install.sh)"',
	'command -v brew >/dev/null 2>&1 ||'
		.. ' eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"',
}, " && ")

local function brew(package)
	return BREW .. " && brew install " .. package
end

local SYSTEM = {
	mac = {
		-- the compiler comes from the command line tools, not from Homebrew
		build = "xcode-select --install || true",
		node = brew("node"),
		python = brew("python"),
		go = brew("go"),
	},
	debian = {
		build = "sudo apt-get update && sudo apt-get install -y build-essential git curl",
		node = "sudo apt-get install -y nodejs npm",
		python = "sudo apt-get install -y python3 python3-venv",
		go = "sudo apt-get install -y golang-go",
	},
	arch = {
		build = "sudo pacman -S --needed --noconfirm base-devel git curl",
		node = "sudo pacman -S --needed --noconfirm nodejs npm",
		python = "sudo pacman -S --needed --noconfirm python",
		go = "sudo pacman -S --needed --noconfirm go",
	},
	fedora = {
		build = "sudo dnf install -y --setopt=install_weak_deps=False gcc gcc-c++ make git curl",
		node = "sudo dnf install -y nodejs npm",
		python = "sudo dnf install -y python3 python3-pip",
		go = "sudo dnf install -y golang",
	},
	suse = {
		build = "sudo zypper install -y gcc gcc-c++ make git curl",
		node = "sudo zypper install -y nodejs npm",
		python = "sudo zypper install -y python3 python3-pip",
		go = "sudo zypper install -y go",
	},
	alpine = {
		build = "sudo apk add --no-cache build-base git curl",
		node = "sudo apk add --no-cache nodejs npm",
		python = "sudo apk add --no-cache python3 py3-pip",
		go = "sudo apk add --no-cache go",
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

--- The musl build on Linux rather than the gnu one: it is statically linked, so
--- it does not care which glibc the distribution shipped, and this is a binary
--- we drop in rather than one a package manager keeps in step.
local function ripgrep_cmd()
	local target
	if M.platform() == "mac" then
		target = (cpu() == "arm64" and "aarch64" or "x86_64") .. "-apple-darwin"
	else
		target = (cpu() == "arm64" and "aarch64" or "x86_64") .. "-unknown-linux-musl"
	end
	-- as with lua-language-server, the asset name embeds the version, so the
	-- tag has to be resolved before there is a URL to fetch
	return table.concat({
		'tag=$(curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest'
			.. ' | sed -n \'s/.*"tag_name": *"\\([^"]*\\)".*/\\1/p\' | head -1)',
		("mkdir -p %s"):format(BIN),
		('curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/$tag/ripgrep-$tag-%s.tar.gz"'):format(
			target
		) .. " -o /tmp/ripgrep.tar.gz",
		"rm -rf /tmp/ripgrep-unpack && mkdir -p /tmp/ripgrep-unpack",
		"tar -xzf /tmp/ripgrep.tar.gz -C /tmp/ripgrep-unpack --strip-components=1",
		("cp /tmp/ripgrep-unpack/rg %s/rg"):format(BIN),
		("chmod +x %s/rg"):format(BIN),
	}, " && ")
end

local function pylsp_cmd()
	return ("python3 -m venv %s/venv && %s/venv/bin/pip install --quiet --upgrade python-lsp-server"):format(DATA, DATA)
end

local function tsgo_cmd()
	return ("mkdir -p %s/node && npm install --silent --prefix %s/node @typescript/native-preview"):format(DATA, DATA)
end

--- GOBIN rather than a plain `go install`, which would put it in $GOPATH/bin.
--- That directory is not on $PATH on a machine that has not been set up for Go
--- development, and a language server nvim cannot see is the same as one that
--- is not installed. Pointed here it lands beside the others, and paths.lua has
--- already put this directory on the PATH nvim runs things with.
local function gopls_cmd()
	return ("mkdir -p %s && GOBIN=%s go install golang.org/x/tools/gopls@latest"):format(BIN, BIN)
end

--- The one local dependency that does not land in .data/, because rust-analyzer
--- on its own is not much use: it needs cargo to read the project and the
--- rust-src component to say anything at all about the standard library, and
--- what keeps those three at one version, including the version a project pins
--- in rust-toolchain.toml, is rustup. So rustup gets installed if it is
--- missing, which is still one command on every platform and still no sudo, and
--- the analyzer comes from there rather than from a release tarball that would
--- drift away from the toolchain underneath it.
local function rust_analyzer_cmd()
	return table.concat({
		"command -v rustup >/dev/null 2>&1 ||"
			.. " { curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
			.. ' && . "$HOME/.cargo/env"; }',
		"rustup component add rust-analyzer rust-src",
	}, " && ")
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
	-- `go version`, not `go --version`: the go tools spell it as a subcommand and
	-- exit 2 on the flag, which the probe below would read as a missing tool.
	{
		bin = "go",
		why = "builds the go language server, and gopls reads the project with it",
		system = "go",
		probe = "version",
	},
	{ bin = "tree-sitter", why = "builds treesitter parsers", get = tree_sitter_cmd },
	{ bin = "rg", why = "greps the project for <leader>g", get = ripgrep_cmd },
	{ bin = "lua-language-server", why = "lua language server", get = lua_ls_cmd },
	{ bin = "pylsp", why = "python language server", get = pylsp_cmd, after = "python3" },
	{ bin = "tsgo", why = "typescript language server", get = tsgo_cmd, after = "npm" },
	{ bin = "gopls", why = "go language server", get = gopls_cmd, after = "go", probe = "version" },
	{ bin = "rust-analyzer", why = "rust language server", get = rust_analyzer_cmd },
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
			vim.system({ dep.bin, dep.probe or "--version" }, { text = true, timeout = 10000 }, function(out)
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

--- Missing dependencies in an order that can actually be installed: a thing
--- named in another's `after` goes first. The list order already happens to
--- satisfy this, which is exactly why it is worth doing on purpose, since
--- nothing would notice the day it stopped.
local function ordered(gone)
	local pending, out = {}, {}
	for _, dep in ipairs(gone) do
		pending[dep.bin] = true
	end
	local left = vim.deepcopy(gone)
	while #left > 0 do
		local moved = false
		for i, dep in ipairs(left) do
			if not (dep.after and pending[dep.after]) then
				out[#out + 1] = dep
				pending[dep.bin] = nil
				table.remove(left, i)
				moved = true
				break
			end
		end
		if not moved then
			-- a cycle, which is a bug in the list rather than in the machine
			vim.list_extend(out, left)
			break
		end
	end
	return out
end

--- Install everything missing, in a terminal so sudo and npm can talk to you.
local function install()
	local gone = M.missing()
	if #gone == 0 then
		vim.notify("deps: nothing missing", vim.log.levels.INFO)
		return
	end

	local script, skipped = { "failed=" }, {}
	for _, dep in ipairs(ordered(gone)) do
		if not dep.command then
			skipped[#skipped + 1] = dep.bin
		else
			script[#script + 1] = ("echo; echo '==> %s'"):format(dep.bin)
			-- Each recipe is one && chain, so `if` around it is enough to tell a
			-- step that worked from one that did not. Without this a failure
			-- scrolls past inside a wall of package manager output and the run
			-- still ends by announcing it is done.
			script[#script + 1] = ("if %s; then echo '<== %s ok'; else echo '<== %s FAILED'; failed=\"$failed %s\"; fi"):format(
				dep.command,
				dep.bin,
				dep.bin,
				dep.bin
			)
		end
	end

	if #skipped > 0 then
		-- Say so rather than silently installing a subset.
		vim.notify(
			("deps: no recipe on this platform for %s"):format(table.concat(skipped, ", ")),
			vim.log.levels.WARN
		)
	end
	if #script == 1 then
		return
	end

	script[#script + 1] = 'echo; if [ -n "$failed" ]; then echo "==> failed:$failed"; else echo "==> all installed"; fi'
	vim.cmd("botright new")
	vim.fn.jobstart({ "sh", "-c", table.concat(script, "\n") }, {
		term = true,
		-- What was probed is what was true before any of this ran, and it is
		-- cached for the session, so :Deps would go on reporting the old answer
		-- and the only advice left would be to restart nvim.
		on_exit = function()
			probed = nil
		end,
	})
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
