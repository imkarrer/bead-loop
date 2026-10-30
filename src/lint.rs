//! `lint`: whether a bead's claims hold before a round ever starts — a path the
//! DESCRIPTION names that is not on the base branch, or an ACCEPTANCE CRITERIA with no
//! command in it (docs/design-measurement.md hypothesis 1, decisions 8, 17, 18, 21).
//! Deterministic, run by hand or from the planner, never inside a round; it never
//! changes labels or routing, only notes the verdict `stamp::linted_of` reads.
use crate::config::Repo;
use crate::shell::{bd_note, bd_ready, bd_show, git_ok};
use crate::stamp::acceptance_kind;
use crate::util::date_iminutes;
use serde_json::Value;

/// What is wrong with a bead's claims: a DESCRIPTION path missing from the base branch,
/// or an ACCEPTANCE CRITERIA with no command in it. Empty when the claims hold.
pub fn problems(repo: &Repo, bead_json: &Value) -> Vec<String> {
    let b = bead_json.get(0).cloned().unwrap_or(Value::Null);
    let s = |k: &str| b.get(k).and_then(|v| v.as_str()).unwrap_or("");
    let description = s("description");
    let acceptance = s("acceptance_criteria");

    let base_ref = format!("{}/{}", repo.base_remote, repo.base);
    let mut problems: Vec<String> = crate::harness::path_tokens(description)
        .into_iter()
        .filter(|t| !git_ok(&repo.repo, &["cat-file", "-e", &format!("{base_ref}:{t}")]))
        .map(|t| format!("path not on base: {t}"))
        .collect();

    match acceptance_kind(acceptance) {
        "none" => problems.push("no acceptance criteria".to_string()),
        "prose" => problems.push("acceptance has no command".to_string()),
        _ => {}
    }
    problems
}

/// `lint REPO [ID...]` (none given: `shell::bd_ready`, every bead in the queue): print
/// each id's verdict and note `bead-loop lint DATE: pass` or the problems, joined by
/// `"; "`, on the bead.
pub fn lint(repo: &Repo, ids: &[String]) {
    let ids: Vec<String> = if ids.is_empty() { bd_ready(repo) } else { ids.to_vec() };
    for id in &ids {
        let bead_json = bd_show(repo, id);
        let problems = problems(repo, &bead_json);
        let verdict = if problems.is_empty() { "pass".to_string() } else { problems.join("; ") };
        println!("{id}: {verdict}");
        bd_note(repo, id, &format!("bead-loop lint {}: {verdict}", date_iminutes()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{scratch, test_repo};
    use serde_json::json;

    #[test]
    fn problems_names_a_missing_path_and_a_prose_acceptance() {
        let d = scratch("lint-problems-fail");
        let repo = test_repo(&d, &["fast:rev:2"]);
        let bead = json!([{"description": "Edit work.txt", "acceptance_criteria": "work.txt exists"}]);
        assert_eq!(problems(&repo, &bead), vec!["path not on base: work.txt", "acceptance has no command"]);
    }

    #[test]
    fn problems_is_empty_for_a_command_acceptance_with_no_paths() {
        let d = scratch("lint-problems-pass");
        let repo = test_repo(&d, &["fast:rev:2"]);
        let bead = json!([{"description": "No paths here", "acceptance_criteria": "Run `cargo test`"}]);
        assert_eq!(problems(&repo, &bead), Vec::<String>::new());
    }
}
