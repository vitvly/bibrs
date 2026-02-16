//! End-to-end tests against the built binary.
//!
//! The `open` tests use a harmless stand-in for the real viewer: a template
//! whose argv[0] is `cp`, `touch` or `sh`. That lets a test observe exactly
//! what got executed — and, for the injection cases, prove that nothing did.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_bibrs")
}

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn run(args: &[&str]) -> Output {
    Command::new(bin()).args(args).output().expect("running bibrs")
}

fn run_in(dir: &Path, args: &[&str]) -> Output {
    Command::new(bin()).args(args).current_dir(dir).output().expect("running bibrs")
}

fn stdout(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).to_string()
}

/// A scratch directory unique to the calling test, cleaned and recreated.
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("bibrs-test-{name}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

// ---- list ----------------------------------------------------------------

#[test]
fn list_uses_the_format_template() {
    let bib = fixtures().join("basic.bib");
    let out = run(&["list", bib.to_str().unwrap(), "--format", "{key}|{year}|{type}"]);
    assert!(out.status.success());
    let s = stdout(&out);
    assert!(s.contains("einstein1905|1905|article"), "got: {s}");
    assert!(s.contains("knuth1984|1984|book"), "got: {s}");
    assert_eq!(s.lines().count(), 3);
}

#[test]
fn list_strips_control_characters() {
    let bib = fixtures().join("hostile.bib");
    let out = run(&["list", bib.to_str().unwrap(), "--format", "{key}\t{title}"]);
    let s = stdout(&out);
    assert!(!s.contains('\x1b'), "ANSI escape survived into list output");
    assert!(!s.contains('\x07'), "BEL survived into list output");
    // One line per entry — a smuggled newline would have split one in two.
    assert_eq!(s.lines().count(), 3, "got: {s:?}");
}

// ---- json / locate --------------------------------------------------------

#[test]
fn json_round_trips() {
    let bib = fixtures().join("basic.bib");
    let out = run(&["json", bib.to_str().unwrap()]);
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_str(&stdout(&out)).expect("valid json");
    assert_eq!(v.as_array().unwrap().len(), 3);
    assert_eq!(v[0]["key"], "einstein1905");
}

#[test]
fn locate_reports_file_and_line() {
    let bib = fixtures().join("basic.bib");
    let out = run(&["locate", bib.to_str().unwrap(), "--key", "knuth1984"]);
    assert!(out.status.success());
    let v: serde_json::Value = serde_json::from_str(&stdout(&out)).unwrap();
    assert_eq!(v["line"], 8);
}

#[test]
fn locate_fails_on_unknown_key() {
    let bib = fixtures().join("basic.bib");
    let out = run(&["locate", bib.to_str().unwrap(), "--key", "nope"]);
    assert!(!out.status.success());
}

// ---- open: files, dirs, pages --------------------------------------------

#[test]
fn open_passes_file_and_page_to_the_viewer() {
    let dir = scratch("open-file");
    std::fs::write(dir.join("paper.pdf"), "x").unwrap();
    std::fs::write(dir.join("r.bib"), "@article{a, title={A}, file={./paper.pdf}}").unwrap();

    // `sh -c 'echo "$1" > out' --` receives the rendered args as real argv.
    let out = run_in(&dir, &[
        "open", "r.bib", "--key", "a", "--page", "7",
        "--viewer", "sh -c 'printf %s \"$1\" > seen.txt' -- {file}#page={page}",
    ]);
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    let seen = std::fs::read_to_string(dir.join("seen.txt")).unwrap();
    assert!(seen.ends_with("paper.pdf#page=7"), "got: {seen}");
}

#[test]
fn open_routes_a_directory_to_the_dir_opener() {
    let dir = scratch("open-dir");
    std::fs::create_dir(dir.join("scans")).unwrap();
    std::fs::write(dir.join("r.bib"), "@misc{d, title={D}, file={./scans}}").unwrap();

    let out = run_in(&dir, &[
        "open", "r.bib", "--key", "d",
        "--viewer", "sh -c 'touch WRONG_VIEWER'",
        "--dir-opener", "sh -c 'printf %s \"$1\" > seen.txt' -- {dir}",
    ]);
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    assert!(!dir.join("WRONG_VIEWER").exists(), "directory went to the PDF viewer");
    let seen = std::fs::read_to_string(dir.join("seen.txt")).unwrap();
    assert!(seen.ends_with("scans"), "got: {seen}");
}

#[test]
fn open_fails_when_entry_has_neither_file_nor_url() {
    let bib = fixtures().join("basic.bib");
    let out = run(&["open", bib.to_str().unwrap(), "--key", "multi2020"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("No file or url"));
}

#[test]
fn open_fails_on_missing_file_path() {
    let dir = scratch("open-missing");
    std::fs::write(dir.join("r.bib"), "@article{a, title={A}, file={./nope.pdf}}").unwrap();
    let out = run_in(&dir, &["open", "r.bib", "--key", "a", "--viewer", "true {file}"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("resolving file path"));
}

// ---- open: url schemes ----------------------------------------------------

#[test]
fn open_refuses_disallowed_url_scheme() {
    let bib = fixtures().join("hostile.bib");
    let out = run(&["open", bib.to_str().unwrap(), "--key", "badscheme2024",
                    "--url-opener", "true {url}"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("disallowed scheme"));
}

#[test]
fn open_allows_listed_url_scheme() {
    let dir = scratch("open-url");
    let bib = fixtures().join("hostile.bib");
    let out = run_in(&dir, &["open", bib.to_str().unwrap(), "--key", "okscheme2024",
                             "--url-opener", "sh -c 'printf %s \"$1\" > seen.txt' -- {url}"]);
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(std::fs::read_to_string(dir.join("seen.txt")).unwrap(),
               "https://example.com/paper");
}

#[test]
fn open_honors_a_narrowed_scheme_list() {
    let bib = fixtures().join("hostile.bib");
    let out = run(&["open", bib.to_str().unwrap(), "--key", "okscheme2024",
                    "--url-schemes", "mailto", "--url-opener", "true {url}"]);
    assert!(!out.status.success());
}

// ---- open: injection regression ------------------------------------------

/// The original vulnerability: `viewer` templates that quote the placeholder
/// (as the documented Skim one does) inverted the quoting of the substituted
/// value, letting a crafted filename run commands. A `.bib` file is untrusted
/// input, so the file it names is attacker-chosen.
#[test]
fn crafted_filename_cannot_execute_commands() {
    let dir = scratch("injection");
    let evil_name = "paper$(touch PWNED_SUBST)`touch PWNED_TICK`;touch PWNED_SEMI.pdf";
    std::fs::write(dir.join(evil_name), "x").unwrap();
    std::fs::write(
        dir.join("r.bib"),
        format!("@article{{a, title={{A}}, file={{./{evil_name}}}}}"),
    ).unwrap();

    // The exact template from the README that made this exploitable.
    let out = run_in(&dir, &[
        "open", "r.bib", "--key", "a", "--page", "3",
        "--viewer", "sh -c 'printf %s \"$1\" > seen.txt' -- 'skim://{file}#page={page}'",
    ]);
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));

    for marker in ["PWNED_SUBST", "PWNED_TICK", "PWNED_SEMI"] {
        assert!(!dir.join(marker).exists(), "{marker} was created — injection succeeded");
    }

    // The value must have arrived as one argument, verbatim.
    let seen = std::fs::read_to_string(dir.join("seen.txt")).unwrap();
    assert!(seen.starts_with("skim://"), "got: {seen}");
    assert!(seen.contains("$(touch PWNED_SUBST)"), "value was mangled: {seen}");
    assert!(seen.ends_with("#page=3"), "got: {seen}");
}

#[test]
fn crafted_directory_name_cannot_execute_commands() {
    let dir = scratch("injection-dir");
    let evil_name = "scans$(touch PWNED_DIR)";
    std::fs::create_dir(dir.join(evil_name)).unwrap();
    std::fs::write(dir.join("r.bib"),
                   format!("@misc{{d, title={{D}}, file={{./{evil_name}}}}}")).unwrap();

    let out = run_in(&dir, &["open", "r.bib", "--key", "d",
                             "--dir-opener", "sh -c 'printf %s \"$1\" > seen.txt' -- 'x://{dir}'"]);
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    assert!(!dir.join("PWNED_DIR").exists(), "injection succeeded");
    assert!(std::fs::read_to_string(dir.join("seen.txt")).unwrap().contains("$(touch PWNED_DIR)"));
}

#[test]
fn open_dir_passes_a_path_with_spaces_as_one_argument() {
    let dir = scratch("open-dir-spaces");
    let target = dir.join("scans dir");
    std::fs::create_dir(&target).unwrap();
    let out = run_in(&dir, &["open-dir", target.to_str().unwrap(),
                             "--dir-opener", "sh -c 'printf %s \"$1\" > seen.txt' -- {dir}"]);
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(std::fs::read_to_string(dir.join("seen.txt")).unwrap(), target.to_str().unwrap());
}

#[test]
fn open_dir_with_crafted_name_cannot_execute_commands() {
    let dir = scratch("open-dir-injection");
    let evil_name = "scans$(touch PWNED_DIR)";
    std::fs::create_dir(dir.join(evil_name)).unwrap();
    let out = run_in(&dir, &["open-dir", evil_name,
                             "--dir-opener", "sh -c 'printf %s \"$1\" > seen.txt' -- {dir}"]);
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    assert!(!dir.join("PWNED_DIR").exists(), "injection succeeded");
    assert_eq!(std::fs::read_to_string(dir.join("seen.txt")).unwrap(), evil_name);
}

#[test]
fn open_dir_rejects_a_malformed_template() {
    let dir = scratch("open-dir-bad-template");
    let out = run_in(&dir, &["open-dir", ".", "--dir-opener", "sh -c 'unterminated {dir}"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("missing closing quote"));
}

#[test]
fn malformed_template_is_rejected_not_executed() {
    let dir = scratch("bad-template");
    std::fs::write(dir.join("paper.pdf"), "x").unwrap();
    std::fs::write(dir.join("r.bib"), "@article{a, title={A}, file={./paper.pdf}}").unwrap();
    let out = run_in(&dir, &["open", "r.bib", "--key", "a", "--viewer", "open 'unterminated {file}"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("missing closing quote"));
}
