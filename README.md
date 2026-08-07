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

## Treesitter and folding

Parsers are installed by nvim-treesitter through `vim.pack`, pinned in
`nvim-pack-lock.json`. Folding is `foldexpr` over the syntax tree, set
globally rather than per filetype so a window split after the fact still has
folds. Files open unfolded (`foldlevelstart=99`); `za` toggles one, `zR` opens
everything, `zM` closes everything. Buffers with no parser cost nothing and
come out unfolded.
