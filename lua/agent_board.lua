-- The board's agents, when this Neovim runs in a terminal column of an Orven
-- board: shown on the dashboard, the sidebar and the note like the ones this
-- editor runs itself, and started, answered and closed through the board.
--
-- On a board an agent is a column beside this terminal rather than a hidden
-- buffer in here, so it outlives this editor and the browser shows it too.
-- What this file does is make one look like any other run: agent.adopt() it
-- with a `remote` that says how to talk to it, keep its state in step with
-- the board's, and let it go when its column does. The views never ask where
-- a run lives; agent.lua asks the run.
--
-- Everything goes through Orven's own package (require("orven")), which the
-- runner puts on every terminal column's path and which does nothing off a
-- board. Off a board, or on a runner too old to have it, this file does
-- nothing either and the hidden terminals are all there is.
--
--   M.on()            whether this Neovim is on a board
--   M.start(opts)     an agent column: { cli, question, ctx, place }
--   M.harnesses(cb)   what a new one can run with, as picker items

local M = {}

local agent = require("agent")

-- The board's state, in the words the views use. "exited" is what they call
-- an agent with nothing running, whatever the reason, and doing says which.
local STATE = {
  starting = { "starting", "starting" },
  running = { "working", "working" },
  waiting = { "waiting", "needs you" },
  idle = { "idle", "your turn" },
  stopped = { "exited", "stopped" },
  offline = { "exited", "runner offline" },
  setup = { "exited", "no runner" },
}

local on = nil

--- Whether this Neovim is on a board. Asked once: the answer is in the
--- environment it started with.
function M.on()
  if on == nil then
    -- The runner puts the package on $XDG_DATA_DIRS, which a shell profile
    -- can replace on the way here; $ORVEN_NVIM is where it is either way.
    local dir = vim.env.ORVEN_NVIM
    if dir and dir ~= "" and not vim.tbl_contains(vim.opt.runtimepath:get(), dir) then
      vim.opt.runtimepath:append(dir)
    end
    local ok, orven = pcall(require, "orven")
    on = ok and orven.on_board() or false
  end
  return on
end

local remote = {}

function remote.send(run, text)
  require("orven.board").send(run.column, text, function(ok, err)
    if not ok then
      vim.notify("agent: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
  return true
end

--- Closing the column is what x means for a board agent: its conversation
--- goes to the board's archive, and the board saying it is gone is what
--- takes it off the list for good.
local closing = {}

function remote.drop(run, done)
  -- Held off the list until the board says the column is gone, so a board
  -- that changes in the meantime does not bring it back for a moment.
  closing[run.column] = true
  require("orven.board").close(run.column, function(ok, err)
    if not ok then
      closing[run.column] = nil
      vim.notify("agent: " .. tostring(err), vim.log.levels.ERROR)
    end
    if done then
      done()
    end
  end)
end

function remote.stop(run)
  vim.notify(("agent: %s runs on the board; stop it from its column"):format(run.name), vim.log.levels.WARN)
  return false
end

--- Its conversation, in `win`. The buffer is kept on the run so the note can
--- tell when you are already looking at it.
function remote.show(run, win)
  require("win_pick").focus(win)
  run.buf = require("orven.agents").conversation(run.column, win)
end

--- Where its changes are: here when it works on this machine, else nowhere
--- this editor can read.
function remote.local_dir(run)
  return run.here and run.cwd ~= "" and run.cwd or nil
end

local function key(column)
  return "board:" .. column
end

--- One board agent as a run: the one already taken on, brought up to date.
local function as_run(c)
  local state = STATE[c.status] or { "idle", c.status or "" }
  local run = agent.get(key(c.id)) or {
    id = key(c.id),
    column = c.id,
    remote = remote,
    since = os.time(),
  }
  if run.status ~= state[1] then
    run.since = os.time()
  end
  run.status, run.doing = state[1], state[2]
  run.name = c.title ~= "" and c.title or "agent"
  -- What it runs with, or for an agent inside another kind of column
  -- (a Database, a Debugger), that kind.
  run.cli = (c.harness or "") ~= "" and c.harness or c.kind
  run.cwd = c.dir or ""
  run.here = c.here
  run.updated = os.time()
  return run
end

local function sync(board)
  if board.down() then
    return
  end
  local live, there = {}, {}
  for _, c in ipairs(board.agents()) do
    there[c.id] = true
    if not closing[c.id] then
      live[key(c.id)] = true
      agent.adopt(as_run(c))
    end
  end
  for column in pairs(closing) do
    if not there[column] then
      closing[column] = nil
    end
  end
  for _, run in ipairs(agent.runs()) do
    if run.remote == remote and not live[run.id] then
      agent.release(run.id)
    end
  end
  agent.changed()
end

--- Start an agent column, asked opts.question about opts.ctx, in
--- opts.place's directory or here.
function M.start(opts)
  local context = require("agent_context")
  local body = opts.ctx and opts.ctx.text or ""
  local place = opts.place
  require("orven.board").open_agent({
    prompt = context.prompt(body, opts.question),
    dir = place and place.dir or vim.fn.getcwd(),
    harness = opts.cli ~= "board" and opts.cli or nil,
  }, function(column, err)
    if not column then
      vim.notify("agent: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if err then
      vim.notify("agent: the column is open, but " .. err, vim.log.levels.WARN)
    end
    local dash = require("agent_dash")
    if not dash.visible() then
      dash.open(agent.get(key(column)))
    end
  end)
end

--- What a new agent can run with, in the shape of agent_cli.available(), so
--- the start dialog lists them the way it lists the CLIs installed here.
--- The board's default comes first.
function M.harnesses(cb)
  require("orven.board").models(function(v, err)
    if not v then
      vim.notify("agent: the board did not say what an agent can run with: " .. tostring(err), vim.log.levels.WARN)
      return cb({ { name = "board", label = "the board's default" } })
    end
    local out, default = {}, v.default and v.default.harness or ""
    for _, h in ipairs(v.harnesses or {}) do
      local item = { name = h.id, label = h.name ~= "" and h.name or h.id }
      table.insert(out, h.id == default and 1 or #out + 1, item)
    end
    if #out == 0 then
      out[1] = { name = "board", label = "the board's default" }
    end
    cb(out)
  end)
end

function M.setup()
  if not M.on() then
    return false
  end
  local orven = require("orven")
  -- Its keys and its note are this config's own, already: <leader>a* and
  -- agent_toast.lua. Orven's :Orven commands stay.
  vim.g.orven_keys = false
  vim.g.orven_notes = false
  orven.setup()
  orven.on("board", sync)
  return true
end

return M
