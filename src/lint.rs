//! `lint`: whether a bead's claims hold before a round ever starts — a path the
//! DESCRIPTION names that is not on the base branch, an ACCEPTANCE CRITERIA with no
//! command in it, or (`--run`) an acceptance that is already green on the base, before
//! the bead's own change (docs/design-measurement.md hypothesis 1, decisions 8, 17, 18,
//! 21). Deterministic, run by hand or from the planner, never inside a round; it never
//! changes labels or routing, only notes the verdict `stamp::linted_of` reads.
use crate::config::Repo;
use crate::shell::{bd_note, bd_ready, bd_show, git_ok, worktree_remove};
use crate::stamp::{acceptance_commands, acceptance_kind};
use crate::util::{cmd, date_iminutes, log, output};
use serde_json::Value;

/// Seconds an acceptance command may run under `--run` before it is killed: long enough
/// for a gate, short enough that a hung check does not wedge the lint pass.
const RUN_TIMEOUT_SECS: u64 = 600;

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
/// `"; "`, on the bead. `--run` adds [`run_problems`] after the static ones; without it
/// lint never executes anything.
pub fn lint(repo: &Repo, ids: &[String], run: bool) {
    let ids: Vec<String> = if ids.is_empty() { bd_ready(repo) } else { ids.to_vec() };
    for id in &ids {
        let bead_json = bd_show(repo, id);
        let mut problems = problems(repo, &bead_json);
        if run {
            let b = bead_json.get(0).cloned().unwrap_or(Value::Null);
            let acceptance = b.get("acceptance_criteria").and_then(|v| v.as_str()).unwrap_or("");
            problems.extend(run_problems(repo, id, acceptance));
        }
        let verdict = if problems.is_empty() { "pass".to_string() } else { problems.join("; ") };
        println!("{id}: {verdict}");
        bd_note(repo, id, &format!("bead-loop lint {}: {verdict}", date_iminutes()));
    }
}

/// `--run`'s own check: a throwaway worktree of the base, under the repo's state dir;
/// `repo.setup` there when it is set; each of the acceptance's commands
/// (`stamp::acceptance_commands`) under `bash -c`, a `RUN_TIMEOUT_SECS` timeout each; the
/// worktree gone again before this returns. Empty when a command exits non-zero there —
/// that is what a bead's check is for. The problem `acceptance is green on base: a
/// bead's check must fail before its change` when every command the acceptance names
/// (or there were none) passed on base.
fn run_problems(repo: &Repo, id: &str, acceptance: &str) -> Vec<String> {
    let commands = acceptance_commands(acceptance);
    if commands.is_empty() {
        return Vec::new();
    }
    let wt = repo.rs.join("wt").join(format!("lint-{id}"));
    worktree_remove(repo, &wt);
    if !git_ok(&repo.repo, &["worktree", "add", "-q", "--detach", &wt.to_string_lossy(), &repo.base_ref()]) {
        log(&format!("{}: {id}: lint --run: could not add a worktree of {}", repo.slug, repo.base_ref()));
        return Vec::new();
    }
    if !repo.setup.is_empty() {
        let _ = output(cmd("bash").args(["-c", &repo.setup]).current_dir(&wt));
    }
    let timeout_s = RUN_TIMEOUT_SECS.to_string();
    let any_red = commands.iter().any(|c| {
        !output(cmd("timeout").args(["--foreground", &timeout_s, "bash", "-c", c]).current_dir(&wt))
            .map(|o| o.status.success())
            .unwrap_or(false)
    });
    worktree_remove(repo, &wt);
    if any_red {
        Vec::new()
    } else {
        vec!["acceptance is green on base: a bead's check must fail before its change".to_string()]
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
