//! The state on disk, `~/.local/state/bead-loop/<repo>/`, and what it means:
//!
//! - `beads/ID/`   what the loop keeps of one bead between rounds: `failures` the count of
//!   send-backs (→ the stage), `rounds.jsonl` the history, one record per send-back
//!   (`notes` the older one-line history), `brief` the brief a research round wrote, for
//!   the worker prompt, and `brief.prev` the one a send-back cleared under
//!   `research = "every"`, for the next research round to refine
//! - `review/ID`   the review queue: the worker's last line, for the reviewer's prompt
//! - `inflight/ID` the merge queue: the PR url; `.ID.red|nocheck|adopted|fixing|conflict|lastred`
//!   beside it
//! - `held/ID`     the bead is in its queue and waits on something outside the loop; the
//!   file says what. Shown in the human queue, polled, cleared when the reason goes.
//! - `parked/ID`   the record of a parking: reason, stage, question, brief
//! - `rejoin/ID`   `SID worker|reviewer`, a session to wait on after a restart
//! - `target/ID`   the `[targets.NAME]` name `for_bead` resolved at claim, when it is not
//!   the default target — read back by `Repo::for_id` so the review lane, the merge
//!   watcher, `open`, `answer` and `escalate` act on the same checkout; goes with
//!   `inflight/ID` at close and at park (docs/design-targets.md)
//! - `.ID.conflict` in the inflight marker list
//! - `.ID.lastred` the red CI run last charged: the head sha and its builds
//! - `lane.<name>` the lane names are dev, review, claude, or the [[lanes]] names
//! - `wt/ID` the worktree while a bead is on a lane or waiting for review
//!
//! and, under the state dir itself: `lock.<name>`, `pause.<name>` (not only dev/review),
//! `restart` (dropped by the deploy before it restarts the service; signals.rs reads it).
use crate::config::{Approvals, Repo, Seat, Stage};
use crate::util::{mtime, read_to_string, touch, write_file};
use std::path::PathBuf;

/// The stage a failure count lands on.
#[derive(Clone, Debug, PartialEq)]
pub struct StageHit {
    pub model: String,
    pub review: String,
    pub timeout: u64,
    /// the last stage: BLOCKED here parks the bead
    pub last: bool,
    /// 1-based, what status --json shows
    pub index: usize,
    pub seats: Vec<Seat>,
    pub approvals: Approvals,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Quorum {
    Approve,
    Reject,
    Pending,
}

/// Applies a stage's seat rule to its seats' verdicts: Some(true) approved, Some(false)
/// rejected, None not in yet. An empty slice is Approve: no reviewer means straight to PR.
pub fn quorum(verdicts: &[Option<bool>], rule: &Approvals) -> Quorum {
    if verdicts.is_empty() {
        return Quorum::Approve;
    }
    match rule {
        Approvals::All => {
            if verdicts.contains(&Some(false)) {
                Quorum::Reject
            } else if verdicts.iter().all(|v| *v == Some(true)) {
                Quorum::Approve
            } else {
                Quorum::Pending
            }
        }
        Approvals::Any => {
            if verdicts.contains(&Some(true)) {
                Quorum::Approve
            } else if verdicts.iter().all(|v| *v == Some(false)) {
                Quorum::Reject
            } else {
                Quorum::Pending
            }
        }
        Approvals::Count(n) => {
            let trues = verdicts.iter().filter(|v| **v == Some(true)).count() as u64;
            let nones = verdicts.iter().filter(|v| v.is_none()).count() as u64;
            if trues >= *n {
                Quorum::Approve
            } else if trues + nones < *n {
                Quorum::Reject
            } else {
                Quorum::Pending
            }
        }
    }
}

impl Repo {
    // ---- files ------------------------------------------------------------------
    /// `beads/ID/`: what the loop keeps of one bead from round to round — the count, the
    /// history, the brief. Queue membership is not here: that is the queue directories.
    pub fn bead_dir(&self, id: &str) -> PathBuf {
        self.rs.join("beads").join(id)
    }
    pub fn failures_path(&self, id: &str) -> PathBuf {
        self.bead_dir(id).join("failures")
    }
    pub fn failures_of(&self, id: &str) -> u64 {
        read_to_string(&self.failures_path(id)).and_then(|s| s.trim().parse().ok()).unwrap_or(0)
    }
    pub fn set_failures(&self, id: &str, n: u64) {
        write_file(&self.failures_path(id), &format!("{n}\n"));
    }
    pub fn notes_path(&self, id: &str) -> PathBuf {
        self.bead_dir(id).join("notes")
    }
    pub fn review_path(&self, id: &str) -> PathBuf {
        self.rs.join("review").join(id)
    }
    /// `review/ID.seats/K` the verdict of seat K (1-based) for bead ID.
    pub fn seat_dir(&self, id: &str) -> PathBuf {
        self.rs.join("review").join(format!("{id}.seats"))
    }
    /// `review/ID.seats/K` the verdict of seat K (1-based) for bead ID.
    pub fn seat_verdict(&self, id: &str, k: usize) -> Option<String> {
        read_to_string(&self.seat_dir(id).join(format!("{k}")))
    }
    /// `review/ID.seats/K.running` true when seat K (1-based) is running for bead ID.
    pub fn seat_running(&self, id: &str, k: usize) -> bool {
        self.seat_dir(id).join(format!("{k}.running")).exists()
    }
    /// `review/ID.seats/K.running` create the marker file for seat K (1-based) running for bead ID.
    pub fn seat_set_running(&self, id: &str, k: usize) {
        let dir = self.seat_dir(id);
        std::fs::create_dir_all(&dir).ok();
        touch(&dir.join(format!("{k}.running")));
    }
    /// `review/ID.seats/K.running` remove the marker file for seat K (1-based) running for bead ID.
    pub fn seat_clear_running(&self, id: &str, k: usize) {
        let _ = std::fs::remove_file(self.seat_dir(id).join(format!("{k}.running")));
    }
    /// `review/ID.seats/K` write the verdict for seat K (1-based) for bead ID.
    pub fn seat_set_verdict(&self, id: &str, k: usize, text: &str) {
        let dir = self.seat_dir(id);
        std::fs::create_dir_all(&dir).ok();
        write_file(&dir.join(format!("{k}")), &format!("{text}\n"));
    }
    /// `review/ID` and `review/ID.seats` both go: the bead leaves review, whether pushed,
    /// sent back, parked, or answered by a human. A seats dir left behind would be read at
    /// the bead's next review and count a stale verdict in the next quorum.
    pub fn review_clear(&self, id: &str) {
        let _ = std::fs::remove_file(self.review_path(id));
        let _ = std::fs::remove_dir_all(self.seat_dir(id));
    }
    pub fn inflight_path(&self, id: &str) -> PathBuf {
        self.rs.join("inflight").join(id)
    }
    /// `mark ID KIND`: the hidden marker beside an inflight file.
    pub fn mark(&self, id: &str, kind: &str) -> PathBuf {
        self.rs.join("inflight").join(format!(".{id}.{kind}"))
    }
    pub fn held_path(&self, id: &str) -> PathBuf {
        self.rs.join("held").join(id)
    }
    /// `proposed/ID`: `open_pr = "ask"`'s PR details, waiting on a human to publish.
    pub fn proposed_path(&self, id: &str) -> PathBuf {
        self.rs.join("proposed").join(id)
    }
    /// Every bead holding a `proposed/ID`, sorted, like `inflight_ids`.
    pub fn proposed_ids(&self) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(self.rs.join("proposed"))
            .map(|rd| rd.flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| !n.starts_with('.')).collect())
            .unwrap_or_default();
        v.sort();
        v
    }
    pub fn target_path(&self, id: &str) -> PathBuf {
        self.rs.join("target").join(id)
    }
    /// The target `for_bead` resolved for this bead at claim, `""` for the default
    /// target (no file, or an unreadable one) — `Repo::for_id`'s source.
    pub fn target_of(&self, id: &str) -> String {
        read_to_string(&self.target_path(id)).map(|s| s.trim().to_string()).unwrap_or_default()
    }
    /// Record the target a bead claimed on; `""` clears the file (the default target
    /// needs none written, and a bead moving back to it should leave none behind).
    pub fn set_target(&self, id: &str, name: &str) {
        if name.is_empty() {
            self.clear_target(id);
        } else {
            write_file(&self.target_path(id), &format!("{name}\n"));
        }
    }
    pub fn clear_target(&self, id: &str) {
        let _ = std::fs::remove_file(self.target_path(id));
    }
    /// `$RS/beads/ID/brief`: the brief the research round wrote, carried by the bead's
    /// worker prompt. Absent (with `research_model` set) is what makes the next pick a
    /// research round.
    pub fn research_path(&self, id: &str) -> PathBuf {
        self.bead_dir(id).join("brief")
    }
    /// `$RS/beads/ID/brief.prev`: the brief a send-back cleared under `research = "every"`,
    /// handed to the next research round to refine.
    pub fn research_prev_path(&self, id: &str) -> PathBuf {
        self.bead_dir(id).join("brief.prev")
    }
    pub fn research_of(&self, id: &str) -> Option<String> {
        read_to_string(&self.research_path(id))
    }
    /// The brief and any earlier one go: the bead closed, parked, or its research is to
    /// run again from nothing.
    pub fn research_clear(&self, id: &str) {
        let _ = std::fs::remove_file(self.research_path(id));
        let _ = std::fs::remove_file(self.research_prev_path(id));
    }
    /// `held/ID.n`: how many holds in a row share the current reason — the backoff's
    /// multiplier (round.rs hold_delay).
    pub fn held_count_path(&self, id: &str) -> PathBuf {
        self.rs.join("held").join(format!("{id}.n"))
    }
    pub fn held_count(&self, id: &str) -> u64 {
        read_to_string(&self.held_count_path(id)).and_then(|s| s.trim().parse().ok()).unwrap_or(1)
    }
    pub fn wt(&self, id: &str) -> PathBuf {
        self.rs.join("wt").join(id)
    }
    pub fn lane_path(&self, name: &str) -> PathBuf {
        self.rs.join(format!("lane.{name}"))
    }
    pub fn lane_set(&self, name: &str, id: &str) {
        write_file(&self.lane_path(name), &format!("{id}\n"));
    }
    /// The marker with the round's role on its second line (`research`), for status to
    /// show; a worker or reviewer round writes the bead alone.
    pub fn lane_set_role(&self, name: &str, id: &str, role: &str) {
        write_file(&self.lane_path(name), &format!("{id}\n{role}\n"));
    }
    /// The role on the marker's second line, when the round wrote one.
    pub fn lane_role(&self, name: &str) -> Option<String> {
        read_to_string(&self.lane_path(name)).and_then(|s| s.lines().nth(1).map(|l| l.trim().to_string())).filter(|s| !s.is_empty())
    }
    pub fn lane_clear(&self, name: &str) {
        let _ = std::fs::remove_file(self.lane_path(name));
    }
    pub fn lane_busy(&self, name: &str) -> bool {
        self.lane_path(name).exists()
    }
    /// The lanes with a marker file in this repo's state dir, by name.
    pub fn lane_files(&self) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(&self.rs)
            .map(|rd| {
                rd.flatten()
                    .filter_map(|e| e.file_name().into_string().ok())
                    .filter_map(|n| n.strip_prefix("lane.").map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }
    pub fn lane_bead(&self, name: &str) -> Option<String> {
        read_to_string(&self.lane_path(name)).and_then(|s| s.lines().next().map(|l| l.trim().to_string())).filter(|s| !s.is_empty())
    }
    /// `$RS/rejoin/ID`: a session of this bead still running on the opencode server after
    /// the loop restarted — `SID worker` or `SID reviewer`. The lane that takes the bead
    /// waits on that session instead of starting one (harness.rs rejoin_session).
    pub fn rejoin_path(&self, id: &str) -> PathBuf {
        self.rs.join("rejoin").join(id)
    }
    pub fn rejoin_set(&self, id: &str, sid: &str, kind: &str) {
        write_file(
            &self.rejoin_path(id),
            &format!(
                "{sid} {kind}
"
            ),
        );
    }
    pub fn rejoin_clear(&self, id: &str) {
        let _ = std::fs::remove_file(self.rejoin_path(id));
    }
    /// (session id, worker|reviewer), when a session is to be rejoined.
    pub fn rejoin_of(&self, id: &str) -> Option<(String, String)> {
        let s = read_to_string(&self.rejoin_path(id))?;
        let mut it = s.split_whitespace();
        Some((it.next()?.to_string(), it.next().unwrap_or("worker").to_string()))
    }
    pub fn pause_path(&self, name: &str) -> PathBuf {
        self.state_dir.join(format!("pause.{name}"))
    }
    pub fn paused(&self, name: &str) -> bool {
        self.pause_path(name).exists()
    }

    /// Ring the bell: every lane blocked on it looks again within a second.
    pub fn wake(&self) {
        touch(&self.state_dir.join("wake"));
    }

    // ---- held: in a queue, waiting on the world ------------------------------------
    /// Hold a bead with a reason; a second hold with the same reason is silent.
    /// Returns true when this is a new hold (the caller logs/notes it once).
    pub fn hold(&self, id: &str, why: &str) -> bool {
        let p = self.held_path(id);
        let old = read_to_string(&p).unwrap_or_default();
        if old.trim() == why.trim() {
            crate::util::touch(&p);
            write_file(&self.held_count_path(id), &format!("{}\n", self.held_count(id) + 1));
            return false;
        }
        write_file(&p, &format!("{why}\n"));
        write_file(&self.held_count_path(id), "1\n");
        true
    }
    pub fn release(&self, id: &str) -> bool {
        let _ = std::fs::remove_file(self.held_count_path(id));
        std::fs::remove_file(self.held_path(id)).is_ok()
    }
    pub fn held_why(&self, id: &str) -> Option<String> {
        read_to_string(&self.held_path(id)).map(|s| s.trim().to_string())
    }
    pub fn held_since(&self, id: &str) -> i64 {
        mtime(&self.held_path(id))
    }

    // ---- the merge queue's count --------------------------------------------------
    /// PRs this loop opened and is waiting on: adopted ones cost CI, not the model.
    pub fn inflight_ids(&self) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(self.rs.join("inflight"))
            .map(|rd| rd.flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| !n.starts_with('.')).collect())
            .unwrap_or_default();
        v.sort();
        v
    }
    /// The whole merge queue, every target together — `status`'s count; the two
    /// `max_inflight` gates (round.rs, lanes.rs) want `inflight_count_for` instead.
    #[allow(dead_code)]
    pub fn inflight_count(&self) -> u64 {
        self.inflight_ids().iter().filter(|id| !self.mark(id, "adopted").exists()).count() as u64 + self.proposed_ids().len() as u64
    }
    /// `inflight_count`, restricted to the beads claimed on `target` (`target_of`; `""`
    /// is the default target) — so a PR waiting on a foreign repo's CI does not count
    /// against this repo's own `max_inflight` (docs/design-targets.md). A `proposed/ID`
    /// (`open_pr = "ask"`, waiting on a human to publish) holds a slot the same way.
    pub fn inflight_count_for(&self, target: &str) -> u64 {
        self.inflight_ids().iter().filter(|id| !self.mark(id, "adopted").exists() && self.target_of(id) == target).count() as u64
            + self.proposed_ids().iter().filter(|id| self.target_of(id) == target).count() as u64
    }

    // ---- stages -----------------------------------------------------------------
    /// `stage_for N`: the stage a failure count lands on, or None when exhausted (and
    /// `on_exhaust` is not `repeat`).
    pub fn stage_for(&self, n: u64) -> Option<StageHit> {
        stage_for(&self.stages, &self.on_exhaust, self.worker_timeout, n)
    }
    /// `last_stage_start`: the lowest failure count that lands on the last stage.
    pub fn last_stage_start(&self) -> u64 {
        let total: u64 = self.stages.iter().map(|s| s.failures).sum();
        total - self.stages.last().map(|s| s.failures).unwrap_or(1)
    }
}

pub fn stage_for(stages: &[Stage], on_exhaust: &str, worker_timeout: u64, n: u64) -> Option<StageHit> {
    let total: u64 = stages.iter().map(|s| s.failures).sum();
    let mut n = n;
    if n >= total {
        if on_exhaust != "repeat" || total == 0 {
            return None;
        }
        n %= total;
    }
    let mut count = 0;
    for (i, s) in stages.iter().enumerate() {
        count += s.failures;
        if n < count {
            return Some(StageHit {
                model: s.worker.clone(),
                review: s.reviewer.clone(),
                timeout: s.timeout.unwrap_or(worker_timeout),
                last: i + 1 == stages.len(),
                index: i + 1,
                seats: s.seats.clone(),
                approvals: s.approvals.clone(),
            });
        }
    }
    None
}

/// `stage_start(&stages, NAME)`: the failure count at which the named stage begins — the
/// sum of `failures` of the stages before it. "last" names the last stage. None when no
/// stage has the name.
pub fn stage_start(stages: &[Stage], name: &str) -> Option<u64> {
    let idx = if name == "last" { stages.len().checked_sub(1) } else { stages.iter().position(|s| s.name == name) }?;
    Some(stages[..idx].iter().map(|s| s.failures).sum())
}

/// The review queue's order: fewest failures, then oldest first.
pub fn review_queue(repo: &Repo) -> Vec<String> {
    let mut v: Vec<(u64, i64, String)> = std::fs::read_dir(repo.rs.join("review"))
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
                .filter_map(|e| e.file_name().into_string().ok())
                .map(|id| (repo.failures_of(&id), mtime(&repo.review_path(&id)), id))
                .collect()
        })
        .unwrap_or_default();
    v.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)));
    v.into_iter().map(|t| t.2).collect()
}

/// `dev_queue`: `bd ready -l LABEL` — open beads, the label, no open blocker — fewest
/// failures first (a stable sort keeps bd's order within a count). A bead that is also
/// in the review or merge queue, or on a lane, is not handed out again whatever bd says
/// (invariant: one place).
pub fn dev_queue(repo: &Repo) -> Vec<String> {
    order_dev(repo, crate::shell::bd_ready(repo))
}

/// The dev queue from what `bd ready` said, in the loop's order.
pub fn order_dev(repo: &Repo, ready: Vec<String>) -> Vec<String> {
    let lanes = repo.lane_files();
    let mut v: Vec<(bool, u64, usize, String)> = ready
        .into_iter()
        .enumerate()
        .filter(|(_, id)| !repo.review_path(id).exists() && !repo.inflight_path(id).exists())
        .filter(|(_, id)| !lanes.iter().any(|n| repo.lane_bead(n).as_deref() == Some(id)))
        // a session to rejoin goes first: it is already running, and it holds the server
        .map(|(i, id)| (repo.rejoin_path(&id).exists(), repo.failures_of(&id), i, id))
        .collect();
    v.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)));
    v.into_iter().map(|t| t.3).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn st(w: &str, r: &str, f: u64) -> Stage {
        Stage {
            name: String::new(),
            worker: w.into(),
            seats: if r.is_empty() { Vec::new() } else { vec![Seat { model: r.into(), agent: String::new() }] },
            reviewer: r.into(),
            failures: f,
            timeout: None,
            approvals: Approvals::All,
        }
    }
    #[test]
    fn research_file_is_read_and_cleared() {
        let d = crate::config::scratch("research");
        let repo = crate::config::test_repo(&d, &["a"]);
        assert_eq!(repo.research_of("t-1"), None, "no brief yet");
        write_file(&repo.research_path("t-1"), "Files:\n- work.txt\n");
        write_file(&repo.research_prev_path("t-1"), "old\n");
        assert_eq!(repo.research_of("t-1").as_deref(), Some("Files:\n- work.txt\n"));
        repo.research_clear("t-1");
        assert_eq!(repo.research_of("t-1"), None, "the brief goes");
        assert!(!repo.research_prev_path("t-1").exists(), "and the earlier one");
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn quorum_all_any_and_a_count() {
        assert_eq!(quorum(&[], &Approvals::All), Quorum::Approve, "no reviewer: straight to PR");
        assert_eq!(quorum(&[], &Approvals::Any), Quorum::Approve);
        assert_eq!(quorum(&[], &Approvals::Count(2)), Quorum::Approve);

        assert_eq!(quorum(&[Some(true), Some(true)], &Approvals::All), Quorum::Approve);
        assert_eq!(quorum(&[Some(true), Some(false)], &Approvals::All), Quorum::Reject);
        assert_eq!(quorum(&[Some(true), None], &Approvals::All), Quorum::Pending);
        assert_eq!(quorum(&[Some(true), Some(true), Some(true)], &Approvals::All), Quorum::Approve);
        assert_eq!(quorum(&[Some(true), Some(true), Some(false)], &Approvals::All), Quorum::Reject);
        assert_eq!(quorum(&[Some(true), None, None], &Approvals::All), Quorum::Pending);

        assert_eq!(quorum(&[Some(true), Some(false)], &Approvals::Any), Quorum::Approve);
        assert_eq!(quorum(&[Some(false), Some(false)], &Approvals::Any), Quorum::Reject);
        assert_eq!(quorum(&[Some(false), None], &Approvals::Any), Quorum::Pending);
        assert_eq!(quorum(&[None, None, Some(true)], &Approvals::Any), Quorum::Approve);
        assert_eq!(quorum(&[Some(false), Some(false), Some(false)], &Approvals::Any), Quorum::Reject);
        assert_eq!(quorum(&[Some(false), None, None], &Approvals::Any), Quorum::Pending);

        assert_eq!(quorum(&[Some(true), Some(true)], &Approvals::Count(2)), Quorum::Approve);
        assert_eq!(quorum(&[Some(true), Some(false)], &Approvals::Count(2)), Quorum::Reject);
        assert_eq!(quorum(&[Some(true), None], &Approvals::Count(2)), Quorum::Pending);
        assert_eq!(quorum(&[Some(true), Some(true), None], &Approvals::Count(2)), Quorum::Approve);
        assert_eq!(quorum(&[Some(true), Some(false), Some(false)], &Approvals::Count(2)), Quorum::Reject);
        assert_eq!(quorum(&[Some(true), None, None], &Approvals::Count(2)), Quorum::Pending);
    }
    #[test]
    fn stages_by_failure_count() {
        let s = vec![st("fast", "rev", 3), st("slow", "senior", 2), st("claude/sonnet", "claude/sonnet", 1)];
        let hit = |n| stage_for(&s, "park", 60, n);
        assert_eq!(hit(0).unwrap().model, "fast");
        assert_eq!(hit(2).unwrap().model, "fast");
        assert_eq!(hit(3).unwrap().model, "slow");
        assert_eq!(hit(4).unwrap().index, 2);
        let last = hit(5).unwrap();
        assert!(last.last && last.model == "claude/sonnet");
        assert!(hit(6).is_none(), "exhausted parks");
        assert_eq!(stage_for(&s, "repeat", 60, 6).unwrap().model, "fast");
        assert_eq!(stage_for(&s, "repeat", 60, 11).unwrap().model, "claude/sonnet");
    }
    #[test]
    fn timeout_falls_back_to_worker_timeout() {
        let mut s = vec![st("a", "", 1)];
        assert_eq!(stage_for(&s, "park", 60, 0).unwrap().timeout, 60);
        s[0].timeout = Some(7);
        assert_eq!(stage_for(&s, "park", 60, 0).unwrap().timeout, 7);
    }
    #[test]
    fn a_stage_label_floors_the_failure_count() {
        let mut s = vec![st("fast", "rev", 3), st("slow", "senior", 2), st("claude/sonnet", "claude/sonnet", 1)];
        s[1].name = "senior".into();
        assert_eq!(stage_start(&s, "senior"), Some(3));
        assert_eq!(stage_start(&s, "last"), Some(5));
        assert_eq!(stage_start(&s, "nope"), None);
    }
    #[test]
    fn last_stage_start_is_the_first_count_that_lands_there() {
        let d = crate::config::scratch("last-stage");
        let repo = crate::config::test_repo(&d, &["fast::2", "slow::2", "claude/opus:claude/opus:1"]);
        assert_eq!(repo.last_stage_start(), 4);
        assert_eq!(repo.stage_for(4).unwrap().model, "claude/opus");
        assert!(repo.stage_for(4).unwrap().last);
        let one = crate::config::test_repo(&d, &["only::3"]);
        assert_eq!(one.last_stage_start(), 0);
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn failures_are_a_file() {
        let d = crate::config::scratch("failures");
        let repo = crate::config::test_repo(&d, &["a"]);
        assert_eq!(repo.failures_of("t-1"), 0, "no file: none");
        repo.set_failures("t-1", 2);
        assert_eq!(repo.failures_of("t-1"), 2);
        assert_eq!(std::fs::read_to_string(repo.rs.join("beads/t-1/failures")).unwrap(), "2\n");
        write_file(&repo.failures_path("t-2"), "junk");
        assert_eq!(repo.failures_of("t-2"), 0, "an unreadable count is none");
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn dev_queue_order_and_the_one_place_invariant() {
        // fewest failures first, bd's order within a count; a bead in the review or merge
        // queue or on a lane is not handed out again whatever bd says.
        let d = crate::config::scratch("dev-queue");
        let repo = crate::config::test_repo(&d, &["a::3"]);
        let ids = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        repo.set_failures("t-1", 1);
        repo.set_failures("t-7", 2);
        assert_eq!(order_dev(&repo, ids(&["t-1", "t-2", "t-7", "t-3"])), ids(&["t-2", "t-3", "t-1", "t-7"]));
        write_file(&repo.review_path("t-2"), "DONE: x\n");
        write_file(&repo.inflight_path("t-3"), "https://example/pull/7\n");
        assert_eq!(order_dev(&repo, ids(&["t-1", "t-2", "t-7", "t-3"])), ids(&["t-1", "t-7"]), "review and merge queues excluded");
        repo.lane_set("dev", "t-1");
        assert_eq!(order_dev(&repo, ids(&["t-1", "t-7"])), ids(&["t-7"]), "the bead on a lane excluded");
        repo.lane_clear("dev");
        repo.lane_set("review", "t-7");
        assert_eq!(order_dev(&repo, ids(&["t-1", "t-7"])), ids(&["t-1"]));
        assert_eq!(repo.lane_bead("review").as_deref(), Some("t-7"));
        assert!(repo.lane_busy("review") && !repo.lane_busy("dev"));
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn review_queue_is_fewest_failures_then_oldest() {
        let d = crate::config::scratch("review-queue");
        let repo = crate::config::test_repo(&d, &["a::3"]);
        for (id, age) in [("t-1", 30), ("t-2", 20), ("t-3", 10)] {
            write_file(&repo.review_path(id), "DONE\n");
            let t = crate::util::now() - age;
            let times = [libc::timespec { tv_sec: t, tv_nsec: 0 }, libc::timespec { tv_sec: t, tv_nsec: 0 }];
            let c = std::ffi::CString::new(repo.review_path(id).to_string_lossy().as_bytes()).unwrap();
            unsafe { libc::utimensat(libc::AT_FDCWD, c.as_ptr(), times.as_ptr(), 0) };
        }
        repo.set_failures("t-1", 1);
        assert_eq!(review_queue(&repo), vec!["t-2", "t-3", "t-1"]);
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn seat_files_live_beside_the_review_queue() {
        let d = crate::config::scratch("seat-files");
        let repo = crate::config::test_repo(&d, &["a"]);
        write_file(&repo.review_path("t-1"), "DONE\n");
        assert_eq!(review_queue(&repo), vec!["t-1"]);
        repo.seat_set_running("t-1", 1);
        assert_eq!(review_queue(&repo), vec!["t-1"]);
        assert!(repo.seat_running("t-1", 1));
        repo.seat_clear_running("t-1", 1);
        assert!(!repo.seat_running("t-1", 1));
        repo.seat_set_verdict("t-1", 2, "APPROVE: ok");
        assert!(repo.seat_verdict("t-1", 2).unwrap().contains("APPROVE"));
        assert!(repo.seat_verdict("t-1", 1).is_none());
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn review_clear_takes_the_seats() {
        let d = crate::config::scratch("review-clear");
        let repo = crate::config::test_repo(&d, &["a"]);
        write_file(&repo.review_path("t-1"), "DONE\n");
        repo.seat_set_verdict("t-1", 1, "APPROVE: ok");
        repo.review_clear("t-1");
        assert!(!repo.review_path("t-1").exists());
        assert!(!repo.seat_dir("t-1").exists());
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn inflight_count_skips_adopted_and_markers() {
        let d = crate::config::scratch("inflight");
        let repo = crate::config::test_repo(&d, &["a"]);
        assert_eq!(repo.inflight_count(), 0);
        write_file(&repo.inflight_path("t-1.2"), "url\n");
        write_file(&repo.inflight_path("x-1"), "url\n");
        touch(&repo.mark("x-1", "adopted"));
        touch(&repo.mark("t-1.2", "red"));
        assert_eq!(repo.inflight_ids(), vec!["t-1.2", "x-1"], "the markers are not PRs");
        assert_eq!(repo.inflight_count(), 1, "a dotted id counts; an adopted PR does not");
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn inflight_count_for_is_per_target() {
        let d = crate::config::scratch("inflight-target");
        let repo = crate::config::test_repo(&d, &["a"]);
        write_file(&repo.inflight_path("t-1"), "url\n");
        write_file(&repo.inflight_path("t-2"), "url\n");
        repo.set_target("t-2", "t");
        assert_eq!(repo.inflight_count_for("t"), 1);
        assert_eq!(repo.inflight_count_for(""), 1);
        assert_eq!(repo.inflight_count(), 2);
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn hold_is_said_once_per_reason() {
        let d = crate::config::scratch("hold");
        let repo = crate::config::test_repo(&d, &["a"]);
        assert!(repo.hold("t-1", "setup failed: false"), "a new hold");
        let old = crate::util::now() - 1000;
        let times = [libc::timespec { tv_sec: old, tv_nsec: 0 }, libc::timespec { tv_sec: old, tv_nsec: 0 }];
        let c = std::ffi::CString::new(repo.held_path("t-1").to_string_lossy().as_bytes()).unwrap();
        unsafe { libc::utimensat(libc::AT_FDCWD, c.as_ptr(), times.as_ptr(), 0) };
        assert_eq!(repo.held_since("t-1"), old, "backdated for the check below");
        assert!(!repo.hold("t-1", "setup failed: false\n"), "the same reason again is silent");
        assert!(repo.held_since("t-1") > old, "a second hold with the same reason still restarts the backoff clock");
        assert_eq!(repo.held_count("t-1"), 2, "the repeat count went up");
        assert!(repo.hold("t-1", "gh cannot read the PR"), "a new reason is a new hold");
        assert_eq!(repo.held_count("t-1"), 1, "a new reason resets the count");
        assert_eq!(repo.held_why("t-1").as_deref(), Some("gh cannot read the PR"));
        assert!(repo.held_since("t-1") > 0);
        assert!(repo.release("t-1"));
        assert!(!repo.release("t-1"), "nothing to release");
        assert!(repo.held_why("t-1").is_none());
        let _ = std::fs::remove_dir_all(&d);
    }
}
