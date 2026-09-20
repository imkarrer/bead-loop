//! The human queue's three ways out — `answer`, `escalate`, `open` — and the guard the
//! bash lacked: a bead in the merge queue is not reopened under its PR.
use crate::config::Repo;
use crate::harness::runnable;
use crate::round::render_bead;
use crate::shell::{bd_note, bd_show, bd_status, branch_exists, git, git_must, local_branch_exists};
use crate::util::{date_iminutes, die, log};

/// A bead in the merge queue stays there: its PR is what moves it.
fn refuse_if_in_merge(repo: &Repo, id: &str, what: &str) {
    if repo.inflight_path(id).exists() {
        let url = crate::util::read_to_string(&repo.inflight_path(id)).unwrap_or_default();
        die(&format!(
            "{}: {id} is in the merge queue at {}; {what} would put it on two lanes at once — close the PR first, or wait for it",
            repo.slug,
            url.trim()
        ));
    }
}

/// `escalate ID`: "work this with Claude" — the failure count set to the first value that
/// lands on the last stage, and the bead reopened so the dev queue hands it out there. A
/// bead on a lane or waiting for review keeps its place; its next round is the escalated
/// one. Noted on the bead, like every other change the loop makes.
pub fn escalate(repo: &Repo, id: &str) {
    refuse_if_in_merge(repo, id, "escalating");
    let n = repo.last_stage_start();
    let st = match repo.stage_for(n) {
        Some(s) => s,
        None => die(&format!("{}: no stage to escalate to", repo.slug)),
    };
    if !runnable(&st.model) {
        die(&format!(
            "{}: {} cannot run: Claude is signed out on this box — sign in first (the page's Sign in, or claude auth login)",
            repo.slug, st.model
        ));
    }
    repo.set_failures(id, n);
    let reviewer = if st.review.is_empty() { "none".to_string() } else { st.review.clone() };
    bd_note(repo, id, &format!("bead-loop {}: escalated by hand to the last stage (worker {}, reviewer {reviewer})", date_iminutes(), st.model));
    let on_lane = repo.lane_bead("dev").as_deref() == Some(id) || repo.lane_bead("review").as_deref() == Some(id);
    if !repo.review_path(id).exists() && !on_lane {
        bd_status(repo, id, "open");
    }
    repo.release(id);
    log(&format!(
        "{}: {id}: escalated to the last stage — worker {}, reviewer {reviewer} — from its next round",
        repo.slug, st.model
    ));
    repo.wake();
}

/// `answer ID TEXT`: the human queue's reply. The note carries the answer to the next
/// round, and the bead goes back to the dev queue at the stage it stopped on: the round
/// that stopped to ask is forgiven (one failure off).
pub fn answer(repo: &Repo, id: &str, text: &str) {
    refuse_if_in_merge(repo, id, "answering");
    let n = repo.failures_of(id);
    if n > 0 {
        repo.set_failures(id, n - 1);
    }
    bd_note(repo, id, &format!("operator {}: {text}", date_iminutes()));
    let _ = std::fs::remove_file(repo.review_path(id));
    repo.release(id);
    bd_status(repo, id, "open");
    log(&format!("{}: {id}: answered; back in the dev queue", repo.slug));
    repo.wake();
}

/// `open ID`: you and Claude on the bead, in its worktree — the branch a round left, or a
/// fresh one — with the bead, the loop's notes and the open question as the first prompt.
/// Interactive Claude Code, your terminal, your session.
pub fn open_bead(repo: &Repo, id: &str) -> ! {
    crate::config::need("claude");
    let json = bd_show(repo, id);
    let branch = format!("bead/{id}");
    let wt = repo.wt(id);
    let _ = git(&repo.repo, &["fetch", "-q", "origin", &repo.base]);
    if !wt.is_dir() {
        if branch_exists(repo, &branch) {
            if !local_branch_exists(repo, &branch) {
                git_must(&repo.repo, &["branch", "-q", "--track", &branch, &format!("origin/{branch}")]);
            }
            git_must(&repo.repo, &["worktree", "add", "-q", &wt.to_string_lossy(), &branch]);
        } else {
            git_must(&repo.repo, &["worktree", "add", "-q", "-b", &branch, &wt.to_string_lossy(), &format!("origin/{}", repo.base)]);
        }
        if !repo.setup.is_empty() {
            log(&format!("{}: setup: {}", repo.slug, repo.setup));
            let logf = repo.rs.join("logs").join(format!("{id}.open.setup"));
            let ok = crate::util::output(
                crate::util::cmd("bash").args(["-c", &repo.setup]).current_dir(&wt),
            )
            .map(|o| {
                let _ = std::fs::write(&logf, [o.stdout.as_slice(), o.stderr.as_slice()].concat());
                o.status.success()
            })
            .unwrap_or(false);
            if !ok {
                log(&format!("{}: setup failed; see {}", repo.slug, logf.display()));
            }
        }
    }
    let why = json
        .get(0)
        .and_then(|b| b.get("notes"))
        .and_then(|n| n.as_str())
        .unwrap_or("")
        .lines()
        .filter(|l| l.starts_with("bead-loop"))
        .last()
        .unwrap_or("")
        .to_string();
    log(&format!("{}: {id}: opening Claude Code in {} on {branch}", repo.slug, wt.display()));
    let prompt = format!(
        "You are working the bead below with its owner, in this worktree, on branch {branch}.{} Read the bead and the notes, then ask what you need to know; commit on this branch when it is done and say so.\n\n<bead>\n{}\n</bead>",
        if why.is_empty() { String::new() } else { format!(" The automated loop stopped on it — its last note: {why}") },
        render_bead(&json)
    );
    use std::os::unix::process::CommandExt;
    let err = crate::util::cmd("claude").arg(&prompt).current_dir(&wt).exec();
    die(&format!("cannot exec claude: {err}"))
}
