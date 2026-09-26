//! The lanes, and the two ways to run them.
//!
//! A lane is a `LaneSpec` (config.rs): a name, the models whose rounds it takes, and
//! its roles. By default there is one lane per provider the config names (`devbox`,
//! `acbox`, `claude`: `providers_named`), so that a round on the CPU box never holds the
//! GPU's queue, and the other way round; `[[lanes]]` in the global config replaces them.
//!
//! A lane with `parallel = N` runs N slots, a thread each, `NAME` then `NAME.2` … — its
//! own lock and marker per slot, one pause flag for the lane. Two slots over one queue
//! would both see its first bead: round.rs `Reservation` gives each bead to one of them.
//!
//! `tick`: reconcile the merge queue, then every lane side by side until the queues are
//! drained and every lane idle, then reconcile once more, and exit — the oneshot the
//! timer used to run, kept for hand runs and the test suite.
//!
//! `run`: the resident loop. The same lanes, but a lane with nothing to do blocks on the
//! bell instead of leaving; a merge watcher polls GitHub while a PR is in flight and
//! rings the bell when one closes or comes back; nothing waits on a clock while there
//! is work. A lane that dies is restarted. The binary re-execs itself at an idle moment
//! when the file on disk changes (the deploy).
//!
//! Repos are walked round-robin — each pass starts one repo later than the last — and
//! a repo named in `$STATE_DIR/priority` goes first on every pass.
use crate::config::{LaneSpec, Repo};
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
    /// tick semantics: leave when the queues are drained and the other lanes idle
    pub until_idle: bool,
    /// the lanes this loop runs, in order — a slot each (`LaneSpec::slots`): a lane with
    /// `parallel = 2` is two entries, NAME and NAME.2
    pub lanes: Vec<LaneSpec>,
}

pub fn lane_names(ctx: &Ctx) -> Vec<String> {
    ctx.lanes.iter().map(|l| l.name.clone()).collect()
}

/// The providers the repos' config names — every stage's worker and reviewer, then
/// `conflict_worker`, `brief_model` and `research_model` when set — deduplicated in the
/// order first seen: the lanes `Layers::lanes` derives when there is no `[[lanes]]`.
pub fn providers_named(repos: &[PathBuf], model_flag: Option<&str>) -> Vec<String> {
    let mut out = Vec::new();
    for r in repos {
        for p in providers_named_in(&Repo::load(r, model_flag)) {
            if !out.contains(&p) {
                out.push(p);
            }
        }
    }
    out
}

/// `providers_named` for one repo.
pub fn providers_named_in(repo: &Repo) -> Vec<String> {
    let mut models: Vec<&str> = Vec::new();
    for s in &repo.stages {
        models.push(&s.worker);
        for x in &s.seats {
            models.push(&x.model);
        }
    }
    models.extend([repo.conflict_worker.as_str(), repo.brief_model.as_str(), repo.research_model.as_str()]);
    let mut out: Vec<String> = Vec::new();
    for m in models {
        if m.is_empty() || m == "none" {
            continue;
        }
        let p = crate::config::provider_name(m).to_string();
        if !out.contains(&p) {
            out.push(p);
        }
    }
    out
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
/// Only a pass that may claim is listed: a lane's first, and the one after a round.
static PASSING: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn set_passing(name: &str, on: bool) {
    let mut g = PASSING.lock().unwrap_or_else(|e| e.into_inner());
    g.retain(|n| n != name);
    if on {
        g.push(name.to_string());
    }
}

fn lane_busy_anywhere(ctx: &Ctx, name: &str) -> bool {
    if PASSING.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|n| n == name) {
        return true;
    }
    ctx.repos.iter().any(|r| Repo::load(r, ctx.opts.model_flag.as_deref()).lane_busy(name))
}

/// Any lane but `name` mid-pass or on a round: the reason a lane with an empty queue
/// does not leave a tick yet.
fn others_busy(ctx: &Ctx, name: &str) -> bool {
    ctx.lanes.iter().filter(|l| l.name != name).any(|l| lane_busy_anywhere(ctx, &l.name))
}

/// `queued_work`: something a lane would take right now.
fn queued_work(ctx: &Ctx) -> bool {
    for r in &ctx.repos {
        let repo = Repo::load(r, ctx.opts.model_flag.as_deref());
        for l in &ctx.lanes {
            if repo.paused(&l.lane) {
                continue;
            }
            if l.reviewer && crate::round::pick_runnable(&repo, "review", Some(l)).is_some() {
                return true;
            }
            if l.worker {
                if let Some(id) = crate::round::pick_runnable(&repo, "dev", Some(l)) {
                    if repo.inflight_count_for(&repo.target_of(&id)) < repo.max_inflight {
                        return true;
                    }
                }
            }
        }
    }
    false
}

/// A snapshot of everything the bell watches: the wake file, each repo's queue
/// directories and its `.beads/` (a bead labelled or reopened by hand), the pause and
/// priority files.
fn world(ctx: &Ctx) -> Vec<i64> {
    let mut v = vec![mtime(&ctx.state_dir.join("wake")), mtime(&ctx.state_dir.join("priority"))];
    for l in &ctx.lanes {
        v.push(mtime(&ctx.state_dir.join(format!("pause.{}", l.lane))));
    }
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

/// One pass of a lane over a repo: finishing before starting — a reviewer round this
/// lane takes, else a worker round; and after a worker round, the bead's reviewer round
/// too when that is this lane's as well (or there is no reviewer: nothing then waits on
/// a model), so a bead's rounds stay together and a `--once` tick carries it to its PR.
fn lane_pass(repo: &Repo, opts: &Opts, spec: &LaneSpec) -> Pass {
    if spec.reviewer && review_one(repo, opts, None, Some(spec), 0) == Pass::Worked {
        return Pass::Worked;
    }
    if !spec.worker {
        return Pass::Nothing;
    }
    let mut last = None;
    if dev_one(repo, opts, None, &mut last, Some(spec)) == Pass::Worked {
        if let (Some(id), true) = (last, spec.reviewer) {
            if repo.review_path(&id).exists() {
                let reviewer = repo.stage_for(repo.failures_of(&id)).map(|s| s.review).unwrap_or_default();
                // The reviewer round is a round: under the pause flag it does not start,
                // and the bead waits in the review queue for the resume.
                if (reviewer.is_empty() || spec.takes(&reviewer)) && !repo.paused(&spec.lane) {
                    review_one(repo, opts, Some(&id), Some(spec), 1);
                }
            }
        }
        return Pass::Worked;
    }
    Pass::Nothing
}

/// `pause.NAME` under the state dir: the operator's hand on the lane (`pause NAME`, the
/// page's Pause). Read before every round — `lane` says so once and waits on the bell.
pub fn paused(state_dir: &Path, name: &str) -> bool {
    state_dir.join(format!("pause.{name}")).exists()
}

/// One pass of a lane over the repos, in this pass's order: `round` runs the lane's
/// rounds on one repo. The pause flag is read before every repo, not once per pass: a
/// lane busy when the flag appears ends its round in the middle of a pass, and the next
/// repo's bead must not be its next round. (21 Sep 2026: `pause cpu` during a bead-loop
/// round; the cpu lane finished it and took inquire-platform's bead two seconds later,
/// never having looked — only the idle claude lane, at the top of its loop, said
/// "paused".) With `once`, the pass ends at its first round. Returns whether a round
/// happened.
fn walk(repos: &[PathBuf], state_dir: &Path, name: &str, pass: usize, once: bool, mut round: impl FnMut(&Path) -> Pass) -> bool {
    let mut moved = false;
    for r in repos_in_order(repos, state_dir, pass) {
        if paused(state_dir, name) {
            break;
        }
        if round(&r) == Pass::Worked {
            moved = true;
            if once {
                break;
            }
        }
    }
    moved
}

/// `lane NAME`: one lane's passes over every repo. With `until_idle` it leaves when it
/// finds nothing and the other lanes have looked idle three checks running (one may
/// still send something this way); otherwise it blocks on the bell and goes on.
pub fn lane(ctx: &Ctx, spec: &LaneSpec, pass_counter: Arc<AtomicUsize>) {
    let name = spec.name.as_str();
    let _lock = match try_lock(&ctx.state_dir.join(format!("lock.{name}"))) {
        Some(l) => l,
        None => {
            log(&format!("another {name} lane holds {}/lock.{name}; skipping", ctx.state_dir.display()));
            return;
        }
    };
    let mut idle = 0;
    let mut said_paused = false;
    // Whether this lane's next pass shows as mid-pass to the others (PASSING): its first
    // pass, and the pass after a round, the passes that may yet claim something. A pass
    // after one that found nothing does not: two lanes that each pick for longer than
    // LANE_WAIT kept finding each other mid-pass, and neither left the tick.
    let mut may_claim = true;
    loop {
        // Paused by hand (pause NAME, or the UI): start nothing new.
        if paused(&ctx.state_dir, &spec.lane) {
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
        set_passing(name, may_claim);
        let moved = walk(&ctx.repos, &ctx.state_dir, &spec.lane, pass, ctx.once, |r| {
            lane_pass(&Repo::load(r, ctx.opts.model_flag.as_deref()), &ctx.opts, spec)
        });
        set_passing(name, false);
        may_claim = moved;
        if ctx.once {
            return;
        }
        if moved {
            idle = 0;
            continue;
        }
        if ctx.until_idle {
            // Nothing for this lane now; another may still hand something over. The others
            // look idle between their rounds too — and at the very start, before they have
            // claimed anything — so this lane leaves only after seeing them idle three
            // checks in a row, LANE_WAIT apart.
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

/// `tick`: reconcile, every lane until drained, reconcile.
pub fn tick(ctx: &Ctx) {
    reconcile_all(ctx);
    let mut round = 0;
    loop {
        let counter = Arc::new(AtomicUsize::new(0));
        if ctx.serial {
            for spec in &ctx.lanes {
                lane(ctx, spec, counter.clone());
            }
        } else {
            let handles: Vec<_> = ctx
                .lanes
                .iter()
                .cloned()
                .map(|spec| {
                    let c = ctx.clone();
                    let k = counter.clone();
                    std::thread::spawn(move || lane(&c, &spec, k))
                })
                .collect();
            for h in handles {
                let _ = h.join();
            }
        }
        round += 1;
        // Every lane left. If one left work another should have taken (a race at startup,
        // a hand-run lane holding a lock), go round once more rather than wait.
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
        // Which bead each lane marker named, and when: the round in flight when the stop
        // came, for the freshness check below — a session from well before that round is
        // not this restart's to rejoin, even if it is still the newest on the worktree.
        let mut lane_mtimes = std::collections::HashMap::new();
        for name in repo.lane_files() {
            if let Some(id) = repo.lane_bead(&name) {
                lane_mtimes.insert(id, mtime(&repo.lane_path(&name)));
            }
            log(&format!("{}: stale lane.{name} from a stop; cleared", repo.slug));
            repo.lane_clear(&name);
        }
        let _ = crate::shell::git(&repo.repo, &["worktree", "prune"]);
        if let Ok(rd) = std::fs::read_dir(repo.rs.join("wt")) {
            for e in rd.flatten() {
                let dir = e.path();
                if !dir.is_dir() {
                    continue;
                }
                let id = e.file_name().to_string_lossy().into_owned();
                repo.rejoin_clear(&id);
                if repo.inflight_path(&id).exists() {
                    crate::harness::abort_sessions(&repo, &dir);
                    continue;
                }
                let in_review = repo.review_path(&id).exists();
                let inprog = crate::shell::bd_in_progress_json(&repo);
                let is_inprog =
                    inprog.as_array().map(|a| a.iter().any(|b| b.get("id").and_then(|i| i.as_str()) == Some(&id))).unwrap_or(false);
                // The server outlived the loop (a deploy restarts the binary alone): a session
                // still running here is the round going on for nobody. Rejoin it — the bead
                // back in its queue with a marker, and the lane that takes it waits on the
                // session instead of starting one — rather than abort it and start over.
                if in_review || is_inprog {
                    // Which seat, when it's a review round still running with more than
                    // one seat: the one whose `K.running` marker names it, read before the
                    // restart cuts every seat's round short. A lone reviewer is seat 1 on
                    // disk but carries no seat number in its rejoin entry or its title,
                    // same as before seats existed.
                    let multi_seat = repo.stage_for(repo.failures_of(&id)).is_some_and(|st| st.seats.len() > 1);
                    let seat = if in_review && multi_seat { repo.seat_which_running(&id).unwrap_or(0) } else { 0 };
                    if in_review {
                        repo.seat_clear_all_running(&id);
                    }
                    let kind = if in_review { "reviewer" } else { "worker" };
                    // The session's title says what round it is (a plain stop deletes the
                    // lane markers, a restart keeps them): a research round rejoined as a
                    // worker's read the researcher's transcript as the worker's. One titled
                    // as no round of this bead's is not rejoined; the abort below takes it.
                    let running =
                        crate::harness::running_session(&repo, &dir).and_then(|sid| match crate::harness::session_title(&repo, &sid) {
                            None => Some((sid, kind)),
                            Some(t) => crate::harness::session_kind(&id, &t).map(|k| (sid, k)),
                        });
                    if let Some((sid, kind)) = running {
                        repo.rejoin_set(&id, &sid, kind, seat);
                        if !in_review {
                            crate::shell::bd_status(&repo, &id, "open");
                        }
                        log(&format!("{}: {id}: {kind} session {sid} still running on the server after the stop; rejoining it", repo.slug));
                        continue;
                    }
                    // Not busy — but did it finish in the gap between the stop and this
                    // start, its result never read? Only when a lane marker named this bead
                    // at the stop: no marker means a plain stop aborted the session (or no
                    // lane was on it), so there is nothing here for this process to read.
                    // Rejoin it anyway: rejoin_session finds it not busy and reads its
                    // messages at once.
                    let round = repo.failures_of(&id) + 1;
                    let finished = lane_mtimes
                        .get(&id)
                        .copied()
                        .and_then(|cutoff| crate::harness::finished_session(&repo, &id, &dir, kind, round, cutoff));
                    if let Some(sid) = finished {
                        repo.rejoin_set(&id, &sid, kind, seat);
                        if !in_review {
                            crate::shell::bd_status(&repo, &id, "open");
                        }
                        log(&format!(
                            "{}: {id}: {kind} session {sid} finished between the stop and the start; rejoining it so its result is not lost",
                            repo.slug
                        ));
                        continue;
                    }
                }
                crate::harness::abort_sessions(&repo, &dir);
                if in_review {
                    continue;
                }
                // in_progress + a worktree + in no queue = a round the stop interrupted
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
    let supervise = |spec: LaneSpec, ctx: Ctx, counter: Arc<AtomicUsize>| {
        std::thread::Builder::new()
            .name(spec.name.clone())
            .spawn(move || loop {
                let c = ctx.clone();
                let k = counter.clone();
                let s = spec.clone();
                let h = std::thread::Builder::new().name(format!("{}-lane", spec.name)).spawn(move || lane(&c, &s, k));
                match h {
                    Ok(h) => {
                        let _ = h.join();
                    }
                    Err(e) => log(&format!("cannot start the {} lane: {e}", spec.name)),
                }
                log(&format!("{} lane stopped; starting it again in 10 s", spec.name));
                sleep_secs(10.0);
            })
            .expect("lane thread")
    };
    let _lanes: Vec<_> = ctx.lanes.iter().cloned().map(|spec| supervise(spec, ctx.clone(), counter.clone())).collect();
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
                let busy = ctx.repos.iter().any(|r| !Repo::load(r, ctx.opts.model_flag.as_deref()).lane_files().is_empty());
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
        assert!(repos_in_order(&[], &t, 3).is_empty());
        let _ = std::fs::remove_dir_all(&t);
    }
    #[test]
    fn a_pass_stops_at_the_pause_flag_between_repos() {
        let t = crate::config::scratch("pause-walk");
        let repos = vec![PathBuf::from("/a"), PathBuf::from("/b")];
        let mut seen = Vec::new();
        assert!(walk(&repos, &t, "cpu", 0, false, |r| {
            seen.push(r.to_path_buf());
            Pass::Worked
        }));
        assert_eq!(seen, repos, "no flag: every repo");
        // The flag appears during the first repo's round: pause cpu while the lane is busy.
        let flag = t.join("pause.cpu");
        seen.clear();
        assert!(walk(&repos, &t, "cpu", 0, false, |r| {
            seen.push(r.to_path_buf());
            touch(&flag);
            Pass::Worked
        }));
        assert_eq!(seen, vec![PathBuf::from("/a")], "the round in flight ends; the next repo's does not start");
        seen.clear();
        assert!(
            !walk(&repos, &t, "cpu", 0, false, |r| {
                seen.push(r.to_path_buf());
                Pass::Worked
            }),
            "with the flag set, nothing"
        );
        assert!(seen.is_empty());
        seen.clear();
        assert!(!walk(&repos, &t, "gpu", 0, false, |r| {
            seen.push(r.to_path_buf());
            Pass::Nothing
        }));
        assert_eq!(seen, repos, "another lane's flag is not this lane's");
        std::fs::remove_file(&flag).unwrap();
        seen.clear();
        assert!(walk(&repos, &t, "cpu", 0, true, |r| {
            seen.push(r.to_path_buf());
            Pass::Worked
        }));
        assert_eq!(seen, vec![PathBuf::from("/a")], "--once: the pass ends at its first round");
        let _ = std::fs::remove_dir_all(&t);
    }
    #[test]
    fn a_held_lock_is_a_skip() {
        let t = crate::config::scratch("lock");
        let p = t.join("lock");
        let first = try_lock(&p).expect("the first taker holds it");
        assert!(try_lock(&p).is_none(), "a second taker is refused while it is held");
        drop(first);
        // A child another test forks in these few microseconds inherits the open file,
        // and with it the flock, until it execs: allow it a moment.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut again = try_lock(&p);
        while again.is_none() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
            again = try_lock(&p);
        }
        assert!(again.is_some(), "and gets it once the holder is gone");
        let _ = std::fs::remove_dir_all(&t);
    }
    #[test]
    fn priority_is_a_file_with_the_repo() {
        let t = crate::config::scratch("priority");
        assert!(priority_repo(&t).is_none());
        set_priority(&t, Some("/nowhere/repo"));
        assert_eq!(priority_repo(&t), Some(PathBuf::from("/nowhere/repo")), "a path that does not resolve is kept as given");
        assert!(t.join("wake").exists(), "the bell rang");
        set_priority(&t, Some("none"));
        assert!(priority_repo(&t).is_none(), "none clears it");
        crate::util::write_file(&t.join("priority"), "  \n");
        assert!(priority_repo(&t).is_none(), "an empty file is no priority");
        let _ = std::fs::remove_dir_all(&t);
    }
}
