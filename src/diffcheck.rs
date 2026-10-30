//! A deterministic check over a bead's DESCRIPTION and its diff, before any model reads
//! either (design-measurement.md hypothesis 9): a bead that names a test file the diff
//! never touches, or a diff that adds a placeholder assertion to one.

/// True if `path` names a test file: a `test`, `tests` or `spec` token in a directory or
/// file name, split on `/`, `.`, `_` and `-` (`tests/x.py`, `test_x.py`, `x_test.go`,
/// `x.test.ts`, `x.spec.ts`, `test/run.sh`); `latest.py` has no such token.
fn is_test_path(path: &str) -> bool {
    path.split(|c: char| "/._-".contains(c)).any(|part| matches!(part, "test" | "tests" | "spec"))
}

/// A placeholder assertion: an added line that asserts nothing. Leading/trailing
/// whitespace ignored.
fn is_placeholder_assertion(line: &str) -> bool {
    matches!(line.trim(), "assert True" | "assert 1" | "assert!(true);" | "expect(true).toBe(true)" | "self.assertTrue(True)")
}

/// The diff's `diff --git a/PATH b/PATH` headers, as the `PATH` after `b/`.
fn diff_headers(diff: &str) -> Vec<&str> {
    diff.lines().filter_map(|l| l.strip_prefix("diff --git a/")).filter_map(|rest| rest.split(" b/").nth(1)).collect()
}

/// A bead's DESCRIPTION naming a test file the diff never touches, and a diff adding a
/// placeholder assertion to one — both found before any model reads the diff
/// (design-measurement.md hypothesis 9: 33 of the last 97 reviewer REJECTs named tests,
/// missing or placeholder).
#[allow(dead_code)]
pub fn problems(description: &str, diff: &str) -> Vec<String> {
    let mut problems = Vec::new();

    let headers = diff_headers(diff);
    for path in crate::harness::path_tokens(description) {
        if is_test_path(&path) && !headers.contains(&path.as_str()) {
            problems.push(format!("bead names a test file the diff never touches: {path}"));
        }
    }

    let mut current_file: Option<&str> = None;
    let mut new_line = 0u32;
    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("diff --git a/") {
            current_file = rest.split(" b/").nth(1);
            continue;
        }
        if let Some(rest) = line.strip_prefix("@@ ") {
            if let Some(plus) = rest.split_whitespace().find(|t| t.starts_with('+')) {
                let plus = plus.trim_start_matches('+');
                let start = plus.split(',').next().unwrap_or("0");
                new_line = start.parse().unwrap_or(0);
            }
            continue;
        }
        if line.starts_with("+++") {
            continue;
        }
        if let Some(added) = line.strip_prefix('+') {
            let Some(file) = current_file else { continue };
            if is_test_path(file) && is_placeholder_assertion(added) {
                problems.push(format!("placeholder test: {file}: {new_line}"));
            }
            new_line += 1;
        } else if !line.starts_with('-') {
            new_line += 1;
        }
    }

    problems
}

#[cfg(test)]
mod tests {
    use super::*;

    fn diff_touching(path: &str, added_line: &str) -> String {
        format!(
            "diff --git a/{path} b/{path}\nindex 0000000..1111111 100644\n--- a/{path}\n+++ b/{path}\n@@ -1,1 +1,2 @@\n line one\n+{added_line}\n"
        )
    }

    #[test]
    fn a_diff_touching_the_named_test_file_has_no_problem_one() {
        let diff = diff_touching("test/run.sh", "echo real work");
        assert_eq!(problems("Files: test/run.sh", &diff), Vec::<String>::new());
    }

    #[test]
    fn a_diff_touching_only_src_has_problem_one() {
        let diff = diff_touching("src/main.rs", "let x = 1;");
        assert_eq!(
            problems("Files: test/run.sh, src/main.rs", &diff),
            vec!["bead names a test file the diff never touches: test/run.sh".to_string()]
        );
    }

    #[test]
    fn each_placeholder_form_is_caught() {
        for (line, lang) in [
            ("assert True", "x_test.py"),
            ("assert 1", "x_test.py"),
            ("assert!(true);", "x_test.rs"),
            ("expect(true).toBe(true)", "x.test.ts"),
            ("self.assertTrue(True)", "x_test.py"),
        ] {
            let diff = diff_touching(lang, line);
            assert_eq!(problems("", &diff), vec![format!("placeholder test: {lang}: 2")], "line {line:?} in {lang}");
        }
    }

    #[test]
    fn the_same_text_in_a_non_test_file_is_not_a_problem() {
        let diff = diff_touching("src/main.rs", "assert True");
        assert_eq!(problems("", &diff), Vec::<String>::new());
    }

    #[test]
    fn a_clean_diff_returns_an_empty_vec() {
        let diff = diff_touching("src/main.rs", "let x = 1;");
        assert_eq!(problems("Files: src/main.rs", &diff), Vec::<String>::new());
    }
}
