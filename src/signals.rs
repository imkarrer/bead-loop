//! `systemctl stop` signals the whole cgroup: the model client dies with us, the
//! server-side session would not. One thread owns TERM and INT (blocked everywhere else,
//! taken with sigwait): it aborts the session under every worktree a lane is on (a plain
//! stop; a restart leaves it for the next process to rejoin), clears the lane markers on
//! a plain stop (a restart keeps them, for the next process's cutoff), forwards the
//! signal to the children still running (a plain `kill`
//! of the supervisor alone reaches them too), and exits 143 — the bash's `on_signal`.
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

struct Lane {
    key: String,
    attach: String,
    slug: String,
    wt: Option<PathBuf>,
    lane_file: Option<PathBuf>,
}

static LANES: Mutex<Vec<Lane>> = Mutex::new(Vec::new());
static CHILDREN: Mutex<Vec<u32>> = Mutex::new(Vec::new());
/// Set first thing on TERM/INT, before a session is aborted: a lane whose worker,
/// gate or reviewer then comes back non-zero is looking at the stop, not the bead.
static STOPPING: AtomicBool = AtomicBool::new(false);
/// Lanes that have come back through `cut_short` since the flag went up.
static ACKED: AtomicUsize = AtomicUsize::new(0);

/// Whether the loop is on its way out (the signal thread is aborting sessions).
pub fn stopping() -> bool {
    STOPPING.load(Ordering::SeqCst)
}

/// A lane on a round saw the stop and left its bead as it was.
pub fn ack_stop() {
    ACKED.fetch_add(1, Ordering::SeqCst);
}

#[cfg(test)]
pub fn set_stopping(on: bool) {
    STOPPING.store(on, Ordering::SeqCst);
}

/// What a lane is on right now: its worktree (a session may be running there) and its
/// marker file. `key` names the lane in this process (dev, review, or a hand-run work).
pub fn set_current(key: &str, attach: &str, slug: &str, wt: Option<PathBuf>, lane_file: Option<PathBuf>) {
    let mut g = LANES.lock().unwrap();
    g.retain(|l| l.key != key);
    g.push(Lane { key: key.to_string(), attach: attach.to_string(), slug: slug.to_string(), wt, lane_file });
}

pub fn clear_current(key: &str) {
    LANES.lock().unwrap().retain(|l| l.key != key);
}

pub fn child_started(pid: u32) {
    CHILDREN.lock().unwrap().push(pid);
}

pub fn child_ended(pid: u32) {
    CHILDREN.lock().unwrap().retain(|p| *p != pid);
}

/// Block TERM/INT in this (the main) thread — every thread spawned later inherits the
/// mask — and start the thread that takes them.
pub fn install() {
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
        // SIGPIPE: a closed pipe on stderr/stdout is an error to handle, not a death.
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    std::thread::Builder::new()
        .name("signals".into())
        .spawn(|| {
            let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
            unsafe {
                libc::sigemptyset(&mut set);
                libc::sigaddset(&mut set, libc::SIGTERM);
                libc::sigaddset(&mut set, libc::SIGINT);
            }
            let mut sig: libc::c_int = 0;
            loop {
                let rc = unsafe { libc::sigwait(&set, &mut sig) };
                if rc == 0 {
                    break;
                }
            }
            on_signal();
        })
        .expect("signal thread");
}

fn on_signal() -> ! {
    STOPPING.store(true, Ordering::SeqCst);
    // Abort what the model server is doing for us, then the lane markers, then the
    // children (timeout, opencode, claude) that a group kill would have reached anyway.
    let lanes: Vec<(String, String, Option<PathBuf>, Option<PathBuf>)> = LANES
        .lock()
        .map(|g| g.iter().map(|l| (l.attach.clone(), l.slug.clone(), l.wt.clone(), l.lane_file.clone())).collect())
        .unwrap_or_default();
    let lanes_on_rounds = lanes.iter().filter(|l| l.2.is_some()).count();
    // A restart (the deploy: `$STATE_DIR/restart` dropped just before it) keeps the
    // sessions: the server outlives this process, and the next one rejoins them
    // (lanes.rs recover). Any other stop — a hand stop, gpu-mode — aborts them, so the
    // model server is freed. It also keeps the lane markers, so the next process's
    // recover can compute its cutoff; a plain stop clears them, since it aborted the
    // sessions they would have named.
    let restart = std::fs::remove_file(crate::config::state_dir().join("restart")).is_ok();
    if restart && lanes_on_rounds > 0 {
        crate::util::log(&format!("restart: {lanes_on_rounds} session(s) left running on the server for the next process to rejoin"));
    }
    for (attach, slug, wt, lane_file) in lanes {
        if let (Some(wt), false) = (wt, restart) {
            crate::harness::abort_sessions_on(&attach, &slug, &wt);
        }
        if let (Some(f), false) = (lane_file, restart) {
            let _ = std::fs::remove_file(f);
        }
    }
    let children: Vec<u32> = CHILDREN.lock().map(|g| g.clone()).unwrap_or_default();
    for pid in children {
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
    }
    // Then a moment for each lane that was on a round to come back through its aborted
    // client or gate and say "cut short" (round.rs) — so the log tells the truth and no
    // lane is mid-judgement when the process goes. Bounded: a lane stuck in git waits
    // for nobody.
    let on_rounds = lanes_on_rounds;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while ACKED.load(Ordering::SeqCst) < on_rounds && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    std::process::exit(143)
}
