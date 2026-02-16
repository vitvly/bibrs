local build = require("bibrs.build")
local eq, truthy, falsy = T.eq, T.truthy, T.falsy

T.describe("build release channel", function()
  T.it("points at a real repo, not the scaffold placeholder", function()
    falsy(build.repo:match("OWNER"), "download URL still uses the OWNER placeholder")
    truthy(build.repo:match("^[%w._-]+/[%w._-]+$"), "repo must be owner/name: " .. build.repo)
  end)
end)

T.describe("build checksum verification", function()
  local root = T.tmpdir("build")

  T.it("hashes a file correctly", function()
    local f = root .. "/data.bin"
    vim.fn.writefile({ "abc" }, f, "b") -- no trailing newline
    -- sha256("abc")
    eq(build._file_sha256(f),
       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  end)

  T.it("returns nil for a missing file", function()
    eq(build._file_sha256(root .. "/nope.bin"), nil)
  end)

  T.it("parses a shasum-style checksum file", function()
    local f = root .. "/sums.txt"
    vim.fn.writefile({ "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  bibrs.tar.gz" }, f)
    eq(build._read_checksum(f),
       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  end)

  T.it("returns nil for a missing or malformed checksum file", function()
    eq(build._read_checksum(root .. "/nope.txt"), nil)
    vim.fn.writefile({ "not a checksum" }, root .. "/bad.txt")
    -- "not" is not hex; the leading token must be hex digits
    local got = build._read_checksum(root .. "/bad.txt")
    falsy(got and #got >= 64, "malformed checksum should not yield a usable digest")
  end)

  T.rmrf(root)
end)

T.describe("build platform detection", function()
  T.it("returns a target triple and archive extension for this host", function()
    local target, ext = build.detect_target()
    truthy(target, "no target for " .. vim.uv.os_uname().sysname .. "/" .. vim.uv.os_uname().machine)
    truthy(ext == ".tar.gz" or ext == ".zip")
  end)
end)
