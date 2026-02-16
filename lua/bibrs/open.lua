local config = require("bibrs.config")
local cli = require("bibrs.cli")

local M = {}

--- Open a citation's `file` (PDF, or a directory via `dir_opener`), falling
--- back to its `url`. Optionally at a specific page.
---@param key string
---@param page? string|number
function M.open(key, page)
  local cfg = config.get()

  local args = { "--key", key }
  if page then
    vim.list_extend(args, { "--page", tostring(page) })
  end
  vim.list_extend(args, {
    "--viewer", cfg.viewer,
    "--url-opener", cfg.url_opener,
    "--dir-opener", cfg.dir_opener,
    "--url-schemes", table.concat(cfg.url_schemes or {}, ","),
  })

  local cmd = cli.bib_command("open", args)
  if not cmd then
    vim.notify("bibrs: no bib files configured", vim.log.levels.ERROR)
    return
  end
  cli.spawn(cmd, "bibrs open failed")
end

--- Locate the source .bib file and line number for a citation key
---@param key string
---@return table|nil loc { file = string, line = integer }
---@return string|nil err
function M.locate(key)
  return cli.json("locate", { "--key", key })
end

--- Get JSON entry for a citation key (for peek)
---@param key string
---@return table|nil entry
---@return string|nil err
function M.get_entry(key)
  local entries, err = cli.json("json")
  if not entries then return nil, err end

  for _, entry in ipairs(entries) do
    if entry.key == key then
      return entry, nil
    end
  end
  return nil, nil
end

return M
