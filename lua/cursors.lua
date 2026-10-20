vim.pack.add({
  {
    src = "https://github.com/jake-stewart/multicursor.nvim",
    version = "1.0",
  },
})

local mc = require("multicursor-nvim")
mc.setup()

mc.addKeymapLayer(function(layer_set)
  layer_set("n", "<Esc>", mc.clearCursors, { desc = "Back to one cursor" })
end)

local M = {}

function M.select_each(spans)
  mc.action(function(ctx)
    local main = ctx:mainCursor()
    local where = main:getPos()
    for _, span in ipairs(spans) do
      local row, first, last = table.unpack(span)
      main:clone():setMode("v"):setVisual({ row, first }, { row, last })
    end
    main:delete()
    ctx:nearestCursor(where):select()
  end)
end

vim.keymap.set("n", "grw", function()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return
  end
  local pattern = "\\V\\C\\<" .. vim.fn.escape(word, "\\") .. "\\>"
  local spans = {}
  for _, match in ipairs(vim.fn.matchbufline(vim.api.nvim_get_current_buf(), pattern, 1, "$")) do
    spans[#spans + 1] = { match.lnum, match.byteidx + 1, match.byteidx + #match.text }
  end
  M.select_each(spans)
end, { silent = true, desc = "A cursor on every whole-word match of the word in the file, strings and comments too" })

return M
