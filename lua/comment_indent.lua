-- Keeping the * of a /* */ comment under the opener's own *.
--
-- Most indent scripts only know code. GetOdinIndent reads the * that ends
-- /** as an operator carried onto the next line and adds a level;
-- GetTypescriptIndent adds a level on the first line after /** and takes it
-- away again on the second. Both run again on any of 'indentkeys' typed
-- mid-line, and : is one of them in Odin, so a comment line that was
-- right can jump a tab the moment its prose reaches a colon. cindent and the
-- Rust and Go scripts get it right, and come out of this unchanged.
--
-- So the filetype's 'indentexpr' is wrapped, not replaced. Inside a block
-- comment, a line starting with * (the */ that closes it too) sits one
-- column right of where the /* starts, an empty one sits under the /* itself,
-- and any other line keeps the indent 'autoindent' gave it, which suits prose
-- inside a comment that has no leader. Everywhere else the filetype's own
-- expression answers as before.
--
-- Typing * as the first thing on a line reindents it, so "* " and " * " both
-- come out in the same column whether or not 'formatoptions' lays the leader
-- down on <CR> (Odin's does not).

local M = {}

local SELF = "v:lua.require'comment_indent'.expr()"

-- How far back to look for the /* before deciding there is none. A comment
-- longer than this is rare enough that the filetype's own guess will do.
local REACH = 500

--- Whether the line ends inside a block comment, and where the /* that left it
--- open starts (a byte index), given whether it began inside one.
---
--- Strings are stepped over so that "src/**/*.ts" does not open a comment, and
--- a // outside a comment ends the line. Single quotes are left alone: Rust
--- lifetimes and Odin runes would read as strings that never close.
local function scan(line, inside)
  local opener
  local i = 1
  while i <= #line do
    local two = line:sub(i, i + 1)
    if inside then
      if two == "*/" then
        inside, i = false, i + 2
      else
        i = i + 1
      end
    elseif two == "/*" then
      inside, opener, i = true, i, i + 2
    elseif two == "//" then
      break
    else
      local c = line:sub(i, i)
      if c == '"' or c == "`" then
        local j = i + 1
        while j <= #line and line:sub(j, j) ~= c do
          j = j + (line:sub(j, j) == "\\" and 2 or 1)
        end
        i = j + 1
      else
        i = i + 1
      end
    end
  end
  return inside, opener
end

--- The display column of the /* whose comment holds line lnum, and the line it
--- is on, or nil when lnum is not inside a block comment.
local function opener(lnum)
  local stop = math.max(1, lnum - REACH)
  for l = lnum - 1, stop, -1 do
    local line = vim.fn.getline(l)
    local open, close = line:find("/*", 1, true), line:find("*/", 1, true)
    if open or close then
      -- A line began inside a comment if it carries the * leader, or if a
      -- */ comes before any /* on it. One that began inside and is still
      -- inside without opening anything is prose that mentions src/*.ts,
      -- and the opener is further up.
      local began = line:match("^%s*%*") ~= nil or (close ~= nil and (open == nil or close < open))
      local inside, at = scan(line, began)
      if not inside then
        return nil
      end
      if at ~= nil then
        return vim.fn.strdisplaywidth(line:sub(1, at - 1)), l
      end
    end
  end
  return nil
end

function M.expr()
  local lnum = vim.v.lnum
  local col = opener(lnum)
  if col == nil then
    local indent = vim.fn.eval(vim.b.comment_indent_expr)
    -- The Go and TypeScript scripts indent code to match the line above,
    -- which after a comment is the */ sitting a column right of its /*.
    -- Code lines up with the comment's first line instead.
    local prev = vim.fn.prevnonblank(lnum - 1)
    if prev > 0 and indent == vim.fn.indent(prev) then
      local _, first = opener(prev)
      if first ~= nil then
        return vim.fn.indent(first)
      end
    end
    return indent
  end
  local line = vim.fn.getline(lnum)
  if line:match("^%s*%*") then
    return col + 1
  end
  -- A line just opened, at the opener's column rather than the leader's, so
  -- that " * " typed out in full lands where "* " does. Vim stops
  -- reindenting a line once a space has been typed into its indent, so the
  -- 0=* below never gets the chance to take the extra column back.
  if line:match("^%s*$") then
    return col
  end
  return -1
end

--- Wrap the buffer's 'indentexpr' if it has one and it is not wrapped already.
local function wrap(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local expr = vim.bo[buf].indentexpr
  if expr == "" or expr == SELF then
    return
  end
  vim.b[buf].comment_indent_expr = expr
  vim.bo[buf].indentexpr = SELF
  if not vim.tbl_contains(vim.split(vim.bo[buf].indentkeys, ","), "0=*") then
    vim.bo[buf].indentkeys = vim.bo[buf].indentkeys .. ",0=*"
  end
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("CommentIndent", { clear = true }),
  callback = function(ev)
    -- Deferred, because Neovim registers the indent scripts' own FileType
    -- handler after init.lua has run, so this one fires first, before there
    -- is any 'indentexpr' to wrap.
    vim.schedule(function()
      wrap(ev.buf)
    end)
  end,
})

return M
