-- Coding agents as things Neovim runs and watches: what is running, what it is
-- doing, and how to talk to it. The dashboard and the sidebar are views onto
-- this file; nothing else here knows they exist.
--
-- An agent runs its own terminal UI in a hidden buffer, so permission prompts,
-- slash commands and its own rendering all work exactly as they do in a
-- terminal. What Neovim adds is knowing, without looking, which of them is
-- working, which is waiting on you, and which has finished.
--
-- That knowledge comes from hooks the agent itself fires (see agent_cli.lua),
-- which write a small file per event into an inbox directory this file
-- watches. A file rather than a socket because a hook that blocks blocks the
-- agent: writing a file cannot fail slowly, but an RPC into a busy Neovim can,
-- and the agent would be sitting on it against its own hook timeout.
--
--   M.spawn{cli=, cwd=, prompt=}  start one
--   M.runs()                      newest first, for the views
--   M.send(run, text)             type into it
--   M.watch(fn)                   call fn whenever anything changes
--
-- One thing to know: an agent is a child of this Neovim, so quitting Neovim
-- ends it. Agents do not outlive the editor the way a tmux pane would.

local M = {}

local cli = require("agent_cli")

-- Names a hook's ancestry can pass through that mean "another agent is running
-- inside this one". Its own process is expected in the chain; a second one is
-- the tell that this event belongs to a nested agent rather than ours.
local AGENT_COMMS = { claude = true, codex = true, grok = true }

local runs = {}
local order = 0
local watchers = {}
local wired = {}
local problems = {}

--------------------------------------------------------------------------- --
-- the store
--------------------------------------------------------------------------- --

local function changed()
	for _, fn in ipairs(watchers) do
		pcall(fn)
	end
end

--- Subscribe to any change in any run. Returns a function that unsubscribes.
function M.watch(fn)
	watchers[#watchers + 1] = fn
	return function()
		for i, other in ipairs(watchers) do
			if other == fn then
				table.remove(watchers, i)
				return
			end
		end
	end
end

--- Every run, newest first.
function M.runs()
	local out = {}
	for _, run in pairs(runs) do
		out[#out + 1] = run
	end
	table.sort(out, function(a, b)
		return a.order > b.order
	end)
	return out
end

function M.get(id)
	return runs[id]
end

function M.problems()
	return problems
end

local function status(run, new, doing)
	-- Once a run has exited nothing can revive it: a Stop hook arriving after
	-- the process is gone is just a slow write, not news.
	if run.status == "exited" then
		return
	end
	local was, doing_was = run.status, run.doing
	run.status = new
	run.since = (was ~= new) and os.time() or run.since
	run.updated = os.time()
	if doing then
		run.doing = doing
	end
	if was ~= new or doing_was ~= run.doing then
		changed()
	end
end

--------------------------------------------------------------------------- --
-- the inbox
--------------------------------------------------------------------------- --

--- Which run an event belongs to, or nil to drop it.
---
--- The run id is authoritative when the agent passed our environment through.
--- Otherwise the ancestry decides: the first process in the chain that we
--- started is the run, unless another agent sits between it and the hook, in
--- which case this event is the nested agent's and saying so would end our
--- agent's turn on its behalf.
local function route(event)
	if event.run ~= "" and runs[event.run] then
		return runs[event.run]
	end
	local chain = {}
	for pid, comm in (event.pids or ""):gmatch("(%d+):(%S*)") do
		chain[#chain + 1] = { pid = tonumber(pid), comm = comm }
	end
	local nested = 0
	for _, step in ipairs(chain) do
		for _, run in pairs(runs) do
			if run.pid == step.pid then
				return nested > 0 and nil or run
			end
		end
		if AGENT_COMMS[step.comm] then
			nested = nested + 1
		end
	end
	return nil
end

local function apply(event)
	local run = route(event)
	if not run then
		return
	end
	-- Codex names its own conversations, so this is the one chance to hear the
	-- id from the agent itself rather than looking it up later.
	if event.session ~= "" and run.session ~= event.session then
		run.session = event.session
		require("agent_store").record(run)
	end
	local name = event.event
	if name == "UserPromptSubmit" then
		status(run, "working", "thinking")
	elseif name == "PostToolUse" then
		status(run, "working", event.tool ~= "" and event.tool or "working")
	elseif name == "Notification" or name == "PermissionRequest" then
		status(run, "waiting", "needs you")
	elseif name == "Stop" then
		-- Said explicitly rather than left alone: whatever it was last doing
		-- is over, and a stale "needs you" from a permission prompt it has
		-- since been through reads as though it is still asking.
		status(run, "idle", "your turn")
	end
end

--- Read everything waiting in the inbox and delete it. Files are named by the
--- second they were written, so sorting the names replays them in order.
local function drain()
	local dir = cli.INBOX
	if vim.fn.isdirectory(dir) == 0 then
		return
	end
	local names = vim.fn.readdir(dir, function(name)
		return name:match("%.json$") and 1 or 0
	end)
	table.sort(names)
	for _, name in ipairs(names) do
		local path = dir .. "/" .. name
		local f = io.open(path, "r")
		if f then
			local text = f:read("*a")
			f:close()
			local ok, event = pcall(vim.json.decode, text)
			if ok and type(event) == "table" and event.event then
				pcall(apply, event)
			end
		end
		vim.fn.delete(path)
	end
end

local watcher, ticker

--- Watch the inbox. The fs event is what makes a status change feel immediate;
--- the timer behind it is because fs events are not reliable everywhere (and
--- on macOS not at all for some volumes), and a status that is a second late
--- is much better than one that never arrives.
local function listen()
	if ticker then
		return
	end
	vim.fn.mkdir(cli.INBOX, "p")
	drain()

	watcher = vim.uv.new_fs_event()
	if watcher then
		pcall(function()
			watcher:start(cli.INBOX, {}, function()
				vim.schedule(drain)
			end)
		end)
	end

	ticker = vim.uv.new_timer()
	ticker:start(1000, 1000, function()
		vim.schedule(function()
			drain()
			-- The views are woken whether or not anything happened here: elapsed
			-- time is on screen, and they show worktrees as well as runs, which
			-- change without this file ever hearing about it. Both are guarded
			-- on being visible, so the cost of a tick nobody is watching is a
			-- loop over an empty list.
			changed()
		end)
	end)
end

--------------------------------------------------------------------------- --
-- running one
--------------------------------------------------------------------------- --

local function id()
	order = order + 1
	return ("%d%s"):format(order, tostring(os.time()):sub(-4))
end

--- Start an agent.
---
---   cli     name from agent_cli (claude, codex, grok)
---   cwd     where it runs, defaulting to Neovim's
---   prompt  what to ask it, passed as the CLI's initial prompt
---   name    what to call it on the dashboard
---   label   extra description of where it is running, e.g. a worktree branch
---   resume  a conversation id to pick up instead of starting a new one
---
--- Returns the run, or nil and a reason.
function M.spawn(opts)
	opts = opts or {}
	local adapter = cli.get(opts.cli)
	if not adapter then
		return nil, "unknown agent: " .. tostring(opts.cli)
	end
	if vim.fn.executable(adapter.bin) == 0 then
		return nil, adapter.bin .. " is not installed"
	end

	local cwd = opts.cwd or vim.fn.getcwd()
	if vim.fn.isdirectory(cwd) == 0 then
		return nil, "no such directory: " .. cwd
	end

	local run = {
		id = id(),
		cli = adapter.name,
		label = adapter.label,
		name = opts.name or vim.fn.fnamemodify(cwd, ":t"),
		where = opts.label,
		base = opts.base,
		cwd = cwd,
		prompt = opts.prompt,
		resume = opts.resume,
		-- Minted here, before the agent starts, for the CLIs that will take
		-- one: that is what makes this conversation findable again tomorrow.
		-- A resume keeps the id it is resuming rather than minting a second.
		session_id = opts.resume or (adapter.mints and cli.uuid() or nil),
		status = "starting",
		doing = "starting",
		since = os.time(),
		updated = os.time(),
		order = order,
	}

	local env = vim.tbl_extend("force", {
		NVIM_AGENT_RUN = run.id,
		NVIM_AGENT_INBOX = cli.INBOX,
	}, adapter.env and adapter:env() or {})

	-- Listed, so <leader>b finds an agent the same way it finds anything else.
	-- The dashboard is the view built for them, but a terminal running in this
	-- editor that does not appear in the list of buffers is a thing you can
	-- only reach through the one window that knows about it.
	local buf = vim.api.nvim_create_buf(true, false)
	vim.bo[buf].bufhidden = "hide"

	local job
	local ok, err = pcall(function()
		vim.api.nvim_buf_call(buf, function()
			job = vim.fn.jobstart(adapter:argv(run), {
				term = true,
				cwd = cwd,
				env = env,
				on_exit = function(_, code)
					run.exit_code = code
					run.status = "exited"
					run.doing = code == 0 and "finished" or ("exited " .. code)
					run.since = os.time()
					run.updated = os.time()
					vim.schedule(function()
						require("agent_store").record(run)
						changed()
					end)
				end,
			})
		end)
	end)
	if not ok or not job or job <= 0 then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		return nil, "could not start " .. adapter.bin .. (ok and "" or (": " .. tostring(err)))
	end

	run.buf = buf
	run.job = job
	run.chan = job
	run.pid = (pcall(vim.fn.jobpid, job)) and vim.fn.jobpid(job) or nil
	-- Named after the run rather than the pid and shell path a terminal buffer
	-- is called by default, since this is the name <leader>b will show.
	pcall(vim.api.nvim_buf_set_name, buf, ("agent://%s/%s"):format(adapter.name, run.name))
	vim.b[buf].agent_run = run.id
	-- The terminal buffer has no scrollback of its own to scroll, so the keys
	-- that would scroll one ask the agent to scroll its own history instead.
	require("agent_scroll").attach(run)

	runs[run.id] = run
	require("agent_store").record(run)
	-- An agent handed a question is working on it before any hook can say so.
	-- One that was not - a resume, or a start with nothing to ask yet - comes
	-- up at its prompt waiting for you, and "starting" is then a state it never
	-- leaves, since the first hook of a turn does not fire until you type.
	local asked = run.prompt and vim.trim(run.prompt) ~= ""
	status(run, asked and "working" or "idle", asked and "starting" or "ready")
	listen()
	changed()
	return run
end

--- Type into a running agent. The trailing carriage return is what submits it,
--- and is separated because some CLIs drop a newline that arrives in the same
--- write as the text before their prompt is ready.
function M.send(run, text, submit)
	if not run or not run.chan or run.status == "exited" then
		return false
	end
	local ok = pcall(vim.api.nvim_chan_send, run.chan, text)
	if ok and submit ~= false then
		vim.defer_fn(function()
			pcall(vim.api.nvim_chan_send, run.chan, "\r")
		end, 40)
	end
	return ok
end

--- Stop an agent. Terminating rather than killing so it can save its session.
function M.stop(run)
	if run and run.job and run.status ~= "exited" then
		pcall(vim.fn.jobstop, run.job)
		return true
	end
	return false
end

--- Forget a run that has exited, and its buffer with it.
function M.forget(run)
	if not run or run.status ~= "exited" then
		return false
	end
	if run.buf and vim.api.nvim_buf_is_valid(run.buf) then
		pcall(vim.api.nvim_buf_delete, run.buf, { force = true })
	end
	runs[run.id] = nil
	changed()
	return true
end

--- How long a run has been in its current state, as something short enough for
--- a column.
function M.elapsed(run)
	local seconds = os.time() - (run.since or os.time())
	if seconds < 60 then
		return seconds .. "s"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. "m"
	end
	return ("%dh%02dm"):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

--- What is wired and what is not, in the shape :Deps reports things. Worth
--- having because a CLI whose hooks failed to install still runs, so without
--- being told you would only notice by the dashboard staying quiet.
local function report()
	local lines = {}
	for _, one in ipairs(cli.available()) do
		local ok = false
		for _, other in ipairs(wired) do
			ok = ok or other.name == one.name
		end
		lines[#lines + 1] = ("  %-8s %s%s"):format(one.name, ok and "tracked" or "runs, but not tracked", one.note and ("  (" .. one.note .. ")") or "")
	end
	if #lines == 0 then
		lines[1] = "  none of claude, codex or grok are installed"
	end
	for _, why in ipairs(problems) do
		lines[#lines + 1] = "  " .. why
	end
	local live = 0
	for _, run in pairs(runs) do
		live = live + (run.status ~= "exited" and 1 or 0)
	end
	table.insert(lines, 1, ("agents: %d running"):format(live))
	vim.notify(table.concat(lines, "\n"))
end

function M.setup()
	wired, problems = cli.setup()
	listen()

	vim.api.nvim_create_user_command("Agents", function(opts)
		if opts.args == "check" then
			report()
		else
			require("agent_dash").open()
		end
	end, {
		nargs = "?",
		complete = function()
			return { "check" }
		end,
		desc = "The agent dashboard, or :Agents check for what is wired",
	})

	-- An agent is a child of this process, so leaving without stopping them
	-- would have Neovim wait on terminals it is about to discard anyway.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("agent_leave", { clear = true }),
		callback = function()
			for _, run in pairs(runs) do
				pcall(vim.fn.jobstop, run.job)
			end
		end,
	})
	return wired, problems
end

return M
