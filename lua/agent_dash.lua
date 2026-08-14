-- Every agent, in a buffer: what it is, what it is doing, how long it has been
-- doing it, and what it has changed.
--
-- A buffer rather than a floating dialog because this is something you leave
-- open and glance at, and because a window you can split, move and close with
-- the keys you already know beats a bespoke one. It is a normal scratch buffer
-- with normal mappings.
--
--   <CR>   open that agent's terminal, choosing a window the netrw way
--   i      type a line to it without leaving the dashboard
--   a      start another
--   s      stop it
--   x      forget one that has exited, and close its terminal
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

--- Ask git what an agent has changed, at most this often. Redrawing happens
--- once a second and the answer moves far more slowly than that, so without a
--- throttle this would be two git processes per agent per second for a number
--- that changes every few minutes.
local STAT_EVERY = 4

local function refresh_stat(run)
	-- Only for a run with a worktree of its own. Diffing the checkout you are
	-- sitting in would report your uncommitted work as the agent's.
	if not run.where or run.stat_busy then
		return
	end
	local now = os.time()
	if run.stat_at and now - run.stat_at < STAT_EVERY then
		return
	end
	run.stat_at, run.stat_busy = now, true
	worktree.stat(run.cwd, run.base, function(stat)
		run.stat_busy = false
		run.stat = stat
	end)
end

--- One run as cells. Shared with the sidebar, which drops the wide ones.
local function cells(run)
	refresh_stat(run)
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

function M.render(into, keep, runs)
	if not into or not vim.api.nvim_buf_is_valid(into) then
		return
	end
	runs = runs or agent.runs()
	local lines, spans

	if #runs == 0 then
		lines, spans = { "no agents running", "", "a to start one" }, {}
	else
		local rows = {}
		for i, run in ipairs(runs) do
			rows[i] = cells(run)
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
	if #runs == 0 then
		pcall(vim.api.nvim_buf_set_extmark, into, ns, 0, 0, { end_line = 3, hl_group = "AgentMeta" })
	end
end

--------------------------------------------------------------------------- --
-- the buffer
--------------------------------------------------------------------------- --

--- The run on the cursor line, or nil.
local function current()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return agent.runs()[line]
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

local function keys(into)
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = into, silent = true, nowait = true, desc = desc })
	end

	for lhs, fn in pairs(win_pick.actions(function(win, run)
		M.terminal(run, win)
	end)) do
		map(lhs, function()
			local run = current()
			if run then
				fn(run)
			end
		end, "Open this agent's terminal")
	end

	map("i", function()
		local run = current()
		if not run then
			return
		end
		vim.ui.input({ prompt = run.name .. " < " }, function(text)
			if text and text ~= "" then
				agent.send(run, text)
			end
		end)
	end, "Say something to this agent")

	map("a", function()
		require("agent_spawn").show(false)
	end, "Start another agent")

	map("s", function()
		local run = current()
		if run and agent.stop(run) then
			vim.notify("agent: stopping " .. run.name)
		end
	end, "Stop this agent")

	map("x", function()
		local run = current()
		if not run then
			return
		end
		if not agent.forget(run) then
			vim.notify("agent: " .. run.name .. " is still running, stop it first", vim.log.levels.WARN)
		end
	end, "Forget an agent that has exited")

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
	end
	M.render(into, M.WIDE)

	if run then
		for i, other in ipairs(agent.runs()) do
			if other.id == run.id then
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
