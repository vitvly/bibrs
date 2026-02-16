local config = require("bibrs.config")
local dir = require("bibrs.dir")
local eq = T.eq

local root = T.tmpdir("dir")
vim.fn.mkdir(root .. "/vault/notes", "p")
vim.fn.mkdir(root .. "/vault/scans dir/sub", "p")
vim.fn.writefile({ "x" }, root .. "/vault/notes/file.md")
local note = root .. "/vault/notes/note.md"
vim.fn.writefile({ "" }, note)
local scans = T.realpath(root .. "/vault/scans dir")

local function at(line, col)
  config.setup({})
  T.buffer({ line }, 1, col, note)
  return dir.at_cursor()
end

T.describe("dir.at_cursor", function()
  T.it("resolves a markdown link with a percent-escaped space", function()
    eq(at("See the [scans](../scans%20dir/) folder.", 10), scans)
  end)

  T.it("resolves a wikilink", function()
    eq(at("Wikilink: [[../scans dir|Scans]]", 14), scans)
  end)

  T.it("resolves a bare relative path containing a space", function()
    eq(at("Bare: ../scans dir", 8), scans)
  end)

  T.it("resolves an absolute path", function()
    eq(at("Abs: " .. scans .. "/sub", 8), scans .. "/sub")
  end)

  T.it("resolves a file:// uri", function()
    eq(at("Uri: [x](file://" .. scans:gsub(" ", "%%20") .. ")", 8), scans)
  end)

  T.it("strips a trailing slash", function()
    eq(at("[s](../scans%20dir/)", 5), scans)
  end)

  T.it("ignores http urls", function()
    eq(at("A [site](https://example.com/foo) here", 5), nil)
  end)

  T.it("ignores paths that do not exist", function()
    eq(at("Missing: ~/definitely/not/here/at/all", 12), nil)
  end)

  T.it("ignores a path that resolves to a file, not a directory", function()
    eq(at("A [f](file.md) link", 4), nil)
  end)

  T.it("returns nil when the cursor is not on the link", function()
    eq(at("word [s](../scans%20dir/) word", 1), nil)
  end)
end)

T.describe("dir.at_cursor with dir_roots", function()
  T.it("resolves vault-relative targets against a configured root", function()
    config.setup({ dir_roots = { root .. "/vault" } })
    T.buffer({ "Vault link: [[scans dir]]" }, 1, 16, note)
    -- Note the asymmetry: a dir_roots base is used as configured, so the result
    -- keeps that form, whereas a buffer-relative base comes from the buffer
    -- name, which Neovim has already symlink-resolved. Both point at the same
    -- directory; the configured spelling is preserved on purpose.
    eq(dir.at_cursor(), vim.fs.normalize(root .. "/vault/scans dir"))
  end)

  T.it("prefers the buffer's own directory over a configured root", function()
    vim.fn.mkdir(root .. "/vault/notes/shared", "p")
    vim.fn.mkdir(root .. "/vault/shared", "p")
    config.setup({ dir_roots = { root .. "/vault" } })
    T.buffer({ "[[shared]]" }, 1, 4, note)
    eq(dir.at_cursor(), T.realpath(root .. "/vault/notes/shared"))
  end)
end)

-- Template rendering is the binary's job; tests/cli.rs covers it end to end.
T.describe("dir.open", function()
  T.it("hands the path and template to the binary as single arguments", function()
    config.setup({ bibrs_bin = "/bin/bibrs", dir_opener = "open -R {dir}" })
    local real = vim.system
    local seen
    vim.system = function(cmd) seen = cmd end
    dir.open(scans)
    vim.system = real
    eq(seen, { "/bin/bibrs", "open-dir", scans, "--dir-opener", "open -R {dir}" })
  end)
end)

T.rmrf(root)
