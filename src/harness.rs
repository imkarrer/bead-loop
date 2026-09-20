//! `run_agent`: one non-interactive session, in the harness the model name selects —
//! `claude/<alias>` is Claude Code (`claude -p`, the agent file's body as its system
//! prompt, tools by role), `aider:<provider>/<model>` is aider on the opencode provider's
//! server (the dev lane only), anything else is an opencode agent. Prints the last text
//! the agent wrote; returns the harness's exit code.
//!
//! Also: aborting sessions on the attached server, and the probes that say whether a
//! model can run at all right now (Claude signed in; a provider's server answering), so
//! a round that would die in seconds is never started and never charged.
use crate::config::{loop_home, Repo};
use crate::signals;
use crate::util::{cmd, log, output, read_to_string, stdout_str, tail_lines};
use serde_json::Value;
use std::path::Path;
use std::sync::Mutex;

pub struct AgentRun {
    /// the last text the agent wrote (the bash printed it; callers grep DONE:/BLOCKED:/APPROVE:)
    pub text: String,
    pub rc: i32,
    /// the session wrote nothing at all — a harness or server failure, not the model's work
    pub empty: bool,
}

#[allow(clippy::too_many_arguments)]
pub fn run_agent(
    repo: &Repo,
    agent: &str,
    model: &str,
    dir: &Path,
    logf: &Path,
    prompt: &str,
    title: &str,
    timeout: u64,
    bead_json: Option<&Value>,
) -> AgentRun {
    let err_path = logf.with_file_name(format!("{}.err", logf.file_name().unwrap().to_string_lossy()));
    let stdout = std::fs::File::create(logf).ok();
    let stderr = std::fs::File::create(&err_path).ok();
    let timeout_s = timeout.to_string();
    let rc;
    let text;
    if let Some(rest) = model.strip_prefix("aider:") {
        // Aider explores nothing: it edits the files it is handed, so the files are the
        // ones the bead's DESCRIPTION names that exist in the worktree. The server is the
        // provider's baseURL in opencode's config, spoken as openai/<model>; local servers
        // ignore the key. Aider's scratch (.aider*) leaves the worktree, or settle_worktree
        // would commit it; the chat goes beside the log.
        let provider = rest.split('/').next().unwrap_or("");
        let model_name = rest.split_once('/').map(|(_, m)| m).unwrap_or(rest);
        let (base, key) = opencode_provider(provider);
        if base.is_empty() {
            log(&format!(
                "{}: no baseURL for opencode provider {provider} in opencode.json; aider uses its own OPENAI_API_BASE",
                repo.slug
            ));
        }
        let files = files_named(bead_json, dir);
        let mut c = cmd("timeout");
        c.args(["--foreground", &timeout_s, "aider", "--yes-always", "--no-auto-commits", "--no-gitignore"]);
        c.args(["--model", &format!("openai/{model_name}")]);
        c.arg("--chat-history-file").arg(format!("{}.chat.md", logf.display()));
        c.arg("--input-history-file").arg(format!("{}.input", logf.display()));
        c.args(["--message", prompt]);
        if !repo.gate.is_empty() {
            c.args(["--lint-cmd", &repo.gate]);
        }
        c.args(&files);
        c.current_dir(dir);
        if !base.is_empty() {
            c.env("OPENAI_API_BASE", &base);
        }
        let key = if key.is_empty() { std::env::var("OPENAI_API_KEY").unwrap_or_else(|_| "unused".into()) } else { key };
        c.env("OPENAI_API_KEY", key);
        rc = run_to_files(&mut c, stdout, stderr);
        clean_aider(dir);
        text = tail_lines(&read_to_string(logf).unwrap_or_default(), 20);
    } else if let Some(alias) = model.strip_prefix("claude/") {
        let tools = if agent == "bead-reviewer" {
            "Read,Glob,Grep,Bash(git *),Bash(cat *),Bash(ls *),Bash(rg *),Bash(grep *)"
        } else {
            "Read,Edit,Write,Glob,Grep,Bash"
        };
        let sys = agent_body(agent);
        let mut c = cmd("timeout");
        c.args(["--foreground", &timeout_s, "claude", "-p", prompt, "--model", alias, "--output-format", "json"]);
        c.args(["--allowedTools", tools, "--append-system-prompt", &sys, "--no-session-persistence"]);
        c.current_dir(dir);
        rc = run_to_files(&mut c, stdout, stderr);
        let raw = read_to_string(logf).unwrap_or_default();
        let result = serde_json::from_str::<Value>(&raw)
            .ok()
            .and_then(|v| v.get("result").and_then(|r| r.as_str()).map(str::to_string))
            .unwrap_or_default();
        text = tail_lines(&result, 20);
    } else {
        // --title: the session's name in the web UI, said by us. Left to opencode, a model
        // call names it from the prompt, and on a busy box that call has come back as "????".
        let mut c = cmd("timeout");
        c.args(["--foreground", &timeout_s, "opencode", "run", "--dir"]).arg(dir).args(["--agent", agent]);
        if !repo.attach.is_empty() {
            c.args(["--attach", &repo.attach]);
        }
        if !model.is_empty() {
            c.args(["-m", model]);
        }
        if !title.is_empty() {
            c.args(["--title", title]);
        }
        c.args(["--format", "json", prompt]);
        c.env("OPENCODE_DISABLE_CLAUDE_CODE_SKILLS", "1");
        rc = run_to_files(&mut c, stdout, stderr);
        // The client is gone (timeout, a kill); with attach the server would keep working
        // the session for nobody. Its log may still be empty, so ask the server by directory.
        if rc != 0 {
            abort_sessions(repo, dir);
        }
        let raw = read_to_string(logf).unwrap_or_default();
        let texts: Vec<String> = raw
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|v| v.get("type").and_then(|t| t.as_str()) == Some("text"))
            .filter_map(|v| v.pointer("/part/text").and_then(|t| t.as_str()).map(str::to_string))
            .collect();
        text = tail_lines(&texts.join("\n"), 20);
    }
    let empty = std::fs::metadata(logf).map(|m| m.len() == 0).unwrap_or(true);
    AgentRun { text, rc, empty }
}

/// Run with stdout/stderr to files, registering the child so a TERM to the supervisor
/// reaches it first. Returns the exit code (124 is `timeout`'s).
fn run_to_files(c: &mut std::process::Command, out: Option<std::fs::File>, err: Option<std::fs::File>) -> i32 {
    use std::process::Stdio;
    c.stdin(Stdio::null());
    c.stdout(out.map(Stdio::from).unwrap_or_else(Stdio::null));
    c.stderr(err.map(Stdio::from).unwrap_or_else(Stdio::null));
    match c.spawn() {
        Ok(mut child) => {
            signals::child_started(child.id());
            let st = child.wait();
            signals::child_ended(child.id());
            match st {
                Ok(s) => s.code().unwrap_or(128 + s.signal_number()),
                Err(_) => 1,
            }
        }
        Err(e) => {
            log(&format!("cannot start {:?}: {e}", c.get_program()));
            127
        }
    }
}

trait SignalNumber {
    fn signal_number(&self) -> i32;
}
impl SignalNumber for std::process::ExitStatus {
    fn signal_number(&self) -> i32 {
        use std::os::unix::process::ExitStatusExt;
        self.signal().unwrap_or(0)
    }
}

fn clean_aider(dir: &Path) {
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().starts_with(".aider") {
                let p = e.path();
                if p.is_dir() {
                    let _ = std::fs::remove_dir_all(&p);
                } else {
                    let _ = std::fs::remove_file(&p);
                }
            }
        }
    }
}

/// The agent file's body — everything after the frontmatter's closing `---`.
fn agent_body(agent: &str) -> String {
    let p = loop_home().join("agents").join(format!("{agent}.md"));
    let text = read_to_string(&p).unwrap_or_default();
    let mut seen = 0;
    let mut out = Vec::new();
    for line in text.lines() {
        if seen >= 2 {
            out.push(line);
        }
        if line == "---" {
            seen += 1;
        }
    }
    let mut s = out.join("\n");
    if !s.is_empty() {
        s.push('\n');
    }
    s
}

/// The opencode provider's `baseURL` and `apiKey` from `~/.config/opencode/opencode.json`
/// (`$OPENCODE_CONFIG`).
pub fn opencode_provider(provider: &str) -> (String, String) {
    let path = std::env::var_os("OPENCODE_CONFIG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| crate::util::home().join(".config/opencode/opencode.json"));
    let v: Value = match read_to_string(&path).and_then(|s| serde_json::from_str(&s).ok()) {
        Some(v) => v,
        None => return (String::new(), String::new()),
    };
    let opts = v.pointer(&format!("/provider/{provider}/options"));
    let get = |k: &str| opts.and_then(|o| o.get(k)).and_then(|s| s.as_str()).unwrap_or("").to_string();
    (get("baseURL"), get("apiKey"))
}

/// The files a bead's DESCRIPTION names: every whitespace-separated token with a slash or
/// a dot, trimmed of punctuation at either end, that exists in the worktree; sorted, unique.
fn files_named(bead_json: Option<&Value>, dir: &Path) -> Vec<String> {
    let desc = bead_json
        .and_then(|j| j.get(0))
        .and_then(|b| b.get("description"))
        .and_then(|d| d.as_str())
        .unwrap_or("");
    let mut files: Vec<String> = desc
        .split_whitespace()
        .map(|t| {
            let t = t.trim_start_matches(|c: char| !(c.is_ascii_alphanumeric() || "_./".contains(c)));
            t.trim_end_matches(|c: char| !(c.is_ascii_alphanumeric() || "_/-".contains(c)))
        })
        .filter(|t| t.contains('/') || t.contains('.'))
        .filter(|t| !t.is_empty() && dir.join(t).is_file())
        .map(str::to_string)
        .collect();
    files.sort();
    files.dedup();
    files
}

/// `abort_sessions DIR`: stop every session the attached server is still running under
/// DIR. One round owns a worktree, so anything busy there is this round's, or an orphan
/// of an earlier one; either way nothing is waiting for it.
pub fn abort_sessions(repo: &Repo, dir: &Path) {
    abort_sessions_on(&repo.attach, &repo.slug, dir);
}

pub fn abort_sessions_on(attach: &str, slug: &str, dir: &Path) {
    if attach.is_empty() || !crate::util::have("curl") {
        return;
    }
    let dir_s = dir.to_string_lossy();
    let status = crate::shell::curl_get(&format!("{attach}/session/status"), Some(&dir_s), 5).unwrap_or_default();
    let v: Value = serde_json::from_str(&status).unwrap_or(Value::Null);
    let mut ids: Vec<String> = v.as_object().map(|o| o.keys().cloned().collect()).unwrap_or_default();
    ids.sort();
    for sid in ids {
        log(&format!("{slug}: aborting session {sid} on {attach}"));
        crate::shell::curl_post(&format!("{attach}/session/{sid}/abort"), 5);
    }
}

// ---- can this model run right now? ------------------------------------------------
// claude_ok: whether a claude/* round can run at all — Claude Code signed in on this box.
// A round started while signed out dies in seconds and would cost the bead a failure for
// nothing, so a lane leaves such a bead in its queue instead and says so. The answer is
// kept for a minute (the resident loop asks on every wake; the bash asked once a process).
static CLAUDE_OK: Mutex<Option<(i64, bool)>> = Mutex::new(None);

pub fn claude_ok() -> bool {
    let now = crate::util::now();
    let mut g = CLAUDE_OK.lock().unwrap();
    if let Some((at, ok)) = *g {
        if now - at < 60 {
            return ok;
        }
    }
    let ok = crate::util::have("claude")
        && output(cmd("claude").args(["auth", "status"]))
            .ok()
            .and_then(|o| serde_json::from_str::<Value>(&stdout_str(&o)).ok())
            .and_then(|v| v.get("loggedIn").and_then(|b| b.as_bool()))
            .unwrap_or(false);
    *g = Some((now, ok));
    ok
}

/// Forget the cached answer: the page's Sign in, or a wake, asks again.
pub fn forget_probes() {
    *CLAUDE_OK.lock().unwrap() = None;
}

/// `runnable MODEL`: whether a model can run now.
pub fn runnable(model: &str) -> bool {
    if model.starts_with("claude/") {
        claude_ok()
    } else {
        true
    }
}
