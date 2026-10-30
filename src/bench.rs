//! `bead-supervisor bench freeze REPO ID...`: a landed bead frozen once into
//! `bench/cases/ID/case.json`, in the repo's checkout, for the operator to commit
//! (docs/design-bench.md "A case", decisions 33, 35; docs/design-measurement.md
//! decision 27). Landed beads only: a parked bead has no merge, and so no set.
use crate::config::Repo;
use crate::shell::{bd_show, git_out};
use crate::util::{log, write_file};
use serde_json::{json, Value};
use std::collections::HashMap;

/// `"tests"` when the diff adds a line matching `^\+\s*#\[test\]` under `src/`, or
/// `^\+case_\w+\(\)` in `test/run.sh`; else `"gate-only"` (decision 27).
pub fn classify(diff: &str) -> &'static str {
    let mut file = String::new();
    for line in diff.lines() {
        if let Some(path) = line.strip_prefix("+++ b/") {
            file = path.to_string();
            continue;
        }
        if line.starts_with("+++") || line.starts_with("---") {
            continue;
        }
        let Some(added) = line.strip_prefix('+') else { continue };
        if file.starts_with("src/") && added.trim_start().starts_with("#[test]") {
            return "tests";
        }
        if file == "test/run.sh" && is_case_fn(added) {
            return "tests";
        }
    }
    "gate-only"
}

/// `case_\w+()`, right after the diff's own `+` (no leading space): `^\+case_\w+\(\)`.
fn is_case_fn(s: &str) -> bool {
    case_fn_name(s).is_some()
}

/// The `NAME` of `case_NAME()` at the start of `s` (no leading space), else `None`.
fn case_fn_name(s: &str) -> Option<&str> {
    let rest = s.strip_prefix("case_")?;
    let name_len = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_').count();
    (name_len > 0 && rest[name_len..].starts_with("()")).then(|| &rest[..name_len])
}

/// `(path, name)` for each `#[test]\nfn NAME(` the diff added under `src/`: the line
/// right after an added `#[test]` attribute, parsed for `fn NAME(`.
fn added_rust_tests(diff: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut file = String::new();
    let mut expect_fn = false;
    for line in diff.lines() {
        if let Some(path) = line.strip_prefix("+++ b/") {
            file = path.to_string();
            expect_fn = false;
            continue;
        }
        if line.starts_with("+++") || line.starts_with("---") {
            expect_fn = false;
            continue;
        }
        let Some(added) = line.strip_prefix('+') else {
            expect_fn = false;
            continue;
        };
        if expect_fn {
            expect_fn = false;
            if file.starts_with("src/") {
                if let Some(name) = fn_name_from_added_line(added) {
                    out.push((file.clone(), name));
                    continue;
                }
            }
        }
        if file.starts_with("src/") && added.trim_start().starts_with("#[test]") {
            expect_fn = true;
        }
    }
    out
}

/// `NAME` from an added line shaped `+    fn NAME(...`, else `None`.
fn fn_name_from_added_line(added: &str) -> Option<String> {
    let rest = added.trim_start().strip_prefix("fn ")?;
    let end = rest.find('(')?;
    Some(rest[..end].trim().to_string())
}

/// `NAME` for each `case_NAME` the diff added to `test/run.sh`.
fn added_case_names(diff: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut file = String::new();
    for line in diff.lines() {
        if let Some(path) = line.strip_prefix("+++ b/") {
            file = path.to_string();
            continue;
        }
        if line.starts_with("+++") || line.starts_with("---") {
            continue;
        }
        let Some(added) = line.strip_prefix('+') else { continue };
        if file == "test/run.sh" {
            if let Some(name) = case_fn_name(added) {
                out.push(name.to_string());
            }
        }
    }
    out
}

/// The byte index immediately after `source[open_idx]` (`open_ch`) that matches it with
/// `close_ch`, depth-counted, skipping `"..."` and `'...'` literals (backslash-escaped,
/// except single-quoted `shell` strings, which have no escape) and comments (`//` and
/// `/* */` unless `shell`, `#` to end of line when `shell`) so a brace or paren inside
/// one of those does not unbalance the count.
fn match_delim(source: &str, open_idx: usize, open_ch: u8, close_ch: u8, shell: bool) -> usize {
    let bytes = source.as_bytes();
    let mut depth = 0i32;
    let mut i = open_idx;
    while i < bytes.len() {
        let b = bytes[i];
        if b == open_ch {
            depth += 1;
            i += 1;
            continue;
        }
        if b == close_ch {
            depth -= 1;
            i += 1;
            if depth == 0 {
                return i - 1;
            }
            continue;
        }
        match b {
            b'"' => {
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == b'\\' {
                        i += 2;
                        continue;
                    }
                    if bytes[i] == b'"' {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            }
            b'\'' => {
                i += 1;
                while i < bytes.len() {
                    if !shell && bytes[i] == b'\\' {
                        i += 2;
                        continue;
                    }
                    if bytes[i] == b'\'' {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            }
            b'/' if !shell && i + 1 < bytes.len() && bytes[i + 1] == b'/' => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if !shell && i + 1 < bytes.len() && bytes[i + 1] == b'*' => {
                i += 2;
                while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                    i += 1;
                }
                i += 2;
            }
            b'#' if shell => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            _ => i += 1,
        }
    }
    bytes.len().saturating_sub(1)
}

fn is_ident_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// The first index of `needle` in `source` not preceded by an identifier byte (so `fn
/// name(` does not match inside `fn other_name(`).
fn find_word(source: &str, needle: &str) -> Option<usize> {
    let bytes = source.as_bytes();
    let mut i = 0;
    while let Some(off) = source.get(i..).and_then(|s| s.find(needle)) {
        let start = i + off;
        if start == 0 || !is_ident_byte(bytes[start - 1]) {
            return Some(start);
        }
        i = start + 1;
    }
    None
}

/// `#[test]\nfn NAME...} \n` cut whole out of `source` (`git show merge_sha:PATH`), with
/// a leading `// from PATH` line (decision 26, 31). `None` when `NAME` is not found.
fn cut_rust_test(source: &str, path: &str, name: &str) -> Option<String> {
    let needle = format!("fn {name}(");
    let fn_start = find_word(source, &needle)?;
    let line_start = source[..fn_start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let attr_start = {
        let before = line_start.checked_sub(1).map(|i| &source[..i]).unwrap_or("");
        let prev_start = before.rfind('\n').map(|i| i + 1).unwrap_or(0);
        if before[prev_start..].trim() == "#[test]" {
            prev_start
        } else {
            line_start
        }
    };
    let paren_open = fn_start + needle.len() - 1;
    let paren_close = match_delim(source, paren_open, b'(', b')', false);
    let open = source[paren_close..].find('{')? + paren_close;
    let close = match_delim(source, open, b'{', b'}', false);
    let end = source[close..].find('\n').map(|i| close + i + 1).unwrap_or(source.len());
    Some(format!("// from {path}\n{}", &source[attr_start..end]))
}

/// `case_NAME() {...}` cut whole out of `source` (`git show merge_sha:test/run.sh`).
/// `None` when `NAME` is not found.
fn cut_case_fn(source: &str, name: &str) -> Option<String> {
    let needle = format!("case_{name}()");
    let start = find_word(source, &needle)?;
    let line_start = source[..start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let open = source[start..].find('{')? + start;
    let close = match_delim(source, open, b'{', b'}', true);
    let end = source[close..].find('\n').map(|i| close + i + 1).unwrap_or(source.len());
    Some(source[line_start..end].to_string())
}

/// A case's `case.json`: the merge and its first parent, the repo's slug, the bead's
/// title/description/acceptance and claim as `text` says where they came from, and the
/// `set` (decision 27) `classify` put it in.
#[allow(clippy::too_many_arguments)]
pub fn case_json(
    id: &str,
    repo_slug: &str,
    merge_sha: &str,
    base_sha: &str,
    title: &str,
    description: &str,
    acceptance: &str,
    text: &str,
    claim: Option<Value>,
    set: &str,
) -> Value {
    json!({
        "id": id,
        "repo": repo_slug,
        "merge_sha": merge_sha,
        "base_sha": base_sha,
        "title": title,
        "description": description,
        "acceptance": acceptance,
        "text": text,
        "claim": claim,
        "set": set,
    })
}

/// The first line of `git log --format=%H%x09%s base_ref` whose subject starts with
/// `ID:` (a squash merge reads `ID: what (#N)`); `None` when there is no such commit.
fn merge_sha_of(repo: &Repo, id: &str, base_ref: &str) -> Option<String> {
    let prefix = format!("{id}:");
    git_out(&repo.repo, &["log", "--format=%H%x09%s", base_ref]).lines().find_map(|l| {
        let (sha, subject) = l.split_once('\t')?;
        subject.starts_with(&prefix).then(|| sha.to_string())
    })
}

/// The claim line (`stamp::read`) when there is one — `text: "first_round"` — else the
/// bead's current text from `bd show --json`, `text: "current"`, claim `null`.
fn text_of(repo: &Repo, id: &str) -> (String, String, String, &'static str, Option<Value>) {
    let claim = crate::stamp::read(repo, id).into_iter().find_map(|l| l.get("claim").cloned());
    if let Some(claim) = claim {
        let s = |k: &str| claim.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        (s("title"), s("description"), s("acceptance"), "first_round", Some(claim))
    } else {
        let bead = bd_show(repo, id);
        let b = bead.get(0).cloned().unwrap_or(Value::Null);
        let s = |k: &str| b.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        (s("title"), s("description"), s("acceptance_criteria"), "current", None)
    }
}

/// `bench freeze`: one `case.json` per id, written under the repo's checkout; an id with
/// no merge commit on `base_remote/base` is skipped, named on the log.
pub fn freeze(repo: &Repo, ids: &[String]) {
    let base_ref = format!("{}/{}", repo.base_remote, repo.base);
    for id in ids {
        let Some(merge_sha) = merge_sha_of(repo, id, &base_ref) else {
            log(&format!("{}: {id}: no merge commit on {base_ref} starting \"{id}:\"; skipped", repo.slug));
            continue;
        };
        let base_sha = git_out(&repo.repo, &["rev-parse", &format!("{merge_sha}^1")]).trim().to_string();
        let diff = git_out(&repo.repo, &["diff", &base_sha, &merge_sha]);
        let set = classify(&diff);
        let (title, description, acceptance, text, claim) = text_of(repo, id);

        let case = case_json(id, &repo.slug, &merge_sha, &base_sha, &title, &description, &acceptance, text, claim, set);
        write_file(
            &repo.repo.join("bench/cases").join(id).join("case.json"),
            &format!("{}\n", serde_json::to_string_pretty(&case).unwrap()),
        );
        if set == "tests" {
            freeze_hidden(repo, id, &merge_sha, &diff);
        }
        log(&format!("{}: {id}: froze {merge_sha} ({set})", repo.slug));
    }
}

/// `NAME.rs`, or `NAME.2.rs` for the second file (`occurrence` 1) `NAME` is found in, and
/// so on: "a NAME in two files gets `.2` before `.rs`" (decision 26).
fn rust_hidden_name(name: &str, occurrence: usize) -> String {
    if occurrence == 0 {
        format!("{name}.rs")
    } else {
        format!("{name}.{}.rs", occurrence + 1)
    }
}

/// `hidden/` for a `"tests"` case (docs/design-bench.md "The hidden check: transplant
/// by name", decisions 26, 31): each added `#[test] fn NAME` as `hidden/rust/NAME.rs`
/// (`.2` before `.rs` when `NAME` repeats across files), each added `case_NAME` as
/// `hidden/cases/NAME.sh`, and `hidden/files.json` naming both.
fn freeze_hidden(repo: &Repo, id: &str, merge_sha: &str, diff: &str) {
    let dir = repo.repo.join("bench/cases").join(id).join("hidden");
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut rust = Vec::new();
    for (path, name) in added_rust_tests(diff) {
        let source = git_out(&repo.repo, &["show", &format!("{merge_sha}:{path}")]);
        let Some(body) = cut_rust_test(&source, &path, &name) else { continue };
        let n = seen.entry(name.clone()).or_insert(0);
        let file_name = rust_hidden_name(&name, *n);
        *n += 1;
        write_file(&dir.join("rust").join(&file_name), &body);
        rust.push(json!({"name": name, "path": path}));
    }
    let run_sh = git_out(&repo.repo, &["show", &format!("{merge_sha}:test/run.sh")]);
    let mut cases = Vec::new();
    for name in added_case_names(diff) {
        let Some(body) = cut_case_fn(&run_sh, &name) else { continue };
        write_file(&dir.join("cases").join(format!("{name}.sh")), &body);
        cases.push(name);
    }
    let files = json!({"rust": rust, "cases": cases});
    write_file(&dir.join("files.json"), &format!("{}\n", serde_json::to_string_pretty(&files).unwrap()));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_finds_a_rust_test_under_src() {
        let diff = "diff --git a/src/bench.rs b/src/bench.rs\n--- a/src/bench.rs\n+++ b/src/bench.rs\n@@ -1,0 +2,2 @@\n+    #[test]\n+    fn it_works() {}\n";
        assert_eq!(classify(diff), "tests");
    }

    #[test]
    fn classify_finds_a_case_fn_in_test_run_sh() {
        let diff = "diff --git a/test/run.sh b/test/run.sh\n--- a/test/run.sh\n+++ b/test/run.sh\n@@ -1,0 +2,1 @@\n+case_new_thing() {\n";
        assert_eq!(classify(diff), "tests");
    }

    #[test]
    fn classify_is_gate_only_without_either() {
        let diff = "diff --git a/src/round.rs b/src/round.rs\n--- a/src/round.rs\n+++ b/src/round.rs\n@@ -1,0 +2,1 @@\n+    let x = 1;\n";
        assert_eq!(classify(diff), "gate-only");
    }

    #[test]
    fn classify_ignores_a_test_attribute_outside_src() {
        let diff = "diff --git a/docs/design.md b/docs/design.md\n--- a/docs/design.md\n+++ b/docs/design.md\n@@ -1,0 +2,1 @@\n+#[test]\n";
        assert_eq!(classify(diff), "gate-only");
    }

    #[test]
    fn classify_ignores_a_case_fn_outside_test_run_sh() {
        let diff =
            "diff --git a/test/other.sh b/test/other.sh\n--- a/test/other.sh\n+++ b/test/other.sh\n@@ -1,0 +2,1 @@\n+case_new_thing() {\n";
        assert_eq!(classify(diff), "gate-only");
    }

    #[test]
    fn added_rust_tests_finds_the_name_and_path() {
        let diff = "diff --git a/src/bench.rs b/src/bench.rs\n--- a/src/bench.rs\n+++ b/src/bench.rs\n@@ -1,0 +2,2 @@\n+    #[test]\n+    fn it_works() {}\n";
        assert_eq!(added_rust_tests(diff), vec![("src/bench.rs".to_string(), "it_works".to_string())]);
    }

    #[test]
    fn added_case_names_finds_the_name() {
        let diff = "diff --git a/test/run.sh b/test/run.sh\n--- a/test/run.sh\n+++ b/test/run.sh\n@@ -1,0 +2,1 @@\n+case_new_thing() {\n";
        assert_eq!(added_case_names(diff), vec!["new_thing".to_string()]);
    }

    #[test]
    fn cut_rust_test_keeps_the_attribute_and_stops_at_its_own_brace() {
        let source = "fn other() {}\n\n#[test]\nfn it_works() {\n    assert_eq!(1, 1);\n}\n\nfn after() {}\n";
        let cut = cut_rust_test(source, "src/bench.rs", "it_works").unwrap();
        assert_eq!(cut, "// from src/bench.rs\n#[test]\nfn it_works() {\n    assert_eq!(1, 1);\n}\n");
    }

    #[test]
    fn cut_rust_test_matches_nested_blocks_and_braces_in_strings_and_comments() {
        let source = concat!(
            "#[test]\n",
            "fn it_works() {\n",
            "    // a brace in a comment: {\n",
            "    let s = \"a brace in a string: {\";\n",
            "    /* a block comment with one too: { */\n",
            "    for _ in 0..1 {\n",
            "        if true {\n",
            "            let _ = s;\n",
            "        }\n",
            "    }\n",
            "}\n",
            "fn after() {}\n",
        );
        let cut = cut_rust_test(source, "src/bench.rs", "it_works").unwrap();
        assert!(cut.ends_with("}\n"), "cut off at its own closing brace: {cut:?}");
        assert!(!cut.contains("after"), "did not run on into the next function: {cut:?}");
    }

    #[test]
    fn cut_rust_test_is_none_when_not_found() {
        let source = "fn other() {}\n";
        assert_eq!(cut_rust_test(source, "src/bench.rs", "missing"), None);
    }

    #[test]
    fn cut_case_fn_matches_nested_blocks_and_braces_in_strings_and_comments() {
        let source = concat!(
            "case_before() { :; }\n",
            "case_new_thing() {\n",
            "  # a brace in a comment: {\n",
            "  local x; x=$(jq -n '{\"a\": 1}')\n",
            "  if true; then\n",
            "    for i in 1 2; do :; done\n",
            "  fi\n",
            "}\n",
            "case_after() { :; }\n",
        );
        let cut = cut_case_fn(source, "new_thing").unwrap();
        assert!(cut.starts_with("case_new_thing() {\n"), "starts at its own declaration: {cut:?}");
        assert!(cut.ends_with("}\n"), "cut off at its own closing brace: {cut:?}");
        assert!(!cut.contains("after"), "did not run on into the next function: {cut:?}");
    }

    #[test]
    fn rust_hidden_name_suffixes_the_second_occurrence() {
        assert_eq!(rust_hidden_name("it_works", 0), "it_works.rs");
        assert_eq!(rust_hidden_name("it_works", 1), "it_works.2.rs");
    }
}
