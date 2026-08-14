-- A git worktree per agent, so two of them working at once cannot overwrite
-- each other's edits.
--
-- The alternative is letting every agent edit the checkout you are sitting in,
-- which is fine for one and quietly destructive for two: they do not take
-- turns, and neither of them knows the other exists. A worktree costs a
-- checkout and gives back the ability to run several and read the diffs
-- separately.
--
-- They live under .data/, which is gitignored, so a few gigabytes of checkouts
-- never reach a commit. The layout mirrors what latis does:
--
--   .data/nvim/agents/worktrees/<repo>-<hash>/<name>
--
-- The hash is of the full path to the repository, so two checkouts of the same
-- project with the same basename stay apart.

local M = {}

local ROOT = vim.fn.stdpath("data") .. "/agents/worktrees"

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

--- A short stable digest of a path, so two projects called "api" do not share
--- a directory.
local function digest(path)
	return vim.fn.sha256(path):sub(1, 12)
end

function M.dir(repo, name)
	return ("%s/%s-%s/%s"):format(ROOT, vim.fn.fnamemodify(repo, ":t"), digest(repo), name)
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

	return dir, branch, from
end

--- Remove a worktree and, if it is unmerged work you asked to drop, its branch.
--- Refuses while the checkout is dirty unless told otherwise, because the whole
--- point of the thing is work you have not read yet.
function M.remove(repo, dir, force)
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
