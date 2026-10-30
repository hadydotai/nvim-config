---@brief
---
--- https://biomejs.dev/
---
--- Biome, for formatting JavaScript and TypeScript on write in the projects
--- that use it. tsgo stays the language server for everything else about
--- these files: Biome is here for its formatter, and its lint warnings come
--- along with it.
---
--- Only where the project asks for it, which is a biome.json or biome.jsonc
--- between the file and the project root. Biome would format without one,
--- but in a project that does not use it every write would rewrite the file
--- in Biome's style, a diff nobody asked for in a project kept by Prettier or
--- by hand. Where there is no Biome, nothing formats on write; tsgo's own
--- formatter is still there for gq.
---
--- Configuration is documented [here](https://biomejs.dev/reference/configuration/).

-- The files that mark a JavaScript project's root, the way lsp/tsgo.lua finds
-- it. A biome.json above this is somebody else's.
local LOCKFILES = { "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock" }

local CONFIGS = { "biome.json", "biome.jsonc" }

--- The project's own biome when it has one, which is the version its
--- package.json pins: another can format the same file differently, and the
--- configuration format changed between 1.x and 2.x. Looked for upward the
--- way node resolves it, so a package in a workspace finds the one installed
--- at the top. The one :Deps installs is for a checkout whose node_modules is
--- not there yet.
local function biome_bin(root)
  for dir in vim.fs.parents(vim.fs.joinpath(root, "node_modules")) do
    local exe = vim.fs.joinpath(dir, "node_modules/.bin/biome")
    if vim.fn.executable(exe) == 1 then
      return exe
    end
  end
  return "biome"
end

local group = vim.api.nvim_create_augroup("Biome", { clear = true })

---@type vim.lsp.Config
return {
  cmd = function(dispatchers, config)
    local root = (config or {}).root_dir
    local exe = root and biome_bin(root) or "biome"
    return vim.lsp.rpc.start({ exe, "lsp-proxy" }, dispatchers)
  end,
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  --- Rooted at the outermost configuration between the file and the project
  --- root rather than the nearest. In a workspace that is the one at the top,
  --- which the packages' own biome.json files extend, and Biome wants to be
  --- started there so it can see them all.
  root_dir = function(bufnr, on_dir)
    local project = vim.fs.root(bufnr, { LOCKFILES, { ".git" } }) or vim.fn.getcwd()
    local found = vim.fs.find(CONFIGS, {
      path = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)),
      upward = true,
      type = "file",
      -- the project root itself is still searched; the search stops above it
      stop = vim.fs.dirname(project),
      limit = math.huge,
    })
    if #found > 0 then
      on_dir(vim.fs.dirname(found[#found]))
    end
  end,
  --- The project's Biome configuration on write, through the server rather
  --- than by shelling out.
  ---
  --- Formatting only. Biome also offers to organize imports and apply its safe
  --- fixes on save, and neither is done here, for the reason rust-analyzer
  --- does not organize imports: an unused import is not an error in
  --- TypeScript, and removing one is an edit you should be asked about.
  ---
  --- Asked for by id, so tsgo, which formats too, stays out of it.
  --- Synchronous, for the reason gopls is: the write is already under way,
  --- and an edit arriving after it would be applied to a buffer that had
  --- already gone to disk, leaving the file and the buffer disagreeing.
  on_attach = function(client, bufnr)
    -- Cleared first: a buffer can attach more than once over its life, and
    -- two copies of this would format twice per write.
    vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      buffer = bufnr,
      desc = "biome: format",
      callback = function()
        vim.lsp.buf.format({ bufnr = bufnr, id = client.id, async = false })
      end,
    })
  end,
}
