mod parse;
mod template;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use template::{render_template, substitute};

#[derive(Parser)]
#[command(name = "bibrs", version, about = "CLI tool for parsing BibTeX/BibLaTeX files")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List bibliography entries as lines suitable for FZF
    List {
        /// BibTeX/BibLaTeX file(s) to parse
        #[arg(required = true)]
        files: Vec<PathBuf>,

        /// Output format template. Available placeholders: {key}, {author}, {title}, {year}, {type}
        #[arg(short, long, default_value = "{key}\t{author} ({year}) {title}")]
        format: String,
    },
    /// Output entries as JSON
    Json {
        /// BibTeX/BibLaTeX file(s) to parse
        #[arg(required = true)]
        files: Vec<PathBuf>,
    },
    /// Open the PDF for a given citation key, optionally at a specific page
    Open {
        /// BibTeX/BibLaTeX file(s) to search
        #[arg(required = true)]
        files: Vec<PathBuf>,

        /// Citation key to look up
        #[arg(short, long)]
        key: String,

        /// Page number to open at
        #[arg(short, long)]
        page: Option<u32>,

        /// PDF viewer command template. Placeholders: {file}, {page}
        /// Example for Skim: "open 'skim://{file}#page={page}'"
        #[arg(long, default_value = "open -a Preview {file}")]
        viewer: String,

        /// Command template for opening a citation's `url` field when it has
        /// no local `file`. Placeholder: {url}
        #[arg(long, default_value = "open {url}")]
        url_opener: String,

        /// Command template used when a citation's `file` field points at a
        /// directory rather than a document. Placeholder: {dir}
        #[arg(long, default_value = "open {dir}")]
        dir_opener: String,

        /// Comma-separated list of URL schemes the `url` field may use
        #[arg(long, default_value = "http,https,mailto,doi,ftp,ftps,file")]
        url_schemes: String,
    },
    /// Open a directory with the file manager command
    OpenDir {
        /// Directory to open
        path: PathBuf,

        /// Command template for opening the directory. Placeholder: {dir}
        #[arg(long, default_value = "open {dir}")]
        dir_opener: String,
    },
    /// Locate the source file and line number where a citation key is defined
    Locate {
        /// BibTeX/BibLaTeX file(s) to search
        #[arg(required = true)]
        files: Vec<PathBuf>,

        /// Citation key to look up
        #[arg(short, long)]
        key: String,
    },
}

/// Run a rendered command directly (no shell) and fail if it does.
fn run_argv(argv: &[String]) -> Result<()> {
    let status = std::process::Command::new(&argv[0])
        .args(&argv[1..])
        .status()
        .with_context(|| format!("launching open command: {argv:?}"))?;

    if !status.success() {
        anyhow::bail!("open command exited with {status}: {argv:?}");
    }
    Ok(())
}

/// Strip control characters from a line destined for the terminal. The fzf
/// picker renders these verbatim, so a crafted title could otherwise smuggle
/// ANSI escapes — or a newline, splitting one entry into two — into the display.
/// Tab survives because it is the default field separator.
fn sanitize_line(line: &str) -> String {
    line.chars().filter(|c| *c == '\t' || !c.is_control()).collect()
}

/// Schemes a citation's `url` field may use. Anything else (a custom
/// app-registered scheme, say) is refused rather than handed to the opener.
fn scheme_allowed(url: &str, allowed: &str) -> bool {
    let Some((scheme, _)) = url.split_once(':') else {
        return false;
    };
    if !scheme.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-')) {
        return false;
    }
    allowed
        .split(',')
        .any(|s| s.trim().eq_ignore_ascii_case(scheme))
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::List { files, format } => {
            let entries = parse::parse_files(&files)?;
            for entry in &entries {
                let line = substitute(
                    &format,
                    &[
                        ("{key}", entry.key.as_str()),
                        ("{author}", entry.author.as_str()),
                        ("{title}", entry.title.as_str()),
                        ("{year}", entry.year.as_str()),
                        ("{type}", entry.entry_type.as_str()),
                    ],
                );
                println!("{}", sanitize_line(&line));
            }
        }
        Command::Json { files } => {
            let entries = parse::parse_files(&files)?;
            println!("{}", serde_json::to_string_pretty(&entries)?);
        }
        Command::Open {
            files,
            key,
            page,
            viewer,
            url_opener,
            dir_opener,
            url_schemes,
        } => {
            let entries = parse::parse_files(&files)?;
            let entry = entries
                .iter()
                .find(|e| e.key == key)
                .ok_or_else(|| anyhow::anyhow!("Citation key '{key}' not found"))?;

            let argv = if let Some(file_path_raw) = entry.file.as_deref() {
                let file_path = shellexpand::tilde(file_path_raw);
                let file_path = std::path::Path::new(file_path.as_ref())
                    .canonicalize()
                    .with_context(|| {
                        format!("resolving file path for '{key}': {file_path_raw}")
                    })?;
                let is_dir = file_path.is_dir();
                let file_path = file_path.to_string_lossy().to_string();

                if is_dir {
                    // A `file` field can point at a folder of scans/supplementary
                    // material rather than a single document; hand it to the file
                    // manager instead of the PDF viewer. A page makes no sense here.
                    render_template(&dir_opener, &[("{dir}", file_path.as_str())])?
                } else {
                    let page_str = page.map(|p| p.to_string()).unwrap_or_default();
                    render_template(
                        &viewer,
                        &[("{file}", file_path.as_str()), ("{page}", page_str.as_str())],
                    )?
                }
            } else if let Some(url) = entry.url.as_deref() {
                if !scheme_allowed(url, &url_schemes) {
                    anyhow::bail!(
                        "refusing to open url with disallowed scheme for '{key}': {url}"
                    );
                }
                render_template(&url_opener, &[("{url}", url)])?
            } else {
                anyhow::bail!("No file or url field for '{key}'");
            };

            run_argv(&argv)?;
        }
        Command::OpenDir { path, dir_opener } => {
            let path = path.to_string_lossy();
            run_argv(&render_template(&dir_opener, &[("{dir}", path.as_ref())])?)?;
        }
        Command::Locate { files, key } => {
            let loc = parse::locate_entry(&files, &key)?;
            println!("{}", serde_json::to_string(&loc)?);
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- scheme_allowed ----------------------------------------------------

    const DEFAULT_SCHEMES: &str = "http,https,mailto,doi,ftp,ftps,file";

    #[test]
    fn allows_listed_schemes_case_insensitively() {
        for url in ["http://a", "https://a", "HTTPS://a", "mailto:x@y", "file:///a"] {
            assert!(scheme_allowed(url, DEFAULT_SCHEMES), "should allow {url}");
        }
    }

    #[test]
    fn refuses_unlisted_and_malformed_schemes() {
        for url in [
            "x-custom-app://do/something",
            "javascript:alert(1)",
            "no-scheme-at-all",
            "",
            " http://leading-space",
        ] {
            assert!(!scheme_allowed(url, DEFAULT_SCHEMES), "should refuse {url}");
        }
    }

    #[test]
    fn respects_a_narrowed_allowlist() {
        assert!(scheme_allowed("https://a", "https"));
        assert!(!scheme_allowed("file:///etc/passwd", "http,https"));
    }

    // ---- sanitize_line -----------------------------------------------------

    #[test]
    fn strips_ansi_escapes_and_newlines_but_keeps_tabs() {
        assert_eq!(sanitize_line("key\ta\x1b[31mred\x07 b\nc"), "key\ta[31mred bc");
    }

    #[test]
    fn leaves_ordinary_text_alone() {
        assert_eq!(sanitize_line("knuth1984\tKnuth (1984) The TeXbook"),
                   "knuth1984\tKnuth (1984) The TeXbook");
    }
}
