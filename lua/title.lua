-- What the terminal window or tab is called: the file, then the project.
--
-- Filename first on purpose. A tab bar truncates from the right and gets narrow
-- as soon as there are a few tabs open, so the part that tells two of them
-- apart has to come before the part they have in common. `+` marks a buffer
-- with unwritten changes, which is the other thing worth seeing from a tab you
-- are not looking at.

-- The project is the checkout nvim is sitting in, not something worked out per
-- buffer: git resolves the question against the process's own directory, so
-- every buffer would get the same answer anyway. Worked out once and kept until
-- :cd moves it, rather than on every redraw, which is what a title is.
local project = nil

local function project_name()
	if project then
		return project
	end
	-- the same call statusline.lua makes, so the two agree on where the
	-- project starts; outside a repository the directory itself is the name
	local root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("%s+$", "")
	project = vim.fn.fnamemodify(root ~= "" and root or vim.fn.getcwd(), ":t")
	return project
end

--- The left half: what this buffer is, or nil when it is not a thing with a
--- name worth showing, in which case the title falls back to the project alone.
local function subject()
	-- netrw calls its buffer "NetrwTreeListing" wherever it is pointed, so the
	-- name is no use; the directory it is listing is the answer to the question
	if vim.bo.filetype == "netrw" then
		local dir = vim.b.netrw_curdir
		return dir and (vim.fn.fnamemodify(dir, ":t") .. "/") or nil
	end
	-- help buffers are a real file and read like one. Everything else with a
	-- buftype is a terminal, the quickfix list or one of the picker's scratch
	-- floats, none of which should take the title off the file behind them.
	if vim.bo.buftype ~= "" and vim.bo.buftype ~= "help" then
		return nil
	end
	local file = vim.fn.expand("%:t")
	return file ~= "" and file or "[No Name]"
end

function _G._title()
	local what = subject()
	if not what then
		return project_name()
	end
	return what .. (vim.bo.modified and " +" or "") .. " - " .. project_name()
end

vim.api.nvim_create_autocmd("DirChanged", {
	group = vim.api.nvim_create_augroup("TitleProject", { clear = true }),
	callback = function()
		project = nil
	end,
})

vim.o.title = true
-- Through %{} rather than writing the string into 'titlestring' on an autocmd:
-- it is re-evaluated on redraw, so the `+` appears the moment the buffer is
-- touched with no event to hook, and what the expression returns is taken
-- literally, so a % in a file name cannot be read back as a format item.
vim.o.titlestring = "%{v:lua._title()}"
