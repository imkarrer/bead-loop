//! The state on disk, `~/.local/state/bead-loop/<repo>/`, and what it means:
//!
//! - `failures/ID` the count of send-backs (→ the stage), `failures/ID.notes` the history
//! - `review/ID`   the review queue: the worker's last line, for the reviewer's prompt
//! - `inflight/ID` the merge queue: the PR url; `.ID.red|nocheck|adopted|fixing|conflict`
//!   beside it
//! - `held/ID`     the bead is in its queue and waits on something outside the loop; the
//!   file says what. Shown in the human queue, polled, cleared when the reason goes.
//! - `lane.dev`, `lane.review` the bead each lane is on
//! - `wt/ID` the worktree while a bead is on a lane or waiting for review
//!
//! and, under the state dir itself: `lock`, `lock.dev`, `lock.review`, `pause.dev`,
//! `pause.review`, `priority` (the repo the lanes look at first), `wake` (the bell).
use crate::config::{Repo, Stage};
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
}

impl Repo {
    // ---- files ------------------------------------------------------------------
    pub fn failures_of(&self, id: &str) -> u64 {
        read_to_string(&self.rs.join("failures").join(id)).and_then(|s| s.trim().parse().ok()).unwrap_or(0)
    }
    pub fn set_failures(&self, id: &str, n: u64) {
        write_file(&self.rs.join("failures").join(id), &format!("{n}\n"));
    }
    pub fn notes_path(&self, id: &str) -> PathBuf {
        self.rs.join("failures").join(format!("{id}.notes"))
    }
    pub fn review_path(&self, id: &str) -> PathBuf {
        self.rs.join("review").join(id)
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
    pub fn wt(&self, id: &str) -> PathBuf {
        self.rs.join("wt").join(id)
    }
    pub fn lane_path(&self, name: &str) -> PathBuf {
        self.rs.join(format!("lane.{name}"))
    }
    pub fn lane_set(&self, name: &str, id: &str) {
        write_file(&self.lane_path(name), &format!("{id}\n"));
    }
    pub fn lane_clear(&self, name: &str) {
        let _ = std::fs::remove_file(self.lane_path(name));
    }
    pub fn lane_busy(&self, name: &str) -> bool {
        self.lane_path(name).exists()
    }
    pub fn lane_bead(&self, name: &str) -> Option<String> {
        read_to_string(&self.lane_path(name)).map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
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
            return false;
        }
        write_file(&p, &format!("{why}\n"));
        true
    }
    pub fn release(&self, id: &str) -> bool {
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
    pub fn inflight_count(&self) -> u64 {
        self.inflight_ids().iter().filter(|id| !self.mark(id, "adopted").exists()).count() as u64
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
            });
        }
    }
    None
}

/// The review queue's order: fewest failures, then oldest first.
pub fn review_queue(repo: &Repo) -> Vec<String> {
    let mut v: Vec<(u64, i64, String)> = std::fs::read_dir(repo.rs.join("review"))
        .map(|rd| {
            rd.flatten()
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
    let ready = crate::shell::bd_ready(repo);
    let mut v: Vec<(u64, usize, String)> = ready
        .into_iter()
        .enumerate()
        .filter(|(_, id)| !repo.review_path(id).exists() && !repo.inflight_path(id).exists())
        .filter(|(_, id)| repo.lane_bead("dev").as_deref() != Some(id) && repo.lane_bead("review").as_deref() != Some(id))
        .map(|(i, id)| (repo.failures_of(&id), i, id))
        .collect();
    v.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    v.into_iter().map(|t| t.2).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn st(w: &str, r: &str, f: u64) -> Stage {
        Stage { worker: w.into(), reviewer: r.into(), failures: f, timeout: None }
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
}
