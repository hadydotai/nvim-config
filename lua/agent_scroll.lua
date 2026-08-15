-- Scrolling back through what an agent has said.
--
-- An agent's terminal buffer has no scrollback to scroll. All three CLIs are
-- full-screen programs that repaint in place: claude takes the alternate
-- screen outright, and codex and grok draw inline but still redraw the same
-- rows rather than letting lines scroll off. So `k` in the terminal buffer
-- walks a screen's worth of text and stops, and there is nothing above it.
--
-- What each of them does have is a history of its own, and keys that move
-- through it. So the keys you would scroll a buffer with are sent to the agent
-- instead, and it scrolls itself:
--
--   <C-u> <C-d>      half a screen
--   <C-b> <C-f>      a screen, and <PageUp>/<PageDown> with them
--   k j              a line, where the agent has a key for one
--   gg G             the top, the bottom
--   q <Esc>          back to the conversation
--
-- In normal mode only. Terminal insert mode already sends every key straight
-- through, so the agent's own scrolling has always worked there; it is normal
-- mode, where these keys mean "scroll the buffer" and the buffer is one screen
-- tall, that had nothing to offer.
--
-- Claude and codex keep their history in a view you open first (ctrl-o and
-- ctrl-/), so the first scroll opens it and typing closes it again, which is
-- why TermEnter is watched below. Grok scrolls the screen it is already
-- showing, and has neither. What each takes is in agent_cli.lua.

local M = {}

local agent = require("agent")
local cli = require("agent_cli")

--- The keys, and which movement each asks the agent for. An agent without a
--- key for one of these simply does not get the mapping.
local KEYS = {
	{ "<C-u>", "half_up" },
	{ "<C-d>", "half_down" },
	{ "<C-b>", "page_up" },
	{ "<C-f>", "page_down" },
	{ "<PageUp>", "page_up" },
	{ "<PageDown>", "page_down" },
	{ "k", "up" },
	{ "j", "down" },
	{ "<Up>", "up" },
	{ "<Down>", "down" },
	{ "gg", "top" },
	{ "G", "bottom" },
}

local function scroll_of(run)
	local adapter = run and cli.get(run.cli)
	return adapter and adapter.scroll or nil
end

--- Come back to the conversation, if we ever left it. Called before anything
--- that is about to type, so an agent is never left in its own history with
--- your keystrokes going to a pager.
function M.leave(run)
	local scroll = scroll_of(run)
	if not run or not run.scrolling or not scroll then
		return
	end
	run.scrolling = false
	if scroll.close then
		agent.send(run, scroll.close, false)
	end
end

--- Ask the agent to scroll. The first one opens its history for the CLIs that
--- keep it somewhere else.
function M.move(run, what)
	local scroll = scroll_of(run)
	if not scroll or not scroll[what] then
		return false
	end
	if scroll.open and not run.scrolling then
		agent.send(run, scroll.open, false)
		run.scrolling = true
	end
	agent.send(run, scroll[what], false)
	return true
end

--- Give a run's terminal buffer the keys above. Called once, when the terminal
--- is made.
function M.attach(run)
	local scroll = scroll_of(run)
	if not run or not run.buf or not scroll then
		return
	end

	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = run.buf, silent = true, nowait = true, desc = desc })
	end

	for _, pair in ipairs(KEYS) do
		local lhs, what = pair[1], pair[2]
		if scroll[what] then
			map(lhs, function()
				M.move(run, what)
			end, "Scroll " .. run.cli .. "'s own history")
		end
	end

	if scroll.close then
		for _, lhs in ipairs({ "q", "<Esc>" }) do
			map(lhs, function()
				M.leave(run)
			end, "Back to the conversation")
		end
	end

	-- Typing ends it, whichever way you got there: i, a, <CR> from the
	-- dashboard, or clicking in. The agent is put back where you can talk to it
	-- before the first keystroke arrives.
	vim.api.nvim_create_autocmd("TermEnter", {
		buffer = run.buf,
		callback = function()
			M.leave(run)
		end,
	})
end

return M
