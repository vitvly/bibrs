# bibrs

CLI tool and Neovim plugin for BibTeX/BibLaTeX citations: an FZF picker, LSP
autocomplete, opening PDFs at the cited page, and jumping to `.bib` entries. Works
with [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim).

## Requirements

- **Neovim 0.11+**
- **[fzf-lua](https://github.com/ibhagwan/fzf-lua)**, only for `:BibInsert`
- **`cargo`** with Rust 1.85+ to build the binary, unless you set `bibrs_bin`.
  Without it, the plugin tries a pre-built download using `curl` and `tar`/`unzip`,
  but see [Releases](#releases).

## Installation

With lazy.nvim:

```lua
{
  "vitvly/bibrs",
  build = ":BibUpdate",   -- the leading ':' matters: without it lazy uses a shell
  ft = { "markdown", "tex", "latex" },
  dependencies = { "ibhagwan/fzf-lua" },
  opts = { files = { "~/refs/library.bib" } },
}
```

With vim-plug
```
Plug 'vitvly/bibrs', { 'do': ':BibUpdate' }
```
and call `require("bibrs").setup({ ... })`.

## Configuration

Every option with its default:

```lua
require("bibrs").setup({
  files = {},   -- bib files that are always loaded, ahead of discovered ones
  auto_discover = {
    enable = true,
    pattern = "%.bib$",   -- Lua pattern, matched against the filename only
    root_markers = { ".git", ".hg", ".jj", ".svn", ".obsidian" },
  },
  dir_roots = {},   -- extra bases for relative directory links, e.g. a vault root
  -- {key} must come first, followed by a tab: :BibInsert inserts what precedes it
  format = "{key}\t{author} ({year}) {title}",   -- also {type}
  citation_format = "auto",   -- "pandoc" | "latex"; auto is latex in TeX buffers
  viewer = "open -a Preview {file}",   -- also {page}; see "PDF viewers"
  url_opener = "open {url}",   -- used when a citation has no local `file`
  dir_opener = "open {dir}",
  -- A .bib file is untrusted input, so other schemes in `url` are refused
  url_schemes = { "http", "https", "mailto", "doi", "ftp", "ftps", "file" },
  filetypes = { "markdown", "tex", "latex" },   -- get mappings and completion
  mappings = {   -- set one to false to disable it, or enable = false for all
    insert = "gbi",
    open   = "gx",
    peek   = "gbp",
    enter  = "<CR>",
    enable = true,
  },
  bibrs_bin = nil,   -- path to the binary; nil auto-installs it
})
```

## Commands and keymaps

| Command | Key | Description |
|---|---|---|
| `:BibInsert` | `gbi` | Pick and insert a citation |
| `:BibOpen` | `gx` | Open the citation or directory reference under the cursor |
| `:BibPeek` | `gbp` | Show the entry in a floating window |
| `:BibEdit` | `<CR>` | Jump to the citation's entry in its `.bib` file |
| `:BibUpdate` | | Build or update the binary |

`gx` and `<CR>` are buffer-local to `filetypes`. Off a citation, `gx` does whatever
it did before, and `<CR>` runs obsidian.nvim's `smart_action` in its notes, or a
plain `<CR>` elsewhere.

`:BibUpdate` exists as soon as the plugin loads; the other commands appear once a
binary is available. It only rebuilds when the binary is missing or its version
differs from `Cargo.toml`, so new code without a version bump is not rebuilt.

## Citation syntax

| Form | Example | With page |
|---|---|---|
| pandoc | `[@einstein1905]` | `[@einstein1905, p. 42]` |
| LaTeX | `\cite{einstein1905}` | `\cite[p. 42]{einstein1905}` |

Page forms: `p. 42`, `p.42`, `pp. 10-20` (opens the first page), `page 5`.

Limitations:

- Not recognized: `\parencite`, `\autocite`, `\citep`, `[see @key]`, bare `@key`,
  and a bare page number (`\cite[42]{key}`).
- Multi-key citations can be inserted but not read back: `[@a; @b]` resolves to
  `a`, and `\cite{a,b}` is looked up as the single key `a,b`.

## Auto-discover

bibrs reads `.bib` files in the buffer's directory and each parent up to the
project root: the nearest directory containing a `root_markers` entry. With no
root, or `root_markers = {}`, only the buffer's directory is searched. Sibling and
child directories are never scanned.

If a key is defined twice, the first match wins: `files` in listed order, then
discovered files, nearest directory first and alphabetical within each.

One `.bib` that fails to parse makes `gx`, `:BibPeek`, `:BibInsert` and completion
report an error, even if it is higher up in the project.

## Completion

An in-process Lua LSP server provides completion through Neovim's builtin
autocompletion, and any UI that consumes `vim.lsp` picks it up too. It triggers on
`[@` and inside `\cite{`, including after a comma, but not on `[@a; @`, `[see @` or
`\cite[p. 3]{`. Entries refresh when you write a `.bib` file from within Neovim.

## Directory references

`gx` opens a directory that exists, written as a markdown link, wikilink or path:

```markdown
[scans](../scans%20dir/)  [[assets/scans]]  ~/refs/scans/
```

Relative targets resolve against the buffer's directory, then `dir_roots`, then the
cwd. A plain word counts too: `gx` on "docs" opens `./docs` if it exists.

A `.bib` entry whose `file` is a directory also opens with `dir_opener`, ignoring
any page. This is a bibrs extension to the BibLaTeX `file` field.

`file` is read as a plain path. JabRef/Zotero's `description:path:type` format is
not parsed. A leading `~` is expanded but `$VAR` is not, and relative paths resolve
against Neovim's working directory, not the `.bib` file's directory or `dir_roots`.

## PDF viewers

```lua
viewer = "open -a Preview {file}"                -- default, ignores the page
viewer = "open 'skim://{file}#page={page}'"      -- Skim
viewer = "zathura --page={page} {file}"          -- Zathura
viewer = "evince --page-index={page} {file}"     -- Evince
```

The defaults for `viewer`, `url_opener` and `dir_opener` use macOS's `open`, so
configure them elsewhere (`xdg-open {dir}` on Linux). With no page, a standalone
`{page}` argument is dropped, while an embedded one becomes empty, as in `--page=`.
`{file}` is not URL-encoded.

These templates are split like shell words but **not** run through a shell, and
placeholders are filled in afterwards, so a path or URL can never be interpreted as
shell syntax. Pipes, `$VAR` and `~` don't work, and a word starting with `#` begins
a comment. For anything more, use a script at an absolute path.

## CLI

```sh
bibrs list refs.bib --format $'{key}\t{author} ({year}) {title}'   # FZF source
bibrs json refs.bib
bibrs locate refs.bib --key einstein1905
bibrs open refs.bib --key einstein1905 --page 3 --viewer "zathura --page={page} {file}"
bibrs open-dir ~/refs/scans --dir-opener "open {dir}"
```

`open` also takes `--dir-opener`, `--url-opener` and `--url-schemes "http,https"`.
All subcommands except `open-dir` accept multiple `.bib` files.

## Testing

```sh
make test        # everything; or make test-rust, make test-lua
```

Both suites run in CI on Linux and macOS. The Lua tests need no extra dependencies.

## Releases

Pre-built binaries are used only when `cargo` is unavailable or the build fails.
The plugin refuses any archive without a matching `.sha256` file, as produced by
`shasum -a 256`. `release.yml` does not generate these yet, so its releases can't be
installed by the plugin until they are added by hand or the workflow is extended.
