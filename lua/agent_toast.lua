-- A note in the top-right corner when an agent is done or needs you, for the
-- times you start one and go back to code without leaving the dashboard open.
--
--   <leader>ao   open the newest one in this window, ready to type
--   <leader>ax   dismiss the note; the statusline still counts them
--
-- An agent goes on the note when it ends a turn, stops to ask for permission,
-- or exits in the middle of one. It comes off when you look at its terminal,
-- by any route, or when it starts working again because you answered it from
-- the dashboard. Nothing comes off on a timer: the note is for when you come
-- back, and one that had expired by then would have told you nothing.
--
-- The note is a float that cannot take focus, so no key ever reaches it and
-- <Esc>, q and the rest keep meaning what they meant. It is a view like the
-- dashboard, built on agent.watch(), and agent.lua does not know it is here.

local M = {}

local agent = require("agent")

local WIDTH_MAX = 60

-- What each state looks like on the note. Done reads brighter than it does on
-- the dashboard, where "your turn" is dim because it is the resting state;
-- here it is the news.
local MARK = {
  waiting = { "?", "AgentWaiting" },
  idle = { "○", "AgentDone" },
  exited = { "x", "AgentDone" },
}

local seen = {} -- run id -> the status it had last time we looked
local alerts = {} -- run id -> { run =, at =, dismissed = }
local buf, win

local function set_hl()
  vim.api.nvim_set_hl(0, "AgentDone", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "AgentFailed", { link = "DiagnosticError", default = true })
end

--- Whether a change of state is something to come and look at.
---
--- Only out of a turn. Claude fires its Notification hook again when it has
--- sat at its prompt for a minute, which moves an idle agent to waiting; by
--- then it has either been on the note since the turn ended or you have seen
--- it, and in neither case is a second bell news.
local function wants_you(was, now)
  local busy = was == "working" or was == "starting"
  if now == "waiting" or now == "idle" then
    return busy
  end
  if now == "exited" then
    return busy or was == "waiting"
  end
  return false
end

--- Whether the run's terminal is in a window of this tab, which is to say you
--- are already looking at it.
local function on_screen(run)
  if not run.buf or not vim.api.nvim_buf_is_valid(run.buf) then
    return false
  end
  local tab = vim.api.nvim_get_current_tabpage()
  for _, w in ipairs(vim.fn.win_findbuf(run.buf)) do
    if vim.api.nvim_win_get_tabpage(w) == tab then
      return true
    end
  end
  return false
end

--- The alerts, newest first, optionally only those still on the note.
local function listed(undismissed)
  local out = {}
  for _, alert in pairs(alerts) do
    if not (undismissed and alert.dismissed) then
      out[#out + 1] = alert
    end
  end
  table.sort(out, function(a, b)
    return a.at > b.at
  end)
  return out
end

local function bell()
  -- Straight to the terminal: Neovim's own bell is off ('belloff' is "all"
  -- by default), and turning it on would ring it for every failed motion too.
  pcall(vim.api.nvim_ui_send, "\a")
end

--------------------------------------------------------------------------- --
-- the note
--------------------------------------------------------------------------- --

local function close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
end

local function leader()
  local key = vim.g.mapleader or "\\"
  return key == " " and "spc" or key
end

local function draw()
  local shown = listed(true)
  if #shown == 0 then
    return close()
  end

  local rows = {}
  for _, alert in ipairs(shown) do
    local run = alert.run
    local mark = MARK[run.status] or MARK.idle
    local hl = (run.status == "exited" and run.exit_code ~= 0) and "AgentFailed" or mark[2]
    rows[#rows + 1] = { mark[1], run.name, tostring(run.doing or ""), agent.elapsed(run), hl }
  end
  local w = { 0, 0, 0 }
  for _, row in ipairs(rows) do
    for i = 2, 4 do
      w[i - 1] = math.max(w[i - 1], vim.fn.strdisplaywidth(row[i]))
    end
  end

  local lines, spans = {}, {}
  for i, row in ipairs(rows) do
    local name = row[2] .. string.rep(" ", w[1] - vim.fn.strdisplaywidth(row[2]))
    local doing = row[3] .. string.rep(" ", w[2] - vim.fn.strdisplaywidth(row[3]))
    local head = " " .. row[1] .. " " .. name .. "  "
    lines[i] = head .. doing .. "  " .. row[4] .. " "
    spans[i] = { row[5], #head, #head + #doing, #row[1] }
  end

  local footer = (" %s ao open  %s ax dismiss "):format(leader(), leader())
  local width = vim.fn.strdisplaywidth(footer)
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, WIDTH_MAX, vim.o.columns - 2)

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("agent_toast")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, span in ipairs(spans) do
    local hl, from, to, mark = span[1], span[2], span[3], span[4]
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 1, { end_col = 1 + mark, hl_group = hl })
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, from, { end_col = to, hl_group = hl })
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, to, { end_col = #lines[i], hl_group = "AgentMeta" })
  end

  -- Below the tabline when there is one, so it is not covering the tabs.
  local tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local config = {
    relative = "editor",
    anchor = "NE",
    row = tabline and 1 or 0,
    col = vim.o.columns,
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " agents ",
    title_pos = "left",
    footer = { { footer, "AgentMeta" } },
    footer_pos = "right",
    focusable = false,
    mouse = false,
    -- Under the picker and the window numbers, which are things you are
    -- doing right now; this is something to do next.
    zindex = 100,
  }

  -- A float belongs to the tab it was opened in, so one opened in another
  -- tab is closed and opened again here.
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage() then
    vim.api.nvim_win_set_config(win, config)
  else
    close()
    win = vim.api.nvim_open_win(buf, false, vim.tbl_extend("force", config, { noautocmd = true }))
    vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
    vim.wo[win].wrap = false
  end
end

--------------------------------------------------------------------------- --
-- keeping up
--------------------------------------------------------------------------- --

--- Look at every run and update the alerts. Called on every change and once
--- a second, which is cheap: a comparison per run.
local function sync()
  local before = vim.tbl_count(alerts)
  local rang = false
  local live = {}

  for _, run in ipairs(agent.runs()) do
    live[run.id] = true
    local was, now = seen[run.id], run.status
    seen[run.id] = now
    local alert = alerts[run.id]
    -- Stopped with s is you dropping it, so it comes off rather than
    -- staying on to say it exited.
    if on_screen(run) or now == "working" or run.stopped then
      alerts[run.id] = nil
    elseif was and was ~= now and wants_you(was, now) then
      -- Moved to the top and back on the note, even if it had been
      -- dismissed: this is a new thing to come and look at.
      alerts[run.id] = { run = run, at = vim.uv.hrtime() }
      rang = true
    elseif alert then
      alert.run = run
    end
  end
  for id in pairs(alerts) do
    if not live[id] then
      alerts[id] = nil
    end
  end
  for id in pairs(seen) do
    if not live[id] then
      seen[id] = nil
    end
  end

  if rang then
    bell()
  end
  draw()
  if rang or vim.tbl_count(alerts) ~= before then
    vim.cmd("redrawstatus!")
  end
end

--------------------------------------------------------------------------- --
-- what you can do about it
--------------------------------------------------------------------------- --

--- A window to open an agent into: this one, unless this one is a float, the
--- file tree, a picker or an agent list, in which case the first that is not.
local function target()
  local function ok(w)
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      return false
    end
    return vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "agents"
  end
  local here = vim.api.nvim_get_current_win()
  local targets = require("win_pick").targets()
  if ok(here) and vim.tbl_contains(targets, here) then
    return here
  end
  for _, w in ipairs(targets) do
    if ok(w) then
      return w
    end
  end
  return nil
end

--- Open the newest agent that wants you: the newest still on the note, and
--- failing that the newest dismissed, which the statusline is still counting.
function M.open()
  local alert = listed(true)[1] or listed(false)[1]
  if not alert then
    vim.notify("agent: nothing is waiting on you")
    return
  end
  local w = target()
  if not w then
    vim.notify("agent: no window to open it in", vim.log.levels.WARN)
    return
  end
  alerts[alert.run.id] = nil
  require("agent_dash").terminal(alert.run, w)
  draw()
  vim.cmd("redrawstatus!")
end

function M.dismiss()
  for _, alert in pairs(alerts) do
    alert.dismissed = true
  end
  close()
end

--- For the statusline: how many agents want you, coloured by the most urgent.
function M.component()
  local n, asking = 0, false
  for _, alert in pairs(alerts) do
    n = n + 1
    asking = asking or alert.run.status == "waiting"
  end
  if n == 0 then
    return ""
  end
  return ("%%#%s#%d agent%s%%* "):format(asking and "AgentWaiting" or "AgentDone", n, n == 1 and "" or "s")
end

set_hl()
agent.watch(sync)

local group = vim.api.nvim_create_augroup("agent_toast", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
-- Taken off the moment you look, rather than at the next tick.
vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "TabEnter" }, {
  group = group,
  callback = function()
    vim.schedule(sync)
  end,
})
vim.api.nvim_create_autocmd("VimResized", { group = group, callback = draw })

vim.keymap.set("n", "<leader>ao", M.open, { silent = true, desc = "Open the newest agent that is done or needs you" })
vim.keymap.set("n", "<leader>ax", M.dismiss, { silent = true, desc = "Dismiss the agent note" })

return M
