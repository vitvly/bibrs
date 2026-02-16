local cite = require("bibrs.cite")
local eq, truthy = T.eq, T.truthy

T.describe("cite.parse_page", function()
  T.it("parses common page suffixes", function()
    eq(cite.parse_page("p. 42"), "42")
    eq(cite.parse_page("p.42"), "42")
    eq(cite.parse_page("pp. 10-20"), "10")
    eq(cite.parse_page("pp. 10–20"), "10")
    eq(cite.parse_page("page 5"), "5")
  end)

  T.it("returns nil when there is no page", function()
    eq(cite.parse_page(""), nil)
    eq(cite.parse_page("see also"), nil)
    eq(cite.parse_page(nil), nil)
  end)
end)

T.describe("cite.parse_at_cursor", function()
  T.it("reads a pandoc citation", function()
    T.buffer({ "As shown in [@einstein1905] this holds." }, 1, 16)
    eq(cite.parse_at_cursor(), { key = "einstein1905", page = nil })
  end)

  T.it("reads a pandoc citation with a page", function()
    T.buffer({ "See [@knuth1984, p. 42]." }, 1, 8)
    eq(cite.parse_at_cursor(), { key = "knuth1984", page = "42" })
  end)

  T.it("reads a latex citation", function()
    T.buffer({ "Text \\cite{knuth1984} more." }, 1, 12)
    eq(cite.parse_at_cursor(), { key = "knuth1984", page = nil })
  end)

  T.it("reads a latex citation with an optional page argument", function()
    T.buffer({ "Text \\cite[p. 7]{knuth1984} more." }, 1, 12)
    eq(cite.parse_at_cursor(), { key = "knuth1984", page = "7" })
  end)

  T.it("returns nil when the cursor is outside the citation", function()
    T.buffer({ "Before [@key] after" }, 1, 0)
    eq(cite.parse_at_cursor(), nil)
    T.buffer({ "Before [@key] after" }, 1, 16)
    eq(cite.parse_at_cursor(), nil)
  end)

  T.it("picks the citation the cursor is actually in", function()
    T.buffer({ "[@first] and [@second]" }, 1, 15)
    eq(cite.parse_at_cursor().key, "second")
  end)

  T.it("handles keys with punctuation", function()
    T.buffer({ "[@smith:2020-a.b+c/d]" }, 1, 5)
    eq(cite.parse_at_cursor().key, "smith:2020-a.b+c/d")
  end)
end)

T.describe("cite.format_citation", function()
  T.it("formats pandoc citations", function()
    eq(cite.format_citation({ "a" }, "pandoc"), "[@a]")
    eq(cite.format_citation({ "a", "b" }, "pandoc"), "[@a; @b]")
  end)

  T.it("formats latex citations", function()
    eq(cite.format_citation({ "a" }, "latex"), "\\cite{a}")
    eq(cite.format_citation({ "a", "b" }, "latex"), "\\cite{a,b}")
  end)
end)

T.describe("cite.detect_format", function()
  T.it("honors an explicit setting", function()
    eq(cite.detect_format({ citation_format = "latex" }), "latex")
    eq(cite.detect_format({ citation_format = "pandoc" }), "pandoc")
  end)

  T.it("derives the format from the filetype when auto", function()
    T.buffer({ "" }, 1, 0)
    vim.bo.filetype = "tex"
    eq(cite.detect_format({ citation_format = "auto" }), "latex")
    vim.bo.filetype = "markdown"
    eq(cite.detect_format({ citation_format = "auto" }), "pandoc")
  end)
end)
