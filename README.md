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
| `lua/picker.lua`     | the modal filterable dialog `<leader>f/b/s/h` all use |
| `lua/win_pick.lua`   | "which window should this open in", the outline overlay |
| `lua/pairs.lua`      | auto-closing brackets, quotes and docstring fences   |
| `lua/diagnostics.lua` | the quickfix list of them, and the full text of one |
| `lua/netrw_*.lua`    | the file tree: pinned sidebar, split picking, `%`    |
| `lsp/*.lua`          | one file per language server                        |
| `.data/ .state/ .cache/` | generated, gitignored: plugins, parsers, undo, logs |

`lua/paths.lua` runs first and points `$XDG_DATA_HOME` and friends at
`.data/`, `.state/`, `.cache/` in here. That is the only lever available:
`vim.pack` hardcodes `stdpath('data')/site/pack/core/opt` with no override.

## Dependencies

`:Deps` shows what is present, `:Deps install` fetches what is missing. System
packages (compiler, git, curl, node, python) come from the OS package manager
and differ per platform; the language servers and the tree-sitter CLI are
fetched straight from upstream into `.data/` with no sudo.

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
buffer) and `<leader>h` (mappings) are the same dialog. Type to narrow,
`<C-n>`/`<C-p>` to move, `<Esc>` to close.

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
