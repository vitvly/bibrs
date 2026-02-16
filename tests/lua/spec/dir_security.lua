--- Regression tests for the command-execution bugs found in the security
--- review. Each one reproduces the original exploit and asserts that nothing
--- ran. A `.bib` file or a note may be attacker-supplied — auto_discover pulls
--- in any .bib beside the buffer — so link targets are untrusted input.

local config = require("bibrs.config")
local dir = require("bibrs.dir")
local eq, falsy = T.eq, T.falsy

local root = T.tmpdir("dir-sec")
vim.fn.mkdir(root .. "/notes", "p")
local note = root .. "/notes/note.md"
vim.fn.writefile({ "" }, note)

local function marker(name)
  return root .. "/" .. name
end

local function fired(name)
  return vim.uv.fs_stat(marker(name)) ~= nil
end

local function at(line, col)
  config.setup({})
  T.buffer({ line }, 1, col, note)
  return dir.at_cursor()
end

T.describe("dir.at_cursor does not execute link targets", function()
  -- vim.fn.expand() performs backtick expansion; using it here meant that
  -- merely resolving a link in an untrusted note ran a shell command.
  T.it("does not run backticks in a markdown link target", function()
    local m = marker("PWNED_MD")
    eq(at("A [ref](`touch " .. m .. "`) link", 10), nil)
    vim.wait(300)
    falsy(fired("PWNED_MD"), "backtick in markdown link target executed")
  end)

  T.it("does not run backticks in a wikilink target", function()
    local m = marker("PWNED_WIKI")
    eq(at("A [[`touch " .. m .. "`]] link", 8), nil)
    vim.wait(300)
    falsy(fired("PWNED_WIKI"), "backtick in wikilink target executed")
  end)

  T.it("does not run backticks in a bare path", function()
    local m = marker("PWNED_BARE")
    at("See ./`touch " .. m .. "`/x", 8)
    vim.wait(300)
    falsy(fired("PWNED_BARE"), "backtick in bare path executed")
  end)

  T.it("treats a directory whose name contains backticks as a plain path", function()
    local weird = root .. "/lit`x`dir"
    vim.fn.mkdir(weird, "p")
    -- resolve() preserves the spelling it was handed; it never resolves symlinks.
    eq(at("[d](" .. weird .. ")", 6), vim.fs.normalize(weird))
  end)

  T.it("does not glob-expand a wildcard target", function()
    -- expand() also globs; a crafted wildcard could be made expensive, and a
    -- match would resolve to a directory the note never actually named.
    vim.fn.mkdir(root .. "/notes/real", "p")
    eq(at("[g](*)", 5), nil)
    eq(at("[g](re*l)", 5), nil)
  end)
end)

-- The injection and malformed-template cases run against the real binary in
-- tests/cli.rs; here it is enough that the name reaches it unaltered.
T.describe("dir.open does not build shell strings", function()
  T.it("passes a crafted directory name through as one argument", function()
    local evil = root .. "/scans$(touch " .. marker("PWNED_OPEN") .. ")"
    config.setup({ bibrs_bin = "/bin/bibrs", dir_opener = "open {dir}" })
    local real = vim.system
    local seen
    vim.system = function(cmd) seen = cmd end
    dir.open(evil)
    vim.system = real
    eq(seen, { "/bin/bibrs", "open-dir", evil, "--dir-opener", "open {dir}" })
  end)
end)

T.rmrf(root)
