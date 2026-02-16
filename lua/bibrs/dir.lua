local config = require("bibrs.config")

local M = {}

--- Percent-decode a link target. Markdown links escape spaces as `%20`
--- whether or not they carry a `file://` scheme. Skipped for targets that
--- already contain spaces, so a literal `%` in a path is left alone.
---@param s string
---@return string
local function url_decode(s)
  if s:find("%s") then return s end
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Turn a link target into an absolute directory path, or nil if it isn't one.
--- Tries each base directory in turn for relative targets, so vault-relative
--- wikilinks resolve even when the note lives in a subfolder.
---@param target string
---@return string|nil
function M.resolve(target)
  if not target or target == "" then return nil end
  target = vim.trim(target)

  local body = target:match("^file://(.*)$")
  if body then
    target = url_decode(body)
  elseif target:match("^%a[%w+.%-]*://") then
    return nil -- http:, obsidian:, ... — not a local path
  else
    target = url_decode(target)
  end

  -- Anchors/queries a markdown link may carry
  target = target:gsub("[#?].*$", "")
  if target == "" then return nil end

  -- Normalize a trailing separator (but never turn "/" into "")
  if #target > 1 then
    target = target:gsub("/+$", "")
  end

  local candidates = {}
  if target:match("^[~/$]") then
    table.insert(candidates, target)
  else
    for _, base in ipairs(M.bases()) do
      table.insert(candidates, base .. "/" .. target)
    end
  end

  for _, path in ipairs(candidates) do
    -- vim.fs.normalize expands ~ and $VAR without invoking a shell. Never use
    -- vim.fn.expand() here: it performs backtick expansion, so a link target
    -- like [x](`id`) in an untrusted note would execute a command just by
    -- resolving it, and it globs, which a crafted target can make expensive.
    local expanded = vim.fs.normalize(path)
    local stat = vim.uv.fs_stat(expanded)
    if stat and stat.type == "directory" then
      return (vim.fn.fnamemodify(expanded, ":p"):gsub("/$", ""))
    end
  end

  return nil
end

--- Base directories that relative targets are resolved against, in order
---@return string[]
function M.bases()
  local bases = {}
  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path ~= "" then
    table.insert(bases, vim.fn.fnamemodify(buf_path, ":h"))
  end
  for _, root in ipairs(config.get().dir_roots or {}) do
    table.insert(bases, vim.fs.normalize(root))
  end
  table.insert(bases, vim.fn.getcwd())
  return bases
end

--- Extract the candidate link targets that span the cursor column
---@return string[]
local function targets_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-indexed
  local found = {}

  -- Cap the candidate list: the space-tolerant bare-path expansion below is
  -- quadratic in words per line, and each candidate costs a stat.
  local MAX_CANDIDATES = 32

  local function add_span(start, stop, target)
    if col >= start and col < stop and target ~= "" and #found < MAX_CANDIDATES then
      table.insert(found, target)
    end
  end

  -- Obsidian wikilink: [[target]] or [[target|label]]
  for start, inner, stop in line:gmatch("()%[%[([^%]]+)%]%]()") do
    add_span(start, stop, (inner:gsub("|.*$", "")))
  end

  -- Markdown link: [label](target) — also handles <...> wrapped targets
  for start, target, stop in line:gmatch("()%[[^%]]*%]%(([^%)]*)%)()") do
    add_span(start, stop, (target:gsub("^<(.*)>$", "%1")))
  end

  -- Bare path token, e.g. ~/refs/scans/ or ./assets. An unbracketed path may
  -- contain spaces, so from the token the cursor sits in we also try the rest
  -- of the line, trimming one trailing word at a time — longest match first,
  -- and only paths that actually exist survive resolution anyway.
  for start, token, stop in line:gmatch("()([^%s()%[%]<>\"'`]+)()") do
    if col >= start and col < stop then
      local rest = line:sub(start)
      while rest ~= "" do
        add_span(start, stop, (rest:gsub("[%.,;:!%?]+$", "")))
        local trimmed = rest:match("^(.*)%s+%S+$")
        if not trimmed then break end
        rest = trimmed
      end
      add_span(start, stop, (token:gsub("[%.,;:!%?]+$", "")))
    end
  end

  return found
end

--- Directory referenced under the cursor, if any
---@return string|nil absolute path
function M.at_cursor()
  for _, target in ipairs(targets_at_cursor()) do
    local dir = M.resolve(target)
    if dir then return dir end
  end
  return nil
end

--- Open a directory with the configured file manager command. The binary
--- renders the template, so there is one implementation of its rules.
---@param path string
function M.open(path)
  local cfg = config.get()
  require("bibrs.cli").spawn(
    { cfg.bibrs_bin, "open-dir", path, "--dir-opener", cfg.dir_opener },
    "bibrs: opening directory failed"
  )
end

return M
