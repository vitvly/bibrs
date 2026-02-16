local M = {}

M.defaults = {
  files = {},
  format = "{key}\t{author} ({year}) {title}",
  citation_format = "auto", -- "auto" | "pandoc" | "latex"
  viewer = "open -a Preview {file}",
  url_opener = "open {url}",  -- used by gx when a citation has no local `file`, only a `url`
  dir_opener = "open {dir}",  -- used when a link/citation points at a directory ("open -R {dir}" reveals it instead)
  -- URL schemes a citation's `url` field may use. Anything else is refused
  -- rather than handed to the opener, since a .bib file is untrusted input and
  -- the system opener will happily dispatch app-registered schemes.
  url_schemes = { "http", "https", "mailto", "doi", "ftp", "ftps", "file" },
  dir_roots = {},             -- extra base dirs relative directory links resolve against (e.g. an Obsidian vault root)
  bibrs_bin = nil,
  auto_discover = {
    enable = true,              -- look for .bib files from the current buffer's directory up to the project root
    pattern = "%.bib$",         -- Lua pattern to match filenames (applied to filename only, not full path)
    root_markers = { ".git", ".hg", ".jj", ".svn", ".obsidian" },  -- the nearest directory containing one is the project root
  },
  filetypes = { "markdown", "tex", "latex" },  -- filetypes for buffer-local mappings
  mappings = {
    insert = "gbi",               -- open fzf picker and insert citation (global)
    open = "gx",                 -- open PDF for citation / directory under cursor, falls back to default gx (buffer-local)
    peek = "gbp",                -- show entry info in floating window (global)
    enter = "<CR>",              -- smart enter: edit citation's bib entry, or obsidian smart_action (buffer-local)
    enable = true,               -- set to false to disable all default mappings
  },
}

M.values = {}

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

function M.get()
  return M.values
end

--- Directories to search, nearest first: `dir` and its ancestors up to the
--- project root. With no root, only `dir` — walking on would pull in whatever
--- .bib files happen to sit above an unrelated note, all the way up to /.
---@param dir string
---@param markers string[]|nil
---@return string[]
local function discovery_dirs(dir, markers)
  local dirs = { dir }
  if not markers or #markers == 0 then return dirs end

  local marker = vim.fs.find(markers, { upward = true, path = dir, limit = 1 })[1]
  if not marker then return dirs end

  local root = vim.fs.dirname(marker)
  if root == dir then return dirs end

  for parent in vim.fs.parents(dir) do
    table.insert(dirs, parent)
    if parent == root then break end
  end
  return dirs
end

--- Discover .bib files from the current buffer's directory up to the project
--- root. Nearer directories come first, and names are sorted within each, so
--- the order (which decides duplicate keys) is predictable.
---@return string[]
function M._discover_local_bibs()
  local discover = M.values.auto_discover
  if not discover or not discover.enable then return {} end

  local buf_path = vim.api.nvim_buf_get_name(0)
  if buf_path == "" then return {} end

  local dir = vim.fs.normalize(vim.fn.fnamemodify(buf_path, ":h"))
  local pattern = discover.pattern or "%.bib$"
  local found = {}

  for _, d in ipairs(discovery_dirs(dir, discover.root_markers)) do
    local handle = vim.uv.fs_scandir(d)
    if handle then
      local names = {}
      while true do
        local name, typ = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if (typ == "file" or typ == "link") and name:match(pattern) then
          table.insert(names, name)
        end
      end
      table.sort(names)
      for _, name in ipairs(names) do
        table.insert(found, d .. "/" .. name)
      end
    end
  end

  return found
end

--- Build the file args string for bibrs CLI
---@return string[]
function M.file_args()
  local seen = {}
  local args = {}

  -- Normalize to an absolute, symlink-resolved path so explicit (~-expanded)
  -- and auto-discovered (concatenated from the buffer name) paths dedup
  -- against each other even when written in different forms. fnamemodify
  -- alone is not enough: Neovim reports buffer names symlink-resolved, so on
  -- macOS a configured /var/... and a discovered /private/var/... are the same
  -- file under two spellings and would otherwise both be passed to bibrs.
  local function add(path)
    local absolute = vim.fn.fnamemodify(path, ":p")
    local normalized = vim.uv.fs_realpath(absolute) or absolute
    if not seen[normalized] then
      seen[normalized] = true
      table.insert(args, absolute)
    end
  end

  -- Explicit files first
  for _, f in ipairs(M.values.files) do
    add(vim.fn.expand(f))
  end

  -- Auto-discovered local .bib files
  for _, f in ipairs(M._discover_local_bibs()) do
    add(f)
  end

  return args
end

return M
