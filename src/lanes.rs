//! The lanes, and the two ways to run them.
//!
//! `tick`: reconcile the merge queue, then the dev and review lanes side by side until
//! both queues are drained and both lanes idle, then reconcile once more, and exit — the
//! oneshot the timer used to run, kept for hand runs and the test suite.
//!
//! `run`: the resident loop. The same lanes, but a lane with nothing to do blocks on the
//! bell instead of leaving; a third loop, the merge watcher, polls GitHub while a PR is
//! in flight and rings the bell when one closes or comes back; nothing waits on a
//! clock while there is work. A lane that dies is restarted. The binary re-execs itself
//! at an idle moment when the file on disk changes (the deploy).
//!
//! Repos are walked round-robin — each pass starts one repo later than the last — and
//! a repo named in `$STATE_DIR/priority` goes first on every pass.
use crate::config::Repo;
use crate::round::{dev_one, review_one, Opts, Pass};
use crate::util::{log, mtime, sleep_secs, touch};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct Ctx {
    pub repos: Vec<PathBuf>,
    pub opts: Opts,
    pub once: bool,
    pub serial: bool,
    pub state_dir: PathBuf,
    /// tick semantics: leave when the queues are drained and the other lane idle
    pub until_idle: bool,
    /// a stage somewhere names claude/*: a third lane takes those rounds, and the dev
    /// and review lanes leave them alone
    pub claude_lane: bool,
}

/// The lanes this loop runs: dev and review always, claude when a stage names it.
pub fn lane_names(ctx: &Ctx) -> Vec<&'static str> {
    if ctx.claude_lane {
        vec!["dev", "review", "claude"]
    } else {
        vec!["dev", "review"]
    }
}

/// Whether any repo's stages name a claude/* worker or reviewer (or conflict_worker).
pub fn has_claude_stage(repos: &[PathBuf], model_flag: Option<&str>) -> bool {
    repos.iter().any(|r| {
        let repo = Repo::load(r, model_flag);
        repo.conflict_worker.starts_with("claude/")
            || repo.stages.iter().any(|s| s.worker.starts_with("claude/") || s.reviewer.starts_with("claude/"))
    })
}

fn lane_wait() -> f64 {
    std::env::var("LANE_WAIT").ok().and_then(|s| s.parse().ok()).unwrap_or(10.0)
}

/// `$STATE_DIR/priority`: the repo the lanes look at first, as a path or a slug.
pub fn priority_repo(state_dir: &Path) -> Option<PathBuf> {
    crate::util::read_to_string(&state_dir.join("priority"))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(|s| crate::util::expand_tilde(&s))
}

pub fn set_priority(state_dir: &Path, repo: Option<&str>) {
    let p = state_dir.join("priority");
    match repo {
        Some(r) if r != "none" => {
            let canon = std::fs::canonicalize(r).map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| r.to_string());
            crate::util::write_file(&p, &format!("{canon}\n"));
            log(&format!("priority repo: {canon} (the lanes look there first)"));
        }
        _ => {
            let _ = std::fs::remove_file(&p);
            log("priority repo cleared: the lanes take the repos round-robin");
        }
    }
    touch(&state_dir.join("wake"));
}

/// The repos in this pass's order: the priority repo first, then the rest rotated by the
/// pass number so that no repo is always last.
pub fn repos_in_order(repos: &[PathBuf], state_dir: &Path, pass: usize) -> Vec<PathBuf> {
    if repos.is_empty() {
        return Vec::new();
    }
    let prio = priority_repo(state_dir);
    let is_prio = |r: &PathBuf| {
        prio.as_ref()
            .map(|p| {
                let canon = std::fs::canonicalize(r).unwrap_or_else(|_| r.clone());
                p == &canon || p == r || r.file_name().map(|n| n == p.as_os_str()).unwrap_or(false)
            })
            .unwrap_or(false)
    };
    let mut rest: Vec<PathBuf> = repos.iter().filter(|r| !is_prio(r)).cloned().collect();
    let n = rest.len();
    if n > 0 {
        rest.rotate_left(pass % n);
    }
    let mut out: Vec<PathBuf> = repos.iter().filter(|r| is_prio(r)).cloned().collect();
    out.extend(rest);
    out
}

/// A lock file the bash held with `flock -n`: taken for the process's life.
pub fn try_lock(path: &Path) -> Option<std::fs::File> {
    use std::os::unix::io::AsRawFd;
    let f = std::fs::OpenOptions::new().create(true).append(true).open(path).ok()?;
    let rc = unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        Some(f)
    } else {
        None
    }
}

/// Which lanes in this process are mid-pass — between starting to look at their queues
/// and either claiming a bead (the lane file then says so) or finding nothing. The bash
/// had only the lane file, and a lane picking slowly looked idle to the other one.
static PASSING: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());

fn set_passing(name: &'static str, on: bool) {
    let mut g = PASSING.lock().unwrap();
    g.retain(|n| *n != name);
    if on {
        g.push(name);
    }
}

fn other_busy(ctx: &Ctx, name: &str) -> bool {
    if PASSING.lock().unwrap().contains(&name) {
        return true;
    }
    ctx.repos.iter().any(|r| Repo::load(r, ctx.opts.model_flag.as_deref()).lane_busy(name))
}

/// `queued_work`: something a lane would take right now.
fn queued_work(ctx: &Ctx) -> bool {
    for r in &ctx.repos {
        let repo = Repo::load(r, ctx.opts.model_flag.as_deref());
        if !repo.paused("review") && !crate::state::review_queue(&repo).is_empty() {
            return true;
        }
        if !repo.paused("dev") && repo.inflight_count() < repo.max_inflight && !crate::state::dev_queue(&repo).is_empty() {
            return true;
        }
    }
    false
}

/// A snapshot of everything the bell watches: the wake file, each repo's queue
/// directories and its `.beads/` (a bead labelled or reopened by hand), the pause files.
fn world(ctx: &Ctx) -> Vec<i64> {
    let mut v = vec![
        mtime(&ctx.state_dir.join("wake")),
        mtime(&ctx.state_dir.join("pause.dev")),
        mtime(&ctx.state_dir.join("pause.review")),
        mtime(&ctx.state_dir.join("priority")),
    ];
    for r in &ctx.repos {
        let slug = r.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let rs = ctx.state_dir.join(&slug);
        v.push(mtime(&rs.join("review")));
        v.push(mtime(&rs.join("inflight")));
        v.push(mtime(&rs.join("held")));
        v.push(mtime(&r.join(".beads")));
        if let Ok(rd) = std::fs::read_dir(r.join(".beads")) {
            for e in rd.flatten() {
                v.push(mtime(&e.path()));
            }
        }
    }
    v
}

/// Block until something changes, or `max` seconds pass (the heartbeat). Looks every
/// second; a change anywhere the lanes read wakes every waiter.
pub fn wait_for_work(ctx: &Ctx, max: f64) {
    let start = std::time::Instant::now();
    let before = world(ctx);
    loop {
        sleep_secs(1.0_f64.min(max));
        if start.elapsed().as_secs_f64() >= max || world(ctx) != before {
            crate::harness::forget_probes();
            return;
        }
    }
}

/// `lane NAME`: one lane's passes over every repo. With `until_idle` it leaves when its
/// queue is empty and the other lane has looked idle three checks running (the other may
/// still send something this way); otherwise it blocks on the bell and goes on.
/// One pass of the Claude lane over a repo: finishing before starting — a review round
/// whose reviewer is claude/*, else a worker round whose worker is; and after a worker
/// round, the bead's review round too when that is Claude's as well, so the bead's
/// rounds stay together (a `--once` tick then carries a Claude bead to its PR, as the
/// dev+review pair did before the lane existed).
fn claude_pass(repo: &Repo, opts: &Opts) -> Pass {
    if review_one(repo, opts, None, Some(true)) == Pass::Worked {
        return Pass::Worked;
    }
    let mut last = None;
    if dev_one(repo, opts, None, &mut last, Some(true)) == Pass::Worked {
        if let Some(id) = last {
            if repo.review_path(&id).exists() {
                // Claude's own reviewer, or none at all (straight to PR): nothing here waits
                // on a local model, so it is this lane's to finish.
                let reviewer = repo.stage_for(repo.failures_of(&id)).map(|s| s.review).unwrap_or_default();
                if reviewer.starts_with("claude/") || reviewer.is_empty() {
                    review_one(repo, opts, Some(&id), None);
                }
            }
        }
        return Pass::Worked;
    }
    Pass::Nothing
}

/// Any lane but `name` mid-pass or on a round: the reason a lane with an empty queue
/// does not leave a tick yet.
fn others_busy(ctx: &Ctx, name: &str) -> bool {
    lane_names(ctx).into_iter().filter(|n| *n != name).any(|n| other_busy(ctx, n))
}

pub fn lane(ctx: &Ctx, name: &str, pass_counter: Arc<AtomicUsize>) {
    // Which rounds this lane takes: with a Claude lane, dev and review leave claude/*
    // rounds to it; without one, they take everything.
    let only: Option<bool> = match name {
        "claude" => Some(true),
        _ if ctx.claude_lane => Some(false),
        _ => None,
    };
    let _lock = match try_lock(&ctx.state_dir.join(format!("lock.{name}"))) {
        Some(l) => l,
        None => {
            log(&format!("another {name} lane holds {}/lock.{name}; skipping", ctx.state_dir.display()));
            return;
        }
    };
    let mut idle = 0;
    let mut said_paused = false;
    loop {
        // Paused by hand (pause NAME, or the UI): start nothing new.
        if ctx.state_dir.join(format!("pause.{name}")).exists() {
            if ctx.until_idle {
                log(&format!("{name} lane paused; starting nothing"));
                return;
            }
            if !said_paused {
                log(&format!("{name} lane paused; starting nothing until resume"));
                said_paused = true;
            }
            wait_for_work(ctx, 60.0);
            continue;
        }
        said_paused = false;
        let pass = pass_counter.fetch_add(1, Ordering::SeqCst);
        let mut moved = false;
        let me: &'static str = match name {
            "dev" => "dev",
            "claude" => "claude",
            _ => "review",
        };
        set_passing(me, true);
        for r in repos_in_order(&ctx.repos, &ctx.state_dir, pass) {
            let repo = Repo::load(&r, ctx.opts.model_flag.as_deref());
            let mut last = None;
            let p = match name {
                "dev" => dev_one(&repo, &ctx.opts, None, &mut last, only),
                "claude" => claude_pass(&repo, &ctx.opts),
                _ => review_one(&repo, &ctx.opts, None, only),
            };
            if p == Pass::Worked {
                moved = true;
                if ctx.once {
                    set_passing(me, false);
                    return;
                }
            }
        }
        set_passing(me, false);
        if moved {
            idle = 0;
            continue;
        }
        if ctx.once {
            return;
        }
        if ctx.until_idle {
            // Nothing for this lane now; the other may still hand something over. The other
            // lane looks idle between its rounds too — and at the very start, before it has
            // claimed anything — so this lane leaves only after seeing it idle three checks
            // in a row, LANE_WAIT apart.
            if others_busy(ctx, name) {
                idle = 0;
            } else {
                idle += 1;
            }
            if idle >= 3 {
                return;
            }
            sleep_secs(lane_wait());
        } else {
            wait_for_work(ctx, 60.0);
        }
    }
}

fn reconcile_all(ctx: &Ctx) {
    for r in &ctx.repos {
        let repo = Repo::load(r, ctx.opts.model_flag.as_deref());
        crate::merge::reconcile(&repo);
    }
}

/// `tick`: reconcile, both lanes until drained, reconcile.
pub fn tick(ctx: &Ctx) {
    reconcile_all(ctx);
    let mut round = 0;
    loop {
        let counter = Arc::new(AtomicUsize::new(0));
        if ctx.serial {
            for name in lane_names(ctx) {
                lane(ctx, name, counter.clone());
            }
        } else {
            let handles: Vec<_> = lane_names(ctx)
                .into_iter()
                .map(|name| {
                    let c = ctx.clone();
                    let k = counter.clone();
                    std::thread::spawn(move || lane(&c, name, k))
                })
                .collect();
            for h in handles {
                let _ = h.join();
            }
        }
        round += 1;
        // Both lanes left. If one left work the other should have taken (a race at startup,
        // a hand-run lane holding a lock), go round once more rather than wait for the timer.
        if !ctx.once && round < 3 && queued_work(ctx) {
            log("lanes done but work is queued; going round again");
            continue;
        }
        break;
    }
    reconcile_all(ctx);
}

/// Start is a recovery: stale lane markers go, sessions under every worktree are
/// aborted (nothing legitimately runs at start), a dev round the last stop cut short is
/// reopened with no failure, and the worktree list is pruned.
pub fn recover(ctx: &Ctx) {
    for r in &ctx.repos {
        let repo = Repo::load(r, ctx.opts.model_flag.as_deref());
        for name in ["dev", "review", "claude"] {
            if repo.lane_busy(name) {
                log(&format!("{}: stale lane.{name} from a stop; cleared", repo.slug));
                repo.lane_clear(name);
            }
        }
        let _ = crate::shell::git(&repo.repo, &["worktree", "prune"]);
        if let Ok(rd) = std::fs::read_dir(repo.rs.join("wt")) {
            for e in rd.flatten() {
                let dir = e.path();
                if !dir.is_dir() {
                    continue;
                }
                crate::harness::abort_sessions(&repo, &dir);
                let id = e.file_name().to_string_lossy().into_owned();
                if repo.review_path(&id).exists() || repo.inflight_path(&id).exists() {
                    continue;
                }
                // in_progress + a worktree + in no queue = a round the stop interrupted
                let inprog = crate::shell::bd_in_progress_json(&repo);
                let is_inprog =
                    inprog.as_array().map(|a| a.iter().any(|b| b.get("id").and_then(|i| i.as_str()) == Some(&id))).unwrap_or(false);
                if is_inprog {
                    crate::shell::bd_note(
                        &repo,
                        &id,
                        &format!(
                            "bead-loop {}: round interrupted by a stop; back in the dev queue, no failure charged",
                            crate::util::date_iminutes()
                        ),
                    );
                    crate::shell::bd_status(&repo, &id, "open");
                    log(&format!("{}: {id}: round interrupted by the last stop; back in the dev queue", repo.slug));
                }
            }
        }
    }
    crate::harness::forget_probes();
}

/// The merge watcher: while any PR is in flight, ask GitHub every 30 s (sooner when the
/// bell rings); with none, block on the bell.
fn watcher(ctx: &Ctx) {
    loop {
        let mut any = false;
        for r in &ctx.repos {
            let repo = Repo::load(r, ctx.opts.model_flag.as_deref());
            if !repo.inflight_ids().is_empty() || repo.adopt {
                any = any || !repo.inflight_ids().is_empty();
                crate::merge::reconcile(&repo);
            }
        }
        wait_for_work(ctx, if any { 30.0 } else { 120.0 });
    }
}

/// `run`: the resident loop.
pub fn run(ctx: &Ctx) -> ! {
    log(&format!("bead-loop resident: {} repo(s); lanes {}; merge watcher", ctx.repos.len(), lane_names(ctx).join(", ")));
    recover(ctx);
    crate::merge::set_quiet(true);
    let exe = std::env::current_exe().ok();
    let exe_stamp = exe.as_ref().map(|p| (mtime(p), std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)));
    let counter = Arc::new(AtomicUsize::new(0));
    let supervise = |name: &'static str, ctx: Ctx, counter: Arc<AtomicUsize>| {
        std::thread::Builder::new()
            .name(name.into())
            .spawn(move || loop {
                let c = ctx.clone();
                let k = counter.clone();
                let h = std::thread::Builder::new().name(format!("{name}-lane")).spawn(move || lane(&c, name, k));
                match h {
                    Ok(h) => {
                        let _ = h.join();
                    }
                    Err(e) => log(&format!("cannot start the {name} lane: {e}")),
                }
                log(&format!("{name} lane stopped; starting it again in 10 s"));
                sleep_secs(10.0);
            })
            .expect("lane thread")
    };
    let _lanes: Vec<_> = lane_names(ctx).into_iter().map(|name| supervise(name, ctx.clone(), counter.clone())).collect();
    let wctx = ctx.clone();
    let _w = std::thread::Builder::new()
        .name("watcher".into())
        .spawn(move || loop {
            let c = wctx.clone();
            let h = std::thread::spawn(move || watcher(&c));
            let _ = h.join();
            log("merge watcher stopped; starting it again in 10 s");
            sleep_secs(10.0);
        })
        .expect("watcher thread");
    // The main thread: the update check. When the binary on disk is not the one running
    // and no lane is on a round, exec the new one with the same arguments.
    loop {
        sleep_secs(60.0);
        if let (Some(exe), Some((m, len))) = (&exe, exe_stamp) {
            let now_stamp = (mtime(exe), std::fs::metadata(exe).map(|x| x.len()).unwrap_or(0));
            if now_stamp != (m, len) && now_stamp.0 != 0 {
                let busy = ctx.repos.iter().any(|r| {
                    let repo = Repo::load(r, ctx.opts.model_flag.as_deref());
                    repo.lane_busy("dev") || repo.lane_busy("review") || repo.lane_busy("claude")
                });
                if !busy {
                    log("binary changed on disk and the lanes are idle: re-exec");
                    use std::os::unix::process::CommandExt;
                    let args: Vec<String> = std::env::args().skip(1).collect();
                    let err = std::process::Command::new(exe).args(&args).exec();
                    log(&format!("re-exec failed: {err}"));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_robin_rotates_and_priority_leads() {
        let t = std::env::temp_dir().join(format!("bl-rr-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&t);
        let repos = vec![PathBuf::from("/a"), PathBuf::from("/b"), PathBuf::from("/c")];
        assert_eq!(repos_in_order(&repos, &t, 0), repos);
        assert_eq!(repos_in_order(&repos, &t, 1), vec![PathBuf::from("/b"), PathBuf::from("/c"), PathBuf::from("/a")]);
        crate::util::write_file(&t.join("priority"), "/c\n");
        assert_eq!(repos_in_order(&repos, &t, 1), vec![PathBuf::from("/c"), PathBuf::from("/b"), PathBuf::from("/a")]);
        crate::util::write_file(&t.join("priority"), "b\n");
        assert_eq!(repos_in_order(&repos, &t, 0)[0], PathBuf::from("/b"));
        let _ = std::fs::remove_dir_all(&t);
    }
}
