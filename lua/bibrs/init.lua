local config = require("bibrs.config")
local build = require("bibrs.build")

local M = {}

--- Register commands and mappings (called after binary is available)
function M._register()
  M._registered = true

  vim.api.nvim_create_user_command("BibInsert", function() M.insert() end, {
    desc = "Pick and insert a citation",
  })
  vim.api.nvim_create_user_command("BibOpen", function() M.open() end, {
    desc = "Open the citation or directory under cursor",
  })
  vim.api.nvim_create_user_command("BibPeek", function() M.peek() end, {
    desc = "Show entry info for citation under cursor",
  })
  vim.api.nvim_create_user_command("BibEdit", function() M.edit() end, {
    desc = "Jump to citation's entry in its .bib file for editing",
  })

  require("bibrs.lsp").register()

  local maps = config.get().mappings
  if maps.enable then
    M._setup_mappings(maps)
  end
end

function M.setup(opts)
  config.setup(opts)

  local cfg = config.get()

  -- Registered up front, not in _register(): the other commands only appear
  -- once a binary is available, but :BibUpdate is what you reach for when the
  -- install failed, and plugin managers invoke it as their build hook.
  vim.api.nvim_create_user_command("BibUpdate", function()
    build.update(function(bin_path)
      config.get().bibrs_bin = bin_path
      -- Recovering from a failed install: nothing else has registered these.
      if not M._registered then
        M._register()
      end
    end)
  end, {
    desc = "Build/update the bibrs binary",
  })

  -- If user explicitly set bibrs_bin, skip auto-install
  if cfg.bibrs_bin then
    M._register()
    return
  end

  -- Auto-install: resolve binary, then register commands
  build.ensure(function(bin_path)
    -- Store the resolved path in config
    cfg.bibrs_bin = bin_path
    M._register()
  end)
end

--- Check if cursor is on a citation
---@return table|nil parsed citation reference
function M._citation_at_cursor()
  return require("bibrs.cite").parse_at_cursor()
end

--- Set up key mappings
function M._setup_mappings(maps)
  -- Global mappings (work in any buffer)
  if maps.insert then
    vim.keymap.set("n", maps.insert, function() M.insert() end, {
      desc = "bibrs: insert citation",
    })
  end

  if maps.peek then
    vim.keymap.set("n", maps.peek, function() M.peek() end, {
      desc = "bibrs: peek citation info",
    })
  end

  -- Buffer-local mappings via filetype autocmd (override obsidian.nvim etc.)
  local ft = config.get().filetypes
  if #ft == 0 then return end

  local function map_enter(buf)
    if not maps.enter then return end
    vim.keymap.set("n", maps.enter, function()
      if M._citation_at_cursor() then
        M.edit()
      else
        M._fallback_enter()
      end
    end, { buffer = buf, desc = "bibrs: smart enter (edit citation's bib entry, or obsidian)" })
  end

  local function map_buffer(buf)
    vim.b[buf].bibrs_mapped = true

    if maps.open then
      -- Capture whatever gx does in this buffer before we override
      local orig = vim.fn.maparg(maps.open, "n", false, true)
      vim.keymap.set("n", maps.open, function()
        if M._try_open() then
          return
        elseif orig and orig.callback then
          orig.callback()
        elseif orig and orig.rhs and orig.rhs ~= "" then
          vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(orig.rhs, true, true, true))
        else
          vim.ui.open(vim.fn.expand("<cfile>"))
        end
      end, { buffer = buf, desc = "bibrs: open citation/directory or default gx" })
    end

    map_enter(buf)
  end

  local group = vim.api.nvim_create_augroup("bibrs_mappings", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = ft,
    callback = function(ev) map_buffer(ev.buf) end,
  })

  -- obsidian.nvim sets its own buffer-local <CR> on BufEnter, after FileType,
  -- and again on every re-entry. This event fires right after that, so take
  -- <CR> back; _fallback_enter still hands non-citations to obsidian.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ObsidianNoteEnter",
    callback = function()
      if vim.tbl_contains(ft, vim.bo.filetype) then
        map_enter(vim.api.nvim_get_current_buf())
      end
    end,
  })

  -- The binary may have arrived after buffers were opened (async first-run
  -- install, or recovery via :BibUpdate); their FileType has already fired.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(ft, vim.bo[buf].filetype)
      and not vim.b[buf].bibrs_mapped then
      vim.api.nvim_buf_call(buf, function() map_buffer(buf) end)
    end
  end
end

--- Fallback for enter key — tries obsidian smart_action, then default <CR>
function M._fallback_enter()
  local keys = "<CR>"
  -- Only in notes obsidian.nvim manages: elsewhere smart_action can act on a
  -- buffer the user never asked it to touch (e.g. creating checkboxes).
  if vim.b.obsidian_buffer then
    local ok, actions = pcall(require, "obsidian.actions")
    if ok and actions.smart_action then
      -- It is written for an expr mapping: it returns keys rather than acting.
      local called, result = pcall(actions.smart_action)
      if called and type(result) == "string" then
        keys = result
      end
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, true, true), "n", false)
end

--- Open fzf-lua picker and insert selected citation(s)
function M.insert()
  require("bibrs.picker").insert()
end

--- Open whatever bibrs recognizes under the cursor: a citation (PDF at its
--- page, or the entry's url/folder), or a link/path pointing at a directory.
---@return boolean handled
function M._try_open()
  local ref = require("bibrs.cite").parse_at_cursor()
  if ref then
    require("bibrs.open").open(ref.key, ref.page)
    return true
  end

  local dir = require("bibrs.dir").at_cursor()
  if dir then
    require("bibrs.dir").open(dir)
    return true
  end

  return false
end

--- Parse citation or directory reference under cursor and open it
function M.open()
  if not M._try_open() then
    vim.notify("bibrs: no citation or directory found under cursor", vim.log.levels.WARN)
  end
end

--- Parse citation under cursor and jump to its entry in the source .bib file
function M.edit()
  local cite = require("bibrs.cite")
  local opener = require("bibrs.open")

  local ref = cite.parse_at_cursor()
  if not ref then
    vim.notify("bibrs: no citation found under cursor", vim.log.levels.WARN)
    return
  end

  local loc, err = opener.locate(ref.key)
  if not loc then
    vim.notify("bibrs: " .. (err or ("entry not found: " .. ref.key)), vim.log.levels.WARN)
    return
  end

  vim.cmd.edit(vim.fn.fnameescape(loc.file))
  -- loc.line was computed from the on-disk file; if it's already open
  -- elsewhere with unsaved changes, :edit reuses that buffer and the line
  -- count may not match. Clamp instead of letting nvim_win_set_cursor throw.
  local line = math.max(1, math.min(loc.line, vim.api.nvim_buf_line_count(0)))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zz")
end

--- Show entry info in a floating window
function M.peek()
  local cite = require("bibrs.cite")
  local opener = require("bibrs.open")

  local ref = cite.parse_at_cursor()
  if not ref then
    vim.notify("bibrs: no citation found under cursor", vim.log.levels.WARN)
    return
  end

  local entry, err = opener.get_entry(ref.key)
  if not entry then
    vim.notify("bibrs: " .. (err or ("entry not found: " .. ref.key)), vim.log.levels.WARN)
    return
  end

  local lines = {
    "Key:    " .. (entry.key or ""),
    "Type:   " .. (entry.entry_type or ""),
    "Author: " .. (entry.author or ""),
    "Title:  " .. (entry.title or ""),
    "Year:   " .. (entry.year or ""),
  }
  if entry.doi then table.insert(lines, "DOI:    " .. entry.doi) end
  if entry.url then table.insert(lines, "URL:    " .. entry.url) end
  if entry.file then table.insert(lines, "File:   " .. entry.file) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width + 2, vim.o.columns - 4),
    height = #lines,
    style = "minimal",
    border = "rounded",
  })

  -- Close on any key press or cursor move
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })

  -- Defer registration by a tick: entering the new window synchronously
  -- triggers a spurious CursorMoved right away, which would close the
  -- window before it's ever seen.
  vim.schedule(function()
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
      buffer = buf,
      once = true,
      callback = function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end,
    })
  end)
end

return M
