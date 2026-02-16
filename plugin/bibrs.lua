-- bibrs: Neovim plugin for BibTeX citation management
-- Commands are registered in require('bibrs').setup()
-- This file exists so Neovim recognizes the plugin directory.

-- Guard against double-loading
if vim.g.loaded_bibrs then return end
vim.g.loaded_bibrs = true

-- Available before setup() so plugin managers can use it as a build hook
vim.api.nvim_create_user_command("BibUpdate", function()
  require("bibrs.build").update()
end, { desc = "Build/update bibrs binary" })
