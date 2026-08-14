-- Starting an agent: which one, where it works, and what you are asking.
--
-- Two steps and no more. The agent is a keypress from the same dialog
-- everything else uses, and the question is one line of input. What you are
-- pointing at is worked out rather than asked about: a visual selection is
-- obviously the subject when there is one, and the file you are in otherwise.
-- Asking would be a third dialog to answer the question you had already
-- answered by putting the cursor somewhere.
--
--   <leader>aa   start one, on the file or the selection
--   <C-w>        in the dialog, toggle between a worktree of its own and here

local M = {}

local agent = require("agent")
local cli = require("agent_cli")
local context = require("agent_context")
local picker = require("picker")
local worktree = require("agent_worktree")

-- Sticky across dialogs within a session: having chosen to work in the current
-- checkout once, being asked again on the next spawn is noise.
local isolate = true

local function set_hl()
	vim.api.nvim_set_hl(0, "AgentName", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "AgentWhy", { link = "Comment", default = true })
end

--- What the run will be called: the question, shortened, since that is what
--- you will be looking for on the dashboard. Falls back to the agent's name.
local function name_for(question, cli_name)
	local slug = worktree.slug(question or "")
	if slug:match("^run%-") then
		return cli_name .. "-" .. os.date("%H%M%S")
	end
	return slug
end

--- Branches and tags, for completing where a worktree is cut from and for
--- noticing that the name you are typing is one that already exists.
function _G._agent_refs(lead)
	local root = worktree.repo()
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

--- Names already taken by a worktree of this project, so completing one is how
--- you send a second agent into an existing worktree on purpose.
function _G._agent_names(lead)
	local root = worktree.repo()
	local names = {}
	for _, dir in ipairs(root and worktree.list(root) or {}) do
		names[#names + 1] = vim.fn.fnamemodify(dir, ":t")
	end
	table.sort(names)
	return vim.tbl_filter(function(name)
		return name:find(lead, 1, true) == 1
	end, names)
end

--- Ask the question, then the name and base if it is getting a worktree of its
--- own, then start.
---
--- The name and base are asked rather than derived because where the work goes
--- is a decision, and one that is painful to discover you got wrong an hour
--- later. Both are prefilled with the answer you would have got anyway, so the
--- common path is two more presses of enter, and both complete: the name
--- against worktrees this project already has, the base against every branch
--- and tag.
local function ask_and_start(chosen, ctx, root, into)
	local subject = ctx.selection and ("selection " .. ctx.selection) or ctx.path or "no file"
	local where = into and into.name or (isolate and "worktree" or "here")
	vim.ui.input({
		prompt = ("%s (%s, %s): "):format(chosen.name, where, subject),
	}, function(question)
		if question == nil then
			return
		end
		local function go(name, base)
			M.start({
				cli = chosen.name,
				question = question,
				name = name,
				base = base,
				ctx = ctx,
				root = root,
				into = into,
				isolate = isolate,
			})
		end
		-- A worktree that already exists answers both questions below: it has a
		-- name, and it is already cut from wherever it was cut from.
		if into then
			return go(into.name, nil)
		end
		if not isolate or not root then
			return go(nil, nil)
		end
		vim.ui.input({
			prompt = "worktree name: ",
			default = name_for(question, chosen.name),
			completion = "customlist,v:lua._agent_names",
		}, function(name)
			if name == nil then
				return
			end
			vim.ui.input({
				prompt = "cut from: ",
				default = "HEAD",
				completion = "customlist,v:lua._agent_refs",
			}, function(base)
				if base == nil then
					return
				end
				go(worktree.slug(name), vim.trim(base) ~= "" and vim.trim(base) or "HEAD")
			end)
		end)
	end)
end

--- Start an agent outright, with everything already decided.
---
---   cli       which one
---   question  what to ask, may be empty
---   ctx       from agent_context.here(), plus an optional prebuilt text
---   isolate   give it a worktree of its own
---   into      a worktree that already exists: { dir, branch, name, base }
function M.start(opts)
	local root = opts.root or worktree.repo()
	local name = opts.name or name_for(opts.question, opts.cli)
	local cwd, branch, base = vim.fn.getcwd(), nil, nil

	if opts.into then
		-- Sending an agent into work that is already there, which is how a
		-- worktree whose agent has gone gets picked back up.
		cwd, branch, base = opts.into.dir, opts.into.branch, opts.into.base
	elseif opts.isolate then
		if not root then
			vim.notify("agent: not a git repository, running here instead", vim.log.levels.WARN)
		else
			local dir, made, from, err = worktree.create(root, name, opts.base)
			if not dir then
				vim.notify("agent: " .. tostring(err) .. ", running here instead", vim.log.levels.WARN)
			else
				cwd, branch, base = dir, made, from
			end
		end
	end

	-- Built against the project root, so a path in the prompt reads the same
	-- as one the agent will report back, even though it is working in a
	-- worktree with a different prefix.
	local body = opts.ctx and opts.ctx.text or ""
	local run, err = agent.spawn({
		cli = opts.cli,
		cwd = cwd,
		prompt = context.prompt(body, opts.question),
		name = name,
		label = branch,
		base = base,
	})
	if not run then
		vim.notify("agent: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end

	local adapter = cli.get(opts.cli)
	if adapter and adapter.note and not vim.g.agent_noted_ then
		vim.g.agent_noted_ = true
		vim.notify("agent: " .. adapter.note, vim.log.levels.INFO)
	end
	-- Something has to say it started, since the agent itself is off in a
	-- hidden buffer. The dashboard is that, unless a view is already open, in
	-- which case it has said so already.
	local dash = require("agent_dash")
	if not dash.visible() then
		dash.open(run)
	end
	return run
end

--- Pick an agent back up where it was left, from what was written down about
--- it (see agent_store).
---
--- The id is the record's for claude and grok, which took one we chose. Codex
--- named its own, so it is looked up now, by the directory - which also finds
--- a codex you started in that worktree from an ordinary terminal.
function M.resume(record)
	if not record then
		return nil
	end
	local adapter = cli.get(record.cli)
	if not adapter then
		vim.notify("agent: " .. tostring(record.cli) .. " is not installed", vim.log.levels.WARN)
		return nil
	end
	local id = record.session
	if not id and adapter.resume_id then
		id = adapter:resume_id(record.cwd)
	end
	if not id then
		vim.notify(
			("agent: no %s conversation recorded for %s"):format(record.cli, record.name or record.cwd),
			vim.log.levels.WARN
		)
		return nil
	end

	local run, err = agent.spawn({
		cli = record.cli,
		cwd = record.cwd,
		name = record.name,
		label = record.where,
		base = record.base,
		resume = id,
	})
	if not run then
		vim.notify("agent: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	local dash = require("agent_dash")
	if not dash.visible() then
		dash.open(run)
	end
	return run
end

--- The dialog. `visual` says the mapping came from a selection, which decides
--- what gets sent along without asking. `into` is a worktree that already
--- exists, which the dashboard passes when the cursor is on one.
function M.show(visual, into)
	local available = cli.available()
	if #available == 0 then
		vim.notify("agent: none of claude, codex or grok are installed", vim.log.levels.WARN)
		return
	end

	local root = worktree.repo()
	local ctx = context.here(root)

	-- Captured now, before the dialog takes the cursor out of the buffer.
	if visual then
		for _, source in ipairs(context.offered(ctx)) do
			if source.name == "selection" then
				ctx.text = source.text
				ctx.selection = tostring(vim.api.nvim_buf_get_mark(ctx.buf, "<")[1])
					.. "-"
					.. tostring(vim.api.nvim_buf_get_mark(ctx.buf, ">")[1])
			end
		end
	end
	if not ctx.text and ctx.path then
		ctx.text = ("In %s:"):format(ctx.path)
	end

	set_hl()
	local footer = into and (" <CR> start in %s   <Esc> close "):format(into.name)
		or (" <CR> start   <C-w> %s   <Esc> close "):format(isolate and "run here instead" or "give it a worktree")

	picker.open({
		title = into and ("Start an agent in " .. into.name) or "Start an agent",
		items = available,
		columns = function(item)
			return {
				{ text = item.label, hl = "AgentName" },
				{ text = item.note and "trust prompt on first run" or "", hl = "AgentWhy" },
			}
		end,
		search = function(item)
			return item.name .. " " .. item.label
		end,
		footer = footer,
		actions = {
			["<CR>"] = function(item)
				ask_and_start(item, ctx, root, into)
			end,
		},
		commands = {
			-- Reopened rather than redrawn: the dialog has no notion of a
			-- setting that changed, and reopening is one line and cannot
			-- leave the two out of step.
			["<C-w>"] = function()
				isolate = not isolate
				vim.schedule(function()
					M.show(visual, into)
				end)
			end,
		},
	})
end

--- Send what you are pointing at to an agent that is already running, which is
--- the other half of the loop: the first prompt starts it, and this is every
--- correction after. Which context to send is asked here, unlike at spawn,
--- because by now you have a reason to prefer one.
function M.send(visual)
	local runs = {}
	for _, run in ipairs(agent.runs()) do
		if run.status ~= "exited" then
			runs[#runs + 1] = run
		end
	end
	if #runs == 0 then
		vim.notify("agent: nothing running. <leader>aa starts one", vim.log.levels.WARN)
		return
	end

	local root = worktree.repo()
	local ctx = context.here(root)
	local sources = context.offered(ctx)
	if visual then
		for _, source in ipairs(sources) do
			if source.name == "selection" then
				sources = { source }
			end
		end
	end

	set_hl()
	picker.open({
		title = "Send to",
		items = runs,
		columns = function(run)
			return {
				{ text = run.name, hl = "AgentName" },
				{ text = run.cli .. "  " .. tostring(run.doing or ""), hl = "AgentWhy" },
			}
		end,
		search = function(run)
			return run.name .. " " .. run.cli
		end,
		footer = " <CR> choose what to send   <Esc> close ",
		actions = {
			["<CR>"] = function(run)
				picker.open({
					title = "Send what",
					items = sources,
					columns = function(source)
						return {
							{ text = source.label, hl = "AgentName" },
							{ text = source.text:gsub("%s+", " "):sub(1, 60), hl = "AgentWhy" },
						}
					end,
					search = function(source)
						return source.label
					end,
					actions = {
						["<CR>"] = function(source)
							vim.ui.input({ prompt = run.name .. " < " }, function(question)
								if question == nil then
									return
								end
								agent.send(run, context.prompt(source.text, question))
							end)
						end,
					},
				})
			end,
		},
	})
end

vim.keymap.set("n", "<leader>aa", function()
	M.show(false)
end, { silent = true, desc = "Start an agent on this file" })

vim.keymap.set("n", "<leader>ac", function()
	M.send(false)
end, { silent = true, desc = "Send this file or line to a running agent" })

vim.keymap.set("x", "<leader>ac", function()
	vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
	M.send(true)
end, { silent = true, desc = "Send the selection to a running agent" })

vim.keymap.set("x", "<leader>aa", function()
	-- Left first so the < and > marks are set, which is where the selection is
	-- read from once the mapping is running.
	vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
	M.show(true)
end, { silent = true, desc = "Start an agent on the selection" })

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

return M
