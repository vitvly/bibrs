use anyhow::{Context, Result};
use biblatex::{Bibliography, ChunksExt, DateValue, Person, PermissiveType, RawBibliography};
use serde::Serialize;
use std::path::Path;

#[derive(Debug, Serialize)]
pub struct Entry {
    pub key: String,
    pub entry_type: String,
    pub author: String,
    pub title: String,
    pub year: String,
    pub file: Option<String>,
    pub doi: Option<String>,
    pub url: Option<String>,
}

pub fn parse_files(paths: &[impl AsRef<Path>]) -> Result<Vec<Entry>> {
    let mut entries = Vec::new();
    for path in paths {
        let path = path.as_ref();
        let src =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let bib = Bibliography::parse(&src)
            .map_err(|e| anyhow::anyhow!("failed to parse {}: {e}", path.display()))?;

        for entry in bib.iter() {
            let author = entry
                .author()
                .map(|authors: Vec<Person>| {
                    authors
                        .iter()
                        .map(|a| a.name.clone())
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();

            let title = entry
                .title()
                .map(|t| t.format_sentence())
                .unwrap_or_default();

            let year = entry
                .date()
                .ok()
                .and_then(|d| match d {
                    PermissiveType::Typed(date) => {
                        let y = match date.value {
                            DateValue::At(dt) | DateValue::After(dt) | DateValue::Before(dt) => {
                                dt.year
                            }
                            DateValue::Between(dt, _) => dt.year,
                        };
                        Some(y.to_string())
                    }
                    PermissiveType::Chunks(_) => None,
                })
                .unwrap_or_default();

            let file = entry.file().ok();
            let doi = entry.doi().ok();
            let url = entry.url().ok();

            entries.push(Entry {
                key: entry.key.clone(),
                entry_type: entry.entry_type.to_string(),
                author,
                title,
                year,
                file,
                doi,
                url,
            });
        }
    }
    Ok(entries)
}

#[derive(Debug, Serialize)]
pub struct Location {
    pub file: String,
    pub line: usize,
}

/// Find the source file and 1-indexed line number where a citation key is defined.
pub fn locate_entry(paths: &[impl AsRef<Path>], key: &str) -> Result<Location> {
    for path in paths {
        let path = path.as_ref();
        let src =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let raw = RawBibliography::parse(&src)
            .map_err(|e| anyhow::anyhow!("failed to parse {}: {e}", path.display()))?;

        if let Some(entry) = raw.entries.iter().find(|e| e.v.key.v == key) {
            let line = src[..entry.span.start].matches('\n').count() + 1;
            return Ok(Location { file: path.display().to_string(), line });
        }
    }
    anyhow::bail!("Citation key '{key}' not found")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
    }

    #[test]
    fn parses_core_fields() {
        let entries = parse_files(&[fixture("basic.bib")]).unwrap();
        let e = entries.iter().find(|e| e.key == "einstein1905").unwrap();
        assert_eq!(e.entry_type, "article");
        assert_eq!(e.author, "Einstein");
        assert_eq!(e.year, "1905");
        assert_eq!(e.doi.as_deref(), Some("10.1002/andp.19053221004"));
        // biblatex's format_sentence() applies sentence case, so capitalized
        // German nouns come back lowercased. Pinned because it is surprising.
        assert_eq!(e.title, "Zur elektrodynamik bewegter körper");
    }

    #[test]
    fn preserves_brace_protected_casing() {
        let entries = parse_files(&[fixture("basic.bib")]).unwrap();
        let e = entries.iter().find(|e| e.key == "knuth1984").unwrap();
        assert_eq!(e.title, "The TeXbook");
    }

    #[test]
    fn joins_multiple_authors() {
        let entries = parse_files(&[fixture("basic.bib")]).unwrap();
        let e = entries.iter().find(|e| e.key == "multi2020").unwrap();
        assert_eq!(e.author, "Doe, Roe");
    }

    #[test]
    fn missing_optional_fields_are_none() {
        let entries = parse_files(&[fixture("basic.bib")]).unwrap();
        let e = entries.iter().find(|e| e.key == "multi2020").unwrap();
        assert!(e.file.is_none());
        assert!(e.url.is_none());
        assert!(e.doi.is_none());
    }

    #[test]
    fn concatenates_multiple_files() {
        let entries = parse_files(&[fixture("basic.bib"), fixture("second.bib")]).unwrap();
        assert_eq!(entries.len(), 4);
        assert!(entries.iter().any(|e| e.key == "lamport1994"));
        assert!(entries.iter().any(|e| e.key == "einstein1905"));
    }

    #[test]
    fn reports_missing_file() {
        let err = parse_files(&[fixture("does-not-exist.bib")]).unwrap_err();
        assert!(err.to_string().contains("reading"));
    }

    #[test]
    fn locates_entry_line_numbers() {
        let loc = locate_entry(&[fixture("basic.bib")], "knuth1984").unwrap();
        assert_eq!(loc.line, 8);
        assert!(loc.file.ends_with("basic.bib"));

        let first = locate_entry(&[fixture("basic.bib")], "einstein1905").unwrap();
        assert_eq!(first.line, 1);
    }

    #[test]
    fn locate_searches_across_files() {
        let loc = locate_entry(&[fixture("basic.bib"), fixture("second.bib")], "lamport1994").unwrap();
        assert!(loc.file.ends_with("second.bib"));
        assert_eq!(loc.line, 1);
    }

    #[test]
    fn locate_reports_unknown_key() {
        let err = locate_entry(&[fixture("basic.bib")], "nope").unwrap_err();
        assert!(err.to_string().contains("not found"));
    }
}
