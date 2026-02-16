local config = require("bibrs.config")

--- Runs the bibrs binary, so that every caller builds commands and reports
--- failures the same way.
local M = {}

--- Command line for a subcommand that reads the configured .bib files.
---@param subcommand string
---@param args? string[]
---@return string[]|nil cmd nil when there are no .bib files to read
function M.bib_command(subcommand, args)
  local files = config.file_args()
  if #files == 0 then return nil end

  local cmd = { config.get().bibrs_bin, subcommand }
  vim.list_extend(cmd, files)
  return vim.list_extend(cmd, args or {})
end

--- Run a subcommand over the .bib files and wait for its output.
--- No .bib files is not a failure: that returns nil with no error.
---@param subcommand string
---@param args? string[]
---@return string|nil stdout, string|nil err
function M.run(subcommand, args)
  local cmd = M.bib_command(subcommand, args)
  if not cmd then return nil, nil end

  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "")
  end
  return result.stdout, nil
end

--- Like run(), for subcommands that print JSON.
---@param subcommand string
---@param args? string[]
---@return any|nil decoded, string|nil err
function M.json(subcommand, args)
  local stdout, err = M.run(subcommand, args)
  if not stdout then return nil, err end

  local ok, decoded = pcall(vim.json.decode, stdout, { luanil = { object = true } })
  if not ok then
    return nil, "invalid JSON from bibrs " .. subcommand
  end
  return decoded, nil
end

--- Launch a command without waiting, notifying if it fails.
---@param cmd string[]
---@param failure string message shown ahead of the command's stderr
function M.spawn(cmd, failure)
  vim.system(cmd, { detach = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify(failure .. ": " .. (result.stderr or ""), vim.log.levels.ERROR)
      end)
    end
  end)
end

return M
