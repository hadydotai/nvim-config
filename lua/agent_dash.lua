-- Every agent, in a buffer: what it is, what it is doing, how long it has been
-- doing it, and what it has changed. Then every worktree of this project whose
-- agent is gone, because the checkout outlives the process that made it.
--
-- That second half is the reason this is a list of places rather than a list of
-- processes. An agent dies when Neovim quits; the branch and the worktree it
-- was working in do not, and a dashboard that showed only what is running would
-- lose track of a dozen checkouts holding real work. So a row is a piece of
-- work: with an agent on it, or waiting for one.
--
-- A buffer rather than a floating dialog because this is something you leave
-- open and glance at, and because a window you can split, move and close with
-- the keys you already know beats a bespoke one. It is a normal scratch buffer
-- with normal mappings.
--
--   <CR>   open it: the agent's terminal, or the worktree itself
--   i      type a line to that agent without leaving the dashboard
--   a      start an agent, in that worktree when the cursor is on one
--   s      stop it
--   x      drop it: forget an agent that has exited, remove a worktree
--   q      close the dashboard
--
-- The rows redraw on every change and once a second besides, because elapsed
-- time is on screen and nothing fires an event when a second passes.

local M = {}

local agent = require("agent")
local win_pick = require("win_pick")
local worktree = require("agent_worktree")

local NAME = "agent://dashboard"
local ns = vim.api.nvim_create_namespace("agent_dash")

-- Shape as well as colour, so the state survives a colourscheme where two of
-- these land close together, and reads at a glance in a narrow sidebar.
local MARK = {
	starting = { "-", "AgentIdle" },
	working = { "●", "AgentWorking" },
	waiting = { "?", "AgentWaiting" },
	idle = { "○", "AgentIdle" },
	exited = { "x", "AgentExited" },
	-- A worktree with nobody in it. Dimmer than any agent state, since the row
	-- is there to be remembered rather than watched.
	spare = { "·", "AgentExited" },
}

local buf, unwatch

local function set_hl()
	local set = function(name, spec)
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
	end
	set("AgentWorking", { link = "DiagnosticInfo" })
	set("AgentWaiting", { link = "DiagnosticWarn" })
	set("AgentIdle", { link = "Comment" })
	set("AgentExited", { link = "NonText" })
	set("AgentRunName", { link = "Normal" })
	set("AgentMeta", { link = "Comment" })
	set("AgentAdded", { link = "DiffAdd" })
	set("AgentRemoved", { link = "DiffDelete" })
end

--------------------------------------------------------------------------- --
-- rows
--------------------------------------------------------------------------- --

--- Ask git what has changed in a checkout, at most this often. Redrawing
--- happens once a second and the answer moves far more slowly than that, so
--- without a throttle this would be two git processes per row per second for a
--- number that changes every few minutes.
local STAT_EVERY = 4

--- And ask which worktrees exist at most this often. Slower again: a worktree
--- appears when you make one and not otherwise.
local TREES_EVERY = 5

--- Kept on the record it describes, whether that is a run or a worktree, so a
--- row that is both does not ask twice.
local function refresh_stat(rec, dir, base)
	if not dir or not base or rec.stat_busy then
		return
	end
	local now = os.time()
	if rec.stat_at and now - rec.stat_at < STAT_EVERY then
		return
	end
	rec.stat_at, rec.stat_busy = now, true
	worktree.stat(dir, base, function(stat)
		rec.stat_busy = false
		rec.stat = stat
	end)
end

--- The repository the dashboard is about: the one you are working in. Cached
--- per directory because finding it is a git process, and this is asked for on
--- the redraw path.
local repos = {}
local function repo()
	local cwd = vim.fn.getcwd()
	if repos[cwd] == nil then
		repos[cwd] = worktree.repo(cwd) or false
	end
	return repos[cwd] or nil
end

--- This project's worktrees, refreshed on a timer and kept by path, so the
--- fork point and diff already worked out for one survive the next listing.
local trees, trees_at, trees_busy, known = {}, nil, false, {}

local function refresh_trees(force)
	if trees_busy then
		return
	end
	local now = os.time()
	if not force and trees_at and now - trees_at < TREES_EVERY then
		return
	end
	local root = repo()
	if not root then
		trees = {}
		return
	end
	trees_at, trees_busy = now, true
	worktree.trees(root, nil, function(found)
		trees_busy = false
		local out = {}
		for _, tree in ipairs(found) do
			local rec = known[tree.dir] or tree
			rec.branch, rec.head = tree.branch, tree.head
			known[tree.dir] = rec
			out[#out + 1] = rec
			-- Worked out once and kept: where this branch left yours does not
			-- move, and it is what the diff has to be measured against.
			if not rec.base and not rec.base_busy then
				rec.base_busy = true
				worktree.forked(root, rec.dir, function(base)
					rec.base_busy = false
					rec.base = base
				end)
			end
		end
		trees = out
	end)
end

--- Every row: the agents, newest first, then the worktrees nobody is in.
---
--- An agent is matched to its worktree by where it is running, so a worktree
--- with an agent in it appears once, as the agent. Shared with the sidebar,
--- and the reason both index the same list from a line number.
function M.items()
	refresh_trees()
	local out, taken = {}, {}
	for _, run in ipairs(agent.runs()) do
		out[#out + 1] = { run = run }
		-- Including one that has exited, which still speaks for its worktree:
		-- "finished" says more than "no agent", and the row only becomes a bare
		-- worktree once you have forgotten the run.
		taken[run.cwd] = true
	end
	for _, tree in ipairs(trees) do
		if not taken[tree.dir] then
			out[#out + 1] = { tree = tree }
		end
	end
	return out
end

--- One row as cells. Shared with the sidebar, which drops the wide ones.
local function cells(item)
	local run, tree = item.run, item.tree

	if tree then
		refresh_stat(tree, tree.dir, tree.base)
		local mark = MARK.spare
		return {
			{ text = mark[1], hl = mark[2] },
			{ text = vim.fn.fnamemodify(tree.dir, ":t"), hl = "AgentMeta" },
			{ text = "", hl = "AgentMeta" },
			{ text = "no agent", hl = mark[2] },
			{ text = "", hl = "AgentMeta" },
			{ text = tree.stat and ("+%d-%d"):format(tree.stat.added, tree.stat.removed) or "", hl = "AgentAdded" },
			{ text = tree.branch or "", hl = "AgentMeta" },
		}
	end

	-- Only for a run with a worktree of its own. Diffing the checkout you are
	-- sitting in would report your uncommitted work as the agent's.
	if run.where then
		refresh_stat(run, run.cwd, run.base)
	end
	local stat = run.stat
	local mark = MARK[run.status] or MARK.idle
	local diff = ""
	if stat then
		diff = ("+%d-%d"):format(stat.added, stat.removed)
	end

	return {
		{ text = mark[1], hl = mark[2] },
		{ text = run.name, hl = "AgentRunName" },
		{ text = run.cli, hl = "AgentMeta" },
		{ text = tostring(run.doing or ""), hl = mark[2] },
		{ text = agent.elapsed(run), hl = "AgentMeta" },
		{ text = diff, hl = stat and "AgentAdded" or "AgentMeta" },
		{ text = run.where or vim.fn.fnamemodify(run.cwd, ":t"), hl = "AgentMeta" },
	}
end

--- Lay cells out in aligned columns and return the lines plus, for each, the
--- highlight spans in byte terms.
local function layout(rows, keep)
	local widths = {}
	for _, row in ipairs(rows) do
		for i, cell in ipairs(row) do
			widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(cell.text))
		end
	end
	local lines, spans = {}, {}
	for r, row in ipairs(rows) do
		local parts, at, span = {}, 0, {}
		for i, cell in ipairs(row) do
			if keep[i] then
				local text = cell.text
				local pad = widths[i] - vim.fn.strdisplaywidth(text)
				local piece = (i == 1 and "" or " ") .. text
				at = at + (i == 1 and 0 or 1)
				if cell.text ~= "" then
					span[#span + 1] = { at, at + #text, cell.hl }
				end
				at = at + #text + pad
				parts[#parts + 1] = piece .. string.rep(" ", pad)
			end
		end
		lines[r] = table.concat(parts):gsub("%s+$", "")
		spans[r] = span
	end
	return lines, spans
end

--- The columns the dashboard shows, and the ones the sidebar has room for.
M.WIDE = { true, true, true, true, true, true, true }
M.NARROW = { true, true, false, true, true, false, false }

function M.render(into, keep, items)
	if not into or not vim.api.nvim_buf_is_valid(into) then
		return
	end
	items = items or M.items()
	local lines, spans

	if #items == 0 then
		lines, spans = { "no agents running", "", "a to start one" }, {}
	else
		local rows = {}
		for i, item in ipairs(items) do
			rows[i] = cells(item)
		end
		lines, spans = layout(rows, keep)
	end

	local was = vim.bo[into].modifiable
	vim.bo[into].modifiable = true
	vim.api.nvim_buf_set_lines(into, 0, -1, false, lines)
	vim.bo[into].modifiable = was
	vim.api.nvim_buf_clear_namespace(into, ns, 0, -1)

	for row, span in pairs(spans) do
		for _, one in ipairs(span) do
			pcall(vim.api.nvim_buf_set_extmark, into, ns, row - 1, one[1], {
				end_col = one[2],
				hl_group = one[3],
			})
		end
	end
	if #items == 0 then
		pcall(vim.api.nvim_buf_set_extmark, into, ns, 0, 0, { end_line = 3, hl_group = "AgentMeta" })
	end
end

--------------------------------------------------------------------------- --
-- the buffer
--------------------------------------------------------------------------- --

--- The row the cursor is on, or nil.
local function current()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.items()[line]
end

--- Show a run's terminal. Terminal buffers are kept alive hidden, so this is
--- only ever a matter of putting an existing one in a window.
function M.terminal(run, win)
	if not run or not run.buf or not vim.api.nvim_buf_is_valid(run.buf) then
		return
	end
	win_pick.focus(win)
	vim.api.nvim_win_set_buf(win, run.buf)
	-- Insert mode is what you want nine times in ten: the reason to open an
	-- agent is to say something to it.
	if run.status ~= "exited" then
		vim.cmd("startinsert")
	end
end

--- Open a row in `win`: the agent's terminal, or the worktree itself, which
--- lands you in the file browser at the top of what it has been doing.
function M.show_in(item, win)
	if not item then
		return
	end
	if item.run then
		return M.terminal(item.run, win)
	end
	win_pick.focus(win)
	vim.cmd.edit(vim.fn.fnameescape(item.tree.dir))
end

--- Remove a worktree, having asked. The branch is a second question, since it
--- is the only remaining copy of anything the agent committed there.
local function drop_tree(tree)
	local root = repo()
	if not root then
		return
	end
	local name = vim.fn.fnamemodify(tree.dir, ":t")
	local what = tree.stat and (" (+%d-%d uncommitted or unmerged)"):format(tree.stat.added, tree.stat.removed) or ""
	local answer = vim.fn.confirm("remove worktree " .. name .. what .. "?", "&Worktree\nworktree and &branch\n&Cancel", 3)
	if answer == 3 or answer == 0 then
		return
	end
	local branch = answer == 2 and tree.branch or nil

	local ok, err = worktree.remove(root, tree.dir, false, branch)
	if not ok and tostring(err):find("modified or untracked") then
		-- git's own refusal, handed back as the question it really is.
		if vim.fn.confirm(name .. " has changes that are not committed. remove anyway?", "&Remove\n&Keep", 2) ~= 1 then
			return
		end
		ok, err = worktree.remove(root, tree.dir, true, branch)
	end
	if not ok then
		vim.notify("agent: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	if err then
		-- Removed, but the branch outlived it: worth saying, not worth failing.
		vim.notify("agent: " .. tostring(err), vim.log.levels.WARN)
	end
	known[tree.dir] = nil
	refresh_trees(true)
	vim.notify("agent: removed " .. name)
end

local function keys(into)
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = into, silent = true, nowait = true, desc = desc })
	end

	for lhs, fn in pairs(win_pick.actions(function(win, item)
		M.show_in(item, win)
	end)) do
		map(lhs, function()
			local item = current()
			if item then
				fn(item)
			end
		end, "Open this agent, or this worktree")
	end

	map("i", function()
		local item = current()
		if not item or not item.run then
			return
		end
		local run = item.run
		vim.ui.input({ prompt = run.name .. " < " }, function(text)
			if text and text ~= "" then
				agent.send(run, text)
			end
		end)
	end, "Say something to this agent")

	map("a", function()
		local item = current()
		-- On a worktree, the obvious meaning of "start one" is "here", and
		-- having to retype a name you are looking at would be silly.
		local into = item
			and item.tree
			and {
				dir = item.tree.dir,
				branch = item.tree.branch,
				name = vim.fn.fnamemodify(item.tree.dir, ":t"),
				base = item.tree.base,
			}
		require("agent_spawn").show(false, into)
	end, "Start an agent, in this worktree when the cursor is on one")

	map("s", function()
		local item = current()
		if item and item.run and agent.stop(item.run) then
			vim.notify("agent: stopping " .. item.run.name)
		end
	end, "Stop this agent")

	map("x", function()
		local item = current()
		if not item then
			return
		end
		if item.tree then
			return drop_tree(item.tree)
		end
		-- An agent first, its worktree second. Forgetting the run leaves the
		-- worktree behind as a row of its own, which is the point: dropping the
		-- process and dropping the work are different decisions, and the second
		-- one should be made looking at what the work was.
		if not agent.forget(item.run) then
			vim.notify("agent: " .. item.run.name .. " is still running, stop it first", vim.log.levels.WARN)
		end
	end, "Forget an agent that has exited, or remove a worktree")

	map("q", function()
		vim.cmd("close")
	end, "Close the dashboard")
end

local function ensure()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, NAME)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "agents"
	vim.bo[buf].modifiable = false
	keys(buf)

	if not unwatch then
		unwatch = agent.watch(function()
			-- Only when it is on screen: the dashboard ticks every second and
			-- redrawing a buffer nobody is looking at is pure cost.
			if buf and vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
				M.render(buf, M.WIDE)
			end
		end)
	end
	return buf
end

--- Open the dashboard, focusing `run`'s row when given.
function M.open(run)
	set_hl()
	local into = ensure()
	local win = vim.fn.bufwinid(into)
	if win == -1 then
		vim.cmd("botright 12split")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, into)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].wrap = false
		vim.wo[win].cursorline = true
		-- In the winbar rather than the buffer, so what a row means and which
		-- row you are on stay the same question: a legend on line one would put
		-- every agent one line further down than the list says it is.
		vim.wo[win].winbar = "%#AgentMeta# <CR> open   i say   a start   s stop   x drop   q close"
	end
	M.render(into, M.WIDE)

	if run then
		for i, item in ipairs(M.items()) do
			if item.run and item.run.id == run.id then
				pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
			end
		end
	end
	return win
end

--- Whether any view onto the agents is on screen. Used to decide whether
--- starting one should open the dashboard: it should say something happened,
--- but not push a split into a layout that is already showing the answer.
function M.visible()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "agents" then
			return true
		end
	end
	return false
end

function M.toggle()
	local into = buf and vim.api.nvim_buf_is_valid(buf) and buf or nil
	local win = into and vim.fn.bufwinid(into) or -1
	if win ~= -1 then
		vim.api.nvim_win_close(win, false)
		return
	end
	M.open()
end

vim.keymap.set("n", "<leader>ad", M.toggle, { silent = true, desc = "Agent dashboard: every agent and what it is doing" })

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

return M
