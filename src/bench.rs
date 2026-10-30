//! `bead-supervisor bench freeze REPO ID...`: a landed bead frozen once into
//! `bench/cases/ID/case.json`, in the repo's checkout, for the operator to commit
//! (docs/design-bench.md "A case", decisions 33, 35; docs/design-measurement.md
//! decision 27). Landed beads only: a parked bead has no merge, and so no set.
use crate::config::Repo;
use crate::shell::{bd_show, git_out};
use crate::util::{log, write_file};
use serde_json::{json, Value};

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
    let Some(rest) = s.strip_prefix("case_") else { return false };
    let name_len = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_').count();
    name_len > 0 && rest[name_len..].starts_with("()")
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
        log(&format!("{}: {id}: froze {merge_sha} ({set})", repo.slug));
    }
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
}
