//! Small things the bash had for free: the log line format, `date -Iminutes`, shelling
//! out with the signal mask a child expects, and a process-wide "die".
use std::ffi::OsStr;
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

/// `HH:MM:SS msg` on stderr — the journal's one-line-per-transition format the page and
/// the tests read.
pub fn log(msg: &str) {
    let _ = writeln!(std::io::stderr(), "{} {}", clock(), msg);
}

/// `log "error: ..."` then exit 1: the bash's `die`.
pub fn die(msg: &str) -> ! {
    log(&format!("error: {msg}"));
    std::process::exit(1)
}

fn tm_now() -> libc::tm {
    let t = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    tm
}

/// `date +%H:%M:%S`
pub fn clock() -> String {
    let tm = tm_now();
    format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
}

/// `date -Iminutes`: `2026-09-20T03:51+00:00`
pub fn date_iminutes() -> String {
    let tm = tm_now();
    let off = tm.tm_gmtoff;
    let sign = if off < 0 { '-' } else { '+' };
    let off = off.abs();
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}{}{:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        sign,
        off / 3600,
        (off % 3600) / 60
    )
}

/// `date +%Y%m%dT%H%M%S`: the stamp in a round's log file names.
pub fn stamp() -> String {
    let tm = tm_now();
    format!(
        "{:04}{:02}{:02}T{:02}{:02}{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

/// Seconds since the epoch.
pub fn now() -> i64 {
    unsafe { libc::time(std::ptr::null_mut()) }
}

/// A child command. The supervisor blocks TERM/INT in every thread so one thread can
/// take them (signals.rs); a child must not inherit that, or `systemctl stop` would not
/// reach the model client. The mask is cleared between fork and exec.
pub fn cmd<S: AsRef<OsStr>>(program: S) -> Command {
    let mut c = Command::new(program);
    unsafe {
        c.pre_exec(|| {
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut());
            Ok(())
        });
    }
    c
}

/// Run to completion, capturing both streams.
pub fn output(c: &mut Command) -> std::io::Result<Output> {
    c.stdin(Stdio::null()).output()
}

pub fn stdout_str(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

pub fn stderr_str(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

/// The last N lines of a text (`tail -n N`), joined by newlines.
pub fn tail_lines(s: &str, n: usize) -> String {
    let lines: Vec<&str> = s.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines[start..].join("\n")
}

/// The first line of a text (`head -1`).
pub fn first_line(s: &str) -> &str {
    s.lines().next().unwrap_or("")
}

/// `cut -c1-N` / `head -c N` on a text: at most N bytes, cut at a char boundary.
pub fn cut_bytes(s: &str, n: usize) -> &str {
    if s.len() <= n {
        return s;
    }
    let mut i = n;
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    &s[..i]
}

pub fn read_to_string(p: &Path) -> Option<String> {
    std::fs::read_to_string(p).ok()
}

/// Write a file whole (the bash `printf > file`), the parent made if missing.
pub fn write_file(p: &Path, s: &str) {
    if let Some(d) = p.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    if let Err(e) = std::fs::write(p, s) {
        die(&format!("cannot write {}: {e}", p.display()));
    }
}

pub fn append_file(p: &Path, s: &str) {
    use std::fs::OpenOptions;
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(p) {
        let _ = f.write_all(s.as_bytes());
    }
}

/// `touch`
pub fn touch(p: &Path) {
    if !p.exists() {
        write_file(p, "");
    } else {
        // bump the mtime: the bell reads it
        let _ = std::fs::OpenOptions::new().append(true).open(p).and_then(|f| f.set_len(std::fs::metadata(p)?.len()));
        let now = libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_NOW };
        let times = [now, now];
        if let Ok(c) = std::ffi::CString::new(p.as_os_str().as_encoded_bytes()) {
            unsafe { libc::utimensat(libc::AT_FDCWD, c.as_ptr(), times.as_ptr(), 0) };
        }
    }
}

/// Seconds-resolution mtime, or 0.
pub fn mtime(p: &Path) -> i64 {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(p).map(|m| m.mtime()).unwrap_or(0)
}

/// `$HOME`, or die.
pub fn home() -> PathBuf {
    match std::env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => die("HOME is not set"),
    }
}

/// `~` and `~/x` to the home directory; anything else as is.
pub fn expand_tilde(s: &str) -> PathBuf {
    if s == "~" {
        home()
    } else if let Some(rest) = s.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(s)
    }
}

/// `command -v NAME`
pub fn have(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(name).is_file()))
        .unwrap_or(false)
}

/// base64url without padding, the way the opencode web UI names a directory.
pub fn base64url(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let b = s.as_bytes();
    let mut out = String::new();
    for chunk in b.chunks(3) {
        let n = ((chunk[0] as u32) << 16)
            | ((chunk.get(1).copied().unwrap_or(0) as u32) << 8)
            | chunk.get(2).copied().unwrap_or(0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(T[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(T[n as usize & 63] as char);
        }
    }
    out
}

/// A sleep that takes fractions (`LANE_WAIT=0.2`).
pub fn sleep_secs(s: f64) {
    if s > 0.0 {
        std::thread::sleep(std::time::Duration::from_secs_f64(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn base64url_matches_coreutils() {
        // printf '%s' "/tmp/x" | base64 -w0 | tr '+/' '-_' | tr -d '='  ->  L3RtcC94
        assert_eq!(base64url("/tmp/x"), "L3RtcC94");
        assert_eq!(base64url("ab"), "YWI");
        assert_eq!(base64url("a"), "YQ");
    }
    #[test]
    fn tail_and_cut() {
        assert_eq!(tail_lines("a\nb\nc", 2), "b\nc");
        assert_eq!(cut_bytes("héllo", 2), "h");
        assert_eq!(cut_bytes("abc", 10), "abc");
    }
}
