//! The four tools the loop speaks to, exactly as the bash did — `bd`, `gh`, `git`,
//! `curl` — so the stubs in test/bin remain the contract.
use crate::config::Repo;
use crate::util::{cmd, log, output, stderr_str, stdout_str};
use serde_json::Value;
use std::path::Path;
use std::process::Output;

/// Every bd call the loop makes acts as the label, not as the git user, so the assignee
/// and the audit trail say the model did it; a BEADS_ACTOR in the environment still wins.
pub fn bd(repo: &Repo, args: &[&str]) -> std::io::Result<Output> {
    let actor = std::env::var("BEADS_ACTOR").unwrap_or_else(|_| repo.label.clone());
    output(cmd("bd").args(args).current_dir(&repo.repo).env("BEADS_ACTOR", actor))
}

/// bd's stdout, or "" on a non-zero exit (the bash `2>/dev/null || true` shape).
pub fn bd_out(repo: &Repo, args: &[&str]) -> String {
    match bd(repo, args) {
        Ok(o) if o.status.success() => stdout_str(&o),
        _ => String::new(),
    }
}

/// A bd call whose failure is a loud stop, like the bash under `set -e`.
pub fn bd_must(repo: &Repo, args: &[&str]) -> String {
    match bd(repo, args) {
        Ok(o) if o.status.success() => stdout_str(&o),
        Ok(o) => {
            let err = stderr_str(&o);
            crate::util::die(&format!("bd {} failed: {}", args.join(" "), err.trim()))
        }
        Err(e) => crate::util::die(&format!("bd: {e}")),
    }
}

/// `bd ready -l LABEL --json -n 0`: the ids, bd's order.
pub fn bd_ready(repo: &Repo) -> Vec<String> {
    let out = bd_out(repo, &["ready", "-l", &repo.label, "--json", "-n", "0"]);
    ids_of(&out)
}

/// `bd ready ... --json` as the array itself (status carries the beads).
pub fn bd_ready_json(repo: &Repo) -> Value {
    parse_array(&bd_out(repo, &["ready", "-l", &repo.label, "--json", "-n", "0"]))
}

/// `bd list --status open --json -n 0`: every open bead, any label — the decision beads
/// and the ones labelled needs-human live here.
pub fn bd_open_json(repo: &Repo) -> Value {
    parse_array(&bd_out(repo, &["list", "--status", "open", "--json", "-n", "0"]))
}

/// `bd list --status in_progress -l LABEL --json -n 0`
pub fn bd_in_progress_json(repo: &Repo) -> Value {
    parse_array(&bd_out(repo, &["list", "--status", "in_progress", "-l", &repo.label, "--json", "-n", "0"]))
}

/// `bd show ID --json`: the one-element array, or die when bd returned nothing.
pub fn bd_show(repo: &Repo, id: &str) -> Value {
    let out = bd_must(repo, &["show", id, "--json"]);
    let v = parse_array(&out);
    if v.as_array().map(|a| a.is_empty()).unwrap_or(true) {
        crate::util::die(&format!("{}: bd show {id} returned nothing", repo.slug));
    }
    v
}

fn parse_array(s: &str) -> Value {
    match serde_json::from_str::<Value>(s) {
        Ok(v @ Value::Array(_)) => v,
        Ok(Value::Null) | Err(_) => Value::Array(Vec::new()),
        Ok(v) => Value::Array(vec![v]),
    }
}

fn ids_of(s: &str) -> Vec<String> {
    parse_array(s)
        .as_array()
        .map(|a| a.iter().filter_map(|b| b.get("id").and_then(|i| i.as_str()).map(str::to_string)).collect())
        .unwrap_or_default()
}

/// `bd update ID --append-notes TEXT` (the note on the bead); failure is logged, not fatal.
pub fn bd_note(repo: &Repo, id: &str, text: &str) {
    if let Ok(o) = bd(repo, &["update", id, "--append-notes", text]) {
        if !o.status.success() {
            log(&format!("{}: {id}: bd could not take the note: {}", repo.slug, stderr_str(&o).trim()));
        }
    }
}

pub fn bd_status(repo: &Repo, id: &str, status: &str) {
    let _ = bd_must(repo, &["update", id, "--status", status]);
}

pub fn bd_comment(repo: &Repo, id: &str, text: &str) {
    let _ = bd(repo, &["comment", id, text]);
}

/// `bd close ID --reason R`; false when bd refused (an adopted bead may already be closed).
pub fn bd_close(repo: &Repo, id: &str, reason: &str) -> bool {
    matches!(bd(repo, &["close", id, "--reason", reason]), Ok(o) if o.status.success())
}

/// `claim ID`: the bead is ours now. A bead in the dev queue is open, so an assignee left
/// on it is stale, and bd's --claim refusing it is not a reason to fail the round.
pub fn bd_claim(repo: &Repo, id: &str) {
    if let Ok(o) = bd(repo, &["update", id, "--claim"]) {
        if o.status.success() {
            return;
        }
    }
    let actor = std::env::var("BEADS_ACTOR").unwrap_or_else(|_| repo.label.clone());
    let _ = bd_must(repo, &["update", id, "--status", "in_progress", "--assignee", &actor]);
}

// ---- gh ---------------------------------------------------------------------------
pub fn gh(repo: &Repo, args: &[&str]) -> std::io::Result<Output> {
    output(cmd("gh").args(args).current_dir(&repo.repo))
}

pub fn gh_ok(repo: &Repo, args: &[&str]) -> bool {
    matches!(gh(repo, args), Ok(o) if o.status.success())
}

pub fn gh_out(repo: &Repo, args: &[&str]) -> Option<String> {
    match gh(repo, args) {
        Ok(o) if o.status.success() => Some(stdout_str(&o)),
        _ => None,
    }
}

/// gh's stdout whatever its exit code (the bash's `$(gh ... 2>/dev/null || true)`): a
/// `--jq` that matched nothing still exits non-zero on some versions.
pub fn gh_stdout_any(repo: &Repo, args: &[&str]) -> String {
    gh(repo, args).map(|o| stdout_str(&o)).unwrap_or_default()
}

// ---- git --------------------------------------------------------------------------
/// The lanes share one repository (its worktrees share .git), and git refuses a second
/// writer while one holds a lock file: two lanes adding worktrees, fetching, or deleting
/// branches at once would fail one of them ("Unable to create ...lock: File exists") —
/// seen on a slow CI runner. The mutating subcommands take this lock; reads, diffs,
/// commits and pushes inside a worktree do not need it.
static GIT_MUTATION: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub fn git(dir: &Path, args: &[&str]) -> std::io::Result<Output> {
    let serialized = matches!(args.first().copied(), Some("worktree" | "branch" | "fetch" | "checkout"));
    let _guard = if serialized { Some(GIT_MUTATION.lock().unwrap_or_else(|e| e.into_inner())) } else { None };
    output(cmd("git").arg("-C").arg(dir).args(args))
}

pub fn git_ok(dir: &Path, args: &[&str]) -> bool {
    matches!(git(dir, args), Ok(o) if o.status.success())
}

pub fn git_out(dir: &Path, args: &[&str]) -> String {
    match git(dir, args) {
        Ok(o) if o.status.success() => stdout_str(&o),
        _ => String::new(),
    }
}

/// A git call whose failure is a loud stop.
pub fn git_must(dir: &Path, args: &[&str]) -> String {
    match git(dir, args) {
        Ok(o) if o.status.success() => stdout_str(&o),
        Ok(o) => crate::util::die(&format!("git {} in {}: {}", args.join(" "), dir.display(), stderr_str(&o).trim())),
        Err(e) => crate::util::die(&format!("git: {e}")),
    }
}

/// `git show-ref -q refs/heads/B || git show-ref -q refs/remotes/origin/B`
pub fn branch_exists(repo: &Repo, branch: &str) -> bool {
    git_ok(&repo.repo, &["show-ref", "-q", &format!("refs/heads/{branch}")])
        || git_ok(&repo.repo, &["show-ref", "-q", &format!("refs/remotes/origin/{branch}")])
}

pub fn local_branch_exists(repo: &Repo, branch: &str) -> bool {
    git_ok(&repo.repo, &["show-ref", "-q", &format!("refs/heads/{branch}")])
}

/// `git worktree remove --force WT || rm -rf WT`
pub fn worktree_remove(repo: &Repo, wt: &Path) {
    if wt.exists() {
        let removed = git_ok(&repo.repo, &["worktree", "remove", "--force", &wt.to_string_lossy()]);
        if !removed {
            let _ = std::fs::remove_dir_all(wt);
        }
    } else {
        // a registered worktree whose directory went: prune the record
        let _ = git(&repo.repo, &["worktree", "prune"]);
    }
}

// ---- curl (the attached opencode server) -------------------------------------------
/// `curl -sfG -m N URL --data-urlencode directory=DIR`; None on failure.
pub fn curl_get(url: &str, dir: Option<&str>, secs: u32) -> Option<String> {
    let mut c = cmd("curl");
    c.args(["-sfG", "-m", &secs.to_string(), url]);
    if let Some(d) = dir {
        c.args(["--data-urlencode", &format!("directory={d}")]);
    }
    match output(&mut c) {
        Ok(o) if o.status.success() => Some(stdout_str(&o)),
        _ => None,
    }
}

pub fn curl_post(url: &str, secs: u32) -> bool {
    matches!(output(cmd("curl").args(["-sf", "-m", &secs.to_string(), "-X", "POST", url])), Ok(o) if o.status.success())
}
