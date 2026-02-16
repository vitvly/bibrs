--- Minimal zero-dependency test runner for headless Neovim.
---
--- Deliberately not plenary/busted: the plugin has no runtime dependencies and
--- the test suite shouldn't add one. Run with:
---   nvim --headless -u NONE -l tests/lua/runner.lua
--- Exits non-zero if any test fails, so CI can consume it.

local M = { passed = 0, failed = 0, failures = {}, current = nil }

function M.describe(name, fn)
  M.current = name
  fn()
  M.current = nil
end

function M.it(name, fn)
  local label = (M.current and (M.current .. " › ") or "") .. name
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
    io.write("  ok   " .. label .. "\n")
  else
    M.failed = M.failed + 1
    table.insert(M.failures, { label = label, err = tostring(err) })
    io.write("  FAIL " .. label .. "\n         " .. tostring(err) .. "\n")
  end
end

local function render(v)
  return type(v) == "table" and vim.inspect(v) or tostring(v)
end

function M.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "",
      render(expected), render(actual)), 2)
  end
end

function M.truthy(v, msg)
  if not v then error(msg or "expected truthy, got " .. render(v), 2) end
end

function M.falsy(v, msg)
  if v then error(msg or "expected falsy, got " .. render(v), 2) end
end

--- Create a scratch tree; returns its path. Cleaned up by the caller via M.rmrf.
function M.tmpdir(name)
  local dir = vim.fn.tempname() .. "-" .. name
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.rmrf(path)
  vim.fn.delete(path, "rf")
end

--- Absolute, symlink-resolved path — macOS reports /var as /private/var, and
--- dir.resolve returns the resolved form, so expectations must match.
function M.realpath(path)
  local direct = vim.uv.fs_realpath(path)
  if direct then return (direct:gsub("/$", "")) end
  -- The leaf may not exist yet (nvim still resolves the directory part when
  -- naming a buffer), so resolve the parent and rejoin.
  local parent = vim.uv.fs_realpath(vim.fn.fnamemodify(path, ":h"))
  if parent then
    return (parent:gsub("/$", "")) .. "/" .. vim.fn.fnamemodify(path, ":t")
  end
  return (vim.fn.fnamemodify(path, ":p"):gsub("/$", ""))
end

--- Load a buffer with the given lines and place the cursor.
function M.buffer(lines, row, col, name)
  -- Reuse a buffer already carrying this name: naming a second one raises E95.
  local buf
  if name then
    -- Neovim stores the symlink-resolved path, so compare resolved forms
    -- (on macOS /var/... is stored as /private/var/...).
    local want = M.realpath(name)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == want then
        buf = b
        break
      end
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    if name then vim.api.nvim_buf_set_name(buf, name) end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return buf
end

function M.run(specs)
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  vim.opt.runtimepath:append(root)
  _G.T = M

  for _, spec in ipairs(specs) do
    io.write("\n" .. spec .. "\n")
    local chunk, err = loadfile(root .. "/tests/lua/spec/" .. spec .. ".lua")
    if not chunk then
      M.failed = M.failed + 1
      table.insert(M.failures, { label = spec, err = "load error: " .. tostring(err) })
      io.write("  FAIL could not load: " .. tostring(err) .. "\n")
    else
      local ok, run_err = pcall(chunk)
      if not ok then
        M.failed = M.failed + 1
        table.insert(M.failures, { label = spec, err = tostring(run_err) })
        io.write("  FAIL spec aborted: " .. tostring(run_err) .. "\n")
      end
    end
  end

  io.write(("\n%d passed, %d failed\n"):format(M.passed, M.failed))
  if M.failed > 0 then
    io.write("\nFailures:\n")
    for _, f in ipairs(M.failures) do
      io.write("  " .. f.label .. "\n    " .. f.err .. "\n")
    end
  end
  vim.cmd("cq " .. (M.failed > 0 and 1 or 0))
end

M.run({ "cite", "dir", "dir_security", "config", "build", "cli", "init" })
