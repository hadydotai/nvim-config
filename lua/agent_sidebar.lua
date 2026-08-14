-- The same rows as the dashboard, in a column narrow enough to leave open.
--
-- The dashboard is something you go to; this is something you keep in the
-- corner of your eye while writing code, so it carries only what can be read
-- without stopping: state, name, what it is doing, how long. Everything else
-- is a column the dashboard has room for and this does not.
--
--   <leader>ae   toggle it
--   <CR>         open it in the editing area: the terminal, or the worktree
--   d            the full dashboard, where a row can be acted on
--
-- It pins itself the way netrw_sidebar.lua does: fixed width, and put back
-- where it belongs if a window command moves it.

local M = {}

local agent = require("agent")
local dash = require("agent_dash")

local WIDTH = 34
local NAME = "agent://sidebar"

local buf, unwatch

--- The sidebar window in this tab, or nil.
local function window()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

--- A window to hand an opened agent to: anything that is not the sidebar.
local function editing(side)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= side and vim.api.nvim_win_get_config(win).relative == "" then
			return win
		end
	end
	return nil
end

local function draw()
	local win = window()
	if win then
		dash.render(buf, dash.NARROW)
	end
end

local function keys(into)
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = into, silent = true, nowait = true, desc = desc })
	end

	map("<CR>", function()
		local item = dash.items()[vim.api.nvim_win_get_cursor(0)[1]]
		local side = window()
		local target = side and editing(side)
		if item and target then
			dash.show_in(item, target)
		end
	end, "Open this agent, or this worktree")

	map("d", function()
		require("agent_dash").open()
	end, "Open the full dashboard")

	map("a", function()
		local item = dash.items()[vim.api.nvim_win_get_cursor(0)[1]]
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

	map("q", M.close, "Close the sidebar")
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
		unwatch = agent.watch(draw)
	end
	return buf
end

function M.open()
	local into = ensure()
	if window() then
		return
	end
	local from = vim.api.nvim_get_current_win()
	vim.cmd("topleft vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, into)
	vim.api.nvim_win_set_width(win, WIDTH)

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	vim.wo[win].winfixwidth = true

	dash.render(into, dash.NARROW)
	-- Focus goes back where it was: the sidebar is for looking at, and taking
	-- the cursor to it every time you open it is the thing that makes people
	-- stop opening it.
	if vim.api.nvim_win_is_valid(from) then
		vim.api.nvim_set_current_win(from)
	end
end

function M.close()
	local win = window()
	if win then
		vim.api.nvim_win_close(win, false)
	end
end

function M.toggle()
	if window() then
		M.close()
	else
		M.open()
	end
end

vim.keymap.set("n", "<leader>ae", M.toggle, { silent = true, desc = "Agent sidebar: a column of what every agent is doing" })

return M
