# nvim

A small Neovim configuration with no plugin manager and, apart from
nvim-treesitter, no plugins. Everything it installs or generates stays inside
this directory, so the whole editor is one repository you can move between
machines.

`<leader>h` lists every mapping this configuration sets, filterable, with the
file and line each one came from. That is the authoritative list; this file
covers the things that need explaining rather than listing.

## Layout

| path                 | what it is                                          |
| -------------------- | --------------------------------------------------- |
| `init.lua`           | the load order, and nothing else                     |
| `lua/paths.lua`      | redirects everything Neovim writes into this directory |
| `lua/deps.lua`       | what the machine needs, and how to get it per platform |
| `lua/picker.lua`     | the modal filterable dialog `<leader>f/b/s/g/h` all use |
| `lua/win_pick.lua`   | "which window should this open in", the outline overlay |
| `lua/pairs.lua`      | auto-closing brackets, quotes and docstring fences   |
| `lua/diagnostics.lua` | the quickfix list of them, and the full text of one |
| `lua/netrw_*.lua`    | the file tree: pinned sidebar, split picking, `%`    |
| `lua/title.lua`      | the terminal's own title: the file, then the project |
| `lua/markdown.lua`   | `<leader>p`, markdown read as rendered rather than as source |
| `lua/unignore.lua`   | the `.gitignore`'d files `<leader>f` shows anyway    |
| `lua/grep.lua`       | `<leader>g`, every matching line in the project      |
| `lua/agent.lua`      | coding agents: what is running and what it is doing  |
| `lua/agent_cli.lua`  | what claude, codex and grok each need to be wired up |
| `lua/agent_spawn.lua` | `<leader>aa`, starting one and feeding it context   |
| `lua/agent_dash.lua` | `<leader>ad`, the dashboard buffer                   |
| `lua/agent_sidebar.lua` | `<leader>ae`, the same thing as a column          |
| `lua/agent_worktree.lua` | `<leader>an`, worktrees: making, choosing and removing one |
| `lua/agent_store.lua` | the agents you have run, so one can be resumed later |
| `lua/agent_project.lua` | `<leader>aw`, what a new worktree needs to build |
| `lua/agent_tree.lua` | picking that from the project tree rather than typing it |
| `lua/agent_context.lua` | the file, line or selection an agent is asked about |
| `lsp/*.lua`          | one file per language server                        |
| `.data/ .state/ .cache/` | generated, gitignored: plugins, parsers, undo, logs |

`lua/paths.lua` runs first and points `$XDG_DATA_HOME` and friends at
`.data/`, `.state/`, `.cache/` in here. That is the only lever available:
`vim.pack` hardcodes `stdpath('data')/site/pack/core/opt` with no override.

## Dependencies

`:Deps` shows what is present, `:Deps install` fetches what is missing. System
packages (compiler, git, curl, node, python) come from the OS package manager
and differ per platform; the language servers, ripgrep and the tree-sitter CLI
are fetched straight from upstream into `.data/` with no sudo.

The platform is the family rather than the distribution, taken from `ID` and
then `ID_LIKE` in `/etc/os-release`, which is what makes derivatives work
without naming every one: mac, debian (also Ubuntu and WSL), arch (also
CachyOS), fedora (also RHEL and Rocky), suse, alpine. Somewhere with no recipe
is told so by name rather than quietly having a subset installed.

macOS is the one that needs bootstrapping, since every recipe for it goes
through Homebrew and a mac does not come with Homebrew. It is installed first
if missing, and then put on the `PATH` of the shell that is about to use it,
which the installer does not do for you.

Each step reports whether it worked, and the run ends by naming what failed
rather than announcing it is done. Anything with an `after` is installed after
the thing it names, so a language server is never built before its language.
When the run finishes, what was probed at startup is thrown away and asked
again, so `:Deps` tells you what is true now rather than what was true before
you installed anything.

rust-analyzer is the one that does not land in `.data/`. It is no use without
cargo to read the project and the `rust-src` component to know the standard
library, and rustup is what holds those at one version, including whatever
version a `rust-toolchain.toml` pins. So it comes from rustup, which the recipe
installs first if the machine has no rust at all.

Presence is decided by running each tool once, not by looking it up on `$PATH`.
The difference matters: a pyenv or asdf shim is executable and resolves fine,
then exits 127 when you run it because the active version does not have the
tool installed.

## Opening things

`<leader>f` (files), `<leader>b` (buffers), `<leader>s` (symbols in this
buffer), `<leader>g` (lines matching a pattern) and `<leader>h` (mappings) are
the same dialog. Type to narrow, `<C-n>`/`<C-p>` to move, `<Esc>` to close.

`<leader>f`, `<leader>b` and `<leader>s` share netrw's two-key convention for
where a thing lands, through the same overlay:

- `<CR>` outlines a candidate window. `hjkl` moves the outline, `<CR>` opens
  there. With only one candidate it opens straight away.
- `<S-CR>` opens in the window you came from, without asking.

The netrw sidebar is never a candidate. Pressing either key from inside the
tree opens into the editing area, and if the sidebar is the only window on
screen a split is made rather than the tree being replaced.

`<leader>f` lists files from `git ls-files --cached --others
--exclude-standard` when there is a `.git`, so `.gitignore` is respected and
`node_modules` is never walked. Outside a repository it falls back to a glob
with an ignore list.

### Ignored files you want back

Respecting `.gitignore` is right nearly always and wrong for the handful of
ignored files you actually work with: a generated client, a vendored directory,
the `.env` you keep editing. `<C-.>` in the `<leader>f` dialog edits the
exceptions for the repository you are in, comma separated, and remembers them.

The patterns are **git pathspecs**, passed to
`git ls-files --others --ignored --exclude-standard -- ...` as they are written.
That is the whole of the matching rule, so they mean here what they would mean
on a git command line rather than following a second scheme invented for this:
a bare `dist` matches at any depth, and `*` on its own is therefore "show
everything ignored", which is the quickest way to find the one file you cannot
name.

The title says so while it is on, as `Files +dist,.env`, because a
`node_modules` path appearing in the list should read as something you asked
for rather than as the filter having quietly broken. Clearing the prompt turns
it back off.

The list is `.state/nvim/unignore.json`, keyed by repository root, so nothing
is written into the project and nothing follows the config to a machine where
those paths would mean nothing. `:find` picks the exceptions up too, since both
go through the same `scan()`.

Two things this deliberately does not do. It does not merge the ignored files
in sorted order: they go on the end of the listing, because the fuzzy filter is
what you actually navigate with and the order it returns is its own. And
`<C-.>` is the one picker key not listed in `<leader>h`, along with the rest of
the picker's keys, which are buffer-local to a dialog that does not exist until
you open it; the footer is where they are advertised.

### Grep

`<leader>g` is every line in the project matching what you type, through the
same dialog and the same two-key split, so a match lands where a file does.
`<C-q>` puts everything on screen in the quickfix list.

It is the `<leader>S` shape rather than the `<leader>f` one: the typing goes to
ripgrep, not to the filter, since only ripgrep has read the files. The list is
replaced on every keystroke, debounced, and the reply a later keystroke
supersedes is not merely ignored but killed, since a search of a large tree
that nobody is waiting for is still reading the disk.

The pattern is ripgrep's, so a regular expression, with `--smart-case`:
lowercase matches anything, a capital makes it case sensitive. Half-written
regular expressions are the normal state of affairs while typing, so the error
an unclosed bracket comes back with is treated as "no matches yet" rather than
reported.

One row per line, not per match. `--vimgrep` reports every match, so a line
matching three times arrives three times, and since a row here is the line and
where it is, those would be three rows that look identical. The column of the
first match is kept, which is where the cursor lands. At a thousand rows it
stops, which the title says.

Ripgrep respects `.gitignore` itself, so the listing agrees with `<leader>f`
about what is in the project. It does not know about the `<C-.>` exceptions
above, which is a `<leader>f` thing: git pathspecs and ripgrep globs are close
enough to look interchangeable and different enough to be wrong quietly.

## Agents

`<leader>aa` starts a coding agent - claude, codex or grok, whichever you have -
on the file you are in or the lines you have selected, and `<leader>ad` shows
every one of them and what it is doing.

The agent runs its own terminal UI in a hidden buffer, so its permission
prompts, slash commands and rendering are its own and work exactly as they do
in a terminal. What this adds is knowing, without going to look, which agent is
working, which is waiting on you and which has finished.

| key | |
| --- | --- |
| `<leader>aa` | start one, on this file or the selection |
| `<leader>ac` | send this file, line, selection or its diagnostics to one already running |
| `<leader>ad` | the dashboard |
| `<leader>ae` | the sidebar, a column narrow enough to leave open |
| `<leader>an` | make a worktree, with or without an agent to put in it |
| `<leader>aw` | the worktree setup for this project |

On the dashboard, `<CR>` opens that agent's terminal through the same window
overlay `<leader>f` uses, `i` types a line to it without leaving, `a` starts
another, `n` makes a worktree, `r` resumes one you left behind, `s` stops one
and `x` drops one: an agent that has exited is forgotten, a worktree is
removed. The keys are in the window bar, so the list stays a list.

`<CR>` never opens into the dashboard itself, since a list with a terminal in
it is a list you no longer have. With nothing beside it but a directory
listing, that listing is what gets taken over, exactly as opening a file from
it would.

### Getting to one

Three ways in, depending on what you are doing:

- `<CR>` on a row of the dashboard or the sidebar, which puts its terminal in a
  window you pick and drops you into insert mode ready to type
- `<leader>b`, because an agent's terminal is an ordinary listed buffer named
  after the run, so the buffer list finds it like anything else
- `<leader>ac` or `i` on the dashboard, to say something to an agent without
  opening it at all, which is usually what you want mid-edit

Inside one you are in a terminal, so `<C-\><C-n>` leaves insert mode. `<Esc>` is
deliberately not mapped: all three agents use it for their own menus, and taking
it would break the interface it is meant to make easier to reach.

### How it knows

From the agent, not by watching its output. All three take the same shape of
hook config, which is Claude Code's - grok documents the compatibility and
reads `~/.claude/settings.json` for it - so one script serves all three, and
each fires it on submitting a prompt, finishing a tool, asking permission and
ending a turn.

Nothing is installed into `~/.claude`, `~/.codex` or `~/.grok`. Claude takes a
settings file as a flag. The other two only read a home directory, so they get
one: a directory that symlinks the real home entry by entry, with the hook file
the only thing that is ours. Credentials, sessions, skills and memory stay where
they are and keep working from a normal terminal.

The hook writes a small file into an inbox directory rather than calling back
into Neovim, because a hook that blocks blocks the agent. Writing a file cannot
fail slowly; an RPC into a busy Neovim can, and the agent would sit on it until
its own hook timeout gave up.

Codex will not run a hook it has not been told to trust and asks once, in its
own dialog, the first time you start it from here. Choose "Trust all and
continue" from its numbered menu and press enter. Its answer is
remembered, which is the reason its mirrored home is kept rather than built per
run.

An agent that fires no hooks is still tracked as running or exited, because the
process is Neovim's own child. `:Agents check` says which are wired.

### Worktrees, and agents in them

An agent runs in the checkout you are sitting in. `<C-w>` in the dialog offers
the places instead: a worktree this project already has, or a new one.

Worktrees are made on their own, with `<leader>an` or `n` on the dashboard, and
one holds as many agents as you send into it. They used to be made one per
agent, on the way to starting it, which is wasteful, because most questions do
not need a checkout of their own; slow, because the checkout and everything the
project needs copied into it were paid for before the agent had said a word;
and wrong about half the time, because plenty of work belongs where you already
are.

The isolation is still the point when you want it. Two agents editing one
checkout do not take turns and neither knows the other exists, so the second
overwrites the first and the diff you read afterwards is neither of them.
Separate worktrees also mean the diff column on the dashboard is that
worktree's work and nothing else, which is why it is not shown for an agent
running in your own checkout: there it would be reporting your uncommitted work
as the agent's.

Making one asks for the name and what to cut it from, both prefilled with the
answer you would have got anyway, so the usual path is two presses of enter.
Both complete: the name against worktrees this project already has, so typing
one is how you say "the one I already have", and the base against every branch
and tag. `agent/` branches are left out of that list, since basing new work on
another agent's unreviewed work is rarely what you meant. They live under
`.data/`, where they are gitignored, and the checkout itself happens in the
background: a large repository takes seconds, and nothing is waiting on it.

### The worktrees, after the agent

The dashboard lists this project's worktrees too, so a row is a piece of work
rather than a process: with an agent on it, or waiting for one. An agent dies
when Neovim quits and its checkout does not, and a list of only what is running
would quietly lose track of a dozen of them holding real work.

A worktree with nobody in it reads `resume` when there is a conversation to pick
back up and `no agent` when there is not, with its branch and what has changed
in it since it left yours. That last number is measured from where the
two branches parted, so it stays right after you have carried on committing in
the checkout you are sitting in.

On such a row, `<CR>` opens the worktree itself in the file browser, `a` starts
an agent in it without asking where, and `x` removes it. Removal
asks first, and asks separately about the branch, which is the only remaining
copy of anything the agent committed there; git's own refusal to discard
uncommitted work is passed back as a second question rather than worked around.

Forgetting an agent that has exited leaves its worktree behind as a row of its
own, which is the point: dropping the process and dropping the work are
different decisions, and the second is better made looking at what the work was.

### What a new worktree needs

`<leader>aw` opens the setup for the project you are in: what to copy, what to
symlink, what to run afterwards.

A fresh worktree is a clean checkout, which is correct and useless. Everything
a project needs in order to build is gitignored on purpose, so an agent arrives
to no `.env`, no `node_modules` and no build cache, and its first discovery is
that the project does not run.

| | |
| --- | --- |
| `a` | pick from the project tree |
| `A` | add by typing a pattern, for a glob no single file stands for |
| `e` | edit, `d` delete, `<Space>` turn one off without losing it |
| `s` | apply the setup to every worktree this project already has |
| `g` | keep this as the starting point for projects with no setup yet |

Copy is for small files that should differ per worktree, symlink for large ones
that should not be duplicated, which is the only reason both exist. The commands
run after creation are asynchronous: an install takes minutes and the agent
should be starting while it happens, not afterwards.

`a` opens the project as a tree, where `c` marks something to copy, `s` to
symlink and `<Space>` cycles. It opens showing only the gitignored files and the
directories that lead to them, because those are the only things a fresh
checkout is actually without, and copying a tracked file into a worktree that
already has it does nothing. `.` shows the rest of the project when you want it.

What gets stored is still a glob, so `A` remains for the ones no single file
stands for, like `*.local`. Those show in the lists but not as marks in the
tree: a glob has no one place in it, and pretending one of its matches was the
entry would make unmarking delete a pattern you never picked there.

Nothing is overwritten. Re-running the setup fills in what a worktree is missing
rather than replacing what is there, since a worktree that has been worked in
may have a `.env` the agent changed deliberately.

The setup is stored per project under `.state/`, keyed by the path to the
repository, so two checkouts of the same project keep separate settings and
nothing is written into the project itself. Where the worktrees go is part of
it: leave it alone for the default, or set a directory of your own, where
`{project}` stands for the repository's name.

### Picking one back up

An agent dies with the editor. Its conversation does not, and `r` on the
dashboard starts the same agent again, in the same directory, resuming the same
conversation. It comes up idle rather than working, because it was handed no
question: the first hook of a turn does not fire until you type, and a row that
says `starting` until then says it forever.

That works because the name is ours. Claude and grok both accept a `--session-id`
we mint before they start, so the conversation is known by an id we chose and
wrote down, and resuming keeps it rather than forking a new one. Codex names its
own, so it is looked up instead: every codex session is a file recording the
directory it was started in, so the one to resume is found by where it ran -
which also finds a codex you started in that worktree from an ordinary terminal.

The list is `.state/nvim/agents/sessions.json`, one record per run: which agent,
where, its id, and when it was last alive. It keeps the newest 40 and drops
anything whose directory has gone, so removing a worktree takes its
conversations with it.

Verified against all three by starting one, closing it, and resuming: claude and
grok recalled a word from the previous conversation through an id we minted,
codex through one found by directory.

### What it does not do

Agents are children of this Neovim, so quitting ends them. A tmux pane would
survive and this does not; if that matters, the agent is a normal CLI and
running it in a terminal remains the way to outlive the editor.

There is no scrollback worth the name in an agent's terminal, and it is not a
setting you are missing. Codex and grok are started with `--no-alt-screen`, so
they draw inline and what is on screen when they exit stays in the buffer;
claude has no such flag and takes over the alternate screen, where by definition
nothing is kept. But all three are full-screen programs that repaint in place
rather than letting lines scroll off, so none of them fills a terminal buffer's
history the way a command that prints and stops would. Measured: 200 lines of
`seq` land in the buffer as 201 lines, and an agent's answer of the same length
leaves it at exactly one screen. `<C-\><C-n>` gets you to normal mode either
way, but paging back through the conversation is the agent's own job.

## Pairs

`( [ {` insert their closing half, `) ] }` step over one that is already there
rather than doubling it, and `"`, `'` and `` ` `` do both depending on which
side of a string you are on. `<BS>` between an empty pair takes both halves; `<CR>`
between one opens a line and leaves the closer below it, indented by the
filetype's own rules. Typing `"""` or `'''` lays down the closing fence too.

The rules that keep it out of the way, all decided from the characters either
side of the cursor:

- No closer in front of a word. Typing `(` before `foo` is how you wrap it, so
  the `)` belongs after `foo`, not against the cursor.
- A quote against a word on either side is an apostrophe or a suffix, never the
  start of a string, so `don't` types as itself.
- An odd run of backslashes escapes the quote, an even one does not. In `"a\`
  the quote ahead of the cursor is the pair's own, but stepping over it there
  would leave the string open, so a literal one goes in instead.
- Nothing at all in a buffer that is not a file, which is what keeps the picker
  prompt an ordinary line to type in.

Each key is an expr mapping that only reads the current line, so there is no
state kept between keystrokes to go stale, and undo, macros and `.` all behave.

## Markdown

`<leader>p` in a markdown buffer stops the markers being drawn, and again puts
them back. Not a preview in another window or another program: the same buffer,
so the cursor keeps its place, the file stays editable, and the colours are the
colorscheme's rather than some renderer's idea of them.

```
## Layout                        Layout

- `init.lua` is the **order**    • init.lua is the order
- see [paths](lua/paths.lua)     • see paths

```lua                             local x = 1
local x = 1
```
```

Most of that is Neovim's, not ours. Its markdown queries already conceal the
code fences and the language annotation, and markdown_inline's conceal the
emphasis markers, inline backticks and link brackets, so `conceallevel` is most
of the feature. `concealcursor` is set to `nc` rather than to everything, so
the line the cursor is on shows its source again the moment you start editing
it.

What Neovim leaves alone is headings and list bullets, and `lua/markdown.lua`
draws those with extmarks. That is not the obvious mechanism and the reason is
worth writing down, because the query language looks like it should do it. The
parser is inconsistent about the space after a marker: `atx_hN_marker` stops at
the last `#`, while a list marker node runs to the end of the space following
it. So concealing the node whole is wrong in a different direction for each,
one leaving a stray column and the other closing the gap up into `•item`. The
query answer is `#offset!`, which is exactly what Neovim's own bullet conceals
use, and they ship commented out with a note blaming "issues with spaces in the
list marker nodes". It cannot work: the directive records
`metadata[capture].offset` and nothing in the treesitter runtime ever reads it
back. An extmark takes the range it is handed, which is why this is code rather
than a query file.

### Tables

Tables are drawn: fitted to the window, wrapped inside their columns, and
aligned.

```
│ Server        │ Root marker               │ Why that one               │
├───────────────┼───────────────────────────┼────────────────────────────┤
│ pylsp         │ pyproject.toml, then      │ Each package brings its    │
│               │ .git                      │ own interpreter, so the    │
│               │                           │ root is the package and    │
│               │                           │ not the checkout.          │
```

The widths are measured against what a cell will *look* like, not what it says.
A cell holding `` `init.lua` `` is eleven characters and draws as eight, so
measuring the source would leave every column after it out by two. That is why
the parse asks for the injected trees: what `markdown_inline` conceals inside a
cell is part of how wide that cell comes out. `strdisplaywidth` does the
measuring, so 日本語 counts as the six columns it occupies rather than the nine
bytes it takes. `:---`, `---:` and `:---:` are honoured.

Columns are fitted to the window before anything is drawn. The widest column
gives up one column at a time, so a table of one prose column beside several
short ones loses width where there is width to lose. Each cell is then wrapped
inside the width it ended up with, at spaces where there is one, and a row
becomes as many lines as its tallest cell needs.

### Why a table is drawn as virtual lines

The obvious way to do this is to conceal the source and draw the replacement
over it. It cannot work, because of a property of `conceal` worth knowing:
**concealing text hides the characters but does not give back the columns they
occupied.** The line still wraps where it would have wrapped. Concealing 150
characters of a 152-character line leaves two characters visible and a line
that still takes three screen rows to display them.

That is invisible while the thing being concealed is a marker or a run of
spaces, which is every other use of conceal in this file, and it is why the
first several attempts at this looked almost right. It stops being invisible
the moment a whole paragraph has to come out of a cell.

So the source rows are removed from the display outright with `conceal_lines`,
which is the one that does return the space, and the table is drawn as virtual
lines. Virtual lines attached to a concealed line are concealed along with it,
so they hang off the line before the table, or the one after it when the table
starts the file; a table with neither is left as it was written.

The cost is that a table is drawn flat. A chunk of virtual text carries one
highlight, not the syntax tree's, so code spans and links inside a cell keep
their text but lose their colour. Everything outside tables is still the
buffer's own text and still fully highlighted. Buying the colour back means
reconstructing per-chunk highlight groups from the tree, which is a good deal
more machinery than the rest of this file put together.

The other consequence is the cursor. A line taken out of the display is not on
the screen anywhere, so a cursor sitting on one is a cursor you cannot see:
`j` through a four row table would be four presses that look like nothing
happened, followed by one that jumps. So the cursor steps over a drawn table in
one move, carrying on the way it was already going, and a table is one thing to
move across because it is one thing to read. Landing on one from a search has
no direction to carry, so it comes out below.

The corollary is that a table cannot be edited while it is drawn, since the
cursor will not stay in it. `<leader>p` again and it is ordinary text.

### Heading levels

With the `#` markers hidden, nothing would tell an h1 from an h3. A colorscheme
usually defines `@markup.heading` and leaves the six numbered groups to fall
back to it, so every level is drawn identically; catppuccin links the lot to
`Title`. A terminal cannot make a heading bigger, so the level is carried by
weight and colour instead, both ends taken from the colorscheme rather than
written down here: its heading colour, and `Comment`, which is by definition
the colour it uses for something receding.

Colour alone will not carry six steps, since those two can be close together
and in catppuccin they are. So h1 and h2 both keep the full heading colour and
are told apart by an underline, which leaves the whole of the range to separate
h3 from h6, where bold giving way to italic is the only other thing left to
vary.

### What it does not do

Ordered lists keep their numbers, `1.` being what it renders as anyway.
Paragraphs outside tables are not rewrapped to a measure; `linebreak` only
stops a wrap falling mid-word. A single word longer than its column is cut
rather than allowed to run past the edge, which is the one place this loses
something the source said. A file that is nothing but a table, with no line
above or below it to hang the drawing on, is left as it was written.

## Clipboard

`clipboard=unnamedplus`, so the unnamed register *is* the system clipboard.
`y` and `p` cross the editor boundary with no `"+` prefix, and so do `d`, `c`
and `x`, which is the cost of it: deleting a line replaces whatever you had
copied from another application, and `p` over a visual selection leaves the
clipboard holding the text it just replaced.

`"0` is the way back. It holds the last thing *yanked* and is never written by
a delete, so `"0p` still pastes what you copied however many `dd`s ago, and
repeats: pasting over a selection with it does not consume it.

Neovim finds the clipboard tool itself, and on macOS that is `pbcopy`, which is
in the base system with nothing to install. On Linux it is `wl-copy`/`wl-paste`
under Wayland and `xsel` or `xclip` under X11, none of which `:Deps` installs;
without one, yanking is silently local to nvim.

Setting `clipboard` also switches off Neovim's OSC 52 fallback, which is the
one that gets a yank over SSH back to the terminal you are sitting at. That is
deliberate upstream (it is slow and can prompt), and it is a `&clipboard ==# ''`
test, so it is this line that costs it, not the machine. Opting back in is
`vim.g.clipboard = "osc52"`, which skips the guard.

## Terminal title

`statusline.lua - nvim`, and `statusline.lua + - nvim` with unwritten changes.

The file comes before the project because a terminal tab bar truncates from the
right and gets narrow as soon as there are a few tabs open, so the half that
tells two of them apart has to come before the half they have in common. The
statusline already says everything else, and is on screen; the title is read
from a tab you are *not* looking at, which is what the two things are for.

The project is the checkout nvim is sitting in, worked out once rather than per
buffer, because git answers `rev-parse` against the process's directory and
every buffer would get the same answer anyway. `:cd` recomputes it. Outside a
repository the directory itself is the name.

Buffers that are not a file do not take the title off the one behind them: the
quickfix list, a terminal and the picker's floats leave it at the project alone,
so opening `<leader>f` does not make the tab bar flicker. netrw is the exception
that needs saying, since it calls its buffer `NetrwTreeListing` wherever it is
pointed; the title shows the directory it is listing instead, as `lua/`.

## LSP

### Keys

Neovim maps most of the LSP verbs itself, and this configuration leaves them
alone. The full set is in `<leader>h`; the ones worth knowing up front:

| key         | what it does                                              |
| ----------- | --------------------------------------------------------- |
| `gd`        | go to definition (the only one added here)                |
| `K`         | documentation for the symbol under the cursor; `K` again focuses the float so you can scroll it, `q` closes |
| `grr`       | references, in the quickfix list                          |
| `grn`       | rename                                                    |
| `gra`       | code actions                                              |
| `gri`/`grt` | go to implementation / type definition                    |
| `<C-s>`     | signature help, in insert mode                            |
| `<leader>s` | symbols in this buffer, as a dialog (`gO` is the same list in the quickfix list) |
| `<leader>S` | symbols across the workspace, the server matching as you type |
| `<leader>d` / `<leader>D` | next / previous diagnostic                  |
| `<leader>q` / `<leader>Q` | diagnostics in the quickfix list, this buffer / all of them |
| `<C-w>d`    | the diagnostics on this line in full, in a float          |

`gd` is the one addition, and only because plain `gd` is an older Vim key that
means something else: "go to local declaration", a backwards keyword search
inside the current function. In Python that lands on whatever happened to match
textually rather than on the definition, which reads as the language server
being broken when it is working fine.

`<leader>s` shows what the file *defines*, not every name in it. Servers
answer `textDocument/documentSymbol` in two different shapes, one nested and
one flat, and both are normalised into the same dotted `Container.name` rows,
so filtering by an enclosing class works whichever server replied. Anything
declared inside a function body, or inside a value holding one, is dropped:
without that, half the list of a 300-line module is caught exceptions and loop
variables. pylsp is also told `jedi_symbols.include_import_symbols = false`,
which keeps every `from x import Y` line out of the list.

`<leader>S` is the same dialog but the typing goes to the server, not to the
filter: only the server has the workspace indexed, each one matches its own
way, and what it knows about grows as it loads more of the project. So the
list is replaced on every keystroke, debounced, with a generation counter
dropping replies a later keystroke has already superseded.

**pylsp does not implement `workspace/symbol`**, so `<leader>S` does nothing
in a Python project and says so. It is not a configuration problem: pylsp only
has the `pylsp_document_symbols` hook, and the request comes back `-32601
Method Not Found`. lua_ls and tsgo both answer it. Getting it for Python means
a different server (pyright, basedpyright), which is a trade against the venv
handling below.

### Diagnostics

`<leader>q` puts this buffer's diagnostics in the quickfix list, `<leader>Q`
every buffer's, as far as the servers have looked. While that list is on
screen it is kept current, so fixing something takes the row away instead of
leaving one that jumps to a line where nothing is wrong any more. Only a list
this configuration put there is ever rewritten, recognised by its title: a
`:grep` you ran since is not ours to overwrite.

A quickfix line is one line, and a diagnostic frequently is not. rustc writes
several and hangs the locations it refers to off the side of them, clippy puts
the address of the lint in the message, pylsp will hand over a paragraph.
Flattened into the list, all of that runs off the right edge with nothing to
scroll. So the list carries the first line, marked `...` when there was more,
and ends with the source and the code, which is the part you go and search
for:

```
src/lib.rs|8 col 5-14 error| cannot borrow `v` as mutable ... [rustc E0502]
```

The rest is a keypress away, from either side:

- `<C-w>d` in the code, which is Neovim's own mapping, shows every diagnostic
  on the line in full, each with the locations it points at. Press it again
  and the float takes focus so it can be scrolled, `q` closes it, and `gf` on
  one of those locations jumps there. That is the same float `K` gives for
  hover, and it behaves the same way.
- `K` in the quickfix window does the same for the entry under the cursor,
  looked up by the buffer and line the entry points at rather than by where
  the cursor is, which is in the quickfix window and knows nothing. On a list
  that is not diagnostics, or an entry whose diagnostic has since been fixed,
  it falls back to unfolding the entry's own text, which is the same fix for a
  `:grep` hit that runs off the edge.

### Backslashes in the hover float

pylsp docstrings come back as `read\_file` rather than `read_file` often
enough to be a nuisance, and they copy out of the float that way.

pylsp runs each docstring through `docstring-to-markdown` first. If the format
is one that library recognises (Google, NumPy, reST) it is converted properly
and nothing is escaped. If it is not, `_utils.format_docstring` falls back to
`escape_markdown`, which backslash-escapes `\ * _ # [ ]` across the whole text
and swaps every run of two spaces for U+00A0. A plain prose docstring is
exactly the unrecognised case:

```
"Wraps read_file and write_file."   ->   "Wraps read\_file and write\_file."
```

So it tracks docstring *style*, not the symbol: the same file will have some
hovers escaped and some not. Neovim renders the markdown source as given,
highlighting fenced blocks without interpreting inline markup, so whatever the
server escaped stays on screen.

`lsp/pylsp.lua` undoes it on the way in, for this server only. Line by line and
never inside a fence, since the signature pylsp puts in a ```` ```python ````
block never went through the escaping and a backslash in there is code. Only
the six characters `escape_markdown` escapes are unescaped, so a real `#`
heading or `` `code span` `` from the converted path survives untouched.

The hook is `on_init` wrapping the client's own `request` method, which is not
where you would expect it. The obvious place is the config's `handlers` table,
but `vim.lsp.buf.hover()` passes its own handler straight to `client:request`,
so a handler registered per method is never consulted. Wrapping `request` is
the one point every caller has to come through. It covers hover and signature
help; completion documentation takes the same route through the server and is
left as it comes, being a preview read in passing rather than copied.

### Status

The statusline shows the servers attached to the current buffer, e.g. `pylsp`.
A server that *should* be attached for this filetype and is not shows as
`pylsp!` in the error colour, which is what a server that failed to start looks
like from the outside. Progress messages replace the names while they run. In
buffers no server was ever going to attach to, the segment is empty.

### Log

`<leader>l` opens the log below the code, scrolled to the end. `R` rereads it,
`q` closes the window.

`:LspLog` does the same, and `:vertical LspLog` splits the other way.
`:LspLog debug` sets the log level before opening it (completes `off`,
`error`, `warn`, `info`, `debug`, `trace`; `warn` by default).

### Python: package root and nearest venv

This is the part worth knowing about, because getting it wrong is the usual
reason a Python language server appears to be running while doing nothing
useful in a monorepo.

`lsp/pylsp.lua` puts `pyproject.toml` before `.git` in `root_markers`, so the
root is the **package**, not the checkout. In a repository laid out like

```
monorepo/
  pyproject.toml
  .venv/
  packages/core/
    pyproject.toml
    .venv/
    src/core/
```

a file under `packages/core/` gets a client rooted at `packages/core`, not at
`monorepo`. Each package gets its own client.

For each of those roots, the nearest `.venv` at or above it is found and passed
to jedi as `plugins.jedi.environment`. Without that, jedi resolves imports out
of whichever interpreter pylsp itself happens to be running under, which in
practice is the global one: every project and third-party import comes back
unresolved, and go-to-definition, hover and completion are all dead for
anything outside the standard library.

That upward search stops at the directory nvim was started in. The tree you
opened is the project; a `.venv` above it belongs to something else. Unbounded
the search runs to `/`, so a forgotten `.venv` in `$HOME` becomes the
environment for every project under it, and a stale one whose interpreter has
since been deleted takes hover and imports down with it while looking exactly
like a broken server. The one exception is opening nvim *inside* a package, in
which case the package root sits above where you started and is its own
ceiling.

The binary to run is chosen in this order:

1. `<venv>/bin/pylsp`, if the project installs its own. That is the only one
   whose plugins (ruff, mypy) are the project's own too.
2. `<data>/venv/bin/pylsp`, the one `:Deps install` puts in `.data/`.
3. `pylsp` from `$PATH`, last on purpose.

Two implementation notes, both non-obvious:

- `cmd` is a function rather than a list, because that is the only hook that
  gets to see `config.root_dir`. It is only resolved once a buffer has been
  matched to a project.
- The settings go through `on_init`, not `before_init`. The client copies
  `config.settings` when it is constructed, so anything written to them later
  than that changes a table nobody reads.

### Go: K, the workspace, and what a write does

`K` in a Go buffer with nothing attached does not open a float: it runs
`go doc` in a terminal split, which looks like a broken hover rather than a
missing server. That is Neovim's own `ftplugin/go.vim` setting `keywordprg` to
`:GoKeywordPrg`, and `K` falling through to it because no client has mapped
`K` to hover. Attaching gopls is the whole fix, with nothing to override here:
Neovim counts an option set by a runtime ftplugin as still default and maps
`K` over it. `:GoKeywordPrg` still runs `go doc` when you want it.

The root is the `go.work` if there is one, and only then the `go.mod`. A Go
workspace is several modules gopls is meant to hold at once; rooted at one of
them the others are just directories to it. Both are ahead of `.git`.

Writing a Go file does two things before it hits disk. gopls organizes the
imports, which is `source.organizeImports`: a code action rather than
formatting, because that is where LSP puts it, and it both drops what is
unused and adds what is missing the way `goimports` does. Go makes an unused
import a compile error, so without that every write leaves work to do by hand.
Then the buffer is formatted, which for gopls is `gofmt`. Both are synchronous:
the write is already under way, and an edit arriving after it would be applied
to a buffer that had already gone to disk. This is the only place in this
configuration where saving rewrites the buffer, and it is scoped to the
buffers gopls attached to.

`staticcheck` is on, which is the same trade as clippy for Rust: more said
about the code than the compiler alone would say, by a tool that comes with
the server rather than one that might not be installed.

`:Deps install` builds gopls with `GOBIN` pointed at `.data/`, not with a
plain `go install`. That would put it in `$GOPATH/bin`, which is not on `$PATH`
on a machine that was never set up for Go development, and a language server
Neovim cannot see is the same as one that is not installed.

### Rust: the workspace, not the crate

The mirror image of the decision above. Python roots at the package because
each package has its own interpreter; Rust roots at the cargo **workspace**,
because cargo resolves every member crate against one `Cargo.lock` and
rust-analyzer wants that whole graph in one process. Rooted at the nearest
`Cargo.toml` instead, a workspace gets one analyzer per member, each holding
its own copy of the dependency graph, and none of them able to follow a path
dependency into a sibling crate.

Finding the top is not a matter of looking for a file. `Cargo.lock` does sit at
the workspace root and nowhere else, but libraries gitignore it, so a fresh
checkout has none until something is built. `cargo metadata --no-deps` answers
authoritatively in either case, so that is what runs, asynchronously, and its
`workspace_root` is the root. Once one crate of a workspace is open the answer
is already known, so opening the next file reuses that root rather than
spawning another cargo.

A `.rs` file with no `Cargo.toml` and no `rust-project.json` above it gets no
server at all. rust-analyzer started there has no crate graph to work from, and
what it does about that is put an error popup on screen, repeatedly, while
answering nothing; single-file mode is not an alternative, `detachedFiles`
having been removed. The file keeps its treesitter highlighting, and the
statusline shows `rust_analyzer!` because a server that could have attached did
not.

`rust-analyzer` on `$PATH` is a rustup proxy, and a proxy picks its toolchain
from the `rust-toolchain.toml` nearest its *working directory*. Started without
one it inherits nvim's, so a project pinning a toolchain would be analyzed by
whichever one the directory you launched from implies. It is started with the
workspace root as its cwd instead.

Two settings, both about staying out of the way:

- `cargo.targetDir` puts the analyzer's build artifacts in `target/rust-analyzer`.
  Sharing one target directory with the terminal means whichever got there
  first holds the lock, so a check on save leaves `cargo run` sitting on
  "Blocking waiting for file lock on build directory", and the other way round.
  The cost is a second set of artifacts on disk.
- `check.command` is `clippy` rather than `check`. It reports a superset, and
  clippy is one of the components the dependency recipe installs, so it is not
  reaching for something that might not be there.

## Treesitter and folding

Parsers are installed by nvim-treesitter through `vim.pack`, pinned in
`nvim-pack-lock.json`. Folding is `foldexpr` over the syntax tree, set
globally rather than per filetype so a window split after the fact still has
folds. Files open unfolded (`foldlevelstart=99`); `za` toggles one, `zR` opens
everything, `zM` closes everything. Buffers with no parser cost nothing and
come out unfolded.
