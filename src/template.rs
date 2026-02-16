use anyhow::{Context, Result};

/// Split a command template into argv the way a shell would — honoring single
/// quotes, double quotes and backslash escapes — but *without* invoking a shell.
///
/// Templates are tokenized before placeholders are substituted, so a value can
/// never be re-parsed as shell syntax. Quoting the value instead (and handing
/// the result to `sh -c`) is not safe: a template that already quotes the
/// placeholder, like `open 'skim://{file}#page={page}'`, inverts the quote
/// parity and leaves the value unquoted.
fn split_template(s: &str) -> Result<Vec<String>> {
    let args = shell_words::split(s).with_context(|| format!("bad command template: {s}"))?;
    if args.is_empty() {
        anyhow::bail!("empty command template");
    }
    Ok(args)
}

/// Replace placeholders in a single pass. Substituted values are not rescanned,
/// so a path containing `{page}` or a title containing `{year}` survives intact.
pub fn substitute(template: &str, subs: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        if let Some((key, value)) = subs.iter().find(|(key, _)| rest.starts_with(key)) {
            out.push_str(value);
            rest = &rest[key.len()..];
        } else {
            out.push('{');
            rest = &rest[1..];
        }
    }
    out.push_str(rest);
    out
}

/// Tokenize a template, then substitute placeholders into the individual argv
/// entries. Tokens that substitution leaves empty (e.g. a bare `{page}` when no
/// page was given) are dropped rather than passed as an empty argument.
pub fn render_template(template: &str, subs: &[(&str, &str)]) -> Result<Vec<String>> {
    let argv = split_template(template)?;
    let mut out: Vec<String> = Vec::with_capacity(argv.len());
    for token in argv {
        let t = substitute(&token, subs);
        if !t.is_empty() {
            out.push(t);
        }
    }
    if out.is_empty() {
        anyhow::bail!("command template resolved to nothing: {template}");
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- split_template ----------------------------------------------------

    #[test]
    fn splits_on_whitespace() {
        assert_eq!(split_template("open -a Preview {file}").unwrap(),
                   vec!["open", "-a", "Preview", "{file}"]);
    }

    #[test]
    fn collapses_repeated_whitespace() {
        assert_eq!(split_template("  open   {file}  ").unwrap(), vec!["open", "{file}"]);
    }

    #[test]
    fn honors_single_quotes() {
        assert_eq!(split_template("open 'skim://{file}#page={page}'").unwrap(),
                   vec!["open", "skim://{file}#page={page}"]);
    }

    #[test]
    fn honors_double_quotes_and_escapes() {
        assert_eq!(split_template(r#"cmd "a b" "c\"d" e\ f"#).unwrap(),
                   vec!["cmd", "a b", "c\"d", "e f"]);
    }

    #[test]
    fn backslash_is_literal_outside_quotes_when_trailing() {
        assert_eq!(split_template(r"cmd x\").unwrap(), vec!["cmd", r"x\"]);
    }

    #[test]
    fn keeps_unknown_escapes_inside_double_quotes() {
        assert_eq!(split_template(r#"cmd "a\b""#).unwrap(), vec!["cmd", r"a\b"]);
    }

    // A word-initial `#` starts a comment, as in a shell; one inside a word is
    // literal, which is what the Skim URL relies on even when left unquoted.
    #[test]
    fn treats_only_a_word_initial_hash_as_a_comment() {
        assert_eq!(split_template("cmd x#y #z w").unwrap(), vec!["cmd", "x#y"]);
    }

    #[test]
    fn rejects_unterminated_quotes() {
        assert!(split_template("open 'unclosed").is_err());
        assert!(split_template("open \"unclosed").is_err());
    }

    #[test]
    fn rejects_empty_template() {
        assert!(split_template("   ").is_err());
    }

    // ---- substitute --------------------------------------------------------

    #[test]
    fn substitutes_every_occurrence() {
        assert_eq!(substitute("{a}-{b}-{a}", &[("{a}", "1"), ("{b}", "2")]), "1-2-1");
    }

    #[test]
    fn does_not_rescan_substituted_values() {
        assert_eq!(substitute("{a} {b}", &[("{a}", "{b}"), ("{b}", "2")]), "{b} 2");
    }

    #[test]
    fn leaves_unknown_placeholders_and_stray_braces_alone() {
        assert_eq!(substitute("{x} { {a", &[("{a}", "1")]), "{x} { {a");
    }

    #[test]
    fn handles_multibyte_text_around_placeholders() {
        assert_eq!(substitute("é{a}ü", &[("{a}", "ö")]), "éöü");
    }

    // ---- render_template ---------------------------------------------------

    #[test]
    fn substitutes_placeholders_per_token() {
        assert_eq!(
            render_template("open -a Preview {file}", &[("{file}", "/tmp/a.pdf")]).unwrap(),
            vec!["open", "-a", "Preview", "/tmp/a.pdf"]
        );
    }

    #[test]
    fn drops_tokens_left_empty_by_substitution() {
        // No page given: the bare `{page}` token must vanish, not become "".
        let argv = render_template(
            "zathura --page={page} {file}",
            &[("{file}", "/tmp/a.pdf"), ("{page}", "")],
        ).unwrap();
        assert_eq!(argv, vec!["zathura", "--page=", "/tmp/a.pdf"]);

        let argv = render_template("viewer {page} {file}",
            &[("{file}", "/tmp/a.pdf"), ("{page}", "")]).unwrap();
        assert_eq!(argv, vec!["viewer", "/tmp/a.pdf"]);
    }

    #[test]
    fn value_with_spaces_stays_one_argument() {
        let argv = render_template("open {file}", &[("{file}", "/tmp/my papers/a.pdf")]).unwrap();
        assert_eq!(argv, vec!["open", "/tmp/my papers/a.pdf"]);
    }

    #[test]
    fn placeholder_text_in_a_path_is_not_substituted() {
        let argv = render_template("v {file} {page}",
            &[("{file}", "/tmp/{page}.pdf"), ("{page}", "3")]).unwrap();
        assert_eq!(argv, vec!["v", "/tmp/{page}.pdf", "3"]);
    }

    // ---- injection regressions --------------------------------------------
    //
    // These pin the fix for the quote-parity bug: quoting a value into a
    // template that already quotes the placeholder inverted the quoting and
    // left the value to be parsed as shell syntax.

    #[test]
    fn command_substitution_in_value_is_inert() {
        let evil = "/tmp/paper$(id > /tmp/pwned).pdf";
        let argv = render_template("open 'skim://{file}#page={page}'",
            &[("{file}", evil), ("{page}", "3")]).unwrap();
        assert_eq!(argv, vec!["open".to_string(), format!("skim://{evil}#page=3")]);
        assert_eq!(argv.len(), 2, "value must not split into extra arguments");
    }

    #[test]
    fn shell_metacharacters_in_value_are_inert() {
        for evil in [
            "/tmp/a;id;b.pdf",
            "/tmp/a`id`b.pdf",
            "/tmp/a|id|b.pdf",
            "/tmp/a&&id.pdf",
            "/tmp/a$(id).pdf",
            "/tmp/a${HOME}.pdf",
            "/tmp/a'b\"c.pdf",
            "/tmp/a\nid\nb.pdf",
        ] {
            let argv = render_template("open {file}", &[("{file}", evil)]).unwrap();
            assert_eq!(argv, vec!["open", evil], "value must survive verbatim: {evil}");
        }
    }

    #[test]
    fn quote_in_value_cannot_escape_a_quoted_template() {
        let evil = "/tmp/a'.pdf";
        let argv = render_template("open 'x://{file}'", &[("{file}", evil)]).unwrap();
        assert_eq!(argv, vec!["open", "x:///tmp/a'.pdf"]);
    }
}
