-- Starting an agent: which one, and what you are asking it.
--
-- Two steps and no more. The agent is a keypress from the same dialog
-- everything else uses, and the question is one line of input. What you are
-- pointing at is worked out rather than asked about: a visual selection is
-- obviously the subject when there is one, and the file you are in otherwise.
-- Asking would be a third dialog to answer the question you had already
-- answered by putting the cursor somewhere.
--
-- Where it runs is not asked either. It runs here, in the checkout you are
-- sitting in, which is what you meant most of the time and costs nothing. When
-- it is not what you meant, <C-w> offers the places: a worktree you have, or a
-- new one. Making that worktree is agent_worktree.lua's job, not this file's -
-- a checkout is worth having on its own, and worth keeping for the next agent
-- rather than cut fresh for every question.
--
--   <leader>aa   start one, on the file or the selection
--   <C-w>        in the dialog, somewhere other than here

local M = {}

local agent = require("agent")
local cli = require("agent_cli")
local context = require("agent_context")
local picker = require("picker")
local worktree = require("agent_worktree")

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

--- Ask the question, then start. One dialog, because where it runs was either
--- decided before this or is simply here.
local function ask_and_start(chosen, ctx, place)
	local subject = ctx.selection and ("selection " .. ctx.selection) or ctx.path or "no file"
	local where = place and place.name or vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	vim.ui.input({
		prompt = ("%s (%s, %s): "):format(chosen.name, where, subject),
	}, function(question)
		if question == nil then
			return
		end
		M.start({ cli = chosen.name, question = question, ctx = ctx, place = place })
	end)
end

--- Start an agent outright, with everything already decided.
---
---   cli       which one
---   question  what to ask, may be empty
---   ctx       from agent_context.here(), plus an optional prebuilt text
---   place     where to run it: { dir, branch, name, base }, or nil for here
function M.start(opts)
	local name = opts.name or name_for(opts.question, opts.cli)
	local place = opts.place

	-- Built against the project root, so a path in the prompt reads the same
	-- as one the agent will report back, even though it is working in a
	-- worktree with a different prefix.
	local body = opts.ctx and opts.ctx.text or ""
	local run, err = agent.spawn({
		cli = opts.cli,
		cwd = place and place.dir or vim.fn.getcwd(),
		prompt = context.prompt(body, opts.question),
		name = name,
		label = place and place.branch or nil,
		base = place and place.base or nil,
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
--- what gets sent along without asking. `place` is where it will run, which
--- the dashboard passes when the cursor is on a worktree, and which <C-w>
--- below is for the rest of the time.
function M.show(visual, place)
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
	local where = place and place.name or vim.fn.fnamemodify(vim.fn.getcwd(), ":t")

	picker.open({
		title = "Start an agent in " .. where,
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
		footer = (" <CR> start in %s   <C-w> somewhere else   <Esc> close "):format(where),
		actions = {
			["<CR>"] = function(item)
				ask_and_start(item, ctx, place)
			end,
		},
		commands = {
			-- Reopened rather than redrawn: the dialog has no notion of a place
			-- that changed, and reopening is one line and cannot leave the two
			-- out of step.
			["<C-w>"] = function()
				worktree.choose(root, function(chosen)
					M.show(visual, chosen.dir ~= vim.fn.getcwd() and chosen or nil)
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
