-- A git worktree per agent, so two of them working at once cannot overwrite
-- each other's edits.
--
-- The alternative is letting every agent edit the checkout you are sitting in,
-- which is fine for one and quietly destructive for two: they do not take
-- turns, and neither of them knows the other exists. A worktree costs a
-- checkout and gives back the ability to run several and read the diffs
-- separately.
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

--- Make a worktree for `name` on a new branch cut from HEAD.
---
--- Returns the path, the branch and the commit it was cut from, or nil and a
--- reason. The commit is worth keeping: it is the only honest answer to "what
--- has this agent changed" once it starts committing, and it stops being
--- derivable from the branch the moment anything else moves.
---
--- An existing worktree of the same name is reused rather than treated as an
--- error: asking twice for the same thing should give you the same thing.
function M.create(repo, name, base)
	if not repo then
		return nil, nil, nil, "not a git repository"
	end
	local dir = M.dir(repo, name)
	local branch = "agent/" .. name
	local _, from = git({ "rev-parse", base or "HEAD" }, repo)

	if vim.fn.isdirectory(dir) == 1 then
		return dir, branch, from
	end

	vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")

	-- An existing branch of this name means a previous run of the same name,
	-- so check it out rather than failing on "already exists".
	local exists = select(1, git({ "rev-parse", "--verify", "--quiet", branch }, repo))
	local args = exists and { "worktree", "add", dir, branch }
		or { "worktree", "add", "-b", branch, dir, base or "HEAD" }

	local ok, _, err = git(args, repo)
	if not ok then
		return nil, nil, nil, err ~= "" and err or "git worktree add failed"
	end

	-- A checkout with none of the gitignored things the project needs is a
	-- checkout that does not build, so the setup is part of creating one
	-- rather than something to remember afterwards.
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

	return dir, branch, from
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

return M
