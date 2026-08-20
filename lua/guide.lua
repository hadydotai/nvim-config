-- <leader>H: how to use this editor, in the order you would want to learn it.
--
-- Not the README, which is written for someone deciding whether to read the
-- code. This is for someone with the editor already open: what to press, what
-- happens, and the few ideas the rest of it follows from.
--
-- It checks itself. Every key named below is looked up in the registry
-- lua/keys.lua keeps, so one that has been renamed or removed is drawn as
-- missing rather than left standing as a sentence that is quietly no longer
-- true, and anything this configuration maps that the guide never mentions is
-- listed at the end. A document living in the same repository as the thing it
-- describes should not be able to drift from it in silence.
--
-- Markdown, drawn by lua/markdown.lua, because that already exists and a guide
-- is the kind of prose it was written for. The buffer is filetype "guide"
-- rather than "markdown" so it is not mistaken for a file you are editing;
-- treesitter is pointed at markdown by hand, which is all the renderer needs.

local M = {}

local keys = require("keys")
local markdown = require("markdown")

--------------------------------------------------------------------------- --
-- what the guide says
--------------------------------------------------------------------------- --

-- Each section is a heading, some prose, and the keys it covers.
--
-- A key entry is { lhs, what it does }, plus at most one of:
--   where  the buffer kind it is recorded under, checked and shown
--   scope  a place we do not record, shown but not checked
--   mode   shown instead of a place, for the ones that are not normal mode
--   also   further keys this row stands for, so they count as covered
--
-- `covers` on the section itself is for keys the prose explains without a row
-- of their own, which is the honest way to describe a group of five that all
-- do the same thing.
local SECTIONS = {
	{
		id = "about",
		title = "What this is",
		body = [==[
No plugin manager, no framework and nothing lazy loaded. Every file in `lua/`
is one idea, loaded at startup by `init.lua`, and the editor is a git
repository you are free to edit while it is running.

One consequence comes before all the others: this configuration is meant to be
read from inside itself. `<leader>h` lists every mapping it sets, each with
the file and line that set it, so any key you meet can be followed back to the
code and the comment explaining why it exists.

`<leader>` is the space bar.
]==],
		keys = {
			{ "<leader>h", "Every mapping this configuration sets, and where it was set" },
			{ "<leader>H", "This guide" },
		},
	},

	{
		id = "windows",
		title = "Windows, and where a file opens",
		body = [==[
One idea runs through every list here, so learn it once. Anything that opens a
file asks where to put it.

`<CR>` outlines the windows it could open into and waits: `hjkl` moves between
the outlines and `<CR>` again opens there. With only one candidate it skips the
question rather than asking a question with one answer. `<S-CR>` never asks and
takes the obvious window, which is the one you came from.

`<C-w>` on its own numbers the panes and then carries on as the usual window
prefix, so `<C-w>2` goes to pane 2 without you counting them.

The file tree is protected from the commands that would displace it. `<C-w>r`,
`<C-w>R`, `<C-w>x` and `<C-w>X` are turned off rather than left to rotate the
tree into the middle of your layout, and the moves keep it in its column.
]==],
		-- The disabled four, and the control spellings of them. win_number.lua
		-- adopts every <C-w>x mapping there is and re-declares it with whatever
		-- followed the prefix left raw, so <C-w><C-r> is recorded as <C-w> and a
		-- literal 0x12 rather than as anything it could be typed as here.
		covers = {
			"<C-w>r",
			"<C-w>R",
			"<C-w>x",
			"<C-w>X",
			"<C-w>" .. vim.keycode("<C-r>"),
			"<C-w>" .. vim.keycode("<C-x>"),
		},
		keys = {
			{ "<C-w>", "Number the panes, then the window command you meant" },
			{ "<C-w>s", "Split, never splitting the tree" },
			{ "<C-w>v", "Vertical split, never splitting the tree" },
			{ "<C-w>H", "Move this window over, leaving the tree where it is", also = { "<C-w>J", "<C-w>K", "<C-w>L" } },
			{
				"<C-w>d",
				"The diagnostic under the cursor, in full",
				also = { "<C-w>" .. vim.keycode("<C-d>") },
			},
			{ "<C-b>", "The buffer you were in before this one" },
		},
	},

	{
		id = "files",
		title = "Finding a file",
		body = [==[
`<leader>f` searches the project by file name, narrowing as you type.
`<leader>b` is the same dialog over the buffers already open, which is the
faster of the two once you are a few files in.

Both open through the window question above, so `<CR>` picks a window and
`<S-CR>` takes the obvious one.
]==],
		keys = {
			{ "<leader>f", "Find a file by name" },
			{ "<leader>b", "The buffers already open" },
		},
	},

	{
		id = "tree",
		title = "The file tree",
		body = [==[
`<leader>e` opens the tree down the left and closes it again. It is netrw,
Neovim's own browser, taught to remember which directories you had expanded so
a toggle does not put you back at the top.

`<leader>E` moves between the tree and what you were editing, which is the
movement you actually want: the tree is somewhere you pass through rather than
somewhere you stay.

Inside it, `<CR>` asks which window to open into exactly as the lists do, and
`<S-CR>` takes netrw's own answer.
]==],
		keys = {
			{ "<leader>e", "Open the tree, or close it" },
			{ "<leader>E", "Jump between the tree and the last window" },
			{ "<CR>", "Outline the windows, and open in the one you pick", where = "netrw" },
			{ "<S-CR>", "Open in the previous window without asking", where = "netrw" },
			{ "%", "Make a file, then choose where to open it", where = "netrw" },
		},
	},

	{
		id = "search",
		title = "Searching the project",
		body = [==[
`<leader>g` greps the project with ripgrep, showing matches as you type rather
than after you commit to a pattern.

`<CR>` opens a match through the window question. `<C-q>` sends the whole
result set to the quickfix list, which is what you want the moment the answer
is "all of them" and you are about to work through it.
]==],
		keys = {
			{ "<leader>g", "Grep the project, and <C-q> for all of it at once" },
		},
	},

	{
		id = "lsp",
		title = "Language servers",
		body = [==[
Five are configured and start on their own when you open a file they handle:
lua_ls, pylsp, tsgo, gopls and rust_analyzer. There is nothing to enable per
project.

Most of the verbs are Neovim's own. They are listed here anyway, so the set
reads as one thing rather than as ours plus a separate set you are expected to
already know.

`K` takes two presses. The first shows the documentation; the second moves the
cursor into that float, where the usual motions scroll it and `q` closes it.

`:lsp` drives the servers themselves. `:lsp restart` after changing a project's
configuration, and `:lsp stop`, `:lsp enable`, `:lsp disable` for the rest. It
is `:lsp`, not `:LspRestart`, which belonged to a plugin this does not have.
]==],
		keys = {
			{ "gd", "Go to definition" },
			{ "K", "Documentation, and K again to move into it" },
			{ "grn", "Rename this symbol" },
			{ "gra", "Code actions" },
			{ "grr", "References, in the quickfix list" },
			{ "gri", "Go to implementation" },
			{ "grt", "Go to type definition" },
			{ "grx", "Run the code lens under the cursor" },
			{ "<C-]>", "Go to definition through 'tagfunc'" },
			{ "<C-s>", "Signature help", mode = "insert" },
			{ "<leader>l", "The LSP log, for when a server behaves as though absent" },
		},
	},

	{
		id = "completion",
		title = "Completion",
		body = [==[
Completion is Neovim's own, fed by the language server, and it triggers by
itself as you type. The keys are the built-in insert mode ones rather than
anything this configuration adds.

| key | |
| --- | --- |
| `<C-y>` | take the highlighted match |
| `<C-e>` | dismiss the list, keeping what you typed |
| `<C-n>` `<C-p>` | move through the list |
| `<C-x><C-o>` | ask for it again after dismissing it |

The first match is highlighted rather than inserted, and the documentation
follows the highlight, so the list reads as something you are moving through
and nothing reaches your buffer until you take it.

The list stays up when it narrows to a single candidate. With the default
setting the popup is drawn only when there is more than one match, so a list
that is filtering correctly disappears at the moment it has found your answer,
and looks broken.

The documentation beside the list cannot be moved into, unlike `K`'s float. It
is the popup 'completeopt' draws, and Neovim gives it no focus. Take the match
and press `K` when you want to read the long version.
]==],
	},

	{
		id = "diagnostics",
		title = "Diagnostics",
		body = [==[
`<leader>d` and `<leader>D` step forward and back through this buffer's
diagnostics. `<C-w>d` shows the one under the cursor in full, which is the only
way to read the long ones that end in an ellipsis.

`<leader>q` puts this buffer's diagnostics in the quickfix list and `<leader>Q`
puts every buffer's there. That is the difference between fixing a file and
finding out how bad things are.

In the quickfix list itself, `K` shows the entry under the cursor in full,
diagnostic or not.
]==],
		keys = {
			{ "<leader>d", "Next diagnostic" },
			{ "<leader>D", "Previous diagnostic" },
			{ "<leader>q", "This buffer's diagnostics, in the quickfix list" },
			{ "<leader>Q", "Every buffer's diagnostics, in the quickfix list" },
			{ "K", "The entry under the cursor, in full", where = "qf" },
		},
	},

	{
		id = "symbols",
		title = "Symbols",
		body = [==[
`<leader>s` lists what is in this buffer as a dialog you can filter, and `gO`
is the same list sent to the quickfix window when you would rather work through
it than jump once.

`<leader>S` searches symbols across the whole workspace. The server does the
matching as you type rather than the dialog filtering a list it already holds,
so it works on projects far too large to enumerate.
]==],
		keys = {
			{ "<leader>s", "Symbols in this buffer" },
			{ "<leader>S", "Symbols across the workspace, matched by the server" },
			{ "gO", "Symbols in this buffer, in the quickfix list" },
		},
	},

	{
		id = "editing",
		title = "Editing",
		body = [==[
Brackets and quotes close themselves, with the details that usually make that
irritating taken care of: a closer typed where one already sits steps over it
instead of doubling it, backspace between an empty pair takes both halves, and
`<CR>` between a pair opens a line and leaves the closer below. A quote does
not close itself when a word is in the way, and a third one fences a docstring.

Yank, delete and paste go through the system clipboard, so `y` and `p` cross
the editor boundary without reaching for `"+` each time. The cost is that `d`,
`c` and `x` clobber it too. `"0` is the way back: it holds the last thing
yanked and nothing that was merely deleted.

Folds come from the language server where one is attached and from treesitter
otherwise, and they start open.

All five of these are insert mode, and none of them changes what the key does
anywhere else.
]==],
		keys = {
			{ "( [ {", "Insert the closing half, unless a word is in the way" },
			{ ") ] }", "Step over the closer already there" },
			{ '" \' `', "Open or close a string; a third fences a docstring" },
			{ "<BS>", "Between an empty pair, delete both halves" },
			{ "<CR>", "Between a pair, open a line with the closer below" },
		},
	},

	{
		id = "markdown",
		title = "Reading markdown",
		body = [==[
`<leader>p` in a markdown file stops the markers being drawn. Headings lose
their hashes and gain weight, bullets become dots, quotes a bar, and tables are
aligned to their widest cell.

It is the same buffer, still editable, with the cursor where you left it, and
the colours are the colorscheme's rather than a renderer's idea of them. Press
it again for the source. This guide is drawn by exactly that code.
]==],
		keys = {
			{ "<leader>p", "Draw this markdown, or stop drawing it", scope = "markdown files" },
		},
	},

	{
		id = "agents",
		title = "Agents",
		body = [==[
A coding agent runs its own terminal interface in a hidden buffer, so its
permission prompts, slash commands and rendering are its own and behave exactly
as they do in a terminal. What this adds is knowing, without going to look,
which agent is working, which is waiting on you and which has finished.

`<leader>aa` starts one on the file you are in or the lines you have selected.
`<leader>ac` sends that same context to one already running, which is usually
what you want mid-edit. Both open a dialog: which agent, what to send with it,
and what to ask.

`<leader>ad` is the dashboard, a row per piece of work rather than per process.
`<leader>ae` is the same list as a column narrow enough to leave open.

Status comes from the agents themselves through their hooks rather than from
watching their output, and nothing is installed into `~/.claude`, `~/.codex` or
`~/.grok` to arrange it.
]==],
		keys = {
			{ "<leader>aa", "Start an agent on this file or selection" },
			{ "<leader>ac", "Send this file, line, selection or diagnostics to one running" },
			{ "<leader>ad", "The dashboard: every agent and what it is doing" },
			{ "<leader>ae", "The sidebar: the same, in a column" },
			{ "<CR>", "Open this agent's terminal in a window you pick", scope = "the dashboard" },
			{ "d", "Read what changed here, as a diff", scope = "the dashboard" },
			{ "i", "Say a line to this agent without opening it", scope = "the dashboard" },
			{ "a", "Start an agent, in this worktree when the cursor is on one", scope = "the dashboard" },
			{ "n", "Make a worktree", scope = "the dashboard" },
			{ "r", "Resume an agent you left behind", scope = "the dashboard" },
			{ "s", "Stop this agent", scope = "the dashboard" },
			{ "x", "Forget an exited agent, or remove a worktree", scope = "the dashboard" },
		},
	},

	{
		id = "worktrees",
		title = "Worktrees",
		body = [==[
An agent runs in the checkout you are sitting in unless you say otherwise.
`<C-w>` in the spawn dialog offers the alternatives: a worktree this project
already has, or a new one.

`<leader>an` makes one on its own. They live under `.data/`, are gitignored,
and one holds as many agents as you send into it. The isolation is the point
when you want it: two agents editing one checkout do not take turns and neither
knows the other is there, so the second overwrites the first and the diff you
read afterwards is neither of them.

A fresh worktree is a clean checkout, which is correct and useless, because
everything a project needs to build is gitignored on purpose. `<leader>aw` is
where you say what to copy into a new one, what to symlink and what to run
afterwards.

The dashboard lists worktrees beside agents, so a row is a piece of work rather
than a process. An agent dies when Neovim quits. Its checkout does not.
]==],
		keys = {
			{ "<leader>an", "Make a worktree, with or without an agent in it" },
			{ "<leader>aw", "What a new worktree needs: copy, symlink, and run after" },
		},
	},

	{
		id = "review",
		title = "Reading what an agent did",
		body = [==[
`<leader>ar` opens everything that changed here as one diff, and `d` on a
dashboard row does the same for that row. One diff covers committed and
uncommitted work together, because it is measured from where the agent's branch
left yours rather than from its last commit. Files git is not tracking get
their own section at the end, since a diff never mentions them and "it did
nothing" is the worst thing to be wrong about.

`o` on a hunk asks what you think and sends that hunk, the file it is in and
the lines it covers back to the agent that wrote it. That is the whole reason
the buffer exists. Saying "no, not like that" about one line used to mean
finding the file, selecting it and losing the diff you were reading.

It reads and comments. Nothing here stages, commits or discards anything.
]==],
		keys = {
			{ "<leader>ar", "The diff for wherever you are" },
			{ "<CR>", "Open this file at this line", scope = "the review" },
			{ "o", "Say something about this hunk to the agent", scope = "the review" },
			{ "]h", "The next hunk", scope = "the review" },
			{ "[h", "The previous hunk", scope = "the review" },
			{ "R", "Read the change again", scope = "the review" },
		},
	},

	{
		id = "health",
		title = "When something is not working",
		body = [==[
`:Deps` lists what this configuration needs and whether it is actually there,
which is a different question from whether the name resolves: a pyenv or asdf
shim is executable and answers to `--version` while being unable to run the
thing you asked for. `:Deps install` fetches what is missing.

`:Agents check` says which of the agent CLIs are wired for status hooks.
`:lsp` restarts and stops language servers, and `<leader>l` opens their log.

Everything this configuration downloads lives in `.data/` and everything it
remembers lives in `.state/`, both inside the configuration directory and both
gitignored. Nothing is written to `~/.local/share/nvim`, so deleting this
directory really does remove all of it.
]==],
	},
}

--------------------------------------------------------------------------- --
-- building it
--------------------------------------------------------------------------- --

local function set_hl()
	vim.api.nvim_set_hl(0, "GuideMeta", { link = "Comment", default = true })
end

--- The middle column: which mode a key is for, or where it applies, or nothing
--- at all, which is the common case and the one worth costing nothing to say.
local function place(entry)
	return entry.mode or entry.where or entry.scope or ""
end

--- Escape the pipes in a key name, so a table cell survives being one.
local function cell(text)
	return (text:gsub("|", "\\|"))
end

local function key_table(section, add, seen)
	local entries = section.keys
	if not entries or #entries == 0 then
		return
	end
	local placed = false
	for _, entry in ipairs(entries) do
		placed = placed or place(entry) ~= ""
	end

	add("")
	add(placed and "| key | where | what |" or "| key | what |")
	add(placed and "| --- | --- | --- |" or "| --- | --- |")
	for _, entry in ipairs(entries) do
		local lhs, what = entry[1], entry[2]
		-- Only the ones we would have recorded. A key belonging to netrw or to a
		-- view that is not open has nothing to be checked against, and marking it
		-- missing would be the guide lying about itself.
		if not entry.scope and not keys.lookup(lhs, entry.where) then
			what = what .. " **(nothing maps this any more)**"
		end
		if not entry.scope and not entry.where then
			-- Through the same spelling the registry used, or a row written the
			-- way it reads would never match the record it is describing.
			seen[keys.normalise(lhs)] = true
			for _, extra in ipairs(entry.also or {}) do
				seen[keys.normalise(extra)] = true
			end
		end
		local row = placed and ("| `%s` | %s | %s |"):format(cell(lhs), place(entry), what)
			or ("| `%s` | %s |"):format(cell(lhs), what)
		add(row)
	end
end

--- Anything mapped globally that no section mentions. The point is not to be
--- exhaustive for its own sake: it is that a guide with a blind spot reads
--- exactly like a guide without one, and this is the only way to tell.
local function uncovered(seen)
	local out = {}
	for _, rec in ipairs(keys.list()) do
		local internal = rec.lhs:match("^<Plug>") ~= nil
		if rec.where == "" and rec.desc and not internal and not seen[rec.lhs] then
			out[#out + 1] = rec
		end
	end
	return out
end

local function build()
	local lines, rows = {}, {}
	local function add(text, row)
		lines[#lines + 1] = text
		rows[#lines] = row or {}
	end

	add("# Hady's Lab")
	add("")
	add("A guide to this editor. `q` closes it, `]]` and `[[` move between")
	add("sections, and `<CR>` on a line below jumps to one.")
	add("")

	for i, section in ipairs(SECTIONS) do
		add(("%d. %s"):format(i, section.title), { kind = "toc", id = section.id })
	end

	local seen = {}
	for _, section in ipairs(SECTIONS) do
		for _, lhs in ipairs(section.covers or {}) do
			seen[keys.normalise(lhs)] = true
		end
	end

	for _, section in ipairs(SECTIONS) do
		add("")
		add("## " .. section.title, { kind = "head", id = section.id })
		add("")
		for _, line in ipairs(vim.split(vim.trim(section.body), "\n", { plain = true })) do
			add(line)
		end
		key_table(section, add, seen)
	end

	add("")
	add("## Everything else", { kind = "head", id = "rest" })
	add("")
	local left = uncovered(seen)
	if #left == 0 then
		add("Nothing. Every mapping this configuration sets appears somewhere above,")
		add("which is checked each time this guide is opened rather than believed.")
	else
		add(("%d mapping%s this configuration sets that the guide above does not"):format(
			#left,
			#left == 1 and "" or "s"
		))
		add("mention. `<leader>h` has them with the file and line that set them.")
		add("")
		add("| key | what |")
		add("| --- | --- |")
		for _, rec in ipairs(left) do
			add(("| `%s` | %s |"):format(cell(rec.lhs), rec.desc))
		end
	end

	return lines, rows
end

--------------------------------------------------------------------------- --
-- the buffer
--------------------------------------------------------------------------- --

local buf, index = nil, {}

local function heading_at(line)
	return index[line] and index[line].kind == "head"
end

local function jump(win, id)
	for line, row in pairs(index) do
		if row.kind == "head" and row.id == id then
			pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
			-- The heading at the top of the window rather than wherever it landed:
			-- a section you jumped to should start where you are looking.
			vim.cmd("normal! zt")
			return
		end
	end
end

local function hop(step)
	local win = vim.api.nvim_get_current_win()
	local line = vim.api.nvim_win_get_cursor(win)[1]
	local count = vim.api.nvim_buf_line_count(0)
	for i = line + step, step > 0 and count or 1, step do
		if heading_at(i) then
			pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
			vim.cmd("normal! zt")
			return
		end
	end
end

local function keymaps(into)
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = into, silent = true, nowait = true, desc = desc })
	end

	map("<CR>", function()
		local win = vim.api.nvim_get_current_win()
		local row = index[vim.api.nvim_win_get_cursor(win)[1]]
		if row and row.id then
			jump(win, row.id)
		end
	end, "Jump to the section on this line")

	map("]]", function()
		hop(1)
	end, "The next section")
	map("[[", function()
		hop(-1)
	end, "The previous section")

	map("q", function()
		-- Opened in a tab of its own, so closing it is closing the tab; the
		-- pcall is for the day it is the only one left, where a plain close
		-- would refuse and leave you looking at a guide you asked to be rid of.
		if #vim.api.nvim_list_tabpages() > 1 then
			vim.cmd("tabclose")
		elseif not pcall(vim.cmd, "close") then
			vim.cmd("enew")
		end
	end, "Close the guide")
end

--- Open the guide. Built fresh each time rather than kept: it is cheap, and a
--- guide that reports what is mapped has to report what is mapped now.
function M.show()
	set_hl()

	if buf and vim.api.nvim_buf_is_valid(buf) then
		local open = vim.fn.bufwinid(buf)
		if open ~= -1 then
			vim.api.nvim_set_current_win(open)
			return open
		end
	end

	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "guide"
	pcall(vim.api.nvim_buf_set_name, buf, "nvim://guide")

	local lines, rows = build()
	index = rows
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	-- A tab of its own. Every other view here is a split because it is something
	-- you consult beside your work; a guide is something you read instead of it,
	-- and a split narrow enough to leave the code visible is too narrow to read.
	vim.cmd("tabnew")
	local empty = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	pcall(vim.api.nvim_buf_delete, empty, { force = true })

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = false
	vim.wo[win].winbar = "%#GuideMeta# <CR> jump to a section   ]] [[ sections   q close"

	keymaps(buf)
	-- The renderer asks treesitter for markdown by name, so the filetype does
	-- not have to be markdown; the highlighting does have to be started by hand
	-- for the same reason.
	pcall(vim.treesitter.start, buf, "markdown")
	if not markdown.rendered(buf) then
		markdown.toggle()
	end
	pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
	return win
end

vim.keymap.set("n", "<leader>H", M.show, {
	silent = true,
	desc = "The guide to this editor",
})

set_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

return M
