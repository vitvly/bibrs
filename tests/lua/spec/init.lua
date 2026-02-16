local eq, truthy = T.eq, T.truthy

-- Stubbed: these specs exercise registration, not the installer or the server.
package.loaded["bibrs.lsp"] = { register = function() end }
local build = require("bibrs.build")
local bibrs = require("bibrs")

local function enter_desc(buf)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == "<CR>" then return m.desc end
  end
end

--- Run _fallback_enter and return the keys it feeds.
local function fed_keys()
  local real = vim.api.nvim_feedkeys
  local fed
  vim.api.nvim_feedkeys = function(keys) fed = keys end
  bibrs._fallback_enter()
  vim.api.nvim_feedkeys = real
  return fed
end

local function termcodes(s)
  return vim.api.nvim_replace_termcodes(s, true, true, true)
end

T.describe("recovering from a failed install", function()
  local open_buf = T.buffer({ "" }, 1, 0)
  vim.bo[open_buf].filetype = "markdown"

  local real_ensure, real_update = build.ensure, build.update
  build.ensure = function() end -- a failed install never calls back
  build.update = function(cb) cb("/bin/echo") end
  bibrs._registered = nil
  bibrs.setup({})

  T.it("holds back the other commands until there is a binary", function()
    eq(vim.fn.exists(":BibInsert"), 0)
    eq(vim.fn.exists(":BibUpdate"), 2)
  end)

  vim.cmd("BibUpdate")

  T.it("registers them after a successful :BibUpdate", function()
    eq(vim.fn.exists(":BibInsert"), 2)
    eq(require("bibrs.config").get().bibrs_bin, "/bin/echo")
  end)

  T.it("maps buffers that were opened before the binary arrived", function()
    truthy(enter_desc(open_buf), "expected a <CR> mapping")
  end)

  build.ensure, build.update = real_ensure, real_update
end)

T.describe("obsidian.nvim <CR>", function()
  local buf = T.buffer({ "plain text" }, 1, 0)
  vim.bo[buf].filetype = "markdown"

  T.it("takes <CR> back when obsidian remaps it on note enter", function()
    vim.keymap.set("n", "<CR>", "<Nop>", { buffer = buf, desc = "Obsidian Smart Action" })
    vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteEnter" })
    truthy(enter_desc(buf):find("bibrs", 1, true), "expected the bibrs mapping")
  end)

  package.loaded["obsidian.actions"] = {
    smart_action = function() return "<cmd>Obsidian follow_link<cr>" end,
  }

  T.it("feeds the keys smart_action returns, in an obsidian note", function()
    vim.b[buf].obsidian_buffer = true
    eq(fed_keys(), termcodes("<cmd>Obsidian follow_link<cr>"))
  end)

  T.it("uses a plain <CR> outside obsidian notes", function()
    vim.b[buf].obsidian_buffer = nil
    eq(fed_keys(), termcodes("<CR>"))
  end)

  T.it("uses a plain <CR> if smart_action errors", function()
    vim.b[buf].obsidian_buffer = true
    package.loaded["obsidian.actions"] = { smart_action = function() error("boom") end }
    eq(fed_keys(), termcodes("<CR>"))
    vim.b[buf].obsidian_buffer = nil
  end)

  package.loaded["obsidian.actions"] = nil
end)

package.loaded["bibrs.lsp"] = nil
