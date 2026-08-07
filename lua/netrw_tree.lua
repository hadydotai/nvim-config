-- Make the netrw sidebar hold its place across toggles.
--
--   * expanded/collapsed directories survive closing and reopening
--   * reopening puts the cursor on the file you were last editing
--   * files currently visible in a window are marked in the listing
--
-- netrw keeps its tree state in w:netrw_treedict / w:netrw_treetop, which are
-- window-local, so :Lexplore closing the window throws them away. We stash them
-- on the tabpage and put them back on the way in.

local M = {}

local ns = vim.api.nvim_create_namespace("netrw_tree_open")

local OPEN_MARK = "●"

local function set_hl()
	vim.api.nvim_set_hl(0, "NetrwOpenMark", { link = "DiagnosticOk", default = true })
	vim.api.nvim_set_hl(0, "NetrwOpenName", { link = "DiagnosticOk", default = true })
end

local function refresh(win)
	vim.api.nvim_win_call(win, function()
		local dir = vim.fn["netrw#Call"]("NetrwBrowseChgDir", 1, "./", 0)
		vim.fn["netrw#Call"]("NetrwRefresh", 1, dir)
	end)
end

local function strip_slash(path)
	return (path:gsub("/+$", ""))
end

--- Resolve every listing line to an absolute path.
--- Tree lines are `| ` repeated once per level, so depth is just that count and
--- the enclosing directories are whatever directory entry was last seen above at
--- each shallower depth.
--- @return table<integer, string> map of 1-based line number to absolute path
function M.line_paths(win)
	local ok, top = pcall(vim.api.nvim_win_get_var, win, "netrw_treetop")
	if not ok or type(top) ~= "string" or top == "" then
		return {}
	end
	top = strip_slash(top)

	local buf = vim.api.nvim_win_get_buf(win)
	local paths, stack = {}, {}
	for lnum, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		local rest, depth = line, 0
		while rest:sub(1, 2) == "| " do
			rest = rest:sub(3)
			depth = depth + 1
		end
		if depth > 0 and rest ~= "" and rest ~= "../" then
			local is_dir = rest:sub(-1) == "/"
			local name = is_dir and rest:sub(1, -2) or rest
			local parts = { top }
			for d = 1, depth - 1 do
				parts[#parts + 1] = stack[d]
			end
			parts[#parts + 1] = name
			paths[lnum] = table.concat(parts, "/")
			if is_dir then
				stack[depth] = name
			end
		end
	end
	return paths
end

-- every file currently displayed in a window of this tabpage
local function visible_files()
	local open = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf = vim.api.nvim_win_get_buf(win)
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" and vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "netrw" then
			open[vim.fn.fnamemodify(name, ":p")] = true
		end
	end
	return open
end

function M.mark(win)
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if vim.bo[buf].filetype ~= "netrw" then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local open = visible_files()
	for lnum, path in pairs(M.line_paths(win)) do
		if open[path] then
			vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
				virt_text = { { " " .. OPEN_MARK, "NetrwOpenMark" } },
				virt_text_pos = "eol",
				hl_group = "NetrwOpenName",
				end_row = lnum - 1,
				end_col = #vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1],
			})
		end
	end
end

function M.mark_all()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "netrw" then
			M.mark(win)
		end
	end
end

local function capture(win)
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	local ok_dict, dict = pcall(vim.api.nvim_win_get_var, win, "netrw_treedict")
	local ok_top, top = pcall(vim.api.nvim_win_get_var, win, "netrw_treetop")
	if ok_dict and ok_top then
		vim.t.netrw_tree_state = { dict = dict, top = top }
		local pos = vim.api.nvim_win_get_cursor(win)
		vim.t.netrw_tree_line = pos[1]
	end
end

-- Put a saved tree back, but only when it belongs to the directory netrw just
-- opened on; otherwise browsing elsewhere would inherit a foreign tree.
local function restore(win)
	local saved = vim.t.netrw_tree_state
	if not (saved and saved.dict and saved.top) then
		return false
	end
	local ok, top = pcall(vim.api.nvim_win_get_var, win, "netrw_treetop")
	if not ok or strip_slash(tostring(top)) ~= strip_slash(saved.top) then
		return false
	end
	vim.api.nvim_win_set_var(win, "netrw_treedict", saved.dict)
	vim.api.nvim_win_set_var(win, "netrw_treetop", saved.top)
	refresh(win)
	return true
end

--- Move the cursor onto `path` if it is present in the listing.
function M.reveal(win, path)
	if not path or path == "" then
		return false
	end
	local want = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
	for lnum, entry in pairs(M.line_paths(win)) do
		if entry == want then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			return true
		end
	end
	return false
end

--- <leader>e: toggle the sidebar, keeping the tree and the cursor in place.
function M.toggle()
	local sidebar = require("netrw_sidebar")
	local side = sidebar.window()

	if side then
		capture(side)
		vim.cmd("Lexplore")
		return
	end

	local last_file = vim.api.nvim_buf_get_name(0)
	vim.cmd("Lexplore")

	local opened = sidebar.window()
	if not opened then
		return
	end
	restore(opened)
	if not M.reveal(opened, last_file) and vim.t.netrw_tree_line then
		-- fall back to the line we were on when it closed
		local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(opened))
		vim.api.nvim_win_set_cursor(opened, { math.min(vim.t.netrw_tree_line, count), 0 })
	end
	M.mark(opened)
end

function M.setup()
	set_hl()

	local group = vim.api.nvim_create_augroup("NetrwTree", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

	-- These run on window events, including ones fired while another feature is
	-- mid-operation, so nothing in here may throw: an error would surface as a
	-- stack trace on top of whatever the user was actually doing.
	local function floating(win)
		local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
		return ok and cfg.relative ~= ""
	end

	-- keep the open-file marks in step with whatever is on screen
	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinClosed", "WinNew" }, {
		group = group,
		callback = function()
			vim.schedule(function()
				pcall(M.mark_all)
			end)
		end,
	})

	-- closing the sidebar any other way (:q, <c-w>c) should still save the tree
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(ev)
			local win = tonumber(ev.match)
			if not win or floating(win) then
				return
			end
			pcall(function()
				local sidebar = require("netrw_sidebar")
				local side = type(sidebar.window) == "function" and sidebar.window() or nil
				if side and win == side then
					capture(win)
				end
			end)
		end,
	})
end

return M
