local config = require("bibrs.config")
local cite = require("bibrs.cite")
local cli = require("bibrs.cli")

local M = {}

--- Run bibrs list and return lines
---@return string[]
local function get_entries()
  local stdout, err = cli.run("list", { "--format", config.get().format })
  if err then
    vim.notify("bibrs list failed: " .. err, vim.log.levels.ERROR)
    return {}
  end

  local lines = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end

--- Extract citation key from a formatted line (text before first tab)
---@param line string
---@return string
local function extract_key(line)
  return line:match("^([^\t]+)") or line
end

--- Open fzf-lua picker and call callback with selected key(s)
---@param opts? { multi?: boolean, on_select: fun(keys: string[]) }
function M.pick(opts)
  opts = opts or {}
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua is required for bibrs picker", vim.log.levels.ERROR)
    return
  end

  local entries = get_entries()
  if #entries == 0 then
    vim.notify("No bibliography entries found", vim.log.levels.WARN)
    return
  end

  fzf.fzf_exec(entries, {
    prompt = "Cite> ",
    multi = opts.multi ~= false,
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local keys = {}
        for _, line in ipairs(selected) do
          table.insert(keys, extract_key(line))
        end
        if opts.on_select then
          opts.on_select(keys)
        end
      end,
    },
  })
end

--- Pick citation(s) and insert at cursor position
function M.insert()
  local cfg = config.get()
  local format = cite.detect_format(cfg)

  M.pick({
    multi = true,
    on_select = function(keys)
      local text = cite.format_citation(keys, format)
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      local new_line = line:sub(1, col) .. text .. line:sub(col + 1)
      vim.api.nvim_set_current_line(new_line)
      vim.api.nvim_win_set_cursor(0, { row, col + #text })
    end,
  })
end

return M
