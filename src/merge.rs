//! The merge queue: `inflight/ID` is the PR url; GitHub's CI is the queue's worker.
//! `reconcile` looks at every PR in flight and moves each bead on — closed on MERGED,
//! back to dev on red or a conflict, parked when closed unmerged — or holds it with the
//! reason when nothing the loop can do will move it: branch protection, a pipeline that
//! does not merge, CI that never reports, gh that cannot answer. A hold is a flag, not a
//! state: the PR is still asked about on every pass, and the flag clears when it moves.
use crate::config::Repo;
use crate::round::send_back;
use crate::shell::{bd_close, bd_knows, bd_note, bd_ready_json, bd_status, gh, gh_ok, gh_out, git};
use crate::util::{date_iminutes, log, mtime, now, read_to_string, stderr_str, stdout_str, touch, write_file};
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
/// A PR this new with no checks is one whose CI has not registered yet (the loop looks a
/// second after labelling it), not one with no CI: pending, not held.
pub const NOCHECK_GRACE: i64 = 300;

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

/// Buildkite's word for a build it skipped: "skip queued branch builds" drops a build
/// still queued when a newer one of the branch arrives, and posts `Build #N skipped` with
/// state error on the build-level context (#132 on 25 Sep: build 285, from the PR's opened
/// event, skipped for the labeled event's 286; its error reached GitHub a second before
/// `Build #286 scheduled`). The description is the only mark of it: commit statuses have
/// no skipped state.
fn is_skip(status: &Value) -> bool {
    let d = status.get("description").and_then(|v| v.as_str()).unwrap_or("");
    d.strip_prefix("Build #")
        .and_then(|r| r.strip_suffix(" skipped"))
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// A status's build: its link up to the first `#` (a step's link adds `#<job>`).
fn build_of(link: &str) -> &str {
    link.split('#').next().unwrap_or("")
}

/// The view with every commit status from a skipped build replaced: a skip is not a
/// result, not red and not green. Its context takes the newest status in `history` (the
/// head's commit statuses, newest first, as GitHub lists them) from a build that was not
/// skipped, or PENDING when no such build has reported it yet. Check runs, and a status
/// whose build nothing calls skipped, are left as they are.
fn drop_skips(view: &Value, history: &Value) -> Value {
    let link = |s: &Value, k: &str| s.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let hist: Vec<&Value> = history.as_array().map(|a| a.iter().collect()).unwrap_or_default();
    let skipped: std::collections::HashSet<String> =
        hist.iter().filter(|s| is_skip(s)).map(|s| build_of(&link(s, "target_url")).to_string()).filter(|b| !b.is_empty()).collect();
    let from_skipped = |l: &str| skipped.contains(build_of(l));
    let mut view = view.clone();
    if let Some(rollup) = view.get_mut("statusCheckRollup").and_then(|v| v.as_array_mut()) {
        for c in rollup.iter_mut() {
            let ctx = match c.get("context").and_then(|v| v.as_str()) {
                Some(x) => x.to_string(),
                None => continue,
            };
            if !from_skipped(&link(c, "targetUrl")) {
                continue;
            }
            let ran = hist.iter().find(|s| link(s, "context") == ctx && !is_skip(s) && !from_skipped(&link(s, "target_url")));
            match ran {
                Some(s) => {
                    c["state"] = Value::from(link(s, "state").to_uppercase());
                    c["targetUrl"] = Value::from(link(s, "target_url"));
                }
                None => c["state"] = Value::from("PENDING"),
            }
        }
    }
    view
}

/// `https://github.com/OWNER/REPO/pull/N` → the REST path of that PR head's commit
/// statuses. The last 100: about seven Buildkite builds of one head.
fn statuses_path(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://github.com/")?;
    match rest.split('/').collect::<Vec<_>>().as_slice() {
        [owner, name, "pull", n] if !owner.is_empty() && !name.is_empty() && !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => {
            Some(format!("repos/{owner}/{name}/commits/refs/pull/{n}/head/statuses?per_page=100"))
        }
        _ => None,
    }
}

/// `skip_free`: the view every arm of reconcile reads, skipped builds dropped. The rollup
/// has no description, so the head's statuses are asked for, and only when a commit
/// status in the rollup is red (a skip is posted as error). A url that is not a GitHub
/// PR, or gh failing, leaves the view as it was: charged as before.
fn skip_free(repo: &Repo, url: &str, view: Value) -> Value {
    let red_status = view
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .is_some_and(|a| a.iter().any(|c| c.get("context").is_some() && RED.contains(&check_state(c).as_str())));
    let history = match statuses_path(url).filter(|_| red_status) {
        Some(path) => gh_out(repo, &["api", &path]).and_then(|s| serde_json::from_str::<Value>(&s).ok()),
        None => None,
    };
    match history {
        Some(h) => drop_skips(&view, &h),
        None => view,
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

/// The view's head commit: `headRefOid`, or "" when it did not come back.
fn head_sha(view: &Value) -> String {
    view.get("headRefOid").and_then(|v| v.as_str()).unwrap_or("").to_string()
}

/// The red run this view shows: the head sha, then the link of each failing check (the
/// same RED filter `failing_checks` uses), cut at the first `#` (a step's link, not the
/// build's), deduplicated and sorted so two reads of the same run compare equal. None
/// when the sha is empty or no failing check has a link — there is no run to name.
fn red_run(view: &Value) -> Option<String> {
    let sha = head_sha(view);
    if sha.is_empty() {
        return None;
    }
    let mut runs: Vec<String> = view
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter(|c| RED.contains(&check_state(c).as_str()))
                .map(|c| c.get("targetUrl").or_else(|| c.get("detailsUrl")).and_then(|v| v.as_str()).unwrap_or(""))
                .map(build_of)
                .filter(|l| !l.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    if runs.is_empty() {
        return None;
    }
    runs.sort();
    runs.dedup();
    Some(std::iter::once(sha).chain(runs).collect::<Vec<_>>().join(" "))
}

/// True when `current` is the same run as the one already `recorded`: the same head sha,
/// and every run in `current` also in `recorded`. A subset, not equality: at the charge
/// the build-level context may already be red while the suite is still running, and
/// afterwards either one may linger while the other has gone stale or cleared.
fn same_red(recorded: &str, current: &str) -> bool {
    let mut r = recorded.split_whitespace();
    let mut c = current.split_whitespace();
    let (rsha, csha) = match (r.next(), c.next()) {
        (Some(a), Some(b)) => (a, b),
        _ => return false,
    };
    if rsha != csha {
        return false;
    }
    let recorded_runs: std::collections::HashSet<&str> = r.collect();
    c.all(|run| recorded_runs.contains(run))
}

/// Records the run charged as red, so the next pass can tell whether a later red is the
/// same run (already charged) or a new one. Cleared when the view no longer names one.
fn record_red(repo: &Repo, id: &str, view: &Value) {
    match red_run(view) {
        Some(r) => write_file(&repo.mark(id, "lastred"), &format!("{r}\n")),
        None => {
            let _ = std::fs::remove_file(repo.mark(id, "lastred"));
        }
    }
}

/// True when this view's red run is the one already charged (`record_red`'s mark).
fn red_seen(repo: &Repo, id: &str, view: &Value) -> bool {
    match red_run(view) {
        Some(current) => match read_to_string(&repo.mark(id, "lastred")) {
            Some(recorded) => same_red(recorded.trim(), &current),
            None => false,
        },
        None => false,
    }
}

/// The head sha of the red run last charged for this bead, if any.
pub fn red_head(repo: &Repo, id: &str) -> Option<String> {
    read_to_string(&repo.mark(id, "lastred"))?.split_whitespace().next().map(str::to_string)
}

/// A fix round that made no new commit cannot re-run CI by pushing (`git push
/// --force-with-lease` of the same sha does nothing) or by re-labelling (the PR already
/// carries the label, so no labeled event fires either) — #132 on 25 Sep showed the fix:
/// take the label off and put it back on, which does fire a labeled event, and build 296
/// re-ran CI that build 286 had left red.
pub fn rerun_ci(repo: &Repo, id: &str, url: &str, why: &str) {
    // A failure here is not fatal: if the label was already off, adding it back still
    // fires the event; if it cannot be taken off, no build starts, and the CI_TIMEOUT
    // hold in reconcile_open's new middle branch reports that in time.
    let _ = gh_ok(repo, &["pr", "edit", url, "--remove-label", &repo.merge_label]);
    log(&format!("{}: {id}: {why}; CI re-runs on {url} (the {} label off and back on)", repo.slug, repo.merge_label));
    bd_note(repo, id, &format!("bead-loop {}: {why}; CI re-runs on {url}", date_iminutes()));
    hand_to_pipeline(repo, id, url);
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
    repo.clear_target(id);
    repo.research_clear(id);
    for m in ["red", "nocheck", "adopted", "held", "lastred"] {
        let _ = std::fs::remove_file(repo.mark(id, m));
    }
    repo.release(id);
    let _ = git(&repo.repo, &["branch", "-D", &format!("bead/{id}")]);
    log(&format!("{}: {id} closed ({url} merged; {checks})", repo.slug));
    repo.wake();
}

/// `hand_to_pipeline ID URL`: merge = "pipeline". The loop labels the PR and the CI
/// pipeline merges it on its own terms; the loop only closes the bead once it is MERGED.
/// A label the repo does not have cannot be added: noted, held, the PR waits for you.
/// The url, not the number: `gh pr edit` on it needs no cwd, whichever target it is on.
pub fn hand_to_pipeline(repo: &Repo, id: &str, url: &str) {
    if gh_ok(repo, &["pr", "edit", url, "--add-label", &repo.merge_label]) {
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
/// wrote it. Runs once per distinct `pr_repo` among this beads repo's targets, plus the
/// default — a target with `adopt = false` is skipped on its own, not the whole repo —
/// and only for a branch whose bead id this backlog's `bd` actually knows: a `bead/id`
/// shape in someone else's history on a shared target is not ours to adopt.
pub fn adopt(repo: &Repo) {
    let mut seen = std::collections::HashSet::new();
    for r in repo.target_repos() {
        if !r.adopt || !seen.insert(r.pr_repo.clone()) {
            continue;
        }
        adopt_from(repo, &r);
    }
}

/// One target's `pr_repo`: every open `bead/…` PR there this repo does not already
/// track. `--repo` is passed when `pr_repo` is known; empty (a local-path remote, which
/// does not parse to `owner/repo` — the test suite's default target) leaves it off, gh's
/// cwd deciding, exactly as before targets existed.
fn adopt_from(repo: &Repo, r: &Repo) {
    let mut args = vec!["pr", "list"];
    if !r.pr_repo.is_empty() {
        args.push("--repo");
        args.push(&r.pr_repo);
    }
    args.extend([
        "--state",
        "open",
        "--limit",
        "100",
        "--json",
        "headRefName,url",
        "--jq",
        ".[] | select(.headRefName | startswith(\"bead/\")) | [.headRefName, .url] | @tsv",
    ]);
    let out = gh_out(r, &args).unwrap_or_default();
    for line in out.lines() {
        let mut parts = line.split('\t');
        let (head, url) = match (parts.next(), parts.next()) {
            (Some(h), Some(u)) if !h.is_empty() => (h, u),
            _ => continue,
        };
        let id = match bead_id_of_branch(head) {
            Some(i) => i,
            None => continue,
        };
        if !bd_knows(repo, &id) {
            continue;
        }
        if repo.inflight_path(&id).exists() {
            continue;
        }
        // A branch of ours sent back to dev is not adopted: dev is fixing it.
        if repo.mark(&id, "fixing").exists() {
            continue;
        }
        crate::util::write_file(&repo.inflight_path(&id), &format!("{url}\n"));
        repo.set_target(&id, &r.target);
        touch(&repo.mark(&id, "adopted"));
        log(&format!("{}: adopted {url} ({head}) as bead {id}", repo.slug));
        if r.merge == "pipeline" {
            hand_to_pipeline(r, &id, url);
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
    let ready = bd_ready_json(repo).as_array().cloned().unwrap_or_default();
    for b in ready {
        let id = match b.get("id").and_then(|v| v.as_str()) {
            Some(i) => i.to_string(),
            None => continue,
        };
        if repo.inflight_path(&id).exists() || repo.review_path(&id).exists() || repo.wt(&id).is_dir() {
            continue;
        }
        // The bead's own target: its PR, if any, is on that target's pr_repo. A config
        // mistake here (an unconfigured work:NAME) surfaces as a hold when dev_one next
        // picks the bead — this pass just leaves it alone.
        let labels: Vec<&str> =
            b.get("labels").and_then(|l| l.as_array()).map(|a| a.iter().filter_map(|v| v.as_str()).collect()).unwrap_or_default();
        let r = match repo.for_bead(&labels) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let mut args = vec!["pr", "list"];
        if !r.pr_repo.is_empty() {
            args.push("--repo");
            args.push(&r.pr_repo);
        }
        let search = format!("head:bead/{id}");
        args.extend(["--state", "merged", "--search", &search, "--json", "url,headRefName", "--jq", ".[] | [.headRefName, .url] | @tsv"]);
        let out = gh_out(&r, &args).unwrap_or_default();
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

/// `bead/<prefix>-<id>[.n]*[-slug]` → the bead id, at any depth (bl-iej.2.2).
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
    while end < b.len() && b[end] == b'.' {
        let mut k = end + 1;
        while k < b.len() && b[k].is_ascii_digit() {
            k += 1;
        }
        if k == end + 1 {
            break;
        }
        end = k;
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
        // The target this bead claimed on (or was adopted onto): the same checkout and
        // PR repo `dev_one` used, so `git branch -D` at close and the rebase round land
        // on the right clone. The url, not the number, so gh needs no cwd either way.
        let r = repo.for_id(&id);
        let f = repo.inflight_path(&id);
        let url = read_to_string(&f).unwrap_or_default().trim().to_string();
        crate::config::need("gh");
        let view =
            match gh(&r, &["pr", "view", &url, "--json", "state,mergedAt,mergeable,mergeStateStatus,statusCheckRollup,url,headRefOid"]) {
                Ok(o) if o.status.success() => match serde_json::from_str::<Value>(&stdout_str(&o)) {
                    Ok(v) => v,
                    Err(_) => {
                        log(&format!("{}: cannot read PR {url}", repo.slug));
                        continue;
                    }
                },
                Ok(o) => {
                    log(&format!("{}: cannot read PR {url}", repo.slug));
                    held_in_merge(repo, &id, &format!("gh cannot read {url}: {}", stderr_str(&o).trim().lines().last().unwrap_or("")));
                    continue;
                }
                Err(_) => {
                    log(&format!("{}: cannot read PR {url}", repo.slug));
                    continue;
                }
            };
        let view = skip_free(&r, &url, view);
        let state = view.get("state").and_then(|s| s.as_str()).unwrap_or("");
        match state {
            "MERGED" => close_merged(&r, &id, &url, &view),
            "CLOSED" => {
                let _ = std::fs::remove_file(&f);
                repo.clear_target(&id);
                repo.research_clear(&id);
                for m in ["red", "nocheck", "adopted", "held", "lastred"] {
                    let _ = std::fs::remove_file(repo.mark(&id, m));
                }
                repo.release(&id);
                log(&format!("{}: {id}: PR closed unmerged, parked for you", repo.slug));
                // The question goes on the bead with the url (the brief, when there is one).
                crate::park::park(repo, &id, crate::park::Reason::PrClosed(url.clone()), None);
                repo.wake();
            }
            "OPEN" => reconcile_open(&r, &id, &f, &url, &view),
            _ => {}
        }
    }
}

fn reconcile_open(repo: &Repo, id: &str, f: &std::path::Path, url: &str, view: &Value) {
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
                    if gh_ok(repo, &["pr", "update-branch", url]) {
                        log(&format!("{}: {id}: updated branch, CI reruns", repo.slug));
                    } else {
                        log(&format!("{}: {id}: update-branch failed", repo.slug));
                    }
                } else if gh_ok(repo, &["pr", "merge", url, "--squash", "--delete-branch"]) {
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
            } else if repo.merge == "external" {
                // Not ours to merge or to time: no hold, no note. The page shows the age.
                say(id, format!("{}: {id}: green, merge is external, awaiting the maintainer: {url}", repo.slug));
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
            } else if red_seen(repo, id, view) {
                // The run already charged, on the same head: no new commit fixed it, and
                // nothing further to charge until a re-run reports.
                if repo.merge == "pipeline" {
                    say(id, format!("{}: {id}: CI red on {url} is the run already charged; waiting for the re-run", repo.slug));
                    let since = mtime(f);
                    if since > 0 && now() - since >= CI_TIMEOUT {
                        held_in_merge(
                            repo,
                            id,
                            &format!(
                                "{url} still shows the red run already charged, {} h after the push; did the re-run start?",
                                (now() - since) / 3600
                            ),
                        );
                    }
                } else {
                    let sha7: String = head_sha(view).chars().take(7).collect();
                    held_in_merge(
                        repo,
                        id,
                        &format!(
                            "CI red on {url} is the run already charged, on the same head {sha7}: the fix round made no new commit. Re-run CI or push a change"
                        ),
                    );
                }
            } else {
                // Ours: back to the dev queue on the same branch; the next push updates this PR.
                record_red(repo, id, view);
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
            let since = mtime(f);
            if repo.merge == "external" {
                // Their CI is their business: no note, no hold, whatever it reports.
                say(id, format!("{}: {id}: no checks on {url}, merge is external, awaiting the maintainer", repo.slug));
            } else if since > 0 && now() - since < NOCHECK_GRACE {
                say(id, format!("{}: {id}: no checks on {url} yet; CI has {} s to start", repo.slug, NOCHECK_GRACE - (now() - since)));
            } else {
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
        }
        _ => {
            say(id, format!("{}: {id}: CI pending on {url}", repo.slug));
            if repo.merge != "external" {
                let since = mtime(f);
                if since > 0 && now() - since >= CI_TIMEOUT {
                    held_in_merge(repo, id, &format!("CI on {url} has been pending for {} h; is the agent up?", (now() - since) / 3600));
                }
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
    fn branch_ids_any_depth() {
        assert_eq!(bead_id_of_branch("bead/bl-iej.2.2").as_deref(), Some("bl-iej.2.2"));
        assert_eq!(bead_id_of_branch("bead/bl-iej.15.1").as_deref(), Some("bl-iej.15.1"));
        assert_eq!(bead_id_of_branch("bead/bl-iej.2.2-slug").as_deref(), Some("bl-iej.2.2"));
        assert_eq!(bead_id_of_branch("bead/bl-5v2").as_deref(), Some("bl-5v2"));
        assert_eq!(bead_id_of_branch("bead/inq-85h.15").as_deref(), Some("inq-85h.15"));
        assert!(bead_id_of_branch("bead/bl-iej.2.x").is_none());
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
    fn a_skipped_build_is_not_a_result() {
        use serde_json::json;
        let st = |ctx: &str, state: &str, desc: &str, link: &str| json!({"context":ctx,"state":state,"description":desc,"target_url":link});
        let rollup = |c: Value| json!({"statusCheckRollup": c});
        let skip285 = st("bk", "error", "Build #285 skipped", "https://bk/builds/285");
        let sched285 = st("bk", "pending", "Build #285 scheduled", "https://bk/builds/285");
        let skipped = rollup(json!([{"context":"bk","state":"ERROR","targetUrl":"https://bk/builds/285"}]));
        // #132: the skip before any build ran; then with the next build's status already posted.
        assert_eq!(verdict(&drop_skips(&skipped, &json!([skip285.clone(), sched285.clone()]))), "pending");
        let next = drop_skips(&skipped, &json!([st("bk", "pending", "Build #286 scheduled", "https://bk/builds/286"), skip285, sched285]));
        assert_eq!(verdict(&next), "pending");
        assert_eq!(next["statusCheckRollup"][0]["targetUrl"], "https://bk/builds/286");
        // A skip after a green build: green. After a red one: red, named as today.
        let late = rollup(json!([
            {"context":"bk","state":"ERROR","targetUrl":"https://bk/builds/287"},
            {"context":"bk/suite","state":"SUCCESS","targetUrl":"https://bk/builds/286#s"}
        ]));
        let skip287 = st("bk", "error", "Build #287 skipped", "https://bk/builds/287");
        let passed = json!([skip287.clone(), st("bk", "success", "Build #286 passed (2 minutes)", "https://bk/builds/286")]);
        assert_eq!(verdict(&drop_skips(&late, &passed)), "green");
        let failed =
            drop_skips(&late, &json!([skip287.clone(), st("bk", "failure", "Build #286 failed (3 minutes)", "https://bk/builds/286")]));
        assert_eq!((verdict(&failed), failing_checks(&failed).as_str()), ("red", "bk"));
        // A red that is no skip, a check run, an empty history: as they were.
        let red =
            rollup(json!([{"context":"bk","state":"FAILURE","targetUrl":"https://bk/builds/288"},{"name":"lint","conclusion":"FAILURE"}]));
        assert_eq!(drop_skips(&red, &json!([skip287, st("bk", "failure", "Build #288 failed", "https://bk/builds/288")])), red);
        assert_eq!(drop_skips(&skipped, &json!([])), skipped);
        assert!(!is_skip(&st("bk", "failure", "Build #286 failed (15 minutes, 37 seconds)", "")));
        assert!(!is_skip(&st("bk", "error", "Build # skipped", "")));
    }
    #[test]
    fn statuses_path_from_the_pr_url() {
        assert_eq!(
            statuses_path("https://github.com/imkarrer/bead-loop/pull/132").as_deref(),
            Some("repos/imkarrer/bead-loop/commits/refs/pull/132/head/statuses?per_page=100")
        );
        assert_eq!(statuses_path("https://x/pull/7"), None);
        assert_eq!(statuses_path("https://github.com/o/r/issues/7"), None);
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
    fn red_run_is_the_head_and_its_builds() {
        use serde_json::json;
        let view = json!({
            "headRefOid": "abc",
            "statusCheckRollup": [
                {"context":"ci","state":"FAILURE","targetUrl":"https://bk/builds/286"},
                {"context":"suite","state":"FAILURE","targetUrl":"https://bk/builds/286#j1"},
                {"context":"rust","state":"SUCCESS","targetUrl":"https://bk/builds/286#j2"}
            ]
        });
        assert_eq!(red_run(&view).as_deref(), Some("abc https://bk/builds/286"));
        let mut no_sha = view.clone();
        no_sha.as_object_mut().unwrap().remove("headRefOid");
        assert_eq!(red_run(&no_sha), None, "no headRefOid, no run");
        let no_link = json!({"headRefOid": "abc", "statusCheckRollup": [{"context":"ci","state":"FAILURE"}]});
        assert_eq!(red_run(&no_link), None, "a failing check with no link");
    }
    #[test]
    fn same_red_when_every_run_was_charged() {
        assert!(same_red("abc https://bk/builds/286", "abc https://bk/builds/286"));
        assert!(!same_red("abc https://bk/builds/286", "abc https://bk/builds/296"));
        assert!(!same_red("abc https://bk/builds/286", "def https://bk/builds/286"));
        assert!(same_red("abc https://bk/builds/286 https://bk/builds/287", "abc https://bk/builds/286"));
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
