//! The merge queue: `inflight/ID` is the PR url; GitHub's CI is the queue's worker.
//! `reconcile` looks at every PR in flight and moves each bead on — closed on MERGED,
//! back to dev on red or a conflict, parked when closed unmerged — or holds it with the
//! reason when nothing the loop can do will move it: branch protection, a pipeline that
//! does not merge, CI that never reports, gh that cannot answer. A hold is a flag, not a
//! state: the PR is still asked about on every pass, and the flag clears when it moves.
use crate::config::Repo;
use crate::round::send_back;
use crate::shell::{bd_close, bd_note, bd_ready, bd_status, gh, gh_ok, gh_out, git};
use crate::util::{date_iminutes, log, mtime, now, read_to_string, stderr_str, stdout_str, touch};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

/// The resident watcher asks GitHub every 30 s; "CI pending" once a pass would flood the
/// journal, so under `quiet` a line is logged only when it differs from the last one for
/// that bead. A tick (one pass) logs every line, as the bash did.
static QUIET: AtomicBool = AtomicBool::new(false);
static LAST: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

pub fn set_quiet(on: bool) {
    QUIET.store(on, Ordering::SeqCst);
}

pub fn say(key: &str, msg: String) {
    if QUIET.load(Ordering::SeqCst) {
        let mut g = LAST.lock().unwrap();
        let map = g.get_or_insert_with(HashMap::new);
        if map.get(key).map(|m| m == &msg).unwrap_or(false) {
            return;
        }
        map.insert(key.to_string(), msg.clone());
    }
    log(&msg);
}

/// How long a green PR may wait on `merge = "pipeline"` before the bead is held.
pub const PIPELINE_TIMEOUT: i64 = 30 * 60;
/// How long CI may stay pending before the bead is held (still polled).
pub const CI_TIMEOUT: i64 = 2 * 3600;

const RED: &[&str] = &["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"];
const GREEN: &[&str] = &["SUCCESS", "NEUTRAL", "SKIPPED"];

fn check_state(c: &Value) -> String {
    for k in ["conclusion", "state", "status"] {
        if let Some(s) = c.get(k).and_then(|v| v.as_str()) {
            return s.to_string();
        }
    }
    String::new()
}

/// `red | nocheck | green | pending` from `statusCheckRollup`.
pub fn verdict(view: &Value) -> &'static str {
    let checks: Vec<String> =
        view.get("statusCheckRollup").and_then(|v| v.as_array()).map(|a| a.iter().map(check_state).collect()).unwrap_or_default();
    if checks.iter().any(|c| RED.contains(&c.as_str())) {
        "red"
    } else if checks.is_empty() {
        "nocheck"
    } else if checks.iter().all(|c| GREEN.contains(&c.as_str())) {
        "green"
    } else {
        "pending"
    }
}

fn failing_checks(view: &Value) -> String {
    view.get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter(|c| RED.contains(&check_state(c).as_str()))
                .map(|c| c.get("context").or_else(|| c.get("name")).and_then(|v| v.as_str()).unwrap_or("").to_string())
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default()
}

/// `ci=SUCCESS build=FAILURE`, what the close reason quotes; "none reported" without checks.
pub fn checks_at_merge(view: &Value) -> String {
    let checks: Vec<String> = view
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .map(|c| {
                    format!(
                        "{}={}",
                        c.get("context").or_else(|| c.get("name")).and_then(|v| v.as_str()).unwrap_or("null"),
                        c.get("conclusion").or_else(|| c.get("state")).and_then(|v| v.as_str()).unwrap_or("null")
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    if checks.is_empty() {
        "none reported".to_string()
    } else {
        checks.join(" ")
    }
}

/// `close_merged ID INFLIGHT URL VIEW`: the bead is done; say what CI said at the merge.
/// If bd will not close it — an adopted bead may already be closed, that is fine; a bd
/// error is not — the inflight file stays and the bead is held, rather than dropped.
pub fn close_merged(repo: &Repo, id: &str, url: &str, view: &Value) {
    let checks = checks_at_merge(view);
    let closed = bd_close(repo, id, &format!("bead-loop: {url} merged; checks at merge: {checks}"));
    if !closed && !repo.mark(id, "adopted").exists() {
        // Was it closed already (by hand)? Then fine. Otherwise keep the PR in the queue.
        let shown = crate::shell::bd_out(repo, &["show", id, "--json"]);
        let status = serde_json::from_str::<Value>(&shown)
            .ok()
            .and_then(|v| v.get(0).and_then(|b| b.get("status")).and_then(|s| s.as_str()).map(str::to_string))
            .unwrap_or_default();
        if status != "closed" {
            crate::round::hold(repo, id, None, &format!("{url} merged but bd would not close the bead"));
            return;
        }
    }
    let _ = std::fs::remove_file(repo.inflight_path(id));
    for m in ["red", "nocheck", "adopted", "held"] {
        let _ = std::fs::remove_file(repo.mark(id, m));
    }
    repo.release(id);
    let _ = git(&repo.repo, &["branch", "-D", &format!("bead/{id}")]);
    log(&format!("{}: {id} closed ({url} merged; {checks})", repo.slug));
    repo.wake();
}

/// `hand_to_pipeline ID NUM URL`: merge = "pipeline". The loop labels the PR and the CI
/// pipeline merges it on its own terms; the loop only closes the bead once it is MERGED.
/// A label the repo does not have cannot be added: noted, held, the PR waits for you.
pub fn hand_to_pipeline(repo: &Repo, id: &str, num: &str, url: &str) {
    if gh_ok(repo, &["pr", "edit", num, "--add-label", &repo.merge_label]) {
        log(&format!("{}: {id}: labelled {} on {url}; the pipeline merges it", repo.slug, repo.merge_label));
    } else {
        bd_note(
            repo,
            id,
            &format!(
                "bead-loop: could not label {url} with {} (does the repo have that label?); the pipeline will not merge it, so it waits for you",
                repo.merge_label
            ),
        );
        log(&format!("{}: {id}: could not label {url} with {}; waiting for you", repo.slug, repo.merge_label));
        held_in_merge(repo, id, &format!("could not label {url} with {}; merge it yourself", repo.merge_label));
    }
}

/// A hold on a bead in the merge queue: the flag, one note; the PR stays polled.
fn held_in_merge(repo: &Repo, id: &str, why: &str) {
    if repo.hold(id, why) {
        log(&format!("{}: {id}: held: {why}", repo.slug));
        bd_note(repo, id, &format!("bead-loop {}: waiting on you: {why}", date_iminutes()));
        repo.wake();
    }
}

/// `adopt`: any open PR on a `bead/<id>[-slug]` branch this loop did not open (another
/// session, a human) joins the merge queue, so green merges and the bead closes whoever
/// wrote it. `adopt = false` turns it off.
pub fn adopt(repo: &Repo) {
    if !repo.adopt {
        return;
    }
    let out = gh_out(
        repo,
        &[
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "100",
            "--json",
            "number,headRefName,url",
            "--jq",
            ".[] | select(.headRefName | startswith(\"bead/\")) | [.number, .headRefName, .url] | @tsv",
        ],
    )
    .unwrap_or_default();
    for line in out.lines() {
        let mut parts = line.split('\t');
        let (num, head, url) = match (parts.next(), parts.next(), parts.next()) {
            (Some(n), Some(h), Some(u)) if !n.is_empty() => (n, h, u),
            _ => continue,
        };
        let id = match bead_id_of_branch(head) {
            Some(i) => i,
            None => continue,
        };
        if repo.inflight_path(&id).exists() {
            continue;
        }
        // A branch of ours sent back to dev is not adopted: dev is fixing it.
        if repo.mark(&id, "fixing").exists() {
            continue;
        }
        crate::util::write_file(&repo.inflight_path(&id), &format!("{url}\n"));
        touch(&repo.mark(&id, "adopted"));
        log(&format!("{}: adopted {url} ({head}) as bead {id}", repo.slug));
        if repo.merge == "pipeline" {
            hand_to_pipeline(repo, &id, num, url);
        }
    }
}

/// A bead worked by hand, or by a subagent, entirely outside the loop: its PR on
/// `bead/<id>[-slug]` merged before `adopt` ever saw it open, so nothing closed the
/// bead and the dev queue would hand it out again. `adopt` only catches a PR while it
/// is still open; this catches the ones that were never caught at all. One `gh pr
/// list` per idle bead in the dev queue — that queue is short, so nothing is cached.
/// `--head` matches a branch name exactly, which would miss an adopted-style
/// `bead/<id>-slug`; `--search head:...` is a substring match on GitHub's side, so a
/// hit is still checked against `bead_id_of_branch` before it counts.
fn close_merged_outside_loop(repo: &Repo) {
    for id in bd_ready(repo) {
        if repo.inflight_path(&id).exists() || repo.review_path(&id).exists() || repo.wt(&id).is_dir() {
            continue;
        }
        let out = gh_out(
            repo,
            &[
                "pr",
                "list",
                "--state",
                "merged",
                "--search",
                &format!("head:bead/{id}"),
                "--json",
                "url,headRefName",
                "--jq",
                ".[] | [.headRefName, .url] | @tsv",
            ],
        )
        .unwrap_or_default();
        let url = out.lines().find_map(|line| {
            let mut parts = line.split('\t');
            let head = parts.next()?;
            let url = parts.next()?;
            (bead_id_of_branch(head).as_deref() == Some(id.as_str())).then(|| url.to_string())
        });
        if let Some(url) = url {
            let reason = format!("bead-loop: {url} merged outside the loop");
            if bd_close(repo, &id, &reason) {
                log(&format!("{}: {id}: closed ({url} merged outside the loop)", repo.slug));
                repo.wake();
            }
        }
    }
}

/// `bead/<prefix>-<id>[.n][-slug]` → the bead id.
pub fn bead_id_of_branch(head: &str) -> Option<String> {
    let rest = head.strip_prefix("bead/")?;
    let b = rest.as_bytes();
    let mut i = 0;
    while i < b.len() && b[i].is_ascii_lowercase() {
        i += 1;
    }
    if i == 0 || i >= b.len() || b[i] != b'-' {
        return None;
    }
    let mut j = i + 1;
    while j < b.len() && (b[j].is_ascii_lowercase() || b[j].is_ascii_digit()) {
        j += 1;
    }
    if j == i + 1 {
        return None;
    }
    let mut end = j;
    if j < b.len() && b[j] == b'.' {
        let mut k = j + 1;
        while k < b.len() && b[k].is_ascii_digit() {
            k += 1;
        }
        if k > j + 1 {
            end = k;
        }
    }
    if end < b.len() && b[end] != b'-' {
        return None;
    }
    Some(rest[..end].to_string())
}

/// `reconcile`: one pass over the merge queue.
pub fn reconcile(repo: &Repo) {
    adopt(repo);
    close_merged_outside_loop(repo);
    for id in repo.inflight_ids() {
        let f = repo.inflight_path(&id);
        let url = read_to_string(&f).unwrap_or_default().trim().to_string();
        let num = url.rsplit('/').next().unwrap_or("").to_string();
        crate::config::need("gh");
        let view = match gh(repo, &["pr", "view", &num, "--json", "state,mergedAt,mergeable,mergeStateStatus,statusCheckRollup,url"]) {
            Ok(o) if o.status.success() => match serde_json::from_str::<Value>(&stdout_str(&o)) {
                Ok(v) => v,
                Err(_) => {
                    log(&format!("{}: cannot read PR {num}", repo.slug));
                    continue;
                }
            },
            Ok(o) => {
                log(&format!("{}: cannot read PR {num}", repo.slug));
                held_in_merge(repo, &id, &format!("gh cannot read {url}: {}", stderr_str(&o).trim().lines().last().unwrap_or("")));
                continue;
            }
            Err(_) => {
                log(&format!("{}: cannot read PR {num}", repo.slug));
                continue;
            }
        };
        let state = view.get("state").and_then(|s| s.as_str()).unwrap_or("");
        match state {
            "MERGED" => close_merged(repo, &id, &url, &view),
            "CLOSED" => {
                let _ = std::fs::remove_file(&f);
                for m in ["red", "nocheck", "adopted", "held"] {
                    let _ = std::fs::remove_file(repo.mark(&id, m));
                }
                repo.release(&id);
                log(&format!("{}: {id}: PR closed unmerged, parked for you", repo.slug));
                // The question goes on the bead with the url (the brief, when there is one).
                crate::park::park(repo, &id, crate::park::Reason::PrClosed(url.clone()), None);
                repo.wake();
            }
            "OPEN" => reconcile_open(repo, &id, &f, &url, &num, &view),
            _ => {}
        }
    }
}

fn reconcile_open(repo: &Repo, id: &str, f: &std::path::Path, url: &str, num: &str, view: &Value) {
    let adopted = repo.mark(id, "adopted").exists();
    // A PR of ours that conflicts with the base is not CI's problem, and not the model's
    // fault: no failure. It goes back to the dev queue on its own branch with a rebase
    // work order, and that round's worker is conflict_worker — the last stage's by
    // default, the strong model — since a rebase is judgement, not typing.
    if view.get("mergeable").and_then(|m| m.as_str()) == Some("CONFLICTING") && !adopted {
        let _ = std::fs::remove_file(f);
        for m in ["nocheck", "red", "held"] {
            let _ = std::fs::remove_file(repo.mark(id, m));
        }
        touch(&repo.mark(id, "fixing"));
        touch(&repo.mark(id, "conflict"));
        repo.release(id);
        let who = if repo.conflict_worker.is_empty() { "the last stage".to_string() } else { repo.conflict_worker.clone() };
        bd_note(repo, id, &format!("bead-loop {}: {url} conflicts with {}; back to dev for a rebase by {who}", date_iminutes(), repo.base));
        bd_status(repo, id, "open");
        log(&format!("{}: {id}: {url} conflicts with {} → dev queue for a rebase ({who})", repo.slug, repo.base));
        repo.wake();
        return;
    }
    let ms = view.get("mergeStateStatus").and_then(|m| m.as_str()).unwrap_or("").to_string();
    match verdict(view) {
        "green" => {
            if repo.merge == "auto" {
                if ms == "BEHIND" {
                    if gh_ok(repo, &["pr", "update-branch", num]) {
                        log(&format!("{}: {id}: updated branch, CI reruns", repo.slug));
                    } else {
                        log(&format!("{}: {id}: update-branch failed", repo.slug));
                    }
                } else if gh_ok(repo, &["pr", "merge", num, "--squash", "--delete-branch"]) {
                    close_merged(repo, id, url, view);
                } else {
                    log(&format!("{}: {id}: green but merge refused ({ms})", repo.slug));
                    // Nothing the loop does changes a BLOCKED/UNSTABLE state: a review or
                    // a check that branch protection wants. Yours.
                    held_in_merge(
                        repo,
                        id,
                        &format!(
                            "{url} is green but GitHub refuses the merge ({ms}): branch protection wants something the loop cannot give"
                        ),
                    );
                }
            } else if repo.merge == "pipeline" {
                say(id, format!("{}: {id}: green, merge is pipeline, waiting for the pipeline: {url}", repo.slug));
                // Green for this long and still open: the pipeline is not merging it.
                let since = green_since(repo, id);
                if now() - since >= PIPELINE_TIMEOUT {
                    held_in_merge(
                        repo,
                        id,
                        &format!("{url} has been green for {} min and the pipeline has not merged it", (now() - since) / 60),
                    );
                }
            } else {
                say(id, format!("{}: {id}: green, merge is manual, waiting for you: {url}", repo.slug));
                held_in_merge(repo, id, &format!("{url} is green; merge is manual, so it is yours to merge"));
            }
        }
        "red" => {
            let checks = failing_checks(view);
            if adopted {
                // Not our branch to fix: one note, the PR waits for whoever opened it.
                if !repo.mark(id, "red").exists() {
                    bd_note(repo, id, &format!("bead-loop: CI red on {url} ({checks}); PR left open"));
                    touch(&repo.mark(id, "red"));
                    log(&format!("{}: {id}: CI red on adopted {url}", repo.slug));
                }
                held_in_merge(repo, id, &format!("CI red on adopted {url} ({checks}); not the loop's branch to fix"));
            } else {
                // Ours: back to the dev queue on the same branch; the next push updates this PR.
                let _ = std::fs::remove_file(f);
                let _ = std::fs::remove_file(repo.mark(id, "nocheck"));
                let _ = std::fs::remove_file(repo.mark(id, "held"));
                touch(&repo.mark(id, "fixing"));
                let model = repo.stage_for(repo.failures_of(id)).map(|s| s.model).unwrap_or_else(|| repo.model.clone());
                log(&format!("{}: {id}: CI red on {url} ({checks})", repo.slug));
                send_back(repo, id, &repo.wt(id), true, &format!("CI red on {url}: {checks}"), &model, false, None);
            }
        }
        "nocheck" => {
            if !repo.mark(id, "nocheck").exists() {
                bd_note(
                    repo,
                    id,
                    &format!(
                        "bead-loop: {url} reports no CI checks, so nothing proves it green; merge it yourself or set merge = \"manual\""
                    ),
                );
                touch(&repo.mark(id, "nocheck"));
                log(&format!("{}: {id}: no checks on {url}", repo.slug));
            }
            held_in_merge(repo, id, &format!("{url} reports no CI checks; merge it yourself or set merge = \"manual\""));
        }
        _ => {
            say(id, format!("{}: {id}: CI pending on {url}", repo.slug));
            let since = mtime(f);
            if since > 0 && now() - since >= CI_TIMEOUT {
                held_in_merge(repo, id, &format!("CI on {url} has been pending for {} h; is the agent up?", (now() - since) / 3600));
            }
        }
    }
}

/// When the PR was first seen green under `pipeline`: a marker beside the inflight file.
fn green_since(repo: &Repo, id: &str) -> i64 {
    let m = repo.mark(id, "green");
    if !m.exists() {
        touch(&m);
    }
    mtime(&m)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn branch_ids() {
        assert_eq!(bead_id_of_branch("bead/t-9-some-slug").as_deref(), Some("t-9"));
        assert_eq!(bead_id_of_branch("bead/inq-85h.15").as_deref(), Some("inq-85h.15"));
        assert_eq!(bead_id_of_branch("bead/inq-85h.15-fix").as_deref(), Some("inq-85h.15"));
        assert_eq!(bead_id_of_branch("bead/x-1").as_deref(), Some("x-1"));
        assert!(bead_id_of_branch("feature/not-a-bead").is_none());
        assert!(bead_id_of_branch("bead/Upper-1").is_none());
    }
    #[test]
    fn verdicts() {
        let v = |c: Value| verdict(&serde_json::json!({"statusCheckRollup": c}));
        assert_eq!(v(serde_json::json!([])), "nocheck");
        assert_eq!(verdict(&serde_json::json!({})), "nocheck", "no rollup at all");
        assert_eq!(v(serde_json::json!([{"context":"ci","state":"SUCCESS"},{"__typename":"CheckRun","conclusion":"SUCCESS"}])), "green");
        assert_eq!(
            v(serde_json::json!([{"context":"a","state":"SUCCESS"},{"context":"b","state":"PENDING"}])),
            "pending",
            "one pending check holds the merge"
        );
        assert_eq!(v(serde_json::json!([{"context":"ci","state":"FAILURE"}])), "red");
        assert_eq!(
            v(serde_json::json!([{"name":"build","conclusion":"SUCCESS"},{"name":"lint","conclusion":"CANCELLED"}])),
            "red",
            "red beats green"
        );
        assert_eq!(
            v(serde_json::json!([{"name":"x","conclusion":"SKIPPED"},{"name":"y","conclusion":"NEUTRAL"}])),
            "green",
            "skipped and neutral are green"
        );
        assert_eq!(v(serde_json::json!([{"name":"x","status":"IN_PROGRESS"}])), "pending", "a check run still running");
    }
    #[test]
    fn what_the_notes_quote() {
        let view = serde_json::json!({"statusCheckRollup": [{"context":"ci","state":"FAILURE"},{"name":"build","conclusion":"SUCCESS"},{"name":"lint","conclusion":"TIMED_OUT"}]});
        assert_eq!(failing_checks(&view), "ci, lint", "the failing checks by name");
        assert_eq!(checks_at_merge(&view), "ci=FAILURE build=SUCCESS lint=TIMED_OUT");
        assert_eq!(checks_at_merge(&serde_json::json!({"statusCheckRollup": []})), "none reported");
        assert_eq!(failing_checks(&serde_json::json!({})), "");
    }
    #[test]
    fn say_repeats_itself_only_when_loud() {
        set_quiet(false);
        say("k", "a".into());
        set_quiet(true);
        say("k2", "b".into());
        say("k2", "b".into()); // silent: the same line for that key
        say("k2", "c".into());
        let g = LAST.lock().unwrap();
        assert_eq!(g.as_ref().unwrap().get("k2").map(String::as_str), Some("c"));
        assert!(g.as_ref().unwrap().get("k").is_none(), "loud lines are not remembered");
        drop(g);
        set_quiet(false);
    }
    #[test]
    fn green_since_is_a_marker_made_once() {
        let d = crate::config::scratch("green-since");
        let repo = crate::config::test_repo(&d, &["a"]);
        let first = green_since(&repo, "t-1");
        assert!(first > 0 && repo.mark("t-1", "green").exists());
        assert_eq!(green_since(&repo, "t-1"), first, "the second look keeps the first time");
        let _ = std::fs::remove_dir_all(&d);
    }
}
