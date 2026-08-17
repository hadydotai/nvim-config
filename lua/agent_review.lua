-- What an agent actually did, as a diff you can answer.
--
-- The dashboard says +12-3. That is enough to know something happened and not
-- enough to know whether it was right, and the moment you want to say "no, not
-- like that" about one particular line you are on your own: find the file,
-- select the lines, use <leader>ac, and the diff you were reading is gone.
--
-- So: the whole change in a buffer, and o on any hunk sends that hunk, where it
-- is, and what you think of it back to the agent that wrote it.
--
--   <CR>   open this file, at this line
--   o      say something about this hunk
--   ]h [h  the next hunk, the previous one
--   R      read it again
--   q      close
--
-- Reading only. Nothing here stages, commits or discards anything: this is a
-- window onto work in progress, and the agent is the one holding the pen.
--
-- One diff covers everything the agent has done, committed or not, because it
-- is measured from where its branch left yours rather than from its last
-- commit. An agent working in the checkout you are sitting in has no fork
-- point of its own, so that one is measured from HEAD and shows only what is
-- uncommitted, which is the honest answer: anything committed there is yours.

local M = {}

local agent = require("agent")
local win_pick = require("win_pick")

local ns = vim.api.nvim_create_namespace("agent_review")

local function set_hl()
	local set = function(name, spec)
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
	end
	set("AgentReviewHead", { link = "Title" })
	set("AgentReviewNote", { link = "Comment" })
end

--------------------------------------------------------------------------- --
-- reading the change
--------------------------------------------------------------------------- --

--- The patch for a checkout, and the files git is not tracking there.
---
--- Untracked files are asked for separately because a diff never mentions
--- them: a file the agent created and did not add is invisible to `git diff`,
--- and "it did nothing" is the worst possible thing to be wrong about.
---
--- Asynchronous for the reason everything else that shells out to git here is:
--- a large repository takes long enough that doing it in the redraw path would
--- be felt.
local function fetch(dir, base, done)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		return done({ err = "no such directory: " .. tostring(dir) })
	end
	vim.system({ "git", "diff", "--no-color", base or "HEAD" }, { cwd = dir, text = true }, function(diff)
		if diff.code ~= 0 then
			local why = vim.trim(diff.stderr or "")
			-- Outside a repository git does not fail, it explains --no-index and
			-- prints its entire usage, which is a page of advice about a flag
			-- nobody here wants. Say the one thing that is true instead.
			if why:find("[Nn]ot a git repository") then
				why = "not a git repository: " .. dir
			end
			return vim.schedule_wrap(done)({ err = why ~= "" and why or "git diff failed" })
		end
		vim.system({ "git", "status", "--porcelain" }, { cwd = dir, text = true }, function(status)
			local untracked = {}
			for line in (status.stdout or ""):gmatch("[^\n]+") do
				local path = line:match("^%?%?%s+(.+)$")
				if path then
					untracked[#untracked + 1] = path
				end
			end
			table.sort(untracked)
			vim.schedule_wrap(done)({ patch = diff.stdout or "", untracked = untracked })
		end)
	end)
end

--- Parse a unified diff into the lines to show and, for each line, what it is.
---
--- The patch is kept verbatim rather than reformatted, which is what makes
--- 'filetype' diff enough to colour the whole thing, and what makes the buffer
--- something you could yank and hand to git apply.
---
--- The interesting part is the number tracked down each hunk: a diff line
--- knows which file it is in but not which line of it, and without that <CR>
--- can only open the file at the top. Context and added lines advance it,
--- removed lines do not, which is exactly what the new file looks like.
local function parse(patch, untracked)
	local lines, rows = {}, {}
	local file, hunk, lnum

	local function add(text, row)
		lines[#lines + 1] = text
		rows[#lines] = row
	end

	for text in (patch or ""):gmatch("([^\n]*)\n?") do
		if text ~= "" or #lines > 0 then
			local path = text:match("^%+%+%+ b/(.+)$")
			if text:match("^diff %-%-git ") then
				-- b/ is the name after the change, which is the one worth having:
				-- it is where the file is now, so it is what <CR> can open.
				file = text:match("^diff %-%-git a/.+ b/(.+)$") or file
				hunk, lnum = nil, nil
				add(text, { kind = "file", file = file })
			elseif path then
				file = path ~= "/dev/null" and path or file
				add(text, { kind = "file", file = file })
			elseif text:match("^@@ ") then
				local start = text:match("^@@ %-%d+,?%d* %+(%d+)")
				lnum = tonumber(start) or 1
				hunk = { file = file, header = text, from = lnum, to = lnum, text = { text } }
				add(text, { kind = "hunk", file = file, hunk = hunk, lnum = lnum })
			elseif hunk and text:match("^[ %+%-\\]") then
				hunk.text[#hunk.text + 1] = text
				local at = lnum
				if not text:match("^%-") and not text:match("^\\") then
					lnum = lnum + 1
					hunk.to = lnum - 1
				end
				add(text, { kind = "line", file = file, hunk = hunk, lnum = at })
			else
				-- index lines, mode changes, "Binary files differ": part of the
				-- patch, nothing to point at.
				add(text, { kind = "other", file = file })
			end
		end
	end

	if #untracked > 0 then
		-- One blank line between the patch and this, and only one: a patch ends
		-- with a newline, so its last line is already empty.
		if #lines > 0 and vim.trim(lines[#lines]) ~= "" then
			add("", {})
		end
		add(("%d file%s git is not tracking:"):format(#untracked, #untracked == 1 and "" or "s"), { kind = "note" })
		for _, path in ipairs(untracked) do
			add("  " .. path, { kind = "untracked", file = path, lnum = 1 })
		end
	end

	if #lines == 0 then
		add("nothing changed here yet", { kind = "note" })
	end
	return lines, rows
end

--------------------------------------------------------------------------- --
-- the buffer
--------------------------------------------------------------------------- --

-- One per checkout, so two worktrees can be reviewed side by side. Keyed by
-- directory rather than by run: the work is the worktree's, and it outlives
-- whichever agent happens to be in there now.
local views = {}

local function render(view)
	if not view.buf or not vim.api.nvim_buf_is_valid(view.buf) then
		return
	end
	local lines, rows = parse(view.patch, view.untracked or {})
	if view.err then
		-- Split, because git says more than one line when it is unhappy - "not a
		-- git repository" comes with advice underneath it - and a buffer line
		-- holding a newline is refused outright.
		lines, rows = vim.split(view.err, "\n", { trimempty = true }), {}
		for i = 1, #lines do
			rows[i] = { kind = "note" }
		end
	end
	view.rows = rows

	vim.bo[view.buf].modifiable = true
	vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
	vim.bo[view.buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
	for i, row in ipairs(rows) do
		-- Only the lines the diff syntax has no opinion about. Everything that
		-- is really part of a patch is already coloured by it.
		local hl = (row.kind == "note" and "AgentReviewNote") or (row.kind == "untracked" and "AgentReviewHead")
		if hl then
			pcall(vim.api.nvim_buf_set_extmark, view.buf, ns, i - 1, 0, { end_col = #lines[i], hl_group = hl })
		end
	end
end

--- Read the change again. `then_do` is for the caller that wants to move the
--- cursor once there is something to move it to.
local function reload(view, then_do)
	if view.busy then
		return
	end
	view.busy = true
	fetch(view.dir, view.base, function(result)
		view.busy = false
		view.patch, view.untracked, view.err = result.patch, result.untracked, result.err
		view.read_at = os.time()
		render(view)
		if then_do then
			then_do()
		end
	end)
end

--- The row the cursor is on.
local function current(view)
	return view.rows and view.rows[vim.api.nvim_win_get_cursor(0)[1]] or nil
end

--- Which agent to answer. The one this review was opened for when it is still
--- alive, else whichever is running in the same checkout, since that is the one
--- with its hands on these files now.
local function target(view)
	if view.run and view.run.status ~= "exited" then
		return view.run
	end
	for _, run in ipairs(agent.runs()) do
		if run.status ~= "exited" and run.cwd == view.dir then
			return run
		end
	end
	return nil
end

--- Where a row points, as a path and a line.
local function points_at(view, row)
	if not row or not row.file then
		return nil
	end
	return view.dir .. "/" .. row.file, row.lnum or 1
end

--- What the agent is told about a hunk: which file, which lines, the hunk
--- itself, and then what you said. Built here rather than in agent_context.lua
--- because the subject is a patch rather than anything in a buffer.
local function about(row, comment)
	local body = table.concat({
		("In %s, lines %d to %d:"):format(row.file, row.hunk.from, row.hunk.to),
		"",
		"```diff",
		table.concat(row.hunk.text, "\n"),
		"```",
	}, "\n")
	return require("agent_context").prompt(body, comment)
end

local function keys(view)
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = view.buf, silent = true, nowait = true, desc = desc })
	end

	-- Built at the keypress, like the dashboard's, because it captures the
	-- window you came from and that is different every time. This one is
	-- excluded: a file opened over the review is a review you no longer have.
	for _, lhs in ipairs({ "<CR>", "<S-CR>" }) do
		map(lhs, function()
			local path, lnum = points_at(view, current(view))
			if not path then
				return
			end
			local mine = vim.api.nvim_get_current_win()
			win_pick.actions(function(win, where)
				win_pick.focus(win)
				vim.cmd.edit(vim.fn.fnameescape(where.path))
				pcall(vim.api.nvim_win_set_cursor, 0, { where.lnum, 0 })
			end, mine)[lhs]({ path = path, lnum = lnum })
		end, "Open this file at this line")
	end

	map("o", function()
		local row = current(view)
		if not row or not row.hunk then
			return vim.notify("agent: put the cursor on a hunk to say something about it", vim.log.levels.WARN)
		end
		local run = target(view)
		if not run then
			return vim.notify("agent: nothing is running in " .. view.name .. " to tell", vim.log.levels.WARN)
		end
		vim.ui.input({ prompt = ("%s < about %s:%d "):format(run.name, row.file, row.hunk.from) }, function(comment)
			if comment == nil or vim.trim(comment) == "" then
				return
			end
			agent.send(run, about(row, vim.trim(comment)))
			vim.notify(("agent: told %s about %s:%d"):format(run.name, row.file, row.hunk.from))
		end)
	end, "Say something about this hunk to the agent that wrote it")

	local function hop(step)
		local line = vim.api.nvim_win_get_cursor(0)[1]
		local rows = view.rows or {}
		for i = line + step, step > 0 and #rows or 1, step do
			if rows[i] and rows[i].kind == "hunk" then
				return pcall(vim.api.nvim_win_set_cursor, 0, { i, 0 })
			end
		end
	end
	map("]h", function()
		hop(1)
	end, "Next hunk")
	map("[h", function()
		hop(-1)
	end, "Previous hunk")

	map("R", function()
		reload(view)
	end, "Read the change again")

	map("q", function()
		vim.cmd("close")
	end, "Close the review")
end

--- The buffer for a checkout, made once and kept.
local function ensure(view)
	if view.buf and vim.api.nvim_buf_is_valid(view.buf) then
		return view.buf
	end
	view.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[view.buf].buftype = "nofile"
	vim.bo[view.buf].bufhidden = "hide"
	vim.bo[view.buf].swapfile = false
	vim.bo[view.buf].modifiable = false
	-- The runtime's own diff syntax, which is the whole reason the patch is
	-- kept verbatim rather than prettied up.
	vim.bo[view.buf].filetype = "diff"

	local name = "agent://review/" .. view.name
	if not pcall(vim.api.nvim_buf_set_name, view.buf, name) then
		-- Two worktrees of the same name in different projects. Cosmetic, but a
		-- buffer with no name at all shows up in <leader>b as [No Name].
		pcall(vim.api.nvim_buf_set_name, view.buf, name .. "-" .. vim.fn.sha256(view.dir):sub(1, 6))
	end

	keys(view)
	-- Read again on the way in rather than on the tick. The cursor is sitting
	-- on a hunk you are reading, and rebuilding under it moves it; coming back
	-- to the window is the moment you are not mid-sentence.
	vim.api.nvim_create_autocmd("WinEnter", {
		buffer = view.buf,
		desc = "agent review: read the change again",
		callback = function()
			reload(view)
		end,
	})
	return view.buf
end

--------------------------------------------------------------------------- --
-- opening one
--------------------------------------------------------------------------- --

--- Review a checkout.
---
---   dir    the checkout to read
---   base   what to measure from, nil for HEAD
---   run    the agent it belongs to, when there is one
---   name   what to call it
function M.show(opts)
	if not opts or not opts.dir then
		return
	end
	set_hl()
	local view = views[opts.dir]
	if not view then
		view = { dir = opts.dir }
		views[opts.dir] = view
	end
	view.base = opts.base or view.base
	view.run = opts.run or view.run
	view.name = opts.name or view.name or vim.fn.fnamemodify(opts.dir, ":t")

	local buf = ensure(view)
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		vim.cmd("botright vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].wrap = false
		vim.wo[win].cursorline = true
	else
		vim.api.nvim_set_current_win(win)
	end
	-- In the winbar for the reason the dashboard's is: a legend on line one
	-- would put every hunk one line away from where the rows say it is.
	vim.wo[win].winbar = ("%%#AgentReviewNote# %s  <CR> open   o comment   ]h [h hunk   R reread   q close"):format(
		view.name:gsub("%%", "%%%%")
	)

	reload(view, function()
		-- On the first hunk rather than the file header, which is the line you
		-- would have moved to anyway.
		for i, row in ipairs(view.rows or {}) do
			if row.kind == "hunk" then
				pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
				break
			end
		end
	end)
	return win
end

--- Review whatever a dashboard row stands for: an agent's checkout, or a
--- worktree nobody is in.
function M.item(item)
	if not item then
		return
	end
	if item.run then
		return M.show({
			dir = item.run.cwd,
			base = item.run.base,
			run = item.run,
			name = item.run.name,
		})
	end
	if item.tree then
		return M.show({
			dir = item.tree.dir,
			base = item.tree.base,
			name = vim.fn.fnamemodify(item.tree.dir, ":t"),
		})
	end
	if item.session then
		return M.show({ dir = item.session.cwd, name = item.session.name })
	end
end

--- Review where you are. The dashboard already knows the fork point of every
--- worktree and every running agent, so the row covering this directory is
--- asked for rather than worked out again; failing that, this is an ordinary
--- checkout and HEAD is what a change is measured from.
function M.here()
	local dir = vim.fn.getcwd()
	for _, item in ipairs(require("agent_dash").items()) do
		local where = (item.run and item.run.cwd) or (item.tree and item.tree.dir) or (item.session and item.session.cwd)
		if where == dir then
			return M.item(item)
		end
	end
	return M.show({ dir = dir, name = vim.fn.fnamemodify(dir, ":t") })
end

vim.keymap.set("n", "<leader>ar", M.here, {
	silent = true,
	desc = "Review what changed here: the diff, and o to answer a hunk",
})

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

return M
