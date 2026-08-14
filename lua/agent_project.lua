-- What a new worktree needs before an agent can work in it, per project, and
-- the buffer for saying so.
--
-- A fresh worktree is a clean checkout: correct, and useless. Everything a
-- project actually needs to build is gitignored on purpose, so the agent
-- arrives to no .env, no node_modules and no build cache, and its first act is
-- to discover the project does not run.
--
-- So each project gets a list of what to copy in, what to symlink, and what to
-- run afterwards. Copy for small files that should differ per worktree; symlink
-- for the large ones that should not be duplicated, which is the whole reason
-- both exist. It is stored under .state/, keyed by the path to the repository,
-- and it never leaves this directory.
--
--   <leader>aw   open the setup for this project
--
-- The completions are the point of the buffer. What you want to copy into a
-- worktree is almost always something git is ignoring, so that is exactly the
-- list you are completing against.

local M = {}

local STORE = vim.fn.stdpath("state") .. "/agents/projects"
local DEFAULTS = STORE .. "/defaults.json"
local ns = vim.api.nvim_create_namespace("agent_project")

--------------------------------------------------------------------------- --
-- the config
--------------------------------------------------------------------------- --

local function digest(path)
	return vim.fn.sha256(path):sub(1, 12)
end

local function path_for(repo)
	return ("%s/%s-%s.json"):format(STORE, vim.fn.fnamemodify(repo, ":t"), digest(repo))
end

local function read_json(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local ok, value = pcall(vim.json.decode, text)
	return ok and type(value) == "table" and value or nil
end

local function write_json(path, value)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(vim.json.encode(value))
	f:close()
	return true
end

local function blank()
	return { worktree_dir = "", copy = {}, symlink = {}, after = {} }
end

--- A project's setup. A project with none yet is seeded from the defaults
--- rather than inheriting from them: inheritance means every list is really
--- two lists and a rule about which wins, and this is a config you edit by
--- hand in a buffer where seeing exactly what will happen matters more than
--- not repeating yourself.
function M.load(repo)
	local config = read_json(path_for(repo))
	if not config then
		config = read_json(DEFAULTS) or blank()
	end
	for key, value in pairs(blank()) do
		if config[key] == nil then
			config[key] = value
		end
	end
	return config
end

function M.save(repo, config)
	return write_json(path_for(repo), config)
end

function M.save_defaults(config)
	return write_json(DEFAULTS, {
		worktree_dir = config.worktree_dir,
		copy = vim.deepcopy(config.copy),
		symlink = vim.deepcopy(config.symlink),
		after = vim.deepcopy(config.after),
	})
end

--- Where this project's worktrees go. `{project}` stands for the repository's
--- own name, so one setting can be shared by every project without them
--- landing on top of each other.
function M.worktree_dir(repo, config)
	config = config or M.load(repo)
	local dir = vim.trim(config.worktree_dir or "")
	if dir == "" then
		return ("%s/agents/worktrees/%s-%s"):format(vim.fn.stdpath("data"), vim.fn.fnamemodify(repo, ":t"), digest(repo))
	end
	dir = dir:gsub("{project}", vim.fn.fnamemodify(repo, ":t"))
	return vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("/$", "")
end

--------------------------------------------------------------------------- --
-- applying it
--------------------------------------------------------------------------- --

local function enabled(list)
	local out = {}
	for _, entry in ipairs(list or {}) do
		if entry.on ~= false and vim.trim(entry.what or "") ~= "" then
			out[#out + 1] = entry.what
		end
	end
	return out
end

--- Patterns are globs, resolved against the repository, and returned as paths
--- relative to it so they can be recreated at the same place in the worktree.
local function matches(repo, pattern)
	local out = {}
	for _, hit in ipairs(vim.fn.glob(repo .. "/" .. pattern, true, true)) do
		local rel = hit:sub(#repo + 2)
		if rel ~= "" then
			out[#out + 1] = rel
		end
	end
	return out
end

--- Put everything the project asked for into `dir`.
---
--- Nothing is overwritten. A worktree that has been worked in may have a .env
--- the agent changed on purpose, and re-running the setup is something you do
--- to fill in what is missing, not to undo work.
---
--- Returns what it did and what it could not do.
function M.apply(repo, dir, config)
	config = config or M.load(repo)
	local done, failed = {}, {}

	local function place(rel, how)
		local src = repo .. "/" .. rel
		local dst = dir .. "/" .. rel
		if vim.fn.empty(vim.fn.glob(dst)) == 0 then
			return
		end
		vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
		if how == "symlink" then
			local ok = vim.uv.fs_symlink(src, dst)
			table.insert(ok and done or failed, ("symlink %s"):format(rel))
		else
			-- cp -R rather than a Lua walk: it already knows about directories,
			-- permissions and links, and this runs once per worktree.
			local out = vim.system({ "cp", "-R", src, dst }, { text = true }):wait()
			table.insert(out.code == 0 and done or failed, ("copy %s"):format(rel))
		end
	end

	for _, how in ipairs({ "copy", "symlink" }) do
		for _, pattern in ipairs(enabled(config[how])) do
			local hits = matches(repo, pattern)
			if #hits == 0 then
				failed[#failed + 1] = ("%s %s (nothing matches)"):format(how, pattern)
			end
			for _, rel in ipairs(hits) do
				place(rel, how)
			end
		end
	end

	return done, failed
end

--- Run the project's after-creation commands in `dir`. Separate from apply and
--- asynchronous, because these are installs: they take minutes, and the agent
--- should be starting while they run rather than after.
function M.run_after(repo, dir, config, done)
	local commands = enabled((config or M.load(repo)).after)
	if #commands == 0 then
		return done and done(0)
	end
	local left, failed = #commands, 0
	for _, command in ipairs(commands) do
		vim.system({ "sh", "-c", command }, { cwd = dir, text = true }, function(out)
			failed = failed + (out.code == 0 and 0 or 1)
			left = left - 1
			if left == 0 and done then
				vim.schedule(function()
					done(failed)
				end)
			end
		end)
	end
end

--------------------------------------------------------------------------- --
-- completion
--------------------------------------------------------------------------- --

--- What a fresh worktree will be missing: everything git is ignoring. That is
--- almost exactly the list of things worth copying or linking, which is why it
--- is what the prompt completes against rather than every file in the project.
function _G._agent_ignored(lead)
	local repo = require("agent_worktree").repo()
	if not repo then
		return {}
	end
	local out = vim.system({
		"git",
		"ls-files",
		"--others",
		"--ignored",
		"--exclude-standard",
		"--directory",
	}, { cwd = repo, text = true }):wait()

	local seen, candidates = {}, {}
	for line in (out.stdout or ""):gmatch("[^\n]+") do
		local entry = line:gsub("/$", "")
		if entry ~= "" and not seen[entry] then
			seen[entry] = true
			candidates[#candidates + 1] = entry
		end
	end
	-- Common cases that are ignored by a parent rule and so never listed one
	-- by one, plus anything already typed.
	for _, extra in ipairs({ ".env", ".env.local", "node_modules", ".envrc" }) do
		if not seen[extra] and vim.fn.empty(vim.fn.glob(repo .. "/" .. extra)) == 0 then
			candidates[#candidates + 1] = extra
		end
	end
	table.sort(candidates)
	return vim.tbl_filter(function(entry)
		return entry:find(lead, 1, true) == 1
	end, candidates)
end

--------------------------------------------------------------------------- --
-- the buffer
--------------------------------------------------------------------------- --

local buf, state

local function set_hl()
	local set = function(name, spec)
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
	end
	set("AgentSection", { link = "Title" })
	set("AgentOn", { link = "String" })
	set("AgentOff", { link = "Comment" })
	set("AgentHint", { link = "Comment" })
	set("AgentPath", { link = "Normal" })
end

local SECTIONS = {
	{ key = "copy", title = "Copy into each new worktree", hint = "small files that should differ per worktree" },
	{ key = "symlink", title = "Symlink into each new worktree", hint = "big things that should not be duplicated" },
	{ key = "after", title = "Run after creating one", hint = "installs, migrations, anything that takes a while" },
}

--- Lines, the highlights for them, and what each line refers to so the keys
--- know what they are acting on.
local function build()
	local lines, spans, rows = {}, {}, {}

	local function add(text, span, row)
		lines[#lines + 1] = text
		spans[#lines] = span
		rows[#lines] = row
	end

	add(("Worktree setup for %s"):format(vim.fn.fnamemodify(state.repo, ":t")), { { 0, -1, "AgentSection" } })
	add(state.repo, { { 0, -1, "AgentHint" } })
	add("")
	add("  Worktrees go in", { { 0, -1, "AgentSection" } })
	local dir = vim.trim(state.config.worktree_dir or "")
	add(
		("    %s"):format(dir ~= "" and dir or M.worktree_dir(state.repo, state.config) .. "   (default)"),
		{ { 0, -1, dir ~= "" and "AgentPath" or "AgentOff" } },
		{ kind = "dir" }
	)

	for _, section in ipairs(SECTIONS) do
		add("")
		add("  " .. section.title, { { 0, -1, "AgentSection" } })
		add("  " .. section.hint, { { 0, -1, "AgentHint" } })
		local list = state.config[section.key]
		if #list == 0 then
			add("    nothing yet, press a to add", { { 0, -1, "AgentOff" } }, { kind = "empty", section = section.key })
		end
		for i, entry in ipairs(list) do
			local on = entry.on ~= false
			add(
				("    [%s] %s"):format(on and "x" or " ", entry.what),
				{ { 0, -1, on and "AgentOn" or "AgentOff" } },
				{ kind = "entry", section = section.key, index = i }
			)
		end
	end

	add("")
	local n = #require("agent_worktree").list(state.repo, state.config)
	add(("  %d worktree%s for this project"):format(n, n == 1 and "" or "s"), { { 0, -1, "AgentHint" } })
	add("")
	add("  a pick from the tree   A type a pattern   e edit   d delete", { { 0, -1, "AgentHint" } })
	add("  <Space> on/off   s sync all   g save as defaults   q close", { { 0, -1, "AgentHint" } })

	return lines, spans, rows
end

local function render()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local lines, spans, rows = build()
	state.rows = rows
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for line, span in pairs(spans) do
		for _, one in ipairs(span) do
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, one[1], {
				end_col = one[2] < 0 and #lines[line] or one[2],
				hl_group = one[3],
			})
		end
	end
end

local function save()
	M.save(state.repo, state.config)
	render()
end

--- The row under the cursor, or the section it belongs to.
local function at_cursor()
	return state.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Which section the cursor is in, so `a` adds to the list you are looking at
--- rather than asking which one you meant.
local function section_at_cursor()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	for i = line, 1, -1 do
		local row = state.rows[i]
		if row and row.section then
			return row.section
		end
	end
	return nil
end

local function ask(prompt, default, completion, done)
	vim.ui.input({ prompt = prompt, default = default, completion = completion }, function(text)
		if text and vim.trim(text) ~= "" then
			done(vim.trim(text))
		end
	end)
end

local function keys(into)
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = into, silent = true, nowait = true, desc = desc })
	end

	map("a", function()
		local row = at_cursor()
		if row and row.kind == "dir" then
			return ask("Worktrees go in ({project} for the name): ", "", "dir", function(text)
				state.config.worktree_dir = text
				save()
			end)
		end
		-- Walking the project beats describing it, so a and s open the tree
		-- for the two lists that name files. Commands have nowhere to point at.
		if section_at_cursor() == "after" then
			return ask("Run after creating a worktree: ", "", "shellcmd", function(text)
				table.insert(state.config.after, { what = text, on = true })
				save()
			end)
		end
		require("agent_tree").show(state.repo, state.config, save)
	end, "Pick files from the project tree")

	map("A", function()
		local key = section_at_cursor()
		if not key then
			return
		end
		local completion = key == "after" and "shellcmd" or "customlist,v:lua._agent_ignored"
		ask(("Add to %s: "):format(key), "", completion, function(text)
			table.insert(state.config[key], { what = text, on = true })
			save()
		end)
	end, "Add an entry by typing a pattern")

	map("e", function()
		local row = at_cursor()
		if row and row.kind == "dir" then
			return ask("Worktrees go in: ", state.config.worktree_dir, "dir", function(text)
				state.config.worktree_dir = text
				save()
			end)
		end
		if not row or row.kind ~= "entry" then
			return
		end
		local entry = state.config[row.section][row.index]
		local completion = row.section == "after" and "shellcmd" or "customlist,v:lua._agent_ignored"
		ask("Edit: ", entry.what, completion, function(text)
			entry.what = text
			save()
		end)
	end, "Edit this entry")

	map("d", function()
		local row = at_cursor()
		if row and row.kind == "dir" then
			state.config.worktree_dir = ""
			return save()
		end
		if row and row.kind == "entry" then
			table.remove(state.config[row.section], row.index)
			save()
		end
	end, "Delete this entry")

	map("<Space>", function()
		local row = at_cursor()
		if row and row.kind == "entry" then
			local entry = state.config[row.section][row.index]
			entry.on = entry.on == false
			save()
		end
	end, "Turn this entry on or off")

	map("g", function()
		M.save_defaults(state.config)
		vim.notify("agent: saved as the defaults for projects with no setup yet")
	end, "Save this as the default for new projects")

	map("s", M.sync, "Apply this to every existing worktree")

	map("q", function()
		vim.cmd("close")
	end, "Close")
end

--- Re-apply the setup to every worktree this project already has, which is
--- what you want the moment you add something to the list and remember the
--- three agents already running do not have it.
function M.sync()
	local repo, config = state.repo, state.config
	local dirs = require("agent_worktree").list(repo, config)
	if #dirs == 0 then
		return vim.notify("agent: no worktrees for this project yet")
	end
	local added, problems = 0, {}
	for _, dir in ipairs(dirs) do
		local done, failed = M.apply(repo, dir, config)
		added = added + #done
		vim.list_extend(problems, failed)
	end
	local said = ("agent: %d thing%s put into %d worktree%s"):format(
		added,
		added == 1 and "" or "s",
		#dirs,
		#dirs == 1 and "" or "s"
	)
	if #problems > 0 then
		said = said .. "\n" .. table.concat(problems, "\n")
	end
	vim.notify(said, #problems > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
	render()
end

function M.show()
	local repo = require("agent_worktree").repo()
	if not repo then
		return vim.notify("agent: not a git repository", vim.log.levels.WARN)
	end
	set_hl()
	state = { repo = repo, config = M.load(repo), rows = {} }

	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "agentsetup"
		vim.bo[buf].modifiable = false
		keys(buf)
	end
	pcall(vim.api.nvim_buf_set_name, buf, "agent://worktree-setup")

	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		vim.cmd("botright vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_width(win, 64)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].cursorline = true
		vim.wo[win].winfixwidth = true
	else
		vim.api.nvim_set_current_win(win)
	end
	render()
end

vim.keymap.set("n", "<leader>aw", M.show, {
	silent = true,
	desc = "Worktree setup for this project: what to copy, symlink and run",
})

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

return M
