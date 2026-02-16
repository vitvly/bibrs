local M = {}

--- Detect citation format based on filetype or config
---@param cfg table
---@return string "pandoc" or "latex"
function M.detect_format(cfg)
  if cfg.citation_format ~= "auto" then
    return cfg.citation_format
  end
  local ft = vim.bo.filetype
  if ft == "tex" or ft == "latex" or ft == "plaintex" then
    return "latex"
  end
  return "pandoc"
end

--- Parse page number from pandoc citation suffix
--- Handles: "p. 42", "pp. 10-20", "p.42", "page 5"
--- A viewer can only jump to one page, so a range yields its first page.
---@param suffix string
---@return string|nil page number
function M.parse_page(suffix)
  if not suffix then return nil end
  local page = suffix:match("pp?%.?%s*(%d+)")
    or suffix:match("page%s+(%d+)")
  return page
end

--- Parse citation under cursor
--- Returns { key = string, page = string|nil } or nil
---@return table|nil
function M.parse_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-indexed

  -- Try pandoc style: [@key] or [@key, p. 42]
  for start, key, suffix, stop in line:gmatch("()%[@([%w_:%-%.%+/]+)([^%]]-)%]()") do
    if col >= start and col < stop then
      return { key = key, page = M.parse_page(suffix) }
    end
  end

  -- Try latex style: \cite{key} or \cite[p. 42]{key}
  for start, opt, key, stop in line:gmatch("()\\cite(%b[])(%b{})()") do
    if col >= start and col < stop then
      local k = key:sub(2, -2) -- strip braces
      local o = opt:sub(2, -2) -- strip brackets
      return { key = k, page = M.parse_page(o) }
    end
  end
  -- \cite{key} without optional arg
  for start, key, stop in line:gmatch("()\\cite(%b{})()") do
    if col >= start and col < stop then
      local k = key:sub(2, -2)
      return { key = k, page = nil }
    end
  end

  return nil
end

--- Format citation key(s) for insertion
---@param keys string[]
---@param format string "pandoc" or "latex"
---@return string
function M.format_citation(keys, format)
  if format == "latex" then
    return "\\cite{" .. table.concat(keys, ",") .. "}"
  end
  -- pandoc
  if #keys == 1 then
    return "[@" .. keys[1] .. "]"
  end
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, "@" .. k)
  end
  return "[" .. table.concat(parts, "; ") .. "]"
end

return M
