//! The two rounds. `dev_one`: claim, worktree, worker, gate (one fix round), into the
//! review queue. `review_one`: the reviewer's verdict, push, PR, into the merge queue.
//! `send_back`: a round failed — the count goes up, the note goes on the bead, the bead
//! goes back to the dev queue on a later stage once this one's failures are spent, or is
//! parked. `hold`: the round could not happen (the world, not the model) — no failure,
//! the bead waits in its queue with the reason, the lane moves on.
//!
//! The log lines and the notes are the bash's, word for word: the page and the tests
//! read them.
use crate::config::Repo;
use crate::harness::{abort_sessions, run_agent, runnable};
use crate::shell::{
    bd_claim, bd_comment, bd_note, bd_show, bd_status, branch_exists, gh, git, git_must, git_ok, git_out, local_branch_exists,
    worktree_remove,
};
use crate::signals;
use crate::state::{dev_queue, review_queue, StageHit};
use crate::util::{
    append_file, cut_bytes, date_iminutes, die, first_line, log, read_to_string, stamp, stderr_str, stdout_str, tail_lines, write_file,
};
use serde_json::Value;
use std::path::Path;

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

/// A bead held less than this long ago is not tried again yet (seconds;
/// `BEAD_LOOP_HOLD_BACKOFF` overrides — the tests set it to 0).
pub fn hold_backoff() -> i64 {
    std::env::var("BEAD_LOOP_HOLD_BACKOFF").ok().and_then(|s| s.parse().ok()).unwrap_or(300)
}

/// `render_bead`: the bead as the prompt carries it.
pub fn render_bead(json: &Value) -> String {
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
    if !s("notes").is_empty() {
        out.push_str(&format!("\n\nNOTES:\n{}", s("notes")));
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
    !git_out(wt, &["rev-list", &format!("origin/{}..HEAD", repo.base)]).trim().is_empty()
}

pub fn run_gate(repo: &Repo, wt: &Path, logf: &Path) -> bool {
    if repo.gate.is_empty() {
        return true;
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

/// The last three notes of earlier rounds, for the prompt.
fn history(repo: &Repo, id: &str) -> String {
    read_to_string(&repo.notes_path(id)).map(|s| tail_lines(&s, 3)).unwrap_or_default()
}

/// Whether a held bead's hold is old enough to try again.
fn hold_expired(repo: &Repo, id: &str) -> bool {
    !repo.held_path(id).exists() || crate::util::now() - repo.held_since(id) >= hold_backoff()
}

/// `pick_runnable dev|review`: the first bead in that queue whose round's model can run
/// now and whose hold (if any) has aged; the ones skipped are logged once per pass.
pub fn pick_runnable(repo: &Repo, which: &str) -> Option<String> {
    let queue = if which == "dev" { dev_queue(repo) } else { review_queue(repo) };
    let mut skipped_claude = 0;
    let mut pick = None;
    for id in queue {
        if !hold_expired(repo, &id) {
            continue;
        }
        let n = repo.failures_of(&id);
        match repo.stage_for(n) {
            None => {
                pick = Some(id);
                break;
            }
            Some(st) => {
                let model = if which == "dev" {
                    st.model.clone()
                } else if st.review.is_empty() {
                    "none".into()
                } else {
                    st.review.clone()
                };
                if runnable(&model) {
                    pick = Some(id);
                    break;
                }
                skipped_claude += 1;
            }
        }
    }
    if skipped_claude > 0 {
        log(&format!(
            "{}: {which}: {skipped_claude} bead(s) wait for Claude — it is signed out on this box (claude auth login)",
            repo.slug
        ));
    }
    pick
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
    repo.lane_clear("dev");
    repo.lane_clear("review");
    signals::clear_current("dev");
    signals::clear_current("review");
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

/// `send_back ID WT fresh|keep NOTE`
pub fn send_back(repo: &Repo, id: &str, wt: &Path, keep: bool, note: &str, model: &str, last: bool) {
    let n = repo.failures_of(id) + 1;
    log(&format!("{}: {id} round {n} stopped: {}", repo.slug, first_line(note)));
    bd_note(repo, id, &format!("bead-loop round {n} ({model}) {}: {note}", date_iminutes()));
    repo.set_failures(id, n);
    let one_line: String = note.replace('\n', " ");
    append_file(&repo.notes_path(id), &format!("round {n} ({model}): {}\n", cut_bytes(&one_line, 2000)));
    repo.lane_clear("dev");
    repo.lane_clear("review");
    signals::clear_current("dev");
    signals::clear_current("review");
    repo.release(id);
    if !keep {
        worktree_remove(repo, wt);
        let _ = git(&repo.repo, &["branch", "-D", &format!("bead/{id}")]);
    }
    if last && note.contains("BLOCKED:") {
        log(&format!("{}: {id}: BLOCKED at the last stage, parked for you", repo.slug));
        park_cleanup(repo, wt);
        repo.wake();
        return;
    }
    match repo.stage_for(n) {
        Some(st) => {
            bd_status(repo, id, "open");
            log(&format!(
                "{}: {id}: → dev queue ({n} failures; next: worker {}, reviewer {})",
                repo.slug,
                st.model,
                if st.review.is_empty() { "none".to_string() } else { st.review.clone() }
            ));
        }
        None => {
            log(&format!("{}: {id}: stages exhausted ({n} failures), parked for you", repo.slug));
            park_cleanup(repo, wt);
        }
    }
    repo.wake();
}

pub fn park_cleanup(repo: &Repo, wt: &Path) {
    let _ = git(&repo.repo, &["worktree", "remove", "--force", &wt.to_string_lossy()]);
}

/// The harness label a bead may carry, applied to the stage's worker.
fn apply_harness_label(repo: &Repo, id: &str, json: &Value, model: &mut String) {
    let labels: Vec<&str> = json
        .get(0)
        .and_then(|b| b.get("labels"))
        .and_then(|l| l.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    if labels.contains(&"harness:aider") {
        if !model.starts_with("aider:") && !model.starts_with("claude/") {
            *model = format!("aider:{model}");
            log(&format!("{}: {id}: label harness:aider: worker {model} runs in aider, not opencode", repo.slug));
        }
    } else if labels.contains(&"harness:opencode") {
        if let Some(m) = model.strip_prefix("aider:") {
            let m = m.to_string();
            *model = m;
            log(&format!("{}: {id}: label harness:opencode: worker {model} runs in opencode, not aider", repo.slug));
        }
    }
}

/// `dev_one [ID]`
pub fn dev_one(repo: &Repo, opts: &Opts, id: Option<&str>, last_id: &mut Option<String>) -> Pass {
    let id = match id {
        Some(i) => i.to_string(),
        None => {
            // The two idle lines: every pass in a tick (the bash did), once per change in
            // the resident loop, which passes every heartbeat.
            if repo.inflight_count() >= repo.max_inflight {
                crate::merge::say(
                    &format!("{}/dev-idle", repo.slug),
                    format!("{}: dev: {} in flight (max {}); waiting on CI", repo.slug, repo.inflight_count(), repo.max_inflight),
                );
                return Pass::Nothing;
            }
            match pick_runnable(repo, "dev") {
                Some(i) => i,
                None => {
                    crate::merge::say(
                        &format!("{}/dev-idle", repo.slug),
                        format!("{}: dev: nothing ready with label {}", repo.slug, repo.label),
                    );
                    return Pass::Nothing;
                }
            }
        }
    };
    let n = repo.failures_of(&id);
    let st: StageHit = match repo.stage_for(n) {
        Some(s) => s,
        None => {
            log(&format!("{}: {id}: stages exhausted ({n} failures), parked", repo.slug));
            bd_status(repo, &id, "in_progress");
            return Pass::Worked;
        }
    };
    let mut model = opts.model_flag.clone().unwrap_or_else(|| st.model.clone());
    let review_model = st.review.clone();
    let timeout = st.timeout;
    let hist = history(repo, &id);
    let json = bd_show(repo, &id);
    let title = json.get(0).and_then(|b| b.get("title")).and_then(|t| t.as_str()).unwrap_or("").to_string();
    apply_harness_label(repo, &id, &json, &mut model);
    let branch = format!("bead/{id}");
    let wt = repo.wt(&id);
    let logf = repo.rs.join("logs").join(format!("{id}.{}", stamp()));
    // The conflict round: the PR could not merge because the branch conflicts with the
    // base. The worker is conflict_worker (default: the last stage's), and its order is
    // the rebase, not the bead. No failure was charged.
    let mut conflict = false;
    let mut rebase_order = String::new();
    if repo.mark(&id, "conflict").exists() {
        conflict = true;
        if !repo.conflict_worker.is_empty() {
            model = repo.conflict_worker.clone();
        } else if let Some(last) = repo.stage_for(repo.last_stage_start()) {
            model = opts.model_flag.clone().unwrap_or(last.model);
        }
        if !runnable(&model) {
            log(&format!("{}: {id}: conflict round needs {model}, which cannot run now (Claude signed out); waiting", repo.slug));
            bd_status(repo, &id, "open");
            return Pass::Nothing;
        }
        rebase_order = format!(
            "\n\nThis branch has an open pull request that GitHub cannot merge: it conflicts with {base}. Your job this round is the rebase, not new work. Run: git fetch origin && git rebase origin/{base}. Resolve every conflict so that both what this branch set out to do (the bead above, and the commits already on the branch) and what {base} changed since are kept; do not drop either side to make the conflict go away. Then run the gate if one is given, make sure the acceptance criteria still hold, and end with DONE: <what conflicted and how you resolved it>. Do not squash or rewrite the branch beyond the rebase.",
            base = repo.base
        );
        log(&format!("{}: {id}: conflict round: rebase onto {} by {model}", repo.slug, repo.base));
    }
    // A branch left from an earlier round (sent back by review or CI) is resumed, not
    // restarted: the worker fixes its commit. A dev-side failure deleted the branch.
    let resumed = branch_exists(repo, &branch);
    let history_block = if hist.is_empty() {
        String::new()
    } else {
        format!(
            "\n\nEarlier rounds on this bead were sent back; their notes follow. A note that begins \"review (...) rejected:\" is a work order from the senior reviewer: do exactly what its \"What to do\" says, prove it with its \"How to check\", and leave alone what it says to leave alone. Read them before you start and do not repeat them.\n\n<previous-attempts>\n{hist}\n</previous-attempts>"
        )
    };
    let prompt = format!(
        "Work the bead below in this repository, following the bead-workflow skill.\n\n<bead>\n{}\n</bead>\n\nYou are on branch {branch}{}. Commit your work on this branch and leave .beads/ untouched. End your turn with one line: DONE: <evidence> or BLOCKED: <note>.{rebase_order}{history_block}",
        render_bead(&json),
        if resumed {
            ", which already carries your earlier commit(s) for this bead: fix them in place rather than starting over".to_string()
        } else {
            format!(", a fresh worktree of {}", repo.base)
        }
    );
    log(&format!(
        "{}: dev: bead {id} — {title} ({n} failures, worker {model}, reviewer {}{}{})",
        repo.slug,
        if review_model.is_empty() { "none" } else { &review_model },
        if resumed { ", resuming the branch" } else { "" },
        if conflict { ", rebase" } else { "" }
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
        println!("{prompt}");
        return Pass::Nothing;
    }
    *last_id = Some(id.clone());
    if !opts.local {
        crate::config::need("gh");
    }

    bd_claim(repo, &id);
    repo.lane_set("dev", &id);
    if !git_ok(&repo.repo, &["fetch", "-q", "origin", &repo.base]) {
        hold(repo, &id, None, &format!("git fetch origin {} failed", repo.base));
        return Pass::Worked;
    }
    abort_sessions(repo, &wt); // a killed earlier round may have left one running here
    signals::set_current("dev", &repo.attach, &repo.slug, Some(wt.clone()), Some(repo.lane_path("dev")));
    let kept = wt.is_dir() && resumed && git_ok(&wt, &["rev-parse", "-q", "--verify", "HEAD"]);
    if !kept {
        if wt.exists() {
            worktree_remove(repo, &wt);
        }
        if resumed {
            if !local_branch_exists(repo, &branch) {
                git_must(&repo.repo, &["branch", "-q", "--track", &branch, &format!("origin/{branch}")]);
            }
            git_must(&repo.repo, &["worktree", "add", "-q", &wt.to_string_lossy(), &branch]);
        } else {
            let _ = git(&repo.repo, &["branch", "-D", &branch]);
            git_must(&repo.repo, &["worktree", "add", "-q", "-b", &branch, &wt.to_string_lossy(), &format!("origin/{}", repo.base)]);
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

    let title_w = format!("{id} · worker · round {}", n + 1);
    let worker_log = std::path::PathBuf::from(format!("{}.worker.jsonl", logf.display()));
    let r = run_agent(repo, "bead-worker", &model, &wt, &worker_log, &prompt, &title_w, timeout, Some(&json));
    if r.rc != 0 {
        if r.empty && r.rc != 124 {
            // Nothing came back at all and it was not the clock: the harness or its server,
            // not the model. No failure; the bead waits, the lane backs off.
            let err = tail_lines(&read_to_string(&worker_log.with_extension("jsonl.err")).unwrap_or_default(), 5);
            hold(repo, &id, Some(&wt), &format!("worker {model} exited {} with no output (harness or server down?). {err}", r.rc));
            return Pass::Worked;
        }
        send_back(
            repo,
            &id,
            &wt,
            false,
            &format!("worker exited {} (timeout={timeout} s). Log: {}", r.rc, worker_log.display()),
            &model,
            st.last,
        );
        return Pass::Worked;
    }
    if let Some(b) = last_line_starting(&r.text, "BLOCKED:") {
        send_back(repo, &id, &wt, false, &b, &model, st.last);
        return Pass::Worked;
    }
    if !settle_worktree(repo, &wt, &format!("{id}: {title}")) {
        send_back(repo, &id, &wt, false, &format!("worker made no commit. Last words: {}", tail_lines(&r.text, 3)), &model, st.last);
        return Pass::Worked;
    }
    // The gate gets one fix round inside the lane: a compiler message is the cheapest review there is.
    let gate_log = std::path::PathBuf::from(format!("{}.gate", logf.display()));
    let mut final_text = r.text;
    if !run_gate(repo, &wt, &gate_log) {
        log(&format!("{}: {id}: gate failed, fix round", repo.slug));
        let gate_out = tail_lines(&read_to_string(&gate_log).unwrap_or_default(), 40);
        let fix_prompt = format!(
            "{prompt}\n\nYour commit on this branch failed the repository's gate: `{}`. Fix exactly what it reports, run it again until it passes, commit, and end with DONE: or BLOCKED:.\n\n<gate-output>\n{gate_out}\n</gate-output>",
            repo.gate
        );
        let fix_log = std::path::PathBuf::from(format!("{}.worker-gate.jsonl", logf.display()));
        let r2 =
            run_agent(repo, "bead-worker", &model, &wt, &fix_log, &fix_prompt, &format!("{id} · worker · gate fix"), timeout, Some(&json));
        if r2.rc != 0 {
            send_back(
                repo,
                &id,
                &wt,
                false,
                &format!("worker exited {} in gate fix round. Log: {}", r2.rc, fix_log.display()),
                &model,
                st.last,
            );
            return Pass::Worked;
        }
        if let Some(b) = last_line_starting(&r2.text, "BLOCKED:") {
            send_back(repo, &id, &wt, false, &format!("gate fix round: {b}"), &model, st.last);
            return Pass::Worked;
        }
        settle_worktree(repo, &wt, &format!("{id}: fix the gate"));
        let gate2 = std::path::PathBuf::from(format!("{}.gate-2", logf.display()));
        if !run_gate(repo, &wt, &gate2) {
            let tail = tail_lines(&read_to_string(&gate2).unwrap_or_default(), 15);
            send_back(repo, &id, &wt, false, &format!("gate failed twice: {}\n{tail}", repo.gate), &model, st.last);
            return Pass::Worked;
        }
        final_text = r2.text;
    }

    // Into the review queue, with the worker's last words for the reviewer.
    let done = last_line_starting(&final_text, "DONE:").unwrap_or_default();
    write_file(&repo.review_path(&id), &format!("{done}\n"));
    repo.release(&id);
    repo.lane_clear("dev");
    signals::clear_current("dev");
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

/// `review_one [ID]`
pub fn review_one(repo: &Repo, opts: &Opts, id: Option<&str>) -> Pass {
    let id = match id {
        Some(i) => i.to_string(),
        None => match pick_runnable(repo, "review") {
            Some(i) => i,
            None => return Pass::Nothing,
        },
    };
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
        if !local_branch_exists(repo, &branch) {
            git_must(&repo.repo, &["branch", "-q", "--track", &branch, &format!("origin/{branch}")]);
        }
        git_must(&repo.repo, &["worktree", "add", "-q", &wt.to_string_lossy(), &branch]);
        log(&format!("{}: {id}: worktree rebuilt from {branch} for the review", repo.slug));
    }
    repo.lane_set("review", &id);
    signals::set_current("review", &repo.attach, &repo.slug, Some(wt.clone()), Some(repo.lane_path("review")));
    let mut verdict = String::new();
    if !review_model.is_empty() {
        log(&format!("{}: review: {id} by {review_model} ({n} failures)", repo.slug));
        let stat = git_out(&wt, &["diff", &format!("origin/{}...HEAD", repo.base), "--stat"]);
        let diff = git_out(&wt, &["diff", &format!("origin/{}...HEAD", repo.base)]);
        let diff = cut_bytes(&diff, 60000);
        let prompt = format!(
            "Review the commit(s) on this branch for the bead below. The diff against {} is under <diff>; read any file you need for context.\n\n<bead>\n{}\n</bead>\n\n<worker-report>\n{final_text}\n</worker-report>\n\n<diff>\n{stat}{diff}\n</diff>\n\nEnd with APPROVE: <what you checked> on one line, or REJECT: <file:line, what is wrong> followed by the 'For the worker:' block your instructions describe — the worker acts on that block alone.",
            repo.base,
            render_bead(&json)
        );
        let review_log = std::path::PathBuf::from(format!("{}.review.jsonl", logf.display()));
        let r = run_agent(
            repo,
            "bead-reviewer",
            &review_model,
            &wt,
            &review_log,
            &prompt,
            &format!("{id} · reviewer · round {}", n + 1),
            timeout,
            Some(&json),
        );
        if r.rc != 0 {
            if r.empty && r.rc != 124 {
                let err = tail_lines(&read_to_string(&review_log.with_extension("jsonl.err")).unwrap_or_default(), 5);
                hold(repo, &id, None, &format!("reviewer {review_model} exited {} with no output (harness or server down?). {err}", r.rc));
                return Pass::Worked;
            }
            let _ = std::fs::remove_file(repo.review_path(&id));
            send_back(repo, &id, &wt, true, &format!("reviewer exited {}. Log: {}", r.rc, review_log.display()), &model, false);
            return Pass::Worked;
        }
        if !r.text.lines().any(|l| l.starts_with("APPROVE:")) {
            let _ = std::fs::remove_file(repo.review_path(&id));
            // The whole of the reviewer's verdict travels — the REJECT line and the block for
            // the worker under it — not a 600-character summary of it: it is the work order.
            let from_reject: String = {
                let mut out = Vec::new();
                let mut on = false;
                for l in r.text.lines() {
                    if l.starts_with("REJECT:") {
                        on = true;
                    }
                    if on {
                        out.push(l);
                    }
                }
                out.join("\n")
            };
            send_back(
                repo,
                &id,
                &wt,
                true,
                &format!("review ({review_model}) rejected:\n{}", cut_bytes(&from_reject, 4000)),
                &model,
                false,
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
        repo.lane_clear("review");
        signals::clear_current("review");
        return Pass::Worked;
    }

    match git(&wt, &["push", "-q", "-u", "origin", &branch, "--force-with-lease"]) {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            write_file(&repo.review_path(&id), &format!("{final_text}\n"));
            hold(repo, &id, None, &format!("push of {branch} refused: {}", tail_lines(stderr_str(&o).trim(), 3)));
            return Pass::Worked;
        }
        Err(e) => die(&format!("git push: {e}")),
    }
    let ac = json.get(0).and_then(|b| b.get("acceptance_criteria")).and_then(|v| v.as_str()).unwrap_or("");
    let ac_quoted: String = ac.lines().map(|l| format!("> {l}")).collect::<Vec<_>>().join("\n");
    let ac_quoted = if ac.is_empty() { "> ".to_string() } else { ac_quoted };
    let worker_line = cut_bytes(final_text.lines().last().unwrap_or(""), 500).to_string();
    let reviewer_line = if review_model.is_empty() {
        String::new()
    } else {
        format!("Reviewer ({review_model}): {}", cut_bytes(&last_line_starting(&verdict, "APPROVE:").unwrap_or_default(), 500))
    };
    let body = format!(
        "Bead `{id}`: {title}\n\n{ac_quoted}\n\nWorker: {worker_line}\n{reviewer_line}\n\nOpened by bead-loop; the bead closes when this merges.\n"
    );
    // A branch sent back by CI already has its PR: the push updated it.
    let existing = crate::shell::gh_stdout_any(
        repo,
        &["pr", "list", "--state", "open", "--head", &branch, "--json", "url", "--jq", ".[0].url // empty"],
    )
    .trim()
    .to_string();
    let url = if !existing.is_empty() {
        log(&format!("{}: {id}: pushed a new round to {existing}", repo.slug));
        bd_comment(repo, &id, &format!("bead-loop: pushed round {} to {existing}", n + 1));
        existing
    } else {
        match gh(repo, &["pr", "create", "--base", &repo.base, "--head", &branch, "--title", &format!("{id}: {title}"), "--body", &body]) {
            Ok(o) if o.status.success() => {
                let url = stdout_str(&o).trim().to_string();
                bd_comment(repo, &id, &format!("bead-loop: opened {url}"));
                log(&format!("{}: opened {url}", repo.slug));
                url
            }
            Ok(o) => {
                write_file(&repo.review_path(&id), &format!("{final_text}\n"));
                hold(repo, &id, None, &format!("gh pr create failed: {}", tail_lines(stderr_str(&o).trim(), 3)));
                return Pass::Worked;
            }
            Err(e) => die(&format!("gh: {e}")),
        }
    };
    let num = url.rsplit('/').next().unwrap_or("").to_string();
    write_file(&repo.inflight_path(&id), &format!("{url}\n"));
    for m in ["red", "fixing", "conflict"] {
        let _ = std::fs::remove_file(repo.mark(&id, m));
    }
    repo.release(&id);
    if repo.merge == "pipeline" {
        crate::merge::hand_to_pipeline(repo, &id, &num, &url);
    }
    let _ = git(&repo.repo, &["worktree", "remove", "--force", &wt.to_string_lossy()]);
    repo.lane_clear("review");
    signals::clear_current("review");
    repo.wake();
    Pass::Worked
}

/// `work REPO [ID]`: one bead through both lanes, in this process, in order: what --local
/// and a hand-run check want. A bead the dev lane sends back stops there.
pub fn work(repo: &Repo, opts: &Opts, id: Option<&str>) {
    let mut last = None;
    if dev_one(repo, opts, id, &mut last) == Pass::Worked {
        if let Some(id) = last {
            if repo.review_path(&id).exists() {
                review_one(repo, opts, Some(&id));
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
}
