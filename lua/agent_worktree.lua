-- Worktrees: making one, choosing one, and taking one away.
--
-- These used to be made one per agent, on the way to starting it. That is
-- wasteful, since most questions do not need a checkout of their own; it is
-- slow, since the checkout and everything the project needs copied into it are
-- paid for before the agent has said a word; and it is wrong about half the
-- time, because plenty of work belongs in the checkout you are already sitting
-- in.
--
-- So a worktree is a thing you make when you want one, and an agent is started
-- in a place: here unless you say otherwise, or one of these when you do. One
-- worktree can hold as many agents as you care to send into it.
--
--   <leader>an   make one
--   n            the same, on the dashboard, beside the ones you have
--
-- The isolation is still the point when you want it. Two agents editing one
-- checkout do not take turns and neither knows the other exists, so the second
-- overwrites the first and the diff you read afterwards is neither of them.
-- That is a reason to have worktrees, not a reason to make one every time.
--
-- By default they live under .data/, which is gitignored, so a few gigabytes of
-- checkouts never reach a commit:
--
--   .data/nvim/agents/worktrees/<repo>-<hash>/<name>
--
-- The hash is of the full path to the repository, so two checkouts of the same
-- project with the same basename stay apart. Where they go, and what gets put
-- into one so the project actually builds, is per project and lives in
-- agent_project.lua.

local M = {}

local function git(args, cwd)
	local out = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
	return out.code == 0, vim.trim(out.stdout or ""), vim.trim(out.stderr or "")
end

--- The repository `dir` is in, or nil. The top level rather than the current
--- directory, so a worktree made from a subdirectory still covers the project.
function M.repo(dir)
	dir = dir or vim.fn.getcwd()
	if vim.fn.executable("git") == 0 then
		return nil
	end
	local ok, top = git({ "rev-parse", "--show-toplevel" }, dir)
	return ok and top ~= "" and top or nil
end

--- Turn what someone typed into something git will accept as a branch and the
--- filesystem as a directory.
function M.slug(text)
	local slug = (text or ""):lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", ""):sub(1, 40)
	return slug ~= "" and slug or ("run-" .. os.date("%H%M%S"))
end

--- Where this project's worktrees live. Asked of the project setup rather than
--- fixed here, since that is where you get to move them (see
--- agent_project.lua); required lazily because that module asks us where the
--- repository is.
function M.dir(repo, name, config)
	return require("agent_project").worktree_dir(repo, config) .. "/" .. name
end

--- Read `git worktree list --porcelain` into records, keeping only the ones
--- under `root`. The filter is what makes this "the worktrees we made" rather
--- than every one the repository has: a worktree you set up by hand is yours,
--- and nothing here should be offering to change or remove it.
local function parse(out, root)
	local trees, current = {}, nil
	for line in out:gmatch("[^\n]+") do
		local dir = line:match("^worktree (.+)$")
		if dir then
			current = dir:sub(1, #root + 1) == root .. "/" and { dir = dir } or nil
			if current then
				trees[#trees + 1] = current
			end
		elseif current then
			current.head = line:match("^HEAD (.+)$") or current.head
			current.branch = line:match("^branch refs/heads/(.+)$") or current.branch
		end
	end
	return trees
end

--- The worktrees this project already has, which is what the setup buffer
--- offers to bring up to date. Read from git rather than from the directory,
--- so one removed behind our back is not reported as still there.
function M.list(repo, config)
	if not repo then
		return {}
	end
	local root = require("agent_project").worktree_dir(repo, config)
	local ok, out = git({ "worktree", "list", "--porcelain" }, repo)
	if not ok then
		return {}
	end
	local dirs = {}
	for _, tree in ipairs(parse(out, root)) do
		dirs[#dirs + 1] = tree.dir
	end
	return dirs
end

--- The same worktrees as records, and without blocking: where each one is,
--- which branch is checked out there, and what that branch is sitting on.
---
--- Asynchronous because the dashboard asks for this on a timer, and an editor
--- that waits on git every second is an editor that stutters every second.
function M.trees(repo, config, done)
	if not repo then
		return done({})
	end
	local root = require("agent_project").worktree_dir(repo, config)
	vim.system({ "git", "worktree", "list", "--porcelain" }, { cwd = repo, text = true }, function(out)
		vim.schedule_wrap(done)(out.code == 0 and parse(vim.trim(out.stdout or ""), root) or {})
	end)
end

--- The commit a worktree's branch and your checkout last had in common.
---
--- This is what "what has it changed" has to be measured against for a
--- worktree whose agent is gone, since the commit it was cut from was only
--- ever held in memory. It is the honest answer even when the main line has
--- moved on since, which a plain diff against HEAD is not.
function M.forked(repo, dir, done)
	vim.system({ "git", "rev-parse", "HEAD" }, { cwd = repo, text = true }, function(head)
		if head.code ~= 0 then
			return vim.schedule_wrap(done)(nil)
		end
		vim.system(
			{ "git", "merge-base", "HEAD", vim.trim(head.stdout or "") },
			{ cwd = dir, text = true },
			function(base)
				vim.schedule_wrap(done)(base.code == 0 and vim.trim(base.stdout or "") or nil)
			end
		)
	end)
end

--- Put into a fresh checkout whatever the project needs in order to build.
---
--- A worktree with none of the gitignored things a project needs is a checkout
--- that does not run, so this is part of making one rather than something to
--- remember afterwards. What to put there is per project and lives in
--- agent_project.lua.
function M.furnish(repo, dir, name)
	local project = require("agent_project")
	local config = project.load(repo)
	local _, failed = project.apply(repo, dir, config)
	if #failed > 0 then
		vim.notify("agent: worktree setup:\n  " .. table.concat(failed, "\n  "), vim.log.levels.WARN)
	end
	project.run_after(repo, dir, config, function(broke)
		if broke > 0 then
			vim.notify(("agent: %d setup command failed in %s"):format(broke, name), vim.log.levels.WARN)
		end
	end)
end

--- Make a worktree for `name` on a new branch cut from `base`.
---
--- `done` is called with a place - `{ dir, branch, name, base }` - or with nil
--- and a reason. The commit it was cut from is worth keeping: it is the only
--- honest answer to "what has changed here" once the branch starts committing,
--- and it stops being derivable the moment anything else moves.
---
--- An existing worktree of the same name is handed back rather than treated as
--- an error: asking twice for the same thing should give you the same thing.
---
--- The checkout itself is asynchronous, because it is the slow part - a large
--- repository takes seconds - and because nothing is waiting on it. The three
--- calls around it are single reads of a ref and are not worth a callback.
function M.create(repo, name, base, done)
	if not repo then
		return done(nil, "not a git repository")
	end
	local dir = M.dir(repo, name)
	local branch = "agent/" .. name
	local _, from = git({ "rev-parse", base or "HEAD" }, repo)
	local place = { dir = dir, branch = branch, name = name, base = from ~= "" and from or nil }

	if vim.fn.isdirectory(dir) == 1 then
		return done(place)
	end

	vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")

	-- An existing branch of this name means a previous worktree of the same
	-- name, so check it out rather than failing on "already exists".
	local exists = select(1, git({ "rev-parse", "--verify", "--quiet", branch }, repo))
	local args = exists and { "git", "worktree", "add", dir, branch }
		or { "git", "worktree", "add", "-b", branch, dir, base or "HEAD" }

	vim.system(args, { cwd = repo, text = true }, function(out)
		vim.schedule(function()
			if out.code ~= 0 then
				local err = vim.trim(out.stderr or "")
				return done(nil, err ~= "" and err or "git worktree add failed")
			end
			M.furnish(repo, dir, name)
			done(place)
		end)
	end)
end

--- Remove a worktree, and its branch too when asked.
---
--- git refuses while the checkout is dirty, and that refusal is passed straight
--- back rather than worked around: the whole point of the thing is work you
--- have not read yet. `force` is how you say you have decided anyway.
---
--- The branch is left alone by default even though the checkout is gone,
--- because a branch costs nothing and is the only copy of whatever the agent
--- committed. Deleting it is a separate answer to a separate question.
function M.remove(repo, dir, force, branch)
	if not repo or vim.fn.isdirectory(dir) == 0 then
		return false, "no such worktree"
	end
	local args = { "worktree", "remove", dir }
	if force then
		args[#args + 1] = "--force"
	end
	local ok, _, err = git(args, repo)
	if not ok then
		return false, err ~= "" and err or "git worktree remove failed"
	end
	if branch then
		local gone, _, why = git({ "branch", "-D", branch }, repo)
		if not gone then
			return true, why ~= "" and why or ("could not delete " .. branch)
		end
	end
	return true
end

local function shortstat(text)
	return {
		files = tonumber(text:match("(%d+) files? changed")) or 0,
		added = tonumber(text:match("(%d+) insertions?")) or 0,
		removed = tonumber(text:match("(%d+) deletions?")) or 0,
	}
end

--- What changed in a worktree: files touched and lines added and removed,
--- counting both what is committed on the branch and what is not yet, since an
--- agent that committed its work otherwise looks like one that did nothing.
---
--- Asynchronous, and not by preference. This is called for every agent every
--- time the dashboard redraws, which is once a second; waiting on two git
--- processes per agent in the redraw path would freeze the editor for as long
--- as the slowest repository takes. `done` is called with the stat, or with
--- nil when there is nothing to report.
function M.stat(dir, base, done)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		return done(nil)
	end
	vim.system({ "git", "diff", "--shortstat", "HEAD" }, { cwd = dir, text = true }, function(work)
		local out = work.code == 0 and shortstat(work.stdout or "") or nil
		if not out then
			return vim.schedule_wrap(done)(nil)
		end
		-- What the branch has committed on top of where it was cut from.
		vim.system(
			{ "git", "diff", "--shortstat", (base or "HEAD") .. "..HEAD" },
			{ cwd = dir, text = true },
			function(committed)
				if committed.code == 0 then
					local also = shortstat(committed.stdout or "")
					out.added = out.added + also.added
					out.removed = out.removed + also.removed
					out.files = math.max(out.files, also.files)
				end
				local empty = out.files == 0 and out.added == 0 and out.removed == 0
				vim.schedule_wrap(done)(not empty and out or nil)
			end
		)
	end)
end

--------------------------------------------------------------------------- --
-- choosing one, and making one on purpose
--------------------------------------------------------------------------- --

--- Branches and tags, for completing where a worktree is cut from and for
--- noticing that the name you are typing is one that already exists.
function _G._agent_refs(lead)
	local root = M.repo()
	if not root then
		return {}
	end
	local out = vim.system({
		"git",
		"for-each-ref",
		"--format=%(refname:short)",
		"refs/heads",
		"refs/remotes",
		"refs/tags",
	}, { cwd = root, text = true }):wait()

	local seen, refs = {}, {}
	for line in (out.stdout or ""):gmatch("[^\n]+") do
		-- The agent/ branches are ours, and offering one back as a base is a
		-- way to build a worktree on top of another agent's unreviewed work.
		if not seen[line] and not line:match("^agent/") then
			seen[line] = true
			refs[#refs + 1] = line
		end
	end
	table.sort(refs)
	return vim.tbl_filter(function(ref)
		return ref:find(lead, 1, true) == 1
	end, refs)
end

--- Names already taken by a worktree of this project, so typing one is how you
--- say "the one I already have" rather than making a second.
function _G._agent_names(lead)
	local root = M.repo()
	local names = {}
	for _, dir in ipairs(root and M.list(root) or {}) do
		names[#names + 1] = vim.fn.fnamemodify(dir, ":t")
	end
	table.sort(names)
	return vim.tbl_filter(function(name)
		return name:find(lead, 1, true) == 1
	end, names)
end

--- Ask for a name and a base, then make it. `done` gets the place, or nil if
--- you backed out or it could not be made.
---
--- Both are asked rather than derived because where work goes is a decision,
--- and one that is painful to discover you got wrong an hour later. Both are
--- prefilled with the answer you would have got anyway, and both complete: the
--- name against the worktrees this project has, the base against every branch
--- and tag.
function M.ask(repo, default, done)
	done = done or function() end
	if not repo then
		vim.notify("agent: not a git repository", vim.log.levels.WARN)
		return done(nil)
	end
	vim.ui.input({
		prompt = "worktree name: ",
		default = default,
		completion = "customlist,v:lua._agent_names",
	}, function(name)
		if name == nil or vim.trim(name) == "" then
			return done(nil)
		end
		vim.ui.input({
			prompt = "cut from: ",
			default = "HEAD",
			completion = "customlist,v:lua._agent_refs",
		}, function(base)
			if base == nil then
				return done(nil)
			end
			local slug = M.slug(name)
			-- Said before the checkout starts rather than after, since the
			-- checkout is the part that takes a while.
			vim.notify("agent: making worktree " .. slug)
			M.create(repo, slug, vim.trim(base) ~= "" and vim.trim(base) or "HEAD", function(place, err)
				if not place then
					vim.notify("agent: " .. tostring(err), vim.log.levels.ERROR)
					return done(nil)
				end
				done(place)
			end)
		end)
	end)
end

--- Where a worktree's branch parted from yours, filled in if it is missing.
--- It is what a diff of the place has to be measured against, and the picker
--- below does not have it: git lists worktrees, not fork points.
local function with_base(repo, place, done)
	if not place or place.base or not place.branch then
		return done(place)
	end
	M.forked(repo, place.dir, function(base)
		place.base = base
		done(place)
	end)
end

--- Pick a place: the checkout you are in, a worktree you already have, or a
--- fresh one. `done` gets it, and is not called at all if you close the list.
function M.choose(repo, done)
	local cwd = vim.fn.getcwd()
	M.trees(repo, nil, function(trees)
		local items = {
			{ name = vim.fn.fnamemodify(cwd, ":t"), dir = cwd, why = "the checkout you are in" },
		}
		for _, tree in ipairs(trees) do
			if tree.dir ~= cwd then
				items[#items + 1] = {
					name = vim.fn.fnamemodify(tree.dir, ":t"),
					dir = tree.dir,
					branch = tree.branch,
					why = tree.branch or tree.head or "",
				}
			end
		end
		items[#items + 1] = { make = true, name = "new worktree", why = "name it, and what to cut it from" }

		require("picker").open({
			title = "Where",
			items = items,
			columns = function(item)
				return {
					{ text = item.name, hl = item.make and "Comment" or "Normal" },
					{ text = item.why, hl = "Comment" },
				}
			end,
			search = function(item)
				return item.name .. " " .. item.why
			end,
			footer = " <CR> work here   <Esc> close ",
			actions = {
				["<CR>"] = function(item)
					if item.make then
						return M.ask(repo, nil, function(place)
							if place then
								done(place)
							end
						end)
					end
					with_base(repo, item, done)
				end,
			},
		})
	end)
end

--- Make one from a keypress, with nothing to run in it yet. `done` is how the
--- dashboard hears that its list has changed.
function M.new(done)
	M.ask(M.repo(), nil, function(place)
		if place then
			vim.notify(("agent: worktree %s on %s"):format(place.name, place.branch))
		end
		if done then
			done(place)
		end
	end)
end

vim.keymap.set("n", "<leader>an", function()
	M.new()
end, { silent = true, desc = "Make a worktree, with or without an agent to put in it" })

return M
