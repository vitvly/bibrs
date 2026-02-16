local config = require("bibrs.config")
local cli = require("bibrs.cli")
local eq, truthy = T.eq, T.truthy

--- Run fn with vim.system answering `result`; returns the command it was given.
local function with_system(result, fn)
  local real = vim.system
  local seen
  vim.system = function(cmd)
    seen = cmd
    return { wait = function() return result end }
  end
  local ok, err = pcall(fn)
  vim.system = real
  if not ok then error(err, 0) end
  return seen
end

local bib = T.tmpdir("cli") .. "/refs.bib"
vim.fn.writefile({ "" }, bib)

T.describe("cli", function()
  local function configure(files)
    config.setup({ bibrs_bin = "/bin/bibrs", files = files, auto_discover = { enable = false } })
  end

  T.it("puts the files between the subcommand and its arguments", function()
    configure({ bib })
    local cmd = cli.bib_command("list", { "--format", "{key}" })
    eq(#cmd, 5)
    eq(cmd[1], "/bin/bibrs")
    eq(cmd[2], "list")
    truthy(cmd[3]:find("refs.bib", 1, true))
    eq(cmd[4], "--format")
  end)

  T.it("treats no bib files as nothing to do, not a failure", function()
    configure({})
    eq(cli.bib_command("json"), nil)
    local called = with_system({ code = 0, stdout = "[]" }, function()
      local out, err = cli.json("json")
      eq(out, nil)
      eq(err, nil)
    end)
    eq(called, nil)
  end)

  T.it("reports a failing command's stderr", function()
    configure({ bib })
    with_system({ code = 1, stderr = "Error: failed to parse refs.bib\n" }, function()
      local out, err = cli.json("json")
      eq(out, nil)
      eq(err, "Error: failed to parse refs.bib")
    end)
  end)

  T.it("decodes JSON, mapping null to nil", function()
    configure({ bib })
    with_system({ code = 0, stdout = '[{"key":"a","file":null}]' }, function()
      eq(cli.json("json"), { { key = "a" } })
    end)
  end)

  T.it("reports invalid JSON", function()
    configure({ bib })
    with_system({ code = 0, stdout = "not json" }, function()
      local out, err = cli.json("json")
      eq(out, nil)
      truthy(err:find("invalid JSON", 1, true))
    end)
  end)
end)

T.describe("failures reach the user", function()
  T.it("peek reports a broken bib file, not a missing entry", function()
    config.setup({ bibrs_bin = "/bin/bibrs", files = { bib }, auto_discover = { enable = false } })
    T.buffer({ "[@a]" }, 1, 1)
    local real_notify = vim.notify
    local message
    vim.notify = function(m) message = m end
    with_system({ code = 1, stderr = "Error: failed to parse refs.bib" }, function()
      require("bibrs").peek()
    end)
    vim.notify = real_notify
    truthy(message:find("failed to parse", 1, true), "got: " .. tostring(message))
  end)
end)

T.rmrf(vim.fn.fnamemodify(bib, ":h"))
