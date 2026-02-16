local M = {}

--- GitHub repo pre-built binaries are downloaded from. Keep this pointed at
--- the real upstream: whoever owns this namespace controls a binary that gets
--- chmod 755'd and executed on every machine where `cargo` is unavailable.
M.repo = "vitvly/bibrs"

--- Parse a `shasum -a 256` style file ("<hex>  <filename>")
---@param path string
---@return string|nil
function M._read_checksum(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line and line:match("^%s*(%x+)")
end

--- SHA-256 of a file, computed in-process (no external hashing tool needed)
---@param path string
---@return string|nil
function M._file_sha256(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data then return nil end
  local ok, digest = pcall(vim.fn.sha256, data)
  return ok and digest or nil
end

--- Resolve the plugin root directory (2 levels up from lua/bibrs/)
---@return string
function M.plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2) -- remove leading @
  -- source is <root>/lua/bibrs/build.lua → go up 3 dirs
  local dir = vim.fn.fnamemodify(source, ":h:h:h")
  return dir
end

--- Path to the locally-installed binary
---@return string
function M.bin_path()
  return M.plugin_root() .. "/bin/bibrs"
end

--- Read the expected version from Cargo.toml
---@return string|nil
function M.expected_version()
  local root = M.plugin_root()
  local cargo_toml = root .. "/Cargo.toml"
  local f = io.open(cargo_toml, "r")
  if not f then return nil end
  for line in f:lines() do
    local ver = line:match('^version%s*=%s*"([^"]+)"')
    if ver then
      f:close()
      return ver
    end
  end
  f:close()
  return nil
end

--- Check installed binary version (synchronous, fast)
---@return string|nil
function M.installed_version()
  local bin = M.bin_path()
  if not vim.uv.fs_stat(bin) then return nil end
  local result = vim.system({ bin, "--version" }, { text = true }):wait()
  if result.code ~= 0 then return nil end
  -- Output is "bibrs X.Y.Z\n"
  local ver = (result.stdout or ""):match("(%d+%.%d+%.%d+)")
  return ver
end

--- Ensure the bibrs binary exists, then call callback(bin_path).
--- Does NOT check version — use update() for that (via plugin manager post-update hook).
---@param callback fun(bin_path: string)
function M.ensure(callback)
  local bin = M.bin_path()

  -- Already built/downloaded — use as-is
  if vim.uv.fs_stat(bin) then
    callback(bin)
    return
  end

  M._install(callback)
end

--- Build or download the binary (shared by ensure and update)
---@param callback fun(bin_path: string)
function M._install(callback)
  local bin = M.bin_path()

  if vim.fn.executable("cargo") == 1 then
    M.build(function(ok)
      if ok then
        callback(bin)
      else
        vim.notify("bibrs: cargo build failed, trying download...", vim.log.levels.WARN)
        M.download(function(dl_ok)
          if dl_ok then
            callback(bin)
          else
            vim.notify("bibrs: failed to install binary", vim.log.levels.ERROR)
          end
        end)
      end
    end)
  else
    M.download(function(ok)
      if ok then
        callback(bin)
      else
        vim.notify("bibrs: failed to download binary (no cargo found either)", vim.log.levels.ERROR)
      end
    end)
  end
end

--- Check version and rebuild/redownload if outdated.
--- Intended to be called from plugin manager post-update hooks or :BibUpdate.
---@param callback? fun(bin_path: string)
function M.update(callback)
  callback = callback or function() end
  local installed = M.installed_version()
  local expected = M.expected_version()

  if installed and expected and installed == expected then
    vim.notify("bibrs: already up-to-date (" .. installed .. ")", vim.log.levels.INFO)
    callback(M.bin_path())
    return
  end

  if installed and expected then
    vim.notify(("bibrs: updating %s -> %s"):format(installed, expected), vim.log.levels.INFO)
  end

  M._install(callback)
end

--- Build from source using cargo
---@param callback fun(ok: boolean)
function M.build(callback)
  local root = M.plugin_root()
  vim.notify("bibrs: building from source...", vim.log.levels.INFO)

  vim.system(
    { "cargo", "build", "--release" },
    { cwd = root },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          vim.notify("bibrs: cargo build failed:\n" .. (result.stderr or ""), vim.log.levels.ERROR)
          callback(false)
          return
        end

        -- Ensure bin/ directory exists
        local bin_dir = root .. "/bin"
        vim.fn.mkdir(bin_dir, "p")

        -- Copy the built binary
        local src = root .. "/target/release/bibrs"
        local dst = M.bin_path()
        local ok = vim.uv.fs_copyfile(src, dst)
        if not ok then
          vim.notify("bibrs: failed to copy binary to " .. dst, vim.log.levels.ERROR)
          callback(false)
          return
        end

        -- Make executable
        vim.uv.fs_chmod(dst, tonumber("755", 8))
        vim.notify("bibrs: build complete", vim.log.levels.INFO)
        callback(true)
      end)
    end
  )
end

--- Detect platform and return the target triple
---@return string|nil target, string|nil ext
function M.detect_target()
  local uname = vim.uv.os_uname()
  local os_map = {
    Darwin = { arm64 = "aarch64-apple-darwin", x86_64 = "x86_64-apple-darwin" },
    Linux = { x86_64 = "x86_64-unknown-linux-gnu", aarch64 = "aarch64-unknown-linux-gnu" },
    Windows_NT = { x86_64 = "x86_64-pc-windows-msvc" },
  }

  local os_targets = os_map[uname.sysname]
  if not os_targets then return nil, nil end

  local target = os_targets[uname.machine]
  if not target then return nil, nil end

  local ext = uname.sysname == "Windows_NT" and ".zip" or ".tar.gz"
  return target, ext
end

--- Download a pre-built binary from GitHub releases
---@param callback fun(ok: boolean)
function M.download(callback)
  local target, ext = M.detect_target()
  if not target then
    vim.notify("bibrs: unsupported platform for pre-built binary", vim.log.levels.ERROR)
    callback(false)
    return
  end

  local root = M.plugin_root()
  local bin_dir = root .. "/bin"
  vim.fn.mkdir(bin_dir, "p")

  local asset = "bibrs-" .. target .. ext
  local base = "https://github.com/" .. M.repo .. "/releases/latest/download/"
  local url = base .. asset
  local tmp = vim.fn.tempname() .. ext
  local sum_tmp = tmp .. ".sha256"

  vim.notify("bibrs: downloading pre-built binary...", vim.log.levels.INFO)

  vim.system(
    { "curl", "-fSL", "--proto", "=https", "--tlsv1.2", "-o", tmp, url },
    {},
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          vim.notify("bibrs: download failed:\n" .. (result.stderr or ""), vim.log.levels.ERROR)
          callback(false)
          return
        end

        -- Verify the archive against the published checksum before unpacking
        -- it. Fail closed: an unverifiable download is not installed.
        local sum_res = vim.system({
          "curl", "-fSL", "--proto", "=https", "--tlsv1.2", "-o", sum_tmp, url .. ".sha256",
        }, {}):wait()
        if sum_res.code ~= 0 then
          os.remove(tmp)
          vim.notify(
            "bibrs: no published checksum for " .. asset .. "; refusing to install.\n"
              .. "Install cargo and let bibrs build from source instead.",
            vim.log.levels.ERROR
          )
          callback(false)
          return
        end

        local expected = M._read_checksum(sum_tmp)
        local actual = M._file_sha256(tmp)
        os.remove(sum_tmp)
        if not expected or not actual or expected:lower() ~= actual:lower() then
          os.remove(tmp)
          vim.notify(
            ("bibrs: checksum mismatch for %s (expected %s, got %s); refusing to install."):format(
              asset, tostring(expected), tostring(actual)
            ),
            vim.log.levels.ERROR
          )
          callback(false)
          return
        end

        -- Extract
        local extract_cmd
        if ext == ".zip" then
          extract_cmd = { "unzip", "-o", "-j", tmp, "-d", bin_dir }
        else
          -- Flatten paths and drop archive-supplied ownership so a crafted
          -- archive can't write outside bin_dir.
          extract_cmd = { "tar", "xzf", tmp, "-C", bin_dir, "--no-same-owner" }
        end

        vim.system(extract_cmd, {}, function(ex_result)
          vim.schedule(function()
            os.remove(tmp)
            if ex_result.code ~= 0 then
              vim.notify("bibrs: extraction failed:\n" .. (ex_result.stderr or ""), vim.log.levels.ERROR)
              callback(false)
              return
            end

            local bin = M.bin_path()
            vim.uv.fs_chmod(bin, tonumber("755", 8))
            vim.notify("bibrs: download complete", vim.log.levels.INFO)
            callback(true)
          end)
        end)
      end)
    end
  )
end

return M
