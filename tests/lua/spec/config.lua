local config = require("bibrs.config")
local eq, truthy = T.eq, T.truthy

local root = T.tmpdir("config")
vim.fn.mkdir(root .. "/papers", "p")
vim.fn.writefile({ "" }, root .. "/papers/refs.bib")
vim.fn.writefile({ "" }, root .. "/papers/other.bib")
vim.fn.writefile({ "" }, root .. "/papers/notes.txt")
vim.fn.writefile({ "" }, root .. "/explicit.bib")
local note = root .. "/papers/paper.md"
vim.fn.writefile({ "" }, note)

local function names(paths)
  local out = {}
  for _, p in ipairs(paths) do table.insert(out, vim.fn.fnamemodify(p, ":t")) end
  table.sort(out)
  return out
end

T.describe("config.setup", function()
  T.it("applies defaults", function()
    config.setup({})
    local cfg = config.get()
    eq(cfg.citation_format, "auto")
    eq(cfg.dir_opener, "open {dir}")
    eq(cfg.auto_discover.enable, true)
    truthy(vim.tbl_contains(cfg.url_schemes, "https"))
  end)

  T.it("merges user options over defaults", function()
    config.setup({ dir_opener = "xdg-open {dir}", auto_discover = { enable = false } })
    eq(config.get().dir_opener, "xdg-open {dir}")
    eq(config.get().auto_discover.enable, false)
    -- untouched keys keep their defaults
    eq(config.get().viewer, "open -a Preview {file}")
  end)
end)

T.describe("config.file_args", function()
  T.it("discovers .bib files beside the buffer", function()
    config.setup({})
    T.buffer({ "" }, 1, 0, note)
    eq(names(config.file_args()), { "other.bib", "refs.bib" })
  end)

  T.it("respects a narrowed discovery pattern", function()
    config.setup({ auto_discover = { enable = true, pattern = "^refs%.bib$" } })
    T.buffer({ "" }, 1, 0, note)
    eq(names(config.file_args()), { "refs.bib" })
  end)

  T.it("can be disabled", function()
    config.setup({ auto_discover = { enable = false } })
    T.buffer({ "" }, 1, 0, note)
    eq(config.file_args(), {})
  end)

  T.it("includes explicit files and lists them first", function()
    config.setup({ files = { root .. "/explicit.bib" }, auto_discover = { enable = false } })
    T.buffer({ "" }, 1, 0, note)
    eq(names(config.file_args()), { "explicit.bib" })
  end)

  T.it("deduplicates a file that is both explicit and discovered", function()
    config.setup({ files = { root .. "/papers/refs.bib" } })
    T.buffer({ "" }, 1, 0, note)
    eq(names(config.file_args()), { "other.bib", "refs.bib" })
  end)

  T.it("returns absolute paths", function()
    config.setup({})
    T.buffer({ "" }, 1, 0, note)
    for _, p in ipairs(config.file_args()) do
      truthy(p:sub(1, 1) == "/", "not absolute: " .. p)
    end
  end)

  T.it("returns nothing for an unnamed buffer with no explicit files", function()
    config.setup({})
    T.buffer({ "" }, 1, 0)
    eq(config.file_args(), {})
  end)
end)

T.describe("auto-discovery up to the project root", function()
  -- outside/
  --   outside.bib            above the root: never found
  --   project/               the root
  --     b.bib, a.bib
  --     sibling/sibling.bib  not an ancestor: never found
  --     chapters/
  --       z.bib, y.bib
  --       deep/deep.bib
  --       deep/paper.md
  local tree = T.realpath(T.tmpdir("discover"))
  local project = tree .. "/outside/project"
  local deep = project .. "/chapters/deep"
  vim.fn.mkdir(deep, "p")
  vim.fn.mkdir(project .. "/sibling", "p")
  for _, f in ipairs({
    "/outside/outside.bib", "/outside/project/b.bib", "/outside/project/a.bib",
    "/outside/project/sibling/sibling.bib", "/outside/project/chapters/z.bib",
    "/outside/project/chapters/y.bib", "/outside/project/chapters/deep/deep.bib",
  }) do
    vim.fn.writefile({ "" }, tree .. f)
  end
  local paper = deep .. "/paper.md"
  vim.fn.writefile({ "" }, paper)

  --- Discovered files in order, as paths relative to the tree.
  local function discovered()
    local out = {}
    for _, p in ipairs(config.file_args()) do
      table.insert(out, (T.realpath(p):gsub("^" .. vim.pesc(tree) .. "/outside/", "")))
    end
    return out
  end

  local function marker(path, make)
    make(path)
    return function() vim.fn.delete(path, "rf") end
  end

  T.it("stays in the buffer's directory when there is no root", function()
    config.setup({})
    T.buffer({ "" }, 1, 0, paper)
    eq(discovered(), { "project/chapters/deep/deep.bib" })
  end)

  T.it("walks up to the root, nearest first, sorted within a directory", function()
    local cleanup = marker(project .. "/.git", function(p) vim.fn.mkdir(p, "p") end)
    config.setup({})
    T.buffer({ "" }, 1, 0, paper)
    eq(discovered(), {
      "project/chapters/deep/deep.bib",
      "project/chapters/y.bib",
      "project/chapters/z.bib",
      "project/a.bib",
      "project/b.bib",
    })
    cleanup()
  end)

  T.it("accepts a .git file, as in a worktree or submodule", function()
    local cleanup = marker(project .. "/.git", function(p) vim.fn.writefile({ "gitdir: x" }, p) end)
    config.setup({})
    T.buffer({ "" }, 1, 0, paper)
    truthy(vim.tbl_contains(discovered(), "project/a.bib"))
    cleanup()
  end)

  T.it("stops at the nearest marker", function()
    local outer = marker(project .. "/.git", function(p) vim.fn.mkdir(p, "p") end)
    local inner = marker(project .. "/chapters/.obsidian", function(p) vim.fn.mkdir(p, "p") end)
    config.setup({})
    T.buffer({ "" }, 1, 0, paper)
    eq(discovered(), {
      "project/chapters/deep/deep.bib",
      "project/chapters/y.bib",
      "project/chapters/z.bib",
    })
    inner()
    outer()
  end)

  T.it("treats the buffer's own directory as a root", function()
    local cleanup = marker(deep .. "/.git", function(p) vim.fn.mkdir(p, "p") end)
    config.setup({})
    T.buffer({ "" }, 1, 0, paper)
    eq(discovered(), { "project/chapters/deep/deep.bib" })
    cleanup()
  end)

  T.it("searches only the buffer's directory with no root markers", function()
    local cleanup = marker(project .. "/.git", function(p) vim.fn.mkdir(p, "p") end)
    config.setup({ auto_discover = { root_markers = {} } })
    T.buffer({ "" }, 1, 0, paper)
    eq(discovered(), { "project/chapters/deep/deep.bib" })
    cleanup()
  end)

  T.it("applies the pattern at every level", function()
    local cleanup = marker(project .. "/.git", function(p) vim.fn.mkdir(p, "p") end)
    config.setup({ auto_discover = { pattern = "^a%.bib$" } })
    T.buffer({ "" }, 1, 0, paper)
    eq(discovered(), { "project/a.bib" })
    cleanup()
  end)

  T.it("keeps explicit files ahead of discovered ones", function()
    local cleanup = marker(project .. "/.git", function(p) vim.fn.mkdir(p, "p") end)
    config.setup({ files = { project .. "/b.bib" } })
    T.buffer({ "" }, 1, 0, paper)
    local got = discovered()
    eq(got[1], "project/b.bib")
    eq(got[2], "project/chapters/deep/deep.bib")
    eq(#got, 5)
    cleanup()
  end)

  T.rmrf(tree)
end)

T.rmrf(root)
