-- What the language servers are doing, in the statusline, and a way into the
-- log for when the answer is "nothing".
--
--   the segment   names of the servers attached to this buffer. A name with !
--                 after it is one that should be attached to this filetype and
--                 is not, which is what a server that failed to start looks
--                 like. Progress messages replace the names while they run.
--   <leader>l     the log file, in a horizontal split, scrolled to the end
--   :LspLog       the same; :vertical LspLog splits the other way
--   :LspLog debug what gets written to it from now on (off/error/warn/info/
--                 debug/trace, warn by default)
--
-- Servers are matched to a buffer by filetype, the same way vim.lsp.enable
-- decides whether to start one, so the segment stays empty in buffers no
-- server was ever going to attach to.

local M = {}

local progress = nil

local function set_hl()
	local hl = vim.api.nvim_set_hl
	hl(0, "StlLsp", { link = "Comment", default = true })
	hl(0, "StlLspDown", { link = "DiagnosticError", default = true })
	hl(0, "StlLspBusy", { link = "DiagnosticInfo", default = true })
end

--------------------------------------------------------------------------- --
-- the segment
--------------------------------------------------------------------------- --

--- Servers enabled for this buffer's filetype, running or not.
local function expected(buf)
	local ft = vim.bo[buf].filetype
	local out = {}
	if ft == "" then
		return out
	end
	for _, name in ipairs(require("lsp").servers) do
		-- indexing vim.lsp.config resolves the config off the runtimepath, and
		-- a broken one throws rather than returning nil
		local ok, cfg = pcall(function()
			return vim.lsp.config[name]
		end)
		if ok and cfg and vim.tbl_contains(cfg.filetypes or {}, ft) then
			out[#out + 1] = name
		end
	end
	return out
end

--- The statusline chunk, highlight escapes included. Empty when there is
--- nothing to say, so the caller can concatenate it unconditionally.
function M.component(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if progress then
		return "%#StlLspBusy#" .. progress:gsub("%%", "%%%%") .. "%* "
	end

	local attached = {}
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
		attached[client.name] = true
	end

	local parts = {}
	for _, name in ipairs(expected(buf)) do
		if attached[name] then
			parts[#parts + 1] = "%#StlLsp#" .. name .. "%*"
			attached[name] = nil
		else
			parts[#parts + 1] = "%#StlLspDown#" .. name .. "!%*"
		end
	end
	-- anything attached that we did not ask for, e.g. a config someone enabled
	-- by hand, still belongs in the list
	for name in vim.spairs(attached) do
		parts[#parts + 1] = "%#StlLsp#" .. name .. "%*"
	end

	if #parts == 0 then
		return ""
	end
	return table.concat(parts, ",") .. " "
end

--------------------------------------------------------------------------- --
-- the log
--------------------------------------------------------------------------- --

local LEVELS = { "off", "error", "warn", "info", "debug", "trace" }

local function log_win()
	local path = vim.lsp.log.get_filename()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == path then
			return win
		end
	end
end

local function reload()
	vim.cmd("silent! checktime")
	vim.cmd("silent! edit")
	vim.cmd("normal! G")
end

--- <leader>l / :LspLog. `split` is the command to make the window with.
function M.log(split)
	local path = vim.lsp.log.get_filename()
	if vim.fn.filereadable(path) == 0 then
		vim.notify("lsp: nothing logged yet (" .. path .. ")", vim.log.levels.WARN)
		return
	end

	local existing = log_win()
	if existing then
		vim.api.nvim_set_current_win(existing)
		reload()
		return
	end

	-- Below the code rather than above it, which is where a log belongs and is
	-- not what a bare :split does without 'splitbelow'. Through the sidebar
	-- helper so <leader>l from netrw splits the editing area rather than
	-- tearing the tree in half.
	require("netrw_sidebar").new_editing_split(split or "belowright split")
	vim.cmd("keepalt edit " .. vim.fn.fnameescape(path))

	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].filetype = "lsplog"
	vim.bo[buf].buflisted = false
	vim.wo.wrap = false
	vim.wo.number = false
	vim.wo.relativenumber = false
	vim.cmd("normal! G")

	vim.keymap.set("n", "R", reload, {
		buffer = buf,
		silent = true,
		desc = "Reread the log and jump to the end",
	})
	vim.keymap.set("n", "q", "<C-w>c", {
		buffer = buf,
		silent = true,
		desc = "Close the log window",
	})
end

--------------------------------------------------------------------------- --

function M.setup()
	set_hl()
	local group = vim.api.nvim_create_augroup("LspStatus", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

	-- Read straight off the event rather than through vim.lsp.status(), which
	-- drains each client's progress ring as a side effect: whichever redraw got
	-- there first would be the only one to see a message.
	vim.api.nvim_create_autocmd("LspProgress", {
		group = group,
		callback = function(ev)
			local value = ev.data and ev.data.params and ev.data.params.value
			if type(value) ~= "table" or value.kind == "end" then
				progress = nil
			else
				progress = value.title or ""
				if value.message then
					progress = progress .. ": " .. value.message
				end
				if value.percentage then
					progress = progress .. " " .. value.percentage .. "%"
				end
			end
			vim.cmd("redrawstatus")
		end,
	})

	vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
		group = group,
		callback = function()
			vim.cmd("redrawstatus")
		end,
	})

	vim.api.nvim_create_user_command("LspLog", function(opts)
		if opts.args ~= "" then
			vim.lsp.log.set_level(opts.args)
			vim.notify("lsp log level: " .. opts.args)
		end
		M.log(opts.smods.vertical and "belowright vsplit" or "belowright split")
	end, {
		nargs = "?",
		desc = "Open the LSP log in a split, optionally setting the log level",
		complete = function(lead)
			return vim.tbl_filter(function(l)
				return l:sub(1, #lead) == lead
			end, LEVELS)
		end,
	})

	vim.keymap.set("n", "<leader>l", function()
		M.log("belowright split")
	end, {
		silent = true,
		desc = "Open the LSP log in a horizontal split",
	})
end

return M
