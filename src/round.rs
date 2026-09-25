//! The two rounds. `dev_one`: claim, worktree, worker, gate (one fix round), into the
//! review queue. `review_one`: the reviewer's verdict, push, PR, into the merge queue.
//! `send_back`: a round failed — the count goes up, the note goes on the bead, the bead
//! goes back to the dev queue on a later stage once this one's failures are spent, or is
//! parked. `hold`: the round could not happen (the world, not the model) — no failure,
//! the bead waits in its queue with the reason, the lane moves on.
//!
//! The log lines and the notes are the bash's, word for word (a note's body now indented
//! under its first line, shell.rs `note_entry`): the page and the tests read them.
use crate::config::{LaneSpec, Repo};
use crate::harness::{abort_sessions, run_agent, runnable, AgentRun};
use crate::park::{park, record_round, Reason};
use crate::shell::{
    bd_claim, bd_comment, bd_note, bd_show, bd_status, branch_exists, gh, git, git_ok, git_out, git_try, local_branch_exists,
    worktree_remove,
};
use crate::signals;
use crate::state::{dev_queue, review_queue, stage_start, StageHit};
use crate::util::{
    cut_bytes, date_iminutes, die, ensure_line, first_line, link_skills, log, read_to_string, stamp, stderr_str, stdout_str, tail_bytes,
    tail_lines, write_file,
};
use serde_json::json;
use serde_json::Value;
use std::path::Path;
use std::sync::Mutex;

/// The run's flags, what the bash kept in globals.
#[derive(Clone, Debug, Default)]
pub struct Opts {
    pub dry_run: bool,
    pub local: bool,
    pub model_flag: Option<String>,
}

/// What a lane learns from one pass: it did a round (go round again), or its queue had
/// nothing for it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Pass {
    Worked,
    Nothing,
}

/// The backoff's base (seconds; `BEAD_LOOP_HOLD_BACKOFF` overrides — the tests set it low).
pub fn hold_backoff() -> i64 {
    std::env::var("BEAD_LOOP_HOLD_BACKOFF").ok().and_then(|s| s.parse().ok()).unwrap_or(300)
}

/// A hold aged this long on the same reason is not worth another backoff: it goes to the
/// human queue instead (24h).
const HOLD_MAX_AGE: i64 = 24 * 3600;

/// The backoff's multiplier for a hold's Nth time in a row on the same reason: 1, 2, 4, 8,
/// capped at 12 — so a 5-minute base climbs 5, 10, 20, 40, 60 (minutes) and no further.
fn hold_multiplier(n: u64) -> i64 {
    let shift = n.max(1).saturating_sub(1).min(4);
    (1i64 << shift).min(12)
}

/// How long a bead's Nth hold in a row on one reason is skipped for.
fn hold_delay(n: u64) -> i64 {
    hold_backoff() * hold_multiplier(n)
}

/// When a held bead is next tried, as an absolute time — what status.rs shows.
pub fn hold_retry_at(repo: &Repo, id: &str) -> i64 {
    repo.held_since(id) + hold_delay(repo.held_count(id))
}

/// `render_bead`: the bead as a loop prompt carries it, with the notes people wrote
/// (`people_notes`) — the loop's own record reaches the prompt from the rounds, not here.
pub fn render_bead(json: &Value) -> String {
    render_bead_with(json, false)
}

/// The bead with its notes whole, the loop's lines and all: for `open`, the hand session
/// whose owner reads the bead's story in it.
pub fn render_bead_whole(json: &Value) -> String {
    render_bead_with(json, true)
}

/// The bead's notes without the loop's own lines. The loop notes each event as one entry:
/// a `bead-loop` line, any body indented under it (shell.rs `bd_note`). Every other line —
/// the filer's notes, an operator's answer, a note appended by hand — is people's and
/// stays, and so does one entry of the loop's: a parking's question, which the answer
/// under it replies to. (An entry from before the body was indented reads, past its first
/// line, as people's.)
pub fn people_notes(notes: &str) -> String {
    let mut keep = true;
    let mut out = Vec::new();
    for l in notes.lines() {
        if let Some(rest) = l.strip_prefix("bead-loop").filter(|r| r.starts_with([' ', ':'])) {
            keep = rest.trim_start().split_once(": ").is_some_and(|(_, what)| what.starts_with("parked ("));
        } else if !(l.is_empty() || l.starts_with([' ', '\t'])) {
            keep = true;
        }
        if keep {
            out.push(l);
        }
    }
    out.join("\n").trim_matches('\n').to_string()
}

fn render_bead_with(json: &Value, whole_notes: bool) -> String {
    let b = json.get(0).cloned().unwrap_or(Value::Null);
    let s = |k: &str| b.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let prio = match b.get("priority") {
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::String(t)) => t.clone(),
        _ => "null".into(),
    };
    let itype = b.get("issue_type").and_then(|v| v.as_str()).unwrap_or("task");
    let ac = {
        let a = s("acceptance_criteria");
        if a.is_empty() {
            "(none given: the description is the criterion)".to_string()
        } else {
            a
        }
    };
    let mut out = format!(
        "id: {}\ntitle: {}\ntype: {}   priority: P{}\n\nDESCRIPTION:\n{}\n\nACCEPTANCE CRITERIA:\n{}",
        s("id"),
        s("title"),
        itype,
        prio,
        s("description"),
        ac
    );
    if !s("design").is_empty() {
        out.push_str(&format!("\n\nDESIGN:\n{}", s("design")));
    }
    let notes = if whole_notes { s("notes") } else { people_notes(&s("notes")) };
    if !notes.is_empty() {
        out.push_str(&format!("\n\nNOTES:\n{notes}"));
    }
    out
}

/// Commit whatever the worker left uncommitted (the gate, reviewer and CI judge it),
/// with .beads/ restored. False when the branch has no commits over base.
pub fn settle_worktree(repo: &Repo, wt: &Path, msg: &str) -> bool {
    let _ = git(wt, &["checkout", "-q", "--", ".beads"]);
    if !git_out(wt, &["status", "--porcelain"]).trim().is_empty() && git_ok(wt, &["add", "-A"]) {
        let _ = git(wt, &["commit", "-q", "-m", msg]);
    }
    !git_out(wt, &["rev-list", &format!("{}/{}..HEAD", repo.base_remote, repo.base)]).trim().is_empty()
}

pub fn run_gate(repo: &Repo, wt: &Path, logf: &Path) -> bool {
    if repo.gate.is_empty() {
        return true;
    }
    if signals::stopping() {
        return false; // the caller finds the stop, not a failed gate
    }
    log(&format!("{}: gate: {}", repo.slug, repo.gate));
    run_shell_to(&repo.gate, wt, logf)
}

/// `(cd DIR && bash -c CMD) >LOG 2>&1`
fn run_shell_to(script: &str, dir: &Path, logf: &Path) -> bool {
    let f = match std::fs::File::create(logf) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let f2 = f.try_clone().ok();
    let mut c = crate::util::cmd("bash");
    c.args(["-c", script]).current_dir(dir).stdin(std::process::Stdio::null()).stdout(f);
    if let Some(f2) = f2 {
        c.stderr(f2);
    }
    match c.spawn() {
        Ok(mut ch) => {
            signals::child_started(ch.id());
            let st = ch.wait();
            signals::child_ended(ch.id());
            st.map(|s| s.success()).unwrap_or(false)
        }
        Err(_) => false,
    }
}

/// The last three rounds' notes, for the prompt.
fn history(repo: &Repo, id: &str) -> String {
    crate::park::history(repo, id, 3)
}

/// Whether a held bead's hold is old enough to try again.
fn hold_expired(repo: &Repo, id: &str) -> bool {
    !repo.held_path(id).exists() || crate::util::now() - repo.held_since(id) >= hold_delay(repo.held_count(id))
}

/// A held bead nobody has retried in a full day: another backoff is not going anywhere —
/// it joins the parked queue with the reason, for a human.
fn hold_stale(repo: &Repo, id: &str) -> bool {
    repo.held_path(id).exists() && crate::util::now() - repo.held_since(id) >= HOLD_MAX_AGE
}

fn park_stale_hold(repo: &Repo, id: &str) {
    let why = repo.held_why(id).unwrap_or_default();
    log(&format!("{}: {id}: held a day on the same reason, parked for you: {}", repo.slug, first_line(&why)));
    bd_status(repo, id, "in_progress");
    park(repo, id, Reason::HoldExpired(why), None);
    repo.release(id);
    let _ = std::fs::remove_file(repo.review_path(id));
}

/// The beads a round in this process is on, as `STATE/ID`. A bead stays in its queue
/// until the round moves it (`bd_claim` a moment after the pick; the review queue's file
/// until the PR), so two slots of one lane, over the same models, would both pick it:
/// the pick takes a reservation, and `pick_runnable` passes over reserved beads.
static RESERVED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// A bead reserved to one round; dropped when the round returns.
pub struct Reservation(String);

impl Drop for Reservation {
    fn drop(&mut self) {
        RESERVED.lock().unwrap_or_else(|e| e.into_inner()).retain(|k| k != &self.0);
    }
}

fn reservation_key(repo: &Repo, id: &str) -> String {
    format!("{}/{id}", repo.rs.display())
}

fn reserved(repo: &Repo, id: &str) -> bool {
    let key = reservation_key(repo, id);
    RESERVED.lock().unwrap_or_else(|e| e.into_inner()).contains(&key)
}

/// This bead for this round, or `None` when another round in this process has it.
pub fn reserve(repo: &Repo, id: &str) -> Option<Reservation> {
    let key = reservation_key(repo, id);
    let mut g = RESERVED.lock().unwrap_or_else(|e| e.into_inner());
    if g.contains(&key) {
        return None;
    }
    g.push(key.clone());
    Some(Reservation(key))
}

/// `pick_runnable`, and the bead reserved to the caller. No lock across the look at the
/// queue: it reads bd, and lanes queued on a lock that long look busy to each other for
/// ever (a tick then never ends). Two slots can pick the same bead; the one whose
/// reservation fails looks again, and the pick passes over a reserved bead.
fn pick_and_reserve(repo: &Repo, which: &str, lane: Option<&LaneSpec>) -> Option<(String, Reservation)> {
    pick_dev_and_reserve_in(repo, which, lane).map(|(id, _, r)| (id, r))
}

/// The dev pick, reserved the same way: (id, research round, reservation). A bead with
/// `research_model` set and no brief is the research lane's before it is the worker's. A
/// worker lane skips it while it has a bead with a brief to take — and takes it without
/// one when it has nothing else, so the worker's server never waits on the researcher's.
fn pick_dev_and_reserve(repo: &Repo, lane: Option<&LaneSpec>) -> Option<(String, bool, Reservation)> {
    pick_dev_and_reserve_in(repo, "dev", lane)
}

fn pick_dev_and_reserve_in(repo: &Repo, which: &str, lane: Option<&LaneSpec>) -> Option<(String, bool, Reservation)> {
    for _ in 0..3 {
        let (id, research) = pick(repo, which, lane)?;
        if let Some(r) = reserve(repo, &id) {
            return Some((id, research, r));
        }
    }
    None
}

/// `pick_runnable dev|review`: the first bead in that queue whose round's model can run
/// now and whose hold (if any) has aged; the ones skipped are logged once per pass.
///
/// `lane`: the lane asking — it takes only the rounds whose model it matches
/// (config.rs `LaneSpec`); `None` takes any (a hand-run `work`). A bead on the Claude
/// stage never waits behind the GPU this way, nor a CPU-box round behind the GPU's.
pub fn pick_runnable(repo: &Repo, which: &str, lane: Option<&LaneSpec>) -> Option<String> {
    pick(repo, which, lane).map(|(id, _)| id)
}

/// A research round is due: research is on, the bead has no brief, and the round is not a
/// rebase or a worker session to rejoin.
pub fn needs_research(repo: &Repo, id: &str) -> bool {
    !repo.research_model.is_empty()
        && !repo.research_path(id).exists()
        && !repo.mark(id, "conflict").exists()
        && repo.rejoin_of(id).map(|(_, kind)| kind == "research").unwrap_or(true)
}

fn pick(repo: &Repo, which: &str, lane: Option<&LaneSpec>) -> Option<(String, bool)> {
    let queue = if which == "dev" { dev_queue(repo) } else { review_queue(repo) };
    let mut skipped_claude = 0;
    let mut waiting_for = String::new();
    let mut pick = None;
    // a bead with no brief this worker lane may take when it finds nothing better
    let mut unresearched = None;
    for id in queue {
        if hold_stale(repo, &id) {
            park_stale_hold(repo, &id);
            continue;
        }
        if !hold_expired(repo, &id) || reserved(repo, &id) {
            continue;
        }
        let n = repo.failures_of(&id);
        if which == "dev" && needs_research(repo, &id) {
            if let Some(st) = repo.stage_for(n) {
                let rm = &repo.research_model;
                if lane.map(|l| l.takes(rm)).unwrap_or(true) && runnable(repo, rm) {
                    pick = Some((id, true));
                    break;
                }
                if unresearched.is_none() && lane.map(|l| l.takes(&st.model)).unwrap_or(true) && runnable(repo, &st.model) {
                    unresearched = Some(id);
                }
                continue;
            }
        }
        // The model this round runs on: the stage's worker or reviewer — or, for a bead
        // sent back with a conflict, the rebase worker (conflict_worker, else the last
        // stage's). A bead whose stages are exhausted is the first lane's to park; a
        // round with no reviewer (straight to PR) names no model and is the first
        // reviewing lane's.
        let model = match repo.stage_for(n) {
            None => {
                if lane.map(|l| !l.parks).unwrap_or(false) {
                    continue;
                }
                pick = Some((id, false));
                break;
            }
            Some(st) => {
                if which == "dev" {
                    if repo.mark(&id, "conflict").exists() {
                        conflict_model(repo).unwrap_or(st.model)
                    } else {
                        st.model
                    }
                } else if st.review.is_empty() {
                    "none".into()
                } else {
                    st.review
                }
            }
        };
        if let Some(l) = lane {
            let mine = if model == "none" { l.fallback || l.takes("none") } else { l.takes(&model) };
            if !mine {
                continue;
            }
        }
        if runnable(repo, &model) {
            pick = Some((id, false));
            break;
        }
        waiting_for = crate::harness::why_not(repo, &model);
        skipped_claude += 1;
    }
    if skipped_claude > 0 {
        log(&format!("{}: {which}: {skipped_claude} bead(s) wait for {waiting_for}", repo.slug));
    }
    pick.or(unresearched.map(|id| (id, false)))
}

/// A worker, gate or reviewer that came back while the loop is stopping came back
/// because of the stop — its session aborted, its process signalled — not because of
/// the bead. Nothing is judged: no failure, no note, the branch and the worktree stay,
/// the bead stays where it is (in_progress with a worktree, or in the review queue),
/// which is exactly what `recover` reopens at the next start with no failure charged.
/// The lane then has nothing left to do: it says so, and waits for the process to go
/// (the signal thread exits once every lane on a round has said so, or after a moment).
fn cut_short(repo: &Repo, id: &str) {
    if !signals::stopping() {
        return;
    }
    log(&format!("{}: {id}: round cut short by the stop; nothing charged, recover reopens it", repo.slug));
    signals::ack_stop();
    loop {
        crate::util::sleep_secs(1.0);
    }
}
/// Drop the marker of whichever lane is on this bead — found by its content, not by a
/// fixed name: the lanes are named by the config (gpu, cpu, claude), and two rounds in
/// one repo must not share a file. A bead on no lane (the watcher's send-back of a red
/// PR) touches nothing, so a running round keeps its marker.
fn clear_lane_of(repo: &Repo, id: &str) {
    for name in repo.lane_files() {
        if repo.lane_bead(&name).as_deref() == Some(id) {
            repo.lane_clear(&name);
            signals::clear_current(&name);
        }
    }
}

/// The hold's reason for a round that came back with nothing from the model
/// (harness.rs `AgentRun::empty`): the harness's own words — the server's error, the
/// model not found on it, a refused connection, its stderr — so the page says why, not
/// an exit code alone.
fn never_answered(role: &str, model: &str, r: &AgentRun) -> String {
    let words = if r.error.is_empty() { String::new() } else { format!(": {}", r.error) };
    format!("{role} {model} exited {} before the model answered (harness or server down?){words}", r.rc)
}

/// `hold`: the round could not happen for a reason that is not the bead's. The bead
/// stays where it is (open: the dev queue; review/ID: the review queue), the reason on
/// the bead once, and the pick skips it for HOLD_BACKOFF seconds.
pub fn hold(repo: &Repo, id: &str, wt: Option<&Path>, why: &str) {
    let first = first_line(why);
    log(&format!("{}: {id}: held: {first}", repo.slug));
    if repo.hold(id, why) {
        bd_note(repo, id, &format!("bead-loop {}: held, no failure charged: {why}", date_iminutes()));
    }
    clear_lane_of(repo, id);
    if let Some(wt) = wt {
        // the fresh worktree of a round that never ran is not worth keeping
        if !branch_exists(repo, &format!("bead/{id}")) {
            worktree_remove(repo, wt);
        }
    }
    if !repo.review_path(id).exists() {
        bd_status(repo, id, "open");
    }
    repo.wake();
}

/// The bead's worktree: on its branch when a round left one (`resumed`, tracking origin's
/// copy when only that exists), else a fresh branch off the base. Git's refusal is the
/// reason to hold the bead.
pub fn make_worktree(repo: &Repo, branch: &str, wt: &Path, resumed: bool) -> Result<(), String> {
    if resumed {
        if !local_branch_exists(repo, branch) {
            git_try(&repo.repo, &["branch", "-q", "--track", branch, &format!("{}/{branch}", repo.push_remote)])?;
        }
        git_try(&repo.repo, &["worktree", "add", "-q", &wt.to_string_lossy(), branch])?;
    } else {
        let _ = git(&repo.repo, &["branch", "-D", branch]);
        git_try(
            &repo.repo,
            &["worktree", "add", "-q", "-b", branch, &wt.to_string_lossy(), &format!("{}/{}", repo.base_remote, repo.base)],
        )?;
    }
    Ok(())
}

/// Two round notes are the same REJECT: both start with "review (" and their first
/// lines starting with "REJECT:", whitespace collapsed, are equal.
pub fn same_reject(prev: &str, this: &str) -> bool {
    // Check if both notes start with "review ("
    if !prev.starts_with("review (") || !this.starts_with("review (") {
        return false;
    }
    // Find the first line that starts with "REJECT:" after trimming whitespace
    let prev_reject_line = prev.lines().find(|line| line.trim_start().starts_with("REJECT:")).map(|line| line.trim_start());
    let this_reject_line = this.lines().find(|line| line.trim_start().starts_with("REJECT:")).map(|line| line.trim_start());
    // If either doesn't have a REJECT line, return false
    let prev_reject = match prev_reject_line {
        Some(line) => line,
        None => return false,
    };
    let this_reject = match this_reject_line {
        Some(line) => line,
        None => return false,
    };
    // Collapse whitespace in both lines and compare
    let prev_collapsed = prev_reject.split_whitespace().collect::<Vec<_>>().join(" ");
    let this_collapsed = this_reject.split_whitespace().collect::<Vec<_>>().join(" ");
    prev_collapsed == this_collapsed
}

/// `send_back ID WT fresh|keep NOTE`. `stem` is the round's log prefix (`logs/ID.STAMP`),
/// so the history can name the round's files.
#[allow(clippy::too_many_arguments)]
pub fn send_back(repo: &Repo, id: &str, wt: &Path, keep: bool, note: &str, model: &str, last: bool, stem: Option<&Path>) {
    let n = repo.failures_of(id) + 1;
    let prev_note = crate::park::rounds(repo, id).last().and_then(|r| r.get("note")).and_then(|v| v.as_str()).map(str::to_string);
    // The same REJECT twice: skip ahead past whatever's left of the current stage to the
    // first later stage with a different worker, instead of giving it another try.
    let escalated = prev_note.filter(|p| same_reject(p, note)).and_then(|_| {
        let cur = repo.stage_for(n - 1).map(|s| s.model);
        let steps: u64 = repo.stages.iter().map(|s| s.failures).sum();
        (0..steps).find_map(|step| {
            let m = n + step;
            repo.stage_for(m).filter(|hit| Some(hit.model.clone()) != cur).map(|hit| (m, hit.model))
        })
    });
    let suffix = escalated.as_ref().map(|(_, w)| format!(", the same REJECT twice: escalated to {w}")).unwrap_or_default();
    log(&format!("{}: {id} round {n} stopped: {}{suffix}", repo.slug, first_line(note)));
    bd_note(repo, id, &format!("bead-loop round {n} ({model}) {}: {note}{suffix}", date_iminutes()));
    record_round(repo, id, n, model, note, stem);
    let n = escalated.map(|(m, _)| m).unwrap_or(n);
    repo.set_failures(id, n);
    // Parked: BLOCKED at the last stage (whatever on_exhaust says), or the stages are
    // spent. The brief runs before the worktree goes, so it can see what was tried.
    let parked = if last && note.contains("BLOCKED:") {
        log(&format!("{}: {id}: BLOCKED at the last stage, parked for you", repo.slug));
        Some(Reason::Blocked)
    } else if repo.stage_for(n).is_none() {
        log(&format!("{}: {id}: stages exhausted ({n} failures), parked for you", repo.slug));
        Some(Reason::Exhausted)
    } else {
        None
    };
    if let Some(reason) = parked.clone() {
        park(repo, id, reason, Some(wt));
        repo.clear_target(id);
        repo.research_clear(id);
    }
    clear_lane_of(repo, id);
    repo.release(id);
    if !keep {
        worktree_remove(repo, wt);
        let _ = git(&repo.repo, &["branch", "-D", &format!("bead/{id}")]);
    }
    if parked.is_some() {
        park_cleanup(repo, wt);
        repo.wake();
        return;
    }
    // research = "every": the brief goes to .prev, so the next pick is a research round
    // that refines it with this round's note
    if repo.research == "every" && !repo.research_model.is_empty() && repo.research_path(id).exists() {
        let _ = std::fs::rename(repo.research_path(id), repo.research_prev_path(id));
    }
    if let Some(st) = repo.stage_for(n) {
        bd_status(repo, id, "open");
        log(&format!(
            "{}: {id}: → dev queue ({n} failures; next: worker {}, reviewer {})",
            repo.slug,
            st.model,
            if st.review.is_empty() { "none".to_string() } else { st.review.clone() }
        ));
    }
    repo.wake();
}

pub fn park_cleanup(repo: &Repo, wt: &Path) {
    let _ = git(&repo.repo, &["worktree", "remove", "--force", &wt.to_string_lossy()]);
}

/// A bead's `labels` array, as `bd show --json` carries it.
fn bead_labels(json: &Value) -> Vec<&str> {
    json.get(0)
        .and_then(|b| b.get("labels"))
        .and_then(|l| l.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default()
}

/// The bead's `stage:NAME` label (docs/design-providers.md): floors its failure count to
/// the named stage's first count, once — the next round's count is already there. A label
/// naming no stage is logged and ignored (the bead runs from stage 1: a typo must not hold
/// work).
fn apply_stage_label(repo: &Repo, id: &str, labels: &[&str]) {
    let Some(label) = labels.iter().find(|l| l.starts_with("stage:")) else { return };
    let name = &label["stage:".len()..];
    match stage_start(&repo.stages, name) {
        Some(start) if start > repo.failures_of(id) => {
            repo.set_failures(id, start);
            let index = if name == "last" { repo.stages.len() } else { repo.stages.iter().position(|s| s.name == name).unwrap() + 1 };
            bd_note(
                repo,
                id,
                &format!("bead-loop {}: label stage:{name}: starting on stage {name} ({index}), failures set to {start}", date_iminutes()),
            );
        }
        Some(_) => {}
        None => log(&format!("{}: {id}: label stage:{name} names no stage; ignored", repo.slug)),
    }
}

/// The harness label a bead may carry, applied to the stage's worker.
fn apply_harness_label(repo: &Repo, id: &str, json: &Value, model: &mut String) {
    let labels = bead_labels(json);
    let (m, why) = harness_for(&labels, model);
    *model = m;
    if let Some(why) = why {
        log(&format!("{}: {id}: {why}", repo.slug));
    }
}

/// `harness:aider` puts an opencode model under aider, `harness:opencode` takes an
/// `aider:` model out of it; `claude/*` is not touched. The worker to run, and the
/// reason to log when the label changed it.
pub fn harness_for(labels: &[&str], model: &str) -> (String, Option<String>) {
    if labels.contains(&"harness:aider") {
        if !model.starts_with("aider:") && !model.starts_with("claude/") {
            let m = format!("aider:{model}");
            return (m.clone(), Some(format!("label harness:aider: worker {m} runs in aider, not opencode")));
        }
    } else if labels.contains(&"harness:opencode") {
        if let Some(m) = model.strip_prefix("aider:") {
            return (m.to_string(), Some(format!("label harness:opencode: worker {m} runs in opencode, not aider")));
        }
    }
    (model.to_string(), None)
}

/// The rebase work order a conflict round carries under the bead: `base_remote` names
/// the fetch and the rebase target alike (both named, not positional, so the two never
/// drift out of sync with each other).
pub fn rebase_order(base_remote: &str, base: &str) -> String {
    format!(
        "\n\nThis branch has an open pull request that GitHub cannot merge: it conflicts with {base}. Your job this round is the rebase, not new work. Run: git fetch {base_remote} && git rebase {base_remote}/{base}. Resolve every conflict so that both what this branch set out to do (the bead above, and the commits already on the branch) and what {base} changed since are kept; do not drop either side to make the conflict go away. Then run the gate if one is given, make sure the acceptance criteria still hold, and end with DONE: <what conflicted and how you resolved it>. Do not squash or rewrite the branch beyond the rebase."
    )
}

/// The researcher's prompt: the bead and the base; after a send-back under `research =
/// "every"`, the brief the worker had and the note it was sent back with (`hist`, the
/// last round), to refine; with no brief to refine but rounds behind the bead (its brief
/// cleared at a parking), their notes (`hist`, the last three).
pub fn research_prompt(json: &Value, base: &str, previous: &str, hist: &str) -> String {
    let refine = if !previous.is_empty() {
        format!(
            "\n\nA worker already tried this bead with the brief under <previous-research> and was sent back with the note under <send-back>. Refine the brief so the next round does not fail the same way; keep what was right, do not start over.\n\n<previous-research>\n{}\n</previous-research>\n\n<send-back>\n{}\n</send-back>",
            previous.trim_end(),
            hist.trim_end()
        )
    } else if !hist.is_empty() {
        format!(
            "\n\nEarlier rounds on this bead were sent back; their notes follow. Brief the next worker so it does not fail the same way.\n\n<previous-attempts>\n{}\n</previous-attempts>",
            hist.trim_end()
        )
    } else {
        String::new()
    };
    format!(
        "Research the bead below in this repository, a fresh worktree of {base}, for the smaller model that will implement it next.\n\n<bead>\n{}\n</bead>{refine}\n\nAnswer under the four headings Files / Shape / Check / Pitfalls, in at most sixty lines, every path from the repository root as it is on disk. If a claim in the bead is false and it cannot be done as written, end instead with one line: BLOCKED: <the false claim, with file:line>.",
        render_bead(json)
    )
}

/// The worker's prompt: the bead, the branch and whether it is resumed, the rebase order
/// of a conflict round, the research brief when one was written, and the notes of the
/// rounds sent back before (the last three).
#[allow(clippy::too_many_arguments)]
pub fn dev_prompt(
    json: &Value,
    branch: &str,
    base: &str,
    resumed: bool,
    gate: &str,
    rebase: &str,
    research: &str,
    hist: &str,
    house: &str,
) -> String {
    let research_block = if research.trim().is_empty() {
        String::new()
    } else {
        format!(
            "\n\nA researcher read the repository for this bead before you; its brief follows. Start from its Files and prove the change with its Check; where it and the bead disagree, the bead wins.\n\n<research>\n{}\n</research>",
            research.trim_end()
        )
    };
    let history_block = if hist.is_empty() {
        String::new()
    } else {
        format!(
            "\n\nEarlier rounds on this bead were sent back; their notes follow. A note that begins \"review (...) rejected:\" is a work order from the senior reviewer: do exactly what its \"What to do\" says, prove it with its \"How to check\", and leave alone what it says to leave alone. Read them before you start and do not repeat them.\n\n<previous-attempts>\n{hist}\n</previous-attempts>"
        )
    };
    let gate_block = if gate.is_empty() {
        String::new()
    } else {
        format!(" The gate this branch must pass before review: `{gate}`. Run it before you write DONE:.")
    };
    let house_block = if house.is_empty() {
        String::new()
    } else {
        format!(" House rules for this work are the skills under .agents/skills/ (linked from {house}); the repository's own AGENTS.md and CONTRIBUTING.md win on style.")
    };
    format!(
        "Work the bead below in this repository, following the bead-workflow skill.\n\n<bead>\n{}\n</bead>\n\nYou are on branch {branch}{}.{gate_block}{house_block} Commit your work on this branch and leave .beads/ untouched. End your turn with one line: DONE: <evidence> or BLOCKED: <note>.{rebase}{research_block}{history_block}",
        render_bead(json),
        if resumed {
            ", which already carries your earlier commit(s) for this bead: fix them in place rather than starting over".to_string()
        } else {
            format!(", a fresh worktree of {base}")
        }
    )
}

/// The gate's fix prompt: the round's prompt with what the gate said.
pub fn gate_fix_prompt(prompt: &str, gate: &str, gate_out: &str) -> String {
    format!(
        "{prompt}\n\nYour commit on this branch failed the repository's gate: `{gate}`. Fix exactly what it reports, run it again until it passes, commit, and end with DONE: or BLOCKED:.\n\n<gate-output>\n{gate_out}\n</gate-output>"
    )
}

/// The post-mortem's prompt: the bead's title and criteria, the worker's last words (cut
/// to the tail — a failure is at the end, not the start), and the gate's tail when there
/// was one.
pub fn postmortem_prompt(bead: &Value, worker_text: &str, gate_tail: &str) -> String {
    let mut out =
        format!("<bead>\n{}\n</bead>\n\n<worker-transcript>\n{}\n</worker-transcript>", render_bead(bead), tail_bytes(worker_text, 8000));
    if !gate_tail.is_empty() {
        out.push_str(&format!("\n\n<gate-output>\n{gate_tail}\n</gate-output>"));
    }
    out.push_str(
        "\n\nIn at most five lines, as three numbered lines:\n1. What the worker tried.\n2. Where and why it stopped.\n3. The first thing the next round should do.\n\nName files and commands from the transcript exactly as they appear; do not guess what the worker meant. No verdict, no format beyond the three numbered lines.",
    );
    out
}

/// The post-mortem note appended to a send-back: empty when there is no pre-check model,
/// or when the model never answers or errors — never a hold, never a failure of its own,
/// so the note it cannot write is simply not there.
fn postmortem(repo: &Repo, id: &str, wt: &Path, json: &Value, worker_text: &str, gate_tail: &str, logf: &Path) -> String {
    if repo.precheck_model.is_empty() {
        return String::new();
    }
    let prompt = postmortem_prompt(json, worker_text, gate_tail);
    let logp = std::path::PathBuf::from(format!("{}.postmortem.jsonl", logf.display()));
    let r = run_agent(repo, "bead-postmortem", &repo.precheck_model, wt, &logp, &prompt, &format!("{id} · post-mortem"), 120, Some(json));
    if r.empty || r.rc != 0 {
        return String::new();
    }
    format!("\nPost-mortem ({}):\n{}", repo.precheck_model, cut_bytes(&r.text, 1500))
}

/// The reviewer's prompt: the bead, the note the last round was sent back with, the
/// worker's report, the diff against the base.
pub fn review_prompt(json: &Value, base: &str, last: &str, report: &str, stat: &str, diff: &str) -> String {
    format!(
        "Review the commit(s) on this branch for the bead below. The diff against {base} is under <diff>; read any file you need for context.\n\n<bead>\n{}\n</bead>{}\n\n<worker-report>\n{report}\n</worker-report>\n\n<diff>\n{stat}{diff}\n</diff>\n\nEnd with APPROVE: <what you checked> on one line, or REJECT: <file:line, what is wrong> followed by the 'For the worker:' block your instructions describe — the worker acts on that block alone.",
        render_bead(json),
        last_round_block(last)
    )
}

/// The note the last round was sent back with (park.rs `last_round`), for the reviewer
/// and the pre-checker to hold the diff to beside the bead; nothing on a first round.
pub fn last_round_block(last: &str) -> String {
    if last.trim().is_empty() {
        return String::new();
    }
    format!(
        "\n\nAn earlier round on this branch was sent back; the note it was sent back with follows. Check that the diff does what it asked as well as what the bead asks: a work order's What to do done, its How to check holding, its Leave alone untouched.\n\n<last-round>\n{}\n</last-round>",
        cut_bytes(last.trim_end(), 4000)
    )
}

/// The whole of a rejection travels — the REJECT line and everything under it, the
/// work order for the worker — not a summary of it.
pub fn reject_block(text: &str) -> String {
    let mut out = Vec::new();
    let mut on = false;
    for l in text.lines() {
        if l.starts_with("REJECT:") {
            on = true;
        }
        if on {
            out.push(l);
        }
    }
    out.join("\n")
}

/// The pre-checker's prompt: the bead, the note the last round was sent back with, the
/// worker's report, the diff against the base — uncut, unlike the reviewer's (the caller
/// cuts it, per bead .2).
pub fn precheck_prompt(json: &Value, last: &str, report: &str, stat: &str, diff: &str) -> String {
    format!(
        "<bead>\n{}\n</bead>{}\n\n<worker-report>\n{report}\n</worker-report>\n\n<diff>\n{stat}{diff}\n</diff>\n\nEnd with PASS: <what you checked> on one line, or SEND BACK: <one line> followed by the 'For the worker:' block your instructions describe.",
        render_bead(json),
        last_round_block(last)
    )
}

/// The pre-checker's verdict: a `PASS:` line passes, a `SEND BACK:` line (and everything
/// under it, as `reject_block` takes it) sends back; if both appear, SEND BACK wins — the
/// model changed its mind downward. Neither line is `Unparsed`.
#[derive(Clone, Debug, PartialEq)]
pub enum Precheck {
    Pass,
    SendBack(String),
    Unparsed,
}

pub fn precheck_verdict(text: &str) -> Precheck {
    if text.lines().any(|l| l.starts_with("SEND BACK:")) {
        let mut out = Vec::new();
        let mut on = false;
        for l in text.lines() {
            if l.starts_with("SEND BACK:") {
                on = true;
            }
            if on {
                out.push(l);
            }
        }
        return Precheck::SendBack(out.join("\n"));
    }
    if text.lines().any(|l| l.starts_with("PASS:")) {
        return Precheck::Pass;
    }
    Precheck::Unparsed
}

/// The PR's body: the bead, its acceptance criteria quoted, the two last words.
pub fn pr_body(id: &str, title: &str, ac: &str, worker_line: &str, reviewer_line: &str) -> String {
    let ac_quoted: String = ac.lines().map(|l| format!("> {l}")).collect::<Vec<_>>().join("\n");
    let ac_quoted = if ac.is_empty() { "> ".to_string() } else { ac_quoted };
    format!(
        "Bead `{id}`: {title}\n\n{ac_quoted}\n\nWorker: {worker_line}\n{reviewer_line}\n\nOpened by bead-loop; the bead closes when this merges.\n"
    )
}

/// The PR's title: `plain` style is just the title; any other style keeps the id prefix.
pub fn pr_title(style: &str, id: &str, title: &str) -> String {
    if style == "plain" {
        title.to_string()
    } else {
        format!("{id}: {title}")
    }
}

/// A plain PR body: the description, how to verify, the worker's last words, and the bead marker.
/// No "Opened by bead-loop" line, no reviewer line.
pub fn pr_body_plain(id: &str, description: &str, ac: &str, worker_line: &str) -> String {
    let worker_line = worker_line.strip_prefix("DONE: ").unwrap_or(worker_line);
    format!("{description}\n\n## How to verify\n{ac}\n\n{worker_line}\n\n<!-- bead: {id} -->\n")
}

/// `dev_one [ID]`
/// The worker of a conflict (rebase) round: `conflict_worker`, else the last stage's.
pub fn conflict_model(repo: &Repo) -> Option<String> {
    if !repo.conflict_worker.is_empty() {
        return Some(repo.conflict_worker.clone());
    }
    repo.stage_for(repo.last_stage_start()).map(|s| s.model)
}

/// A local branch with no commits over the base and never pushed: what a research round
/// leaves, never work to resume.
fn research_leftover(repo: &Repo, branch: &str) -> bool {
    local_branch_exists(repo, branch)
        && !git_ok(&repo.repo, &["show-ref", "-q", &format!("refs/remotes/{}/{branch}", repo.push_remote)])
        && git_out(&repo.repo, &["rev-list", &format!("{}/{}..{branch}", repo.base_remote, repo.base)]).trim().is_empty()
}

/// `research_one ID`: the research round — the bead claimed, a worktree on the base (or
/// its branch after a send-back), the researcher reads and answers. A brief goes to
/// `beads/ID/brief` and the bead back to the dev queue for its worker; `BLOCKED:` parks it
/// with the researcher's line as the question; nothing from the model holds it. Research
/// never counts a failure. A bead labelled `harness:aider` was scoped to its files by whoever
/// filed it: no round, an empty brief, straight to the worker. True when the worker round
/// may go next (a brief written, or research skipped).
fn research_one(repo: &Repo, opts: &Opts, id: &str, lane: Option<&LaneSpec>, last_id: &mut Option<String>) -> bool {
    let n = repo.failures_of(id);
    let Some(st) = repo.stage_for(n) else { return false };
    let model = repo.research_model.clone();
    let json = bd_show(repo, id);
    let labels = bead_labels(&json);
    if labels.contains(&"harness:aider") {
        // the lane's time is the reviewer's too: a bead already scoped needs no brief
        log(&format!("{}: {id}: harness:aider names its files; no research round", repo.slug));
        if !opts.dry_run {
            write_file(&repo.research_path(id), "\n");
        }
        return true;
    }
    let repo = match repo.for_bead(&labels) {
        Ok(r) => r,
        Err(e) => {
            hold(repo, id, None, &e);
            return false;
        }
    };
    let repo = &repo;
    let title = json.get(0).and_then(|b| b.get("title")).and_then(|t| t.as_str()).unwrap_or("").to_string();
    let branch = format!("bead/{id}");
    let wt = repo.wt(id);
    let logf = repo.rs.join("logs").join(format!("{id}.{}", stamp()));
    let rejoin = repo
        .rejoin_of(id)
        .filter(|(_, kind)| kind == "research")
        .map(|(sid, _)| sid)
        .filter(|_| wt.is_dir())
        .filter(|sid| opts.dry_run || crate::harness::rejoin_fits(repo, id, sid, "research"));
    repo.rejoin_clear(id);
    let mut resumed = branch_exists(repo, &branch);
    // An empty branch never pushed, with no session to rejoin on it, is an earlier research
    // round's that a stop cut short: gone, so the worker does not take it for work to resume.
    if !opts.dry_run && rejoin.is_none() && resumed && research_leftover(repo, &branch) {
        worktree_remove(repo, &wt);
        let _ = git(&repo.repo, &["branch", "-D", &branch]);
        resumed = false;
    }
    let previous = read_to_string(&repo.research_prev_path(id)).unwrap_or_default();
    // the note to refine the brief by; with no brief to refine, the rounds behind the bead
    let hist = crate::park::history(repo, id, if previous.is_empty() { 3 } else { 1 });
    let prompt = research_prompt(&json, &repo.base, &previous, &hist);
    // a research round holds a lane the reviewer may share: its own, shorter clock
    let timeout = st.timeout.min(repo.research_timeout);
    log(&format!(
        "{}: research: bead {id} — {title} ({n} failures, researcher {model}{}{})",
        repo.slug,
        if previous.is_empty() { "" } else { ", refining the brief" },
        rejoin.as_deref().map(|s| format!(", rejoining session {s}")).unwrap_or_default()
    ));
    if opts.dry_run {
        println!("--- research  model: {model}  base: {}", repo.base);
        println!("{prompt}");
        return false;
    }
    let lane_name = lane.map(|l| l.name.as_str()).unwrap_or("dev");
    repo.lane_set_role(lane_name, id, "research");
    *last_id = Some(id.to_string());
    bd_claim(repo, id);
    repo.set_target(id, &repo.target);
    repo.unpark(id);
    if !git_ok(&repo.repo, &["fetch", "-q", &repo.base_remote, &repo.base]) {
        hold(repo, id, None, &format!("git fetch {} {} failed", repo.base_remote, repo.base));
        return false;
    }
    if rejoin.is_none() {
        abort_sessions(repo, &wt);
    }
    signals::set_current(lane_name, &repo.attach, &repo.slug, Some(wt.clone()), Some(repo.lane_path(lane_name)));
    // The researcher reads; it needs no setup. A worktree it had to make goes again after
    // it, so the worker's round makes its own (with setup) as it always has.
    let made = !wt.is_dir();
    if made {
        if let Err(e) = make_worktree(repo, &branch, &wt, resumed) {
            hold(repo, id, Some(&wt), &format!("cannot make the worktree: {e}"));
            return false;
        }
    }
    let research_log = std::path::PathBuf::from(format!("{}.research.jsonl", logf.display()));
    let r = match &rejoin {
        Some(sid) => crate::harness::rejoin_session(repo, sid, &wt, &research_log, timeout),
        None => run_agent(
            repo,
            "bead-researcher",
            &model,
            &wt,
            &research_log,
            &prompt,
            &format!("{id} · research · round {}", n + 1),
            timeout,
            Some(&json),
        ),
    };
    cut_short(repo, id);
    // what the round made goes: its worktree, and a branch it left empty (a rejoined round's
    // too), so the worker starts fresh rather than "resuming" nothing
    let tidy = |repo: &Repo| {
        if research_leftover(repo, &branch) {
            worktree_remove(repo, &wt);
            let _ = git(&repo.repo, &["branch", "-D", &branch]);
        } else if made {
            worktree_remove(repo, &wt);
        }
    };
    if r.empty && r.rc != 124 {
        hold(repo, id, Some(&wt), &never_answered("researcher", &model, &r));
        tidy(repo);
        return false;
    }
    if let Some(b) = last_line_starting(&r.text, "BLOCKED:") {
        log(&format!("{}: {id}: the researcher found the bead cannot be done as written; parked for you", repo.slug));
        bd_note(repo, id, &format!("bead-loop {}: research ({model}) {b}", date_iminutes()));
        park(repo, id, Reason::ResearchBlocked(b), Some(&wt));
        repo.clear_target(id);
        repo.research_clear(id);
        clear_lane_of(repo, id);
        repo.release(id);
        park_cleanup(repo, &wt);
        if research_leftover(repo, &branch) {
            let _ = git(&repo.repo, &["branch", "-D", &branch]);
        }
        repo.wake();
        return false;
    }
    // A brief without the headings is kept as it is: a worse brief is still a brief. A
    // round the clock ended leaves an empty one — the worker goes without, and research
    // is not tried again for this bead until a send-back under `every` clears it.
    let brief = if r.rc == 0 { r.text.trim().to_string() } else { String::new() };
    write_file(&repo.research_path(id), &format!("{brief}\n"));
    let _ = std::fs::remove_file(repo.research_prev_path(id));
    let what = if brief.is_empty() {
        format!("research ({model}) gave no brief (exited {}); the worker goes without. Log: {}", r.rc, research_log.display())
    } else {
        format!("research ({model}) wrote the brief ({} lines)", brief.lines().count())
    };
    log(&format!("{}: {id}: {what} → dev queue", repo.slug));
    bd_note(repo, id, &format!("bead-loop {}: {what}", date_iminutes()));
    clear_lane_of(repo, id);
    repo.release(id);
    tidy(repo);
    bd_status(repo, id, "open");
    repo.wake();
    true
}

pub fn dev_one(repo: &Repo, opts: &Opts, id: Option<&str>, last_id: &mut Option<String>, lane: Option<&LaneSpec>) -> Pass {
    // The reservation holds the bead to this round (research included) until it returns.
    let (id, research, _mine) = match id {
        Some(i) => match reserve(repo, i) {
            Some(r) => (i.to_string(), needs_research(repo, i) && runnable(repo, &repo.research_model), r),
            None => return Pass::Nothing,
        },
        None => {
            // The two idle lines: every pass in a tick (the bash did), once per change in
            // the resident loop, which passes every heartbeat.
            let name = lane.map(|l| l.name.as_str()).unwrap_or("dev");
            match pick_dev_and_reserve(repo, lane) {
                Some(p) => p,
                None => {
                    crate::merge::say(
                        &format!("{}/{name}-idle", repo.slug),
                        if name == "dev" {
                            format!("{}: dev: nothing ready with label {}", repo.slug, repo.label)
                        } else {
                            format!("{}: {name}: nothing queued for this lane", repo.slug)
                        },
                    );
                    return Pass::Nothing;
                }
            }
        }
    };
    if research {
        let brief = research_one(repo, opts, &id, lane, last_id);
        // A lane goes round again, and the worker's lane takes the bead from the queue; a
        // hand-run `work` goes straight on to the worker round, the brief in its prompt.
        if opts.dry_run {
            return Pass::Nothing;
        }
        if lane.is_some() || !brief {
            return Pass::Worked;
        }
    }
    let json = bd_show(repo, &id);
    // The bead's work:NAME label (docs/design-targets.md): the checkout this round works
    // in and the GitHub repo its PR goes to. No such label is the default target; two
    // labels, or one naming no configured target, is a config mistake — held, no failure,
    // and the lane moves on (`repo` here is the fresh `Repo::load`, still the default,
    // which is exactly what `hold` needs: the beads repo's own state dir).
    let labels = bead_labels(&json);
    let repo = match repo.for_bead(&labels) {
        Ok(r) => r,
        Err(e) => {
            hold(repo, &id, None, &e);
            return Pass::Worked;
        }
    };
    let repo = &repo;
    // The bead's stage:NAME label (docs/design-providers.md): floors the failure count
    // before the stage is picked, so a bead labelled past stage 1 starts there.
    apply_stage_label(repo, &id, &labels);
    let n = repo.failures_of(&id);
    let st: StageHit = match repo.stage_for(n) {
        Some(s) => s,
        None => {
            // Picked with no stage left (the config changed under it): parked, with the question.
            log(&format!("{}: {id}: stages exhausted ({n} failures), parked", repo.slug));
            bd_status(repo, &id, "in_progress");
            park(repo, &id, Reason::Exhausted, None);
            repo.clear_target(&id);
            return Pass::Worked;
        }
    };
    let mut model = opts.model_flag.clone().unwrap_or_else(|| st.model.clone());
    let review_model = st.review.clone();
    let timeout = st.timeout;
    let hist = history(repo, &id);
    // Per target, not the whole merge queue: a PR waiting on a foreign repo's CI does not
    // stop this repo's own beads (docs/design-targets.md).
    let name = lane.map(|l| l.name.as_str()).unwrap_or("dev");
    if repo.inflight_count_for(&repo.target) >= repo.max_inflight {
        crate::merge::say(
            &format!("{}/{name}-idle", repo.slug),
            format!(
                "{}: {name}: {} in flight (max {}); waiting on CI",
                repo.slug,
                repo.inflight_count_for(&repo.target),
                repo.max_inflight
            ),
        );
        return Pass::Nothing;
    }
    let title = json.get(0).and_then(|b| b.get("title")).and_then(|t| t.as_str()).unwrap_or("").to_string();
    apply_harness_label(repo, &id, &json, &mut model);
    let branch = format!("bead/{id}");
    let wt = repo.wt(&id);
    let logf = repo.rs.join("logs").join(format!("{id}.{}", stamp()));
    // The conflict round: the PR could not merge because the branch conflicts with the
    // base. The worker is conflict_worker (default: the last stage's), and its order is
    // the rebase, not the bead. No failure was charged.
    let mut conflict = false;
    let mut rebase = String::new();
    if repo.mark(&id, "conflict").exists() {
        // The PR that earned the mark may since have closed on its own (the work landed
        // another way, as bl-eoq's did): the same `gh pr view` the merge queue uses in
        // src/merge.rs, by branch since the closing round dropped the url. Not OPEN means
        // no rebase — and if the branch already matches the base, there is nothing left
        // to do at all, so it is parked rather than looping on "no commit" forever.
        let head = repo.head_ref(&branch);
        let pr = gh(repo, &["pr", "view", &head, "--json", "state,url"])
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| serde_json::from_str::<Value>(&stdout_str(&o)).ok());
        let state = pr.as_ref().and_then(|v| v.get("state")).and_then(|s| s.as_str()).unwrap_or("").to_string();
        if !state.is_empty() && state != "OPEN" {
            let _ = std::fs::remove_file(repo.mark(&id, "conflict"));
            let _ = std::fs::remove_file(repo.mark(&id, "fixing"));
            // The worktree of the round that opened this PR is long gone (push_pr removes
            // it): the branch itself, kept as a ref in repo.repo either way (its own or
            // push_remote's remote-tracking copy), is what there is to check.
            let _ = git_ok(&repo.repo, &["fetch", "-q", &repo.base_remote, &repo.base]);
            let branch_ref = if local_branch_exists(repo, &branch) { branch.clone() } else { format!("{}/{branch}", repo.push_remote) };
            let range = format!("{}/{}...{branch_ref}", repo.base_remote, repo.base);
            if branch_exists(repo, &branch) && git_ok(&repo.repo, &["diff", "--quiet", &range]) {
                let url = pr.as_ref().and_then(|v| v.get("url")).and_then(|u| u.as_str()).unwrap_or("").to_string();
                log(&format!(
                    "{}: {id}: conflict round: its PR ({url}) is {state}, and the branch already matches {}; parked",
                    repo.slug, repo.base
                ));
                bd_status(repo, &id, "in_progress");
                park(repo, &id, Reason::PrClosed(url), None);
                repo.clear_target(&id);
                return Pass::Worked;
            }
            log(&format!("{}: {id}: conflict round: its PR is {state}, not open; back to a plain round", repo.slug));
        } else {
            conflict = true;
            if !repo.conflict_worker.is_empty() {
                model = repo.conflict_worker.clone();
            } else if let Some(last) = repo.stage_for(repo.last_stage_start()) {
                model = opts.model_flag.clone().unwrap_or(last.model);
            }
            if !runnable(repo, &model) {
                log(&format!(
                    "{}: {id}: conflict round needs {model}, which cannot run now ({}); waiting",
                    repo.slug,
                    crate::harness::why_not(repo, &model)
                ));
                bd_status(repo, &id, "open");
                return Pass::Nothing;
            }
            rebase = rebase_order(&repo.base_remote, &repo.base);
            log(&format!("{}: {id}: conflict round: rebase onto {} by {model}", repo.slug, repo.base));
        }
    }
    // A branch left from an earlier round (sent back by review or CI) is resumed, not
    // restarted: the worker fixes its commit. A dev-side failure deleted the branch.
    let resumed = branch_exists(repo, &branch);
    let research = repo.research_of(&id).unwrap_or_default();
    if !opts.dry_run && needs_research(repo, &id) {
        // research is on, but the researcher is on other work: the worker does not wait
        log(&format!("{}: {id}: no brief yet; the worker goes without rather than wait for {}", repo.slug, repo.research_model));
    }
    // A worker session of this bead still running on the server since the last process
    // (recover found it): the round is that session, waited on, not a new one — and the
    // worktree it works in is left alone. Without the worktree there is nothing to rejoin.
    let rejoin = repo
        .rejoin_of(&id)
        .filter(|(_, kind)| kind == "worker")
        .map(|(sid, _)| sid)
        .filter(|_| wt.is_dir())
        .filter(|sid| opts.dry_run || crate::harness::rejoin_fits(repo, &id, sid, "worker"));
    repo.rejoin_clear(&id);
    log(&format!(
        "{}: dev: bead {id} — {title} ({n} failures, worker {model}, reviewer {}{}{}{})",
        repo.slug,
        if review_model.is_empty() { "none" } else { &review_model },
        if resumed { ", resuming the branch" } else { "" },
        if conflict { ", rebase" } else { "" },
        rejoin.as_deref().map(|s| format!(", rejoining session {s}")).unwrap_or_default()
    ));
    if opts.dry_run {
        println!(
            "--- failures: {n}  model: {}  base: {}  setup: {}  gate: {}  review: {}  merge: {}",
            if model.is_empty() { "agent default" } else { &model },
            repo.base,
            if repo.setup.is_empty() { "none" } else { &repo.setup },
            if repo.gate.is_empty() { "none" } else { &repo.gate },
            if review_model.is_empty() { "none" } else { &review_model },
            repo.merge
        );
        println!("{}", dev_prompt(&json, &branch, &repo.base, resumed, &repo.gate, &rebase, &research, &hist, ""));
        return Pass::Nothing;
    }
    *last_id = Some(id.clone());
    if !opts.local {
        crate::config::need("gh");
    }

    // The marker carries the lane's name (gpu, cpu, claude — or dev, the default pair's),
    // so status shows the lane on it and two lanes in one repo never share a file.
    let lane_name = lane.map(|l| l.name.as_str()).unwrap_or("dev");
    repo.lane_set(lane_name, &id);
    bd_claim(repo, &id);
    // The target this bead claimed on, for the review lane, the merge watcher, `open`,
    // `answer` and `escalate` to read back (`Repo::for_id`) — "" (the default) removes
    // any stale file from an earlier claim on a different target.
    repo.set_target(&id, &repo.target);
    // Reopened by hand: the old question is history.
    repo.unpark(&id);
    if !git_ok(&repo.repo, &["fetch", "-q", &repo.base_remote, &repo.base]) {
        hold(repo, &id, None, &format!("git fetch {} {} failed", repo.base_remote, repo.base));
        return Pass::Worked;
    }
    if rejoin.is_none() {
        abort_sessions(repo, &wt); // a killed earlier round may have left one running here
    }
    signals::set_current(lane_name, &repo.attach, &repo.slug, Some(wt.clone()), Some(repo.lane_path(lane_name)));
    let kept = rejoin.is_some() || (wt.is_dir() && resumed && git_ok(&wt, &["rev-parse", "-q", "--verify", "HEAD"]));
    if !kept {
        if wt.exists() {
            worktree_remove(repo, &wt);
        }
        // Git refusing the worktree is the world's doing, not the bead's: held, no
        // failure, the lane on to the next bead (a stale registration once killed the loop).
        if let Err(e) = make_worktree(repo, &branch, &wt, resumed) {
            hold(repo, &id, Some(&wt), &format!("cannot make the worktree: {e}"));
            return Pass::Worked;
        }
        if !repo.setup.is_empty() {
            log(&format!("{}: setup: {}", repo.slug, repo.setup));
            let setup_path = std::path::PathBuf::from(format!("{}.setup", logf.display()));
            if !run_shell_to(&repo.setup, &wt, &setup_path) {
                // Setup runs on a fresh worktree of the base: it cannot be the bead's fault.
                let tail = tail_lines(&read_to_string(&setup_path).unwrap_or_default(), 15);
                hold(repo, &id, Some(&wt), &format!("setup failed: {}\n{tail}", repo.setup));
                return Pass::Worked;
            }
        }
    }

    // A foreign target's worktree has none of the beads repo's own skills (docs/design-
    // targets.md "House rules travel"): the default target is the beads repo itself, so
    // there is nothing to link. `.agents/` goes in the target checkout's shared exclude
    // file (worktrees share `--git-common-dir`), never committed to its tree.
    let house = if repo.target.is_empty() {
        String::new()
    } else {
        let linked = link_skills(&repo.beads.join(".agents").join("skills"), &wt);
        if linked.is_empty() {
            String::new()
        } else {
            let common_dir = git_out(&wt, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).trim().to_string();
            ensure_line(&std::path::PathBuf::from(common_dir).join("info").join("exclude"), ".agents/");
            log(&format!("{}: {id}: house rules linked: {}", repo.slug, linked.join(", ")));
            repo.beads.to_string_lossy().to_string()
        }
    };
    let prompt = dev_prompt(&json, &branch, &repo.base, resumed, &repo.gate, &rebase, &research, &hist, &house);

    let title_w = format!("{id} · worker · round {}", n + 1);
    let worker_log = std::path::PathBuf::from(format!("{}.worker.jsonl", logf.display()));
    let r = match &rejoin {
        Some(sid) => crate::harness::rejoin_session(repo, sid, &wt, &worker_log, timeout),
        None => run_agent(repo, "bead-worker", &model, &wt, &worker_log, &prompt, &title_w, timeout, Some(&json)),
    };
    cut_short(repo, &id);
    if r.empty && r.rc != 124 {
        // Nothing from the model and it was not the clock: the harness or its server, not
        // the model. No failure; the bead waits, the lane backs off.
        hold(repo, &id, Some(&wt), &never_answered("worker", &model, &r));
        return Pass::Worked;
    }
    if r.rc != 0 {
        let note =
            r.stalled.clone().unwrap_or_else(|| format!("worker exited {} (timeout={timeout} s). Log: {}", r.rc, worker_log.display()));
        let pm = postmortem(repo, &id, &wt, &json, &r.text, "", &logf);
        send_back(repo, &id, &wt, false, &format!("{note}{pm}"), &model, st.last, Some(&logf));
        return Pass::Worked;
    }
    if let Some(b) = last_line_starting(&r.text, "BLOCKED:") {
        send_back(repo, &id, &wt, false, &b, &model, st.last, Some(&logf));
        return Pass::Worked;
    }
    if !settle_worktree(repo, &wt, &format!("{id}: {title}")) {
        // A rebase round that ends DONE with nothing to commit is not a failure to send
        // back and retry — it is a bl-eoq: the branch already matches the base, so every
        // retry says the same "no commit" forever. Parked, not looped.
        if conflict && last_line_starting(&r.text, "DONE:").is_some() {
            log(&format!("{}: {id}: conflict round: DONE with no diff against {} — parked", repo.slug, repo.base));
            let _ = std::fs::remove_file(repo.mark(&id, "conflict"));
            let _ = std::fs::remove_file(repo.mark(&id, "fixing"));
            bd_status(repo, &id, "in_progress");
            park(repo, &id, Reason::Delivered, Some(&wt));
            clear_lane_of(repo, &id);
            repo.release(&id);
            repo.clear_target(&id);
            park_cleanup(repo, &wt);
            repo.wake();
            return Pass::Worked;
        }
        let note = format!("worker made no commit. Last words: {}", tail_lines(&r.text, 3));
        let pm = postmortem(repo, &id, &wt, &json, &r.text, "", &logf);
        send_back(repo, &id, &wt, false, &format!("{note}{pm}"), &model, st.last, Some(&logf));
        return Pass::Worked;
    }
    // The gate gets one fix round inside the lane: a compiler message is the cheapest review there is.
    let gate_log = std::path::PathBuf::from(format!("{}.gate", logf.display()));
    let mut final_text = r.text;
    if !run_gate(repo, &wt, &gate_log) {
        cut_short(repo, &id);
        log(&format!("{}: {id}: gate failed, fix round", repo.slug));
        let gate_out = tail_lines(&read_to_string(&gate_log).unwrap_or_default(), 40);
        let fix_prompt = gate_fix_prompt(&prompt, &repo.gate, &gate_out);
        let fix_log = std::path::PathBuf::from(format!("{}.worker-gate.jsonl", logf.display()));
        let r2 =
            run_agent(repo, "bead-worker", &model, &wt, &fix_log, &fix_prompt, &format!("{id} · worker · gate fix"), timeout, Some(&json));
        cut_short(repo, &id);
        if r2.empty && r2.rc != 124 {
            // The fix round never reached the model either: held. The round's commit stays
            // on its branch in its worktree, and the next round resumes it.
            hold(repo, &id, Some(&wt), &never_answered("worker", &model, &r2));
            return Pass::Worked;
        }
        if r2.rc != 0 {
            let note =
                r2.stalled.clone().unwrap_or_else(|| format!("worker exited {} in gate fix round. Log: {}", r2.rc, fix_log.display()));
            let pm = postmortem(repo, &id, &wt, &json, &r2.text, &gate_out, &logf);
            send_back(repo, &id, &wt, false, &format!("{note}{pm}"), &model, st.last, Some(&logf));
            return Pass::Worked;
        }
        if let Some(b) = last_line_starting(&r2.text, "BLOCKED:") {
            send_back(repo, &id, &wt, false, &format!("gate fix round: {b}"), &model, st.last, Some(&logf));
            return Pass::Worked;
        }
        settle_worktree(repo, &wt, &format!("{id}: fix the gate"));
        let gate2 = std::path::PathBuf::from(format!("{}.gate-2", logf.display()));
        if !run_gate(repo, &wt, &gate2) {
            cut_short(repo, &id);
            let tail = tail_lines(&read_to_string(&gate2).unwrap_or_default(), 15);
            let note = format!("gate failed twice: {}\n{tail}", repo.gate);
            let pm = postmortem(repo, &id, &wt, &json, &r2.text, &tail, &logf);
            send_back(repo, &id, &wt, false, &format!("{note}{pm}"), &model, st.last, Some(&logf));
            return Pass::Worked;
        }
        final_text = r2.text;
    }

    // Into the review queue, with the worker's last words for the reviewer.
    let done = last_line_starting(&final_text, "DONE:").unwrap_or_default();
    if !repo.precheck_model.is_empty() {
        // The precheck never blocks a round and never holds a bead: a skip falls through
        // to the review queue exactly as a bare `precheck_model` would.
        let range = format!("{}/{}...HEAD", repo.base_remote, repo.base);
        let stat = git_out(&wt, &["diff", &range, "--stat"]);
        let diff = git_out(&wt, &["diff", &range]);
        let diff = cut_bytes(&diff, 24000);
        let precheck_log = std::path::PathBuf::from(format!("{}.precheck.jsonl", logf.display()));
        let pc = run_agent(
            repo,
            "bead-prechecker",
            &repo.precheck_model,
            &wt,
            &precheck_log,
            &precheck_prompt(&json, &crate::park::last_round(repo, &id), &done, &stat, diff),
            &format!("{id} · precheck"),
            180,
            Some(&json),
        );
        cut_short(repo, &id);
        let pm = &repo.precheck_model;
        if pc.empty || pc.rc != 0 {
            let why = if pc.empty { "no answer".to_string() } else { format!("exited {}", pc.rc) };
            log(&format!("{}: {id}: precheck ({pm}) skipped: {why}", repo.slug));
        } else {
            match precheck_verdict(&pc.text) {
                Precheck::Pass => log(&format!("{}: {id}: precheck ({pm}): PASS", repo.slug)),
                Precheck::Unparsed => log(&format!("{}: {id}: precheck ({pm}) skipped: no verdict line", repo.slug)),
                Precheck::SendBack(block) => {
                    send_back(
                        repo,
                        &id,
                        &wt,
                        false,
                        &format!("precheck ({pm}) sent back:\n{}", cut_bytes(&block, 4000)),
                        &model,
                        st.last,
                        Some(&logf),
                    );
                    return Pass::Worked;
                }
            }
        }
    }
    write_file(&repo.review_path(&id), &format!("{done}\n"));
    repo.release(&id);
    repo.lane_clear(lane_name);
    signals::clear_current(lane_name);
    log(&format!(
        "{}: {id}: gate passed → review queue ({})",
        repo.slug,
        if review_model.is_empty() { "no reviewer: straight to PR".to_string() } else { review_model }
    ));
    repo.wake();
    Pass::Worked
}

/// `grep '^PREFIX' | tail -1`
fn last_line_starting(text: &str, prefix: &str) -> Option<String> {
    text.lines().rfind(|l| l.starts_with(prefix)).map(str::to_string)
}

/// `gh pr create` for `head`: `--repo pr_repo` when it is known, `--base`/`--head` and
/// the title and body given. Shared with `publish` (human.rs), which opens the PR an
/// `open_pr = "ask"` round left waiting in proposed/ — the operator's title/body, or the
/// proposal's own, exactly as this would have opened it from the review lane.
pub fn create_pr(repo: &Repo, head: &str, title: &str, body: &str) -> Result<String, String> {
    let repo_args: Vec<&str> = if repo.pr_repo.is_empty() { vec![] } else { vec!["--repo", &repo.pr_repo] };
    let mut create_args = vec!["pr", "create"];
    create_args.extend(repo_args.iter().copied());
    create_args.extend(["--base", &repo.base, "--head", head, "--title", title, "--body", body]);
    match gh(repo, &create_args) {
        Ok(o) if o.status.success() => Ok(stdout_str(&o).trim().to_string()),
        Ok(o) => Err(tail_lines(stderr_str(&o).trim(), 3).to_string()),
        Err(e) => die(&format!("gh: {e}")),
    }
}

/// `review_one [ID]`
pub fn review_one(repo: &Repo, opts: &Opts, id: Option<&str>, lane: Option<&LaneSpec>) -> Pass {
    let (id, _mine) = match id {
        Some(i) => match reserve(repo, i) {
            Some(r) => (i.to_string(), r),
            // another slot took its review first (lane_pass hands the worker slot the
            // review too, and the queue shows it to every slot meanwhile)
            None => return Pass::Nothing,
        },
        None => match pick_and_reserve(repo, "review", lane) {
            Some(x) => x,
            None => return Pass::Nothing,
        },
    };
    // The target dev_one resolved and wrote at claim (`state.rs target_of`): the same
    // checkout and PR repo act on this bead from here on, whichever the default is.
    let repo = &repo.for_id(&id);
    let n = repo.failures_of(&id);
    let (mut review_model, model, timeout) = match repo.stage_for(n) {
        Some(st) => (st.review, st.model, st.timeout),
        None => (repo.review_model.clone(), repo.model.clone(), repo.worker_timeout),
    };
    let model = opts.model_flag.clone().unwrap_or(model);
    let branch = format!("bead/{id}");
    let wt = repo.wt(&id);
    let logf = repo.rs.join("logs").join(format!("{id}.{}", stamp()));
    let final_text = read_to_string(&repo.review_path(&id)).unwrap_or_default();
    let final_text = final_text.trim_end_matches('\n').to_string();
    let json = bd_show(repo, &id);
    let title = json.get(0).and_then(|b| b.get("title")).and_then(|t| t.as_str()).unwrap_or("").to_string();
    // The worktree may be gone (a crash, a hand `worktree remove`): rebuild it from the
    // branch rather than review an empty directory.
    if !wt.join(".git").exists() && branch_exists(repo, &branch) {
        worktree_remove(repo, &wt);
        if let Err(e) = make_worktree(repo, &branch, &wt, true) {
            hold(repo, &id, None, &format!("cannot rebuild the worktree for the review: {e}"));
            return Pass::Worked;
        }
        log(&format!("{}: {id}: worktree rebuilt from {branch} for the review", repo.slug));
    }
    let lane_name = lane.map(|l| l.name.as_str()).unwrap_or("review");
    repo.lane_set(lane_name, &id);
    signals::set_current(lane_name, &repo.attach, &repo.slug, Some(wt.clone()), Some(repo.lane_path(lane_name)));
    let mut verdict = String::new();
    if !review_model.is_empty() {
        // A reviewer session of this bead still running on the server since the last
        // process (recover found it): waited on, not started again.
        let rejoin = repo
            .rejoin_of(&id)
            .filter(|(_, kind)| kind == "reviewer")
            .map(|(sid, _)| sid)
            .filter(|sid| crate::harness::rejoin_fits(repo, &id, sid, "reviewer"));
        repo.rejoin_clear(&id);
        log(&format!(
            "{}: review: {id} by {review_model} ({n} failures{})",
            repo.slug,
            rejoin.as_deref().map(|s| format!(", rejoining session {s}")).unwrap_or_default()
        ));
        let review_log = std::path::PathBuf::from(format!("{}.review.jsonl", logf.display()));
        let r = match &rejoin {
            Some(sid) => crate::harness::rejoin_session(repo, sid, &wt, &review_log, timeout),
            None => {
                let range = format!("{}/{}...HEAD", repo.base_remote, repo.base);
                let stat = git_out(&wt, &["diff", &range, "--stat"]);
                let diff = git_out(&wt, &["diff", &range]);
                let diff = cut_bytes(&diff, 60000);
                let prompt = review_prompt(&json, &repo.base, &crate::park::last_round(repo, &id), &final_text, &stat, diff);
                run_agent(
                    repo,
                    "bead-reviewer",
                    &review_model,
                    &wt,
                    &review_log,
                    &prompt,
                    &format!("{id} · reviewer · round {}", n + 1),
                    timeout,
                    Some(&json),
                )
            }
        };
        cut_short(repo, &id);
        if r.empty && r.rc != 124 {
            hold(repo, &id, None, &never_answered("reviewer", &review_model, &r));
            return Pass::Worked;
        }
        if r.rc != 0 {
            let _ = std::fs::remove_file(repo.review_path(&id));
            let note = r.stalled.clone().unwrap_or_else(|| format!("reviewer exited {}. Log: {}", r.rc, review_log.display()));
            send_back(repo, &id, &wt, true, &note, &model, false, Some(&logf));
            return Pass::Worked;
        }
        if r.text.trim().is_empty() {
            // A clean exit with not one word (a step started, then nothing): no verdict on
            // the work, so nothing the worker can fix. Held like a reviewer that never
            // answered, no failure charged; not a REJECT with an empty work order.
            hold(
                repo,
                &id,
                None,
                &format!("reviewer {review_model} gave no verdict (it exited 0 with no text). Log: {}", review_log.display()),
            );
            return Pass::Worked;
        }
        if !r.text.lines().any(|l| l.starts_with("APPROVE:")) {
            let _ = std::fs::remove_file(repo.review_path(&id));
            // The whole of the reviewer's verdict travels — the REJECT line and the block for
            // the worker under it — not a 600-character summary of it: it is the work order.
            send_back(
                repo,
                &id,
                &wt,
                true,
                &format!("review ({review_model}) rejected:\n{}", cut_bytes(&reject_block(&r.text), 4000)),
                &model,
                false,
                Some(&logf),
            );
            return Pass::Worked;
        }
        log(&format!("{}: {id}: review approved", repo.slug));
        verdict = r.text;
    } else {
        review_model.clear();
    }
    let _ = std::fs::remove_file(repo.review_path(&id));

    if opts.local {
        log(&format!("{}: --local: branch {branch} is ready in {}; nothing pushed", repo.slug, wt.display()));
        bd_note(repo, &id, &format!("bead-loop: worked locally on {branch} (not pushed)"));
        repo.lane_clear(lane_name);
        signals::clear_current(lane_name);
        return Pass::Worked;
    }

    // Function to store PR details in the proposed directory for manual publishing
    fn store_proposed_pr(repo: &Repo, id: &str, title: &str, body: &str, head: &str, compare_url: &str) -> Result<(), String> {
        let proposed_path = repo.rs.join("proposed").join(id);
        let pr_details = json!({
            "title": title,
            "body": body,
            "head": head,
            "base": repo.base,
            "pr_repo": repo.pr_repo,
            "compare_url": compare_url
        });

        write_file(&proposed_path, &pr_details.to_string());
        Ok(())
    }

    match git(&wt, &["push", "-q", "-u", &repo.push_remote, &branch, "--force-with-lease"]) {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            write_file(&repo.review_path(&id), &format!("{final_text}\n"));
            hold(repo, &id, None, &format!("push of {branch} refused: {}", tail_lines(stderr_str(&o).trim(), 3)));
            return Pass::Worked;
        }
        Err(e) => die(&format!("git push: {e}")),
    }
    let ac = json.get(0).and_then(|b| b.get("acceptance_criteria")).and_then(|v| v.as_str()).unwrap_or("");
    let worker_line = cut_bytes(final_text.lines().last().unwrap_or(""), 500).to_string();
    let reviewer_line = if review_model.is_empty() {
        String::new()
    } else {
        format!("Reviewer ({review_model}): {}", cut_bytes(&last_line_starting(&verdict, "APPROVE:").unwrap_or_default(), 500))
    };
    let body = if repo.pr_style == "plain" {
        let desc = json.get(0).and_then(|b| b.get("description")).and_then(|v| v.as_str()).unwrap_or("");
        pr_body_plain(&id, desc, ac, &worker_line)
    } else {
        pr_body(&id, &title, ac, &worker_line, &reviewer_line)
    };
    let title_line = pr_title(&repo.pr_style, &id, &title);
    // The head gh's pr create/list --head take: the bare branch on our own repos, else
    // OWNER:BRANCH (config.rs Repo::head_ref) — and --repo pr_repo, when it is known
    // (empty in the test suite's local-path remotes, where the owner cannot be parsed).
    let head = repo.head_ref(&branch);
    let repo_args: Vec<&str> = if repo.pr_repo.is_empty() { vec![] } else { vec!["--repo", &repo.pr_repo] };
    // A branch sent back by CI already has its PR: the push updated it.
    let mut list_args = vec!["pr", "list", "--state", "open"];
    list_args.extend(repo_args.iter().copied());
    list_args.extend(["--head", &head, "--json", "url", "--jq", ".[0].url // empty"]);
    let existing = crate::shell::gh_stdout_any(repo, &list_args).trim().to_string();
    if existing.is_empty() && repo.open_pr.as_deref() == Some("ask") {
        let compare_url = format!("https://github.com/{}/compare/{}...{head}?expand=1", repo.pr_repo, repo.base);
        if let Err(e) = store_proposed_pr(repo, &id, &title_line, &body, &head, &compare_url) {
            write_file(&repo.review_path(&id), &format!("{final_text}\n"));
            hold(repo, &id, None, &format!("failed to store proposed PR: {e}"));
            return Pass::Worked;
        }
        bd_comment(repo, &id, &format!("bead-loop: ready to publish: {compare_url}"));
        log(&format!("{}: {id}: pushed to {head}, PR details stored in proposed/", repo.slug));
        repo.release(&id);
        repo.lane_clear(lane_name);
        signals::clear_current(lane_name);
        repo.wake();
        return Pass::Worked;
    }
    let url = if !existing.is_empty() {
        log(&format!("{}: {id}: pushed a new round to {existing}", repo.slug));
        bd_comment(repo, &id, &format!("bead-loop: pushed round {} to {existing}", n + 1));
        existing
    } else {
        match create_pr(repo, &head, &title_line, &body) {
            Ok(url) => {
                bd_comment(repo, &id, &format!("bead-loop: opened {url}"));
                log(&format!("{}: opened {url}", repo.slug));
                url
            }
            Err(e) => {
                write_file(&repo.review_path(&id), &format!("{final_text}\n"));
                hold(repo, &id, None, &format!("gh pr create failed: {e}"));
                return Pass::Worked;
            }
        }
    };
    write_file(&repo.inflight_path(&id), &format!("{url}\n"));
    for m in ["red", "fixing", "conflict"] {
        let _ = std::fs::remove_file(repo.mark(&id, m));
    }
    repo.release(&id);
    if repo.merge == "pipeline" {
        crate::merge::hand_to_pipeline(repo, &id, &url);
    }
    let _ = git(&repo.repo, &["worktree", "remove", "--force", &wt.to_string_lossy()]);
    repo.lane_clear(lane_name);
    signals::clear_current(lane_name);
    repo.wake();
    Pass::Worked
}

/// `work REPO [ID]`: one bead through both lanes, in this process, in order: what --local
/// and a hand-run check want. A bead the dev lane sends back stops there.
pub fn work(repo: &Repo, opts: &Opts, id: Option<&str>) {
    let mut last = None;
    if dev_one(repo, opts, id, &mut last, None) == Pass::Worked {
        if let Some(id) = last {
            if repo.review_path(&id).exists() {
                review_one(repo, opts, Some(&id), None);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn render_bead_shape() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D","priority":2,"labels":[]}]);
        let s = render_bead(&j);
        assert!(s.starts_with("id: t-1\ntitle: T\ntype: task   priority: P2\n\nDESCRIPTION:\nD\n\nACCEPTANCE CRITERIA:\n(none given"));
        assert!(!s.contains("NOTES:"));
    }
    #[test]
    fn last_line() {
        assert_eq!(last_line_starting("x\nDONE: a\nDONE: b\n", "DONE:").as_deref(), Some("DONE: b"));
        assert!(last_line_starting("nothing", "DONE:").is_none());
    }
    #[test]
    fn render_bead_carries_everything_the_prompt_needs() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"Do the thing","description":"Edit work.txt","acceptance_criteria":"work.txt exists",
            "priority":"1","issue_type":"bug","design":"like so","notes":"operator 2026: use the other flag"}]);
        let s = render_bead(&j);
        assert!(s.contains("type: bug   priority: P1"), "a string priority reads like a number: {s}");
        assert!(s.contains("ACCEPTANCE CRITERIA:\nwork.txt exists"));
        assert!(s.contains("\n\nDESIGN:\nlike so"));
        assert!(s.ends_with("\n\nNOTES:\noperator 2026: use the other flag"), "the notes come last, so the next round reads the answer");
        assert!(render_bead(&serde_json::json!([])).starts_with("id: \ntitle: "), "an empty array renders empty fields");
        let logged: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D",
            "notes":"\nbead-loop 2026-09-18T17:05+00:00: research (x) wrote the brief (9 lines)"}]);
        assert!(!render_bead(&logged).contains("NOTES:"), "only the loop's lines: no NOTES at all");
        assert!(
            render_bead_whole(&logged).ends_with("NOTES:\n\nbead-loop 2026-09-18T17:05+00:00: research (x) wrote the brief (9 lines)"),
            "open's is whole"
        );
    }
    #[test]
    fn people_notes_leave_the_loops_lines_out() {
        let notes = [
            "Filed with: the flag is --dry-run",
            "  (checked in cli.ts)",
            "bead-loop round 1 (stub/worker) 2026-09-18T17:05+00:00: review (stub/reviewer) rejected:",
            "  REJECT: x.ts:1 wrong",
            "  ",
            "  For the worker:",
            "  - What to do: y",
            "bead-loop 2026-09-18T17:06+00:00: round interrupted by a stop; back in the dev queue, no failure charged",
            "a note appended by hand",
            "bead-loop: CI red on https://github.com/example/repo/pull/7 (ci); PR left open",
            "bead-loop 2026-09-18T17:07+00:00: parked (stages exhausted after 3 rounds). Which flag?",
            "  Or both?",
            "operator 2026-09-18T18:00+00:00: --dry-run",
        ]
        .join("\n");
        assert_eq!(
            people_notes(&format!("\n{notes}")),
            [
                "Filed with: the flag is --dry-run",
                "  (checked in cli.ts)",
                "a note appended by hand",
                "bead-loop 2026-09-18T17:07+00:00: parked (stages exhausted after 3 rounds). Which flag?",
                "  Or both?",
                "operator 2026-09-18T18:00+00:00: --dry-run",
            ]
            .join("\n"),
            "people's lines, and the question the answer replies to"
        );
        assert_eq!(people_notes("bead-loop 2026-09-18T17:05+00:00: held, no failure charged: x"), "");
        assert_eq!(people_notes("bead-loopy is a word here"), "bead-loopy is a word here", "not the loop's prefix");
    }
    #[test]
    fn harness_label_picks_the_worker_harness() {
        assert_eq!(
            harness_for(&["harness:opencode"], "aider:stub/worker"),
            ("stub/worker".into(), Some("label harness:opencode: worker stub/worker runs in opencode, not aider".into()))
        );
        assert_eq!(
            harness_for(&["harness:aider"], "stub/worker"),
            ("aider:stub/worker".into(), Some("label harness:aider: worker aider:stub/worker runs in aider, not opencode".into()))
        );
        assert_eq!(harness_for(&["harness:aider"], "claude/opus"), ("claude/opus".into(), None), "claude/* stays in Claude Code");
        assert_eq!(harness_for(&["harness:aider"], "aider:x/y"), ("aider:x/y".into(), None), "already under aider: nothing to say");
        assert_eq!(harness_for(&["harness:opencode"], "stub/worker"), ("stub/worker".into(), None));
        assert_eq!(harness_for(&["delegate:local"], "aider:x/y"), ("aider:x/y".into(), None), "no harness label: the stage's choice");
    }
    #[test]
    fn dev_prompt_says_fresh_or_resumed_and_carries_the_history() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D"}]);
        let fresh = dev_prompt(&j, "bead/t-1", "main", false, "", "", "", "", "");
        assert!(fresh.contains("<bead>\nid: t-1\n"), "the bead rendered into the prompt");
        assert!(fresh.contains("You are on branch bead/t-1, a fresh worktree of main."));
        assert!(!fresh.contains("<previous-attempts>"), "first attempt has no history");
        assert!(!fresh.contains("The gate this branch must pass"), "no gate line when the gate is empty");
        assert!(fresh.ends_with("DONE: <evidence> or BLOCKED: <note>."));
        let gated = dev_prompt(&j, "bead/t-1", "main", false, "cargo test", "", "", "", "");
        assert!(
            gated.contains("You are on branch bead/t-1, a fresh worktree of main. The gate this branch must pass before review: `cargo test`. Run it before you write DONE:."),
            "the gate line follows the branch sentence"
        );
        assert!(
            gated.find("The gate this branch must pass").unwrap() < gated.find("DONE: <evidence> or BLOCKED: <note>.").unwrap(),
            "gate line comes before the DONE line"
        );
        let hist = "round 1 (stub/fast): worker made no commit\nround 2 (stub/fast): review (r) rejected: REJECT: work.txt:1 For the worker: - What is wrong: x";
        let again = dev_prompt(&j, "bead/t-1", "main", true, "", "", "", hist, "");
        assert!(
            again.contains("which already carries your earlier commit(s) for this bead: fix them in place rather than starting over"),
            "told to fix, not restart"
        );
        assert!(again.contains("a work order from the senior reviewer"), "told to act on it");
        assert!(again.contains(&format!("<previous-attempts>\n{hist}\n</previous-attempts>")), "the notes verbatim");
        let rebase = dev_prompt(&j, "bead/t-1", "main", true, "", &rebase_order("origin", "main"), "", "", "");
        assert!(rebase.contains("Your job this round is the rebase, not new work. Run: git fetch origin && git rebase origin/main"));
        assert!(rebase.find("rebase origin/main").unwrap() > rebase.find("</bead>").unwrap(), "the order comes after the bead");
    }
    #[test]
    fn research_prompt_carries_bead_and_previous_brief() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"Edit work.txt"}]);
        let first = research_prompt(&j, "main", "", "");
        assert!(first.contains("<bead>\nid: t-1\n"), "the bead rendered");
        assert!(first.contains("a fresh worktree of main"));
        assert!(first.contains("Files / Shape / Check / Pitfalls") && first.contains("at most sixty lines"));
        assert!(first.ends_with("BLOCKED: <the false claim, with file:line>."));
        assert!(!first.contains("<previous-research>"), "nothing to refine the first time");
        let again = research_prompt(&j, "main", "Files:\n- work.txt\n", "round 1 (stub/worker): worker made no commit\n");
        assert!(again.contains("<previous-research>\nFiles:\n- work.txt\n</previous-research>"));
        assert!(again.contains("<send-back>\nround 1 (stub/worker): worker made no commit\n</send-back>"));
        assert!(again.contains("Refine the brief") && again.contains("do not start over"));
        assert!(again.find("</bead>").unwrap() < again.find("<previous-research>").unwrap(), "the bead first");
        assert!(!again.contains("<previous-attempts>"), "refining: the one note, under <send-back>");
        let hist = "round 1 (stub/worker): worker made no commit\nround 2 (stub/worker): REJECT: x";
        let after_park = research_prompt(&j, "main", "", hist);
        assert!(after_park.contains(&format!("<previous-attempts>\n{hist}\n</previous-attempts>")), "no brief to refine: the rounds");
        assert!(!after_park.contains("<previous-research>"));
    }
    #[test]
    fn dev_prompt_carries_the_research_before_the_history() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D"}]);
        let p = dev_prompt(&j, "bead/t-1", "main", false, "", "", "Files:\n- work.txt\n", "round 1 (x): y", "");
        assert!(p.contains("<research>\nFiles:\n- work.txt\n</research>"), "the brief verbatim");
        assert!(p.find("</research>").unwrap() < p.find("<previous-attempts>").unwrap(), "before the history");
        assert!(!dev_prompt(&j, "bead/t-1", "main", false, "", "", "  \n", "", "").contains("<research>"), "a blank brief is none");
    }
    #[test]
    fn dev_prompt_names_house_rules_only_when_linked() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D"}]);
        let housed = dev_prompt(&j, "bead/t-1", "main", false, "", "", "", "", "/src/beads");
        assert!(housed.contains("House rules"), "the house-rules sentence when house is set");
        assert!(housed.contains("/src/beads"), "the link named in the sentence");
        let unhoused = dev_prompt(&j, "bead/t-1", "main", false, "", "", "", "", "");
        assert!(!unhoused.contains("House rules"), "no house-rules sentence when house is empty");
    }
    #[test]
    fn gate_fix_prompt_feeds_the_gate_back() {
        let p = gate_fix_prompt("PROMPT", "cargo test", "error[E0308]\n  --> x.rs:1");
        assert!(p.starts_with("PROMPT\n\nYour commit on this branch failed the repository's gate: `cargo test`."));
        assert!(p.ends_with("<gate-output>\nerror[E0308]\n  --> x.rs:1\n</gate-output>"));
    }
    #[test]
    fn postmortem_prompt_carries_bead_transcript_and_gate() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D","acceptance_criteria":"AC"}]);
        let p = postmortem_prompt(&j, "I tried this.\nBLOCKED: no such flag", "error[E0308]");
        assert!(p.contains("<bead>\nid: t-1"));
        assert!(p.contains("ACCEPTANCE CRITERIA:\nAC"));
        assert!(p.contains("<worker-transcript>\nI tried this.\nBLOCKED: no such flag\n</worker-transcript>"));
        assert!(p.contains("<gate-output>\nerror[E0308]\n</gate-output>"));
        assert!(p.contains("1. What the worker tried."));
        assert!(p.ends_with("do not guess what the worker meant. No verdict, no format beyond the three numbered lines."));
        let no_gate = postmortem_prompt(&j, "text", "");
        assert!(!no_gate.contains("<gate-output>"), "no gate output when there was none");
    }
    #[test]
    fn review_prompt_carries_report_and_diff() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D"}]);
        let p = review_prompt(&j, "main", "", "DONE: did it", " work.txt | 1 +\n", "diff --git a/work.txt");
        assert!(p.contains("The diff against main is under <diff>"));
        assert!(p.contains("<worker-report>\nDONE: did it\n</worker-report>"));
        assert!(p.contains("<diff>\n work.txt | 1 +\ndiff --git a/work.txt\n</diff>"), "stat, then the diff");
        assert!(p.ends_with("the worker acts on that block alone."));
        assert!(!p.contains("<last-round>"), "a first round: no earlier note");
        let last = "round 1 (stub/worker):\nreview (stub/reviewer) rejected:\nREJECT: x.ts:1 wrong\n\nFor the worker:\n- How to check: grep -c fixed x.ts";
        let again = review_prompt(&j, "main", last, "DONE: did it", "", "diff");
        assert!(again.contains(&format!("<last-round>\n{last}\n</last-round>")), "the note whole, newlines kept");
        assert!(again.find("</bead>").unwrap() < again.find("<last-round>").unwrap(), "after the bead");
        assert!(again.find("</last-round>").unwrap() < again.find("<worker-report>").unwrap(), "before the report");
    }
    #[test]
    fn the_whole_rejection_travels() {
        let text = "I looked at it.\nREJECT: work.txt:1 wrong, fix it\nFor the worker:\n- What is wrong: work.txt:1 says round 1\n- What to do: append the word fixed\n- How to check: grep -c fixed work.txt prints 1";
        let block = reject_block(text);
        assert!(block.starts_with("REJECT: work.txt:1 wrong, fix it\nFor the worker:"), "from the REJECT line on");
        assert!(block.ends_with("- How to check: grep -c fixed work.txt prints 1"), "to the end");
        assert!(!block.contains("I looked at it."), "what came before it does not");
        assert_eq!(reject_block("APPROVE: fine"), "", "nothing without a REJECT line");
    }
    #[test]
    fn precheck_prompt_carries_bead_report_and_diff() {
        let j: Value = serde_json::json!([{"id":"t-1","title":"T","description":"D"}]);
        let p = precheck_prompt(&j, "", "DONE: did it", " work.txt | 1 +\n", "diff --git a/work.txt");
        assert!(p.contains("<bead>\nid: t-1"));
        assert!(!p.contains("<last-round>"));
        assert!(precheck_prompt(&j, "round 1 (x):\nCI red on u: ci", "", "", "")
            .contains("<last-round>\nround 1 (x):\nCI red on u: ci\n</last-round>"));
        assert!(p.contains("<worker-report>\nDONE: did it\n</worker-report>"));
        assert!(p.contains("<diff>\n work.txt | 1 +\ndiff --git a/work.txt\n</diff>"), "stat, then the diff");
        assert!(p.ends_with("the 'For the worker:' block your instructions describe."));
    }
    #[test]
    fn precheck_verdict_reads_pass_sendback_or_neither() {
        assert_eq!(precheck_verdict("PASS: checked the three things"), Precheck::Pass);
        let text = "I looked.\nSEND BACK: work.txt:1 no such command in DONE\nFor the worker:\n- What is wrong: x";
        assert_eq!(
            precheck_verdict(text),
            Precheck::SendBack("SEND BACK: work.txt:1 no such command in DONE\nFor the worker:\n- What is wrong: x".into())
        );
        assert_eq!(precheck_verdict("nothing usable here"), Precheck::Unparsed);
        let both = "PASS: looked fine\nSEND BACK: actually no, work.txt:2";
        assert_eq!(precheck_verdict(both), Precheck::SendBack("SEND BACK: actually no, work.txt:2".into()), "SEND BACK wins");
    }
    #[test]
    fn pr_body_quotes_the_criteria() {
        let b = pr_body("t-1", "Do the thing", "a\nb", "DONE: did it", "Reviewer (stub/reviewer): APPROVE: checked");
        assert!(b.starts_with("Bead `t-1`: Do the thing\n\n> a\n> b\n\nWorker: DONE: did it\nReviewer (stub/reviewer): APPROVE: checked\n"));
        assert!(b.ends_with("Opened by bead-loop; the bead closes when this merges.\n"));
        assert!(pr_body("t-1", "T", "", "w", "").contains("\n\n> \n\nWorker: w\n\n\n"), "no criteria: an empty quote, no reviewer line");
    }
    #[test]
    fn a_plain_pr_reads_as_a_contribution() {
        let b = pr_body_plain("t-1", "Fix the parser.", "cargo test passes", "DONE: fixed it");
        assert!(b.contains("Fix the parser."));
        assert!(b.contains("## How to verify\ncargo test passes"));
        assert!(b.contains("fixed it"));
        assert!(b.ends_with("<!-- bead: t-1 -->\n") || b.ends_with("<!-- bead: t-1 -->"));
        assert!(!b.contains("bead-loop"));
        assert!(!b.contains("DONE:"));
        assert_eq!(pr_title("plain", "t-1", "Fix it"), "Fix it");
        assert_eq!(pr_title("loop", "t-1", "Fix it"), "t-1: Fix it");
    }
    #[test]
    fn a_round_the_model_never_answered_holds_with_the_harness_words() {
        let r =
            |rc, error: &str| AgentRun { text: String::new(), full: String::new(), rc, empty: true, error: error.into(), stalled: None };
        assert_eq!(
            never_answered("reviewer", "acbox/reviewer", &r(1, "UnknownError: Unexpected server error. Check server logs for details. (ref err_502a8619)")),
            "reviewer acbox/reviewer exited 1 before the model answered (harness or server down?): UnknownError: Unexpected server error. Check server logs for details. (ref err_502a8619)",
            "the harness's error event, so the page says why"
        );
        assert_eq!(
            never_answered("worker", "stub/worker", &r(7, "connection refused")),
            "worker stub/worker exited 7 before the model answered (harness or server down?): connection refused",
            "an empty log: the harness's stderr"
        );
        assert_eq!(
            never_answered("worker", "stub/worker", &r(7, "")),
            "worker stub/worker exited 7 before the model answered (harness or server down?)",
            "nothing said at all"
        );
    }
    #[test]
    fn hold_backoff_reads_the_environment() {
        // Set only here; the integration suite sets it to 0 for the runs that need a hold to age.
        assert_eq!(hold_backoff(), 300);
    }
    #[test]
    fn same_reject_matches_modulo_whitespace() {
        let note1 = "review (a/b) rejected:\nREJECT: x.rs:1, missing  key\nFor the worker: one";
        let note2 = "review (c/d) rejected:\nREJECT: x.rs:1,   missing key\nFor the worker: two";
        assert!(same_reject(note1, note2));
        let note3 = "review (a/b) rejected:\nREJECT: x.rs:1 a\nFor the worker: one";
        let note4 = "review (c/d) rejected:\nREJECT: x.rs:2 b\nFor the worker: two";
        assert!(!same_reject(note3, note4));
        let note5 = "review (a/b) rejected:\nREJECT: x.rs:1 a\nFor the worker: one";
        let note6 = "gate failed twice: cargo test";
        assert!(!same_reject(note5, note6));
        let note7 = "review (a/b) rejected:\nFor the worker: one";
        assert!(!same_reject(note7, note7));
    }
}
