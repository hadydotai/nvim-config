-- The agents you have run, written down, so one can be brought back after
-- Neovim has been closed.
--
-- An agent is a child of this editor and dies with it. Its conversation does
-- not: all three CLIs keep their own transcripts and will resume one by id.
-- What was missing is the id, which is why this file exists - a small list of
-- what was run, where, and under which name, kept in .state/ and reread on
-- startup.
--
-- The id is ours wherever the CLI will take one. claude and grok accept a
-- --session-id we mint, so the name is decided before the agent starts and
-- stays true for every resume after that. codex names its own, so its record
-- carries none and the id is looked up by directory at the moment you resume
-- (see agent_cli.resume_id).
--
--   M.record(run)      remember a run, or update what is remembered
--   M.forget(id)       drop one
--   M.forget_dir(dir)  drop every record for a directory, when it is removed
--   M.newest()         the newest record per directory, newest first
--
-- Records are pruned on load: a directory that no longer exists cannot be
-- resumed into, and a worktree you removed should not leave a row behind.

local M = {}

local PATH = vim.fn.stdpath("state") .. "/agents/sessions.json"

-- Enough to be worth keeping and few enough that the list stays a list. A
-- record is small, but a dashboard row per abandoned experiment is not free.
local KEEP = 40

local records = nil

local function read()
	local f = io.open(PATH, "r")
	if not f then
		return {}
	end
	local text = f:read("*a")
	f:close()
	local ok, value = pcall(vim.json.decode, text)
	return ok and vim.islist(value) and value or {}
end

local function write()
	vim.fn.mkdir(vim.fn.fnamemodify(PATH, ":h"), "p")
	local f = io.open(PATH, "w")
	if not f then
		return false
	end
	f:write(vim.json.encode(records))
	f:close()
	return true
end

--- Newest first, which is both the order the dashboard wants and the order
--- pruning has to work in.
local function sort()
	table.sort(records, function(a, b)
		return (a.at or 0) > (b.at or 0)
	end)
end

local function load()
	if records then
		return records
	end
	records = {}
	for _, one in ipairs(read()) do
		-- A record whose directory is gone is a resume that cannot happen: the
		-- worktree was removed, or the project moved. Dropping it here is what
		-- keeps the file from growing without end.
		if type(one) == "table" and one.cwd and vim.fn.isdirectory(one.cwd) == 1 then
			records[#records + 1] = one
		end
	end
	sort()
	while #records > KEEP do
		table.remove(records)
	end
	return records
end

--- Remember a run, replacing what was remembered under the same id.
---
--- Called on every change worth surviving a restart rather than only at the
--- end, because the end may be Neovim being killed, and a run nobody wrote
--- down is a conversation you cannot get back to.
function M.record(run)
	load()
	if not run.id or not run.cwd then
		return
	end
	local one = {
		id = run.id,
		cli = run.cli,
		name = run.name,
		cwd = run.cwd,
		where = run.where,
		base = run.base,
		session = run.session_id or run.session,
		prompt = run.prompt,
		at = os.time(),
		status = run.status,
	}
	for i, other in ipairs(records) do
		if other.id == one.id then
			records[i] = one
			sort()
			return write()
		end
	end
	table.insert(records, 1, one)
	sort()
	while #records > KEEP do
		table.remove(records)
	end
	return write()
end

function M.forget(id)
	load()
	for i, one in ipairs(records) do
		if one.id == id then
			table.remove(records, i)
			return write()
		end
	end
	return false
end

--- Everything remembered about a directory, gone with it. Called when a
--- worktree is removed, since the conversation is about work that no longer
--- exists anywhere.
function M.forget_dir(dir)
	load()
	local kept, dropped = {}, 0
	for _, one in ipairs(records) do
		if one.cwd == dir then
			dropped = dropped + 1
		else
			kept[#kept + 1] = one
		end
	end
	records = kept
	if dropped > 0 then
		write()
	end
	return dropped
end

function M.all()
	return load()
end

--- The newest record for each directory, newest first. That is what a row on
--- the dashboard stands for: not every conversation ever had in a worktree,
--- but the one you would go back to.
---
--- Not filtered by project here, deliberately. A worktree lives under `.data/`
--- rather than inside the repository it belongs to, so "is this ours" is a
--- question about the list of worktrees, which the dashboard has and this file
--- does not.
function M.newest()
	load()
	local seen, out = {}, {}
	for _, one in ipairs(records) do
		if not seen[one.cwd] then
			seen[one.cwd] = true
			out[#out + 1] = one
		end
	end
	return out
end

return M
