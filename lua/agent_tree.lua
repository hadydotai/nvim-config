-- Pick what a new worktree needs by walking the project, rather than by
-- describing it.
--
-- The setup buffer takes glob patterns, which is the right thing to store and
-- the wrong thing to have to compose from memory. What you actually know is
-- "the agent will need that", and that is a place in the tree, so this is a
-- tree with two marks in it.
--
--   c        copy this
--   s        symlink this
--   <Space>  cycle none, copy, symlink
--   <CR>     open or close a directory
--   .        show everything, not only what a worktree would be missing
--
-- It opens filtered, showing the gitignored entries and the directories that
-- lead to them, because those are the only things a fresh checkout is actually
-- without. Everything else is one keypress away and is nearly always noise:
-- copying a tracked file into a worktree that already has it does nothing.

local M = {}

local ns = vim.api.nvim_create_namespace("agent_tree")

local MARKS = { copy = "c", symlink = "s" }

local buf, state

local function set_hl()
	local set = function(name, spec)
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
	end
	set("AgentTreeDir", { link = "Directory" })
	set("AgentTreeMissing", { link = "Normal" })
	set("AgentTreeTracked", { link = "Comment" })
	set("AgentTreeCopy", { link = "String" })
	set("AgentTreeSymlink", { link = "Constant" })
	set("AgentTreeHint", { link = "Comment" })
	set("AgentTreeTitle", { link = "Title" })
end

--------------------------------------------------------------------------- --
-- what the project is missing
--------------------------------------------------------------------------- --

--- Every path git is ignoring, which is every path a fresh worktree will not
--- have. Asked once when the tree opens: it walks the whole repository, and
--- the answer does not change while you are looking at it.
local function ignored_set(repo)
	local out = vim.system({
		"git",
		"ls-files",
		"--others",
		"--ignored",
		"--exclude-standard",
		"--directory",
	}, { cwd = repo, text = true }):wait()

	local set = {}
	for line in (out.stdout or ""):gmatch("[^\n]+") do
		local path = line:gsub("/+$", "")
		if path ~= "" then
			set[path] = true
		end
	end
	return set
end

--- Whether `path` is missing from a worktree: itself ignored, or inside
--- something that is. The ancestor walk is what makes a file deep inside
--- node_modules count without git having listed it one by one.
local function missing(path)
	local at = path
	while at ~= "" do
		if state.ignored[at] then
			return true
		end
		at = at:match("^(.*)/[^/]*$") or ""
	end
	return false
end

--- In filtered mode a directory earns its place by leading somewhere missing,
--- so the tree shows the route to a gitignored file without showing the rest
--- of the project on the way.
local function leads_to_missing(dir)
	local prefix = dir .. "/"
	for path in pairs(state.ignored) do
		if path:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function worth_showing(path, is_dir)
	if state.everything then
		return true
	end
	if missing(path) then
		return true
	end
	return is_dir and leads_to_missing(path)
end

--------------------------------------------------------------------------- --
-- the tree
--------------------------------------------------------------------------- --

--- One directory's entries, directories first, each already judged worth
--- showing. Read on demand: a repository with a big node_modules should not
--- pay for it unless you open it.
local function children(rel)
	local dir = rel == "" and state.repo or (state.repo .. "/" .. rel)
	local ok, entries = pcall(vim.fn.readdir, dir)
	if not ok then
		return {}
	end
	local out = {}
	for _, name in ipairs(entries) do
		if name ~= ".git" then
			local path = rel == "" and name or (rel .. "/" .. name)
			local is_dir = vim.fn.isdirectory(dir .. "/" .. name) == 1
			if worth_showing(path, is_dir) then
				out[#out + 1] = { path = path, name = name, dir = is_dir }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.dir ~= b.dir then
			return a.dir
		end
		return a.name < b.name
	end)
	return out
end

--- How `path` is currently marked, by matching the patterns the config stores.
--- Only an exact match counts: a hand-written glob like `*.local` genuinely
--- has no single place in the tree, and pretending one of its matches is "the"
--- entry would make unmarking it delete a pattern you did not pick here.
local function mark_of(path)
	for kind in pairs(MARKS) do
		for _, entry in ipairs(state.config[kind] or {}) do
			if entry.what == path then
				return kind, entry
			end
		end
	end
	return nil
end

local function set_mark(path, want)
	local kind, entry = mark_of(path)
	if kind then
		for i, other in ipairs(state.config[kind]) do
			if other == entry then
				table.remove(state.config[kind], i)
				break
			end
		end
	end
	if want and want ~= kind then
		table.insert(state.config[want], { what = path, on = true })
	end
	state.save()
end

--------------------------------------------------------------------------- --
-- drawing
--------------------------------------------------------------------------- --

local function build()
	local lines, spans, rows = {}, {}, {}

	local function add(text, span, row)
		lines[#lines + 1] = text
		spans[#lines] = span
		rows[#lines] = row
	end

	add("Pick what each new worktree needs", { { 0, -1, "AgentTreeTitle" } })
	add(
		state.everything and "everything in " .. vim.fn.fnamemodify(state.repo, ":t")
			or "what a worktree would be missing, in " .. vim.fn.fnamemodify(state.repo, ":t"),
		{ { 0, -1, "AgentTreeHint" } }
	)
	add("")

	local function walk(rel, depth)
		for _, node in ipairs(children(rel)) do
			local kind = mark_of(node.path)
			local open = state.open[node.path]
			local glyph = node.dir and (open and "v " or "> ") or "  "
			local text = ("[%s] %s%s%s"):format(
				kind and MARKS[kind] or " ",
				string.rep("  ", depth),
				glyph,
				node.name .. (node.dir and "/" or "")
			)
			local hl = kind == "copy" and "AgentTreeCopy"
				or kind == "symlink" and "AgentTreeSymlink"
				or node.dir and "AgentTreeDir"
				or missing(node.path) and "AgentTreeMissing"
				or "AgentTreeTracked"
			add(text, { { 0, 3, kind and hl or "AgentTreeHint" }, { 4, -1, hl } }, node)
			if node.dir and open then
				walk(node.path, depth + 1)
			end
		end
	end
	walk("", 0)

	if #rows == 0 or vim.tbl_isempty(rows) then
		add("  nothing here", { { 0, -1, "AgentTreeHint" } })
	end
	add("")
	add("  c copy   s symlink   <Space> cycle   <CR> open   . everything   q done", {
		{ 0, -1, "AgentTreeHint" },
	})
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
				end_col = one[2] < 0 and #lines[line] or math.min(one[2], #lines[line]),
				hl_group = one[3],
			})
		end
	end
end

local function at_cursor()
	return state.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Redraw without losing your place, since every key here redraws the whole
--- buffer and marking three things in a row should not walk the cursor home.
local function keep_place(fn)
	local win = vim.api.nvim_get_current_win()
	local line = vim.api.nvim_win_get_cursor(win)[1]
	fn()
	render()
	local count = vim.api.nvim_buf_line_count(buf)
	pcall(vim.api.nvim_win_set_cursor, win, { math.min(line, count), 0 })
end

local function keys(into)
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = into, silent = true, nowait = true, desc = desc })
	end

	local function mark(want)
		return function()
			local node = at_cursor()
			if not node then
				return
			end
			keep_place(function()
				local kind = mark_of(node.path)
				set_mark(node.path, kind ~= want and want or nil)
			end)
		end
	end

	map("c", mark("copy"), "Copy this into each worktree")
	map("s", mark("symlink"), "Symlink this into each worktree")

	map("<Space>", function()
		local node = at_cursor()
		if not node then
			return
		end
		keep_place(function()
			local kind = mark_of(node.path)
			set_mark(node.path, kind == nil and "copy" or kind == "copy" and "symlink" or nil)
		end)
	end, "Cycle none, copy, symlink")

	local function open()
		local node = at_cursor()
		if node and node.dir then
			keep_place(function()
				state.open[node.path] = not state.open[node.path] or nil
			end)
		end
	end
	map("<CR>", open, "Open or close this directory")
	map("o", open, "Open or close this directory")

	map(".", function()
		keep_place(function()
			state.everything = not state.everything
		end)
	end, "Show everything, not only what is missing")

	map("q", function()
		vim.cmd("close")
	end, "Done")
end

--- Open the tree for `repo`, writing marks into `config`. `save` is called
--- after every change so the setup buffer behind this one stays true.
function M.show(repo, config, save)
	set_hl()
	state = {
		repo = repo,
		config = config,
		save = save or function() end,
		ignored = ignored_set(repo),
		open = {},
		everything = false,
		rows = {},
	}

	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "agenttree"
		vim.bo[buf].modifiable = false
		keys(buf)
	end
	pcall(vim.api.nvim_buf_set_name, buf, "agent://worktree-files")

	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		vim.cmd("vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_width(win, 52)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].cursorline = true
		vim.wo[win].winfixwidth = true
	else
		vim.api.nvim_set_current_win(win)
	end
	render()
	pcall(vim.api.nvim_win_set_cursor, win, { 4, 0 })
end

return M
