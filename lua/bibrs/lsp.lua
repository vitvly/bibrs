local config = require("bibrs.config")

--- In-process LSP server providing bibliography citation completion.
--- Runs entirely inside Neovim (no external process); attaches to configured
--- filetypes and feeds Neovim's builtin `vim.lsp.completion`.
local M = {}

-- Entry cache, keyed by directory so different projects don't share state.
local cache = {} ---@type table<string, table[]>

--- Load bib entries for the given directory (cached).
---@param dir string
---@return table[]
local function load_entries(dir)
  if cache[dir] then return cache[dir] end

  local entries, err = require("bibrs.cli").json("json")
  if err then
    -- Cached like a success, so this reports once per reload, not per keystroke.
    vim.notify("bibrs: could not load entries: " .. err, vim.log.levels.ERROR)
  end
  cache[dir] = entries or {}
  return cache[dir]
end

--- Invalidate the entry cache so entries are reloaded on the next completion.
function M.reload()
  cache = {}
end

--- Build LSP CompletionItems for the citation context at the cursor.
---@param params table LSP completion params (textDocument.uri + position)
---@return table|nil result LSP CompletionList, or nil when not in a citation
local function completions(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local pos = params.position
  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
  local col = pos.character

  local before = line:sub(1, col)
  -- Only treat "@key" as a citation when it's inside "[...]" (pandoc's actual
  -- bracketed citation syntax) — cite.lua doesn't recognize bare "@key"
  -- either, so completing it would insert a key nothing else can find.
  local pandoc_pos = before:match("()@[%w_:%-%.%+/]*$")
  local in_pandoc = pandoc_pos ~= nil and before:sub(pandoc_pos - 1, pandoc_pos - 1) == "["
  local in_latex = before:match("\\cite%{[%w_:,%-%.%+/]*$") ~= nil

  if not in_pandoc and not in_latex then
    return { isIncomplete = false, items = {} }
  end

  local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)) or vim.uv.cwd()
  local entries = load_entries(dir)

  -- pandoc [@key] wants a trailing ], and \cite{key} wants a trailing },
  -- unless one already follows the cursor.
  local after = line:sub(col + 1)
  local needs_close_pandoc = in_pandoc and not after:match("^[%w_:%-%.%+/]*%]")
  local needs_close_latex = in_latex and not after:match("^[%w_:,%-%.%+/]*%}")

  local items = {}
  for _, entry in ipairs(entries) do
    local detail = string.format("%s (%s) %s", entry.author or "", entry.year or "", entry.title or "")
    local insert = entry.key
    if needs_close_pandoc then
      insert = insert .. "]"
    elseif needs_close_latex then
      insert = insert .. "}"
    end
    table.insert(items, {
      label = entry.key,
      kind = 18, -- CompletionItemKind.Reference
      detail = detail,
      insertText = insert,
      documentation = {
        kind = "markdown",
        value = table.concat({
          "**" .. (entry.title or entry.key) .. "**",
          "",
          entry.author and ("*" .. entry.author .. "*") or nil,
          entry.year,
        }, "\n"),
      },
    })
  end

  return { isIncomplete = false, items = items }
end

--- In-process LSP server factory (used as `cmd` for `vim.lsp.start`).
--- See `:h vim.lsp.rpc.start` for the dispatcher/server contract.
---@param dispatchers table
---@return table
local function server(dispatchers)
  local closing = false
  local next_id = 0

  local handlers = {
    ["initialize"] = function(_params, callback)
      callback(nil, {
        capabilities = {
          completionProvider = {
            triggerCharacters = { "@", "{", "," },
            resolveProvider = false,
          },
        },
        serverInfo = { name = "bibrs" },
      })
    end,
    ["textDocument/completion"] = function(params, callback)
      callback(nil, completions(params))
    end,
    ["shutdown"] = function(_params, callback)
      callback(nil, nil)
    end,
  }

  local srv = {}

  function srv.request(method, params, callback)
    local handler = handlers[method]
    if handler then
      handler(params, callback)
    else
      -- Unknown request: reply with MethodNotFound so the client doesn't hang.
      callback({ code = -32601, message = "method not found: " .. method }, nil)
    end
    next_id = next_id + 1
    return true, next_id
  end

  function srv.notify(method, _params)
    if method == "exit" then
      if dispatchers.on_exit then
        dispatchers.on_exit(0, 15)
      end
    end
    return true
  end

  function srv.is_closing()
    return closing
  end

  function srv.terminate()
    closing = true
  end

  return srv
end

--- Start (or reuse) the bibrs LSP client for the given buffer.
---@param bufnr integer
function M.attach(bufnr)
  local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
  vim.lsp.start({
    name = "bibrs",
    cmd = server,
    root_dir = dir or vim.uv.cwd(),
    on_attach = function(client, buf)
      -- Enable Neovim's builtin LSP autocompletion for this client/buffer.
      if vim.lsp.completion and vim.lsp.completion.enable then
        vim.lsp.completion.enable(true, client.id, buf, { autotrigger = true })
      end
    end,
  }, { bufnr = bufnr })
end

--- Register a FileType autocmd that attaches the LSP to configured filetypes.
function M.register()
  local ft = config.get().filetypes
  if not ft or #ft == 0 then return end

  local group = vim.api.nvim_create_augroup("bibrs_lsp", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = ft,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })

  -- Entries are cached per directory; invalidate on save so edits (e.g. via
  -- <CR>'s jump-to-edit) show up in completion without needing to reload Neovim.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.bib",
    callback = M.reload,
  })

  -- Attach to already-open buffers of matching filetypes (e.g. on lazy-load).
  local ftset = {}
  for _, f in ipairs(ft) do ftset[f] = true end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and ftset[vim.bo[buf].filetype] then
      M.attach(buf)
    end
  end
end

return M
