//! `run_agent`: one non-interactive session, in the harness `Repo::resolve` names for the model —
//! `claude/<alias>` is Claude Code (`claude -p`, the agent file's body as its system
//! prompt, tools by role), `aider:<provider>/<model>` is aider on the opencode provider's
//! server (the dev lane only), anything else is an opencode agent. A provider with
//! `harness = "command"` runs its `command` (and `model_flag`) under `sh -c` in the
//! worktree: the prompt on its stdin, `BEAD_ROLE`, `BEAD_MODEL`, `BEAD_AGENT_PROMPT` and
//! `BEAD_TIMEOUT` in its environment, and its stdout the text. Prints the last text
//! the agent wrote; returns the harness's exit code.
//!
//! Also: aborting sessions on the attached server, and the probes that say whether a
//! model can run at all right now (Claude signed in; a provider's server answering), so
//! a round that would die in seconds is never started and never charged.
use crate::config::{loop_home, Repo};
use crate::signals;
use crate::util::{cmd, log, output, read_to_string, stdout_str, tail_lines, write_file};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

pub struct AgentRun {
    /// the last text the agent wrote (the bash printed it; callers grep DONE:/BLOCKED:/APPROVE:)
    pub text: String,
    /// all of it: what the brief reads, not the last twenty lines
    pub full: String,
    pub rc: i32,
    /// the model never answered: the session wrote nothing at all, or nothing but the
    /// harness's own error events (the server answering an error before the model ran:
    /// a 5xx, the model not found on it, a refused connection) — a harness or server
    /// failure, not the model's work
    pub empty: bool,
    /// what the harness said about it, for the hold's reason: its error events' lines,
    /// else — with nothing written at all — the last lines of its stderr
    pub error: String,
    /// opencode sessions only: the watchdog's reason when it killed the session for
    /// stalling — "stalled: N compactions, M tool calls without an edit" — so the
    /// send-back note says why instead of just the exit code
    pub stalled: Option<String>,
}

/// What an opencode `--format json` transcript holds. `text` events are the model's
/// words; `tool_use`, `step_start`, `step_finish` are the model at work; `error` events
/// are the harness's own — the server answering an error (a 5xx, the model not found on
/// it, a refused or reset connection). A transcript of errors alone, or of nothing, is a
/// round the model never answered: the server's failure, never the bead's. (21 Sep 2026:
/// the reviewer model added to opencode.json without a server restart cost a bead a
/// failure and a Sonnet review; its transcript was one error event.)
pub struct Transcript {
    pub texts: Vec<String>,
    pub errors: Vec<String>,
    /// events that are neither: the model at work, or lines this parser does not know
    pub other: usize,
}

impl Transcript {
    pub fn never_answered(&self) -> bool {
        self.texts.is_empty() && self.other == 0
    }
}

pub fn parse_transcript(raw: &str) -> Transcript {
    let mut t = Transcript { texts: Vec::new(), errors: Vec::new(), other: 0 };
    for line in raw.lines().filter(|l| !l.trim().is_empty()) {
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => {
                t.other += 1;
                continue;
            }
        };
        match v.get("type").and_then(|t| t.as_str()) {
            Some("text") => match v.pointer("/part/text").and_then(|s| s.as_str()) {
                Some(s) => t.texts.push(s.to_string()),
                None => t.other += 1,
            },
            Some("error") => t.errors.push(error_line(v.get("error").unwrap_or(&Value::Null))),
            _ => t.other += 1,
        }
    }
    t
}

/// One line for an error event: `Name: message (ref X)` as opencode's providers report
/// it (`error.name`, `error.data.message`, `error.data.ref`), `CODE path` for a socket
/// error (`error.code`, `error.path`), else the JSON as it came.
fn error_line(e: &Value) -> String {
    let s = |p: &str| e.pointer(p).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let (name, message, r) = (s("/name"), s("/data/message"), s("/data/ref"));
    if !name.is_empty() || !message.is_empty() {
        let mut out = match (name.is_empty(), message.is_empty()) {
            (false, false) => format!("{name}: {message}"),
            (false, true) => name,
            _ => message,
        };
        if !r.is_empty() {
            out.push_str(&format!(" (ref {r})"));
        }
        return out;
    }
    let code = s("/code");
    if !code.is_empty() {
        return format!("{code} {}", s("/path")).trim_end().to_string();
    }
    e.to_string()
}

/// What a `claude -p` round can use. `--tools` is the tool set itself: a tool it leaves out
/// (Monitor, WebFetch, Task, ...) the model never sees. `--allowedTools` only says what runs
/// without asking, and a -p session has no one to ask, so anything else is refused at call
/// time. `--strict-mcp-config`, with no --mcp-config, drops the claude.ai connectors' tools.
/// The worker keeps Skill for the repo's skills, not the loop's own (agents/bead-worker.md
/// denies the same four): the Skill tool still lists them, and a call is refused.
/// Every other agent (reviewer, pre-checker, researcher, briefer, post-mortem) only reads,
/// with git's reading commands.
fn claude_tool_flags(agent: &str) -> Vec<&'static str> {
    let mut f = if agent == "bead-worker" {
        vec![
            "--tools",
            "Read,Edit,Write,Glob,Grep,Bash,Skill",
            "--allowedTools",
            "Read,Edit,Write,Glob,Grep,Bash,Skill",
            "--disallowedTools",
            "Skill(bead-workflow),Skill(beads),Skill(delegate),Skill(workstation)",
        ]
    } else {
        vec![
            "--tools",
            "Read,Glob,Grep,Bash",
            "--allowedTools",
            "Read,Glob,Grep,Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status *),Bash(git grep *),\
             Bash(git blame *),Bash(git ls-files *),Bash(git rev-parse *),Bash(git merge-base *),\
             Bash(cat *),Bash(ls *),Bash(rg *),Bash(grep *)",
        ]
    };
    f.push("--strict-mcp-config");
    f
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
    if signals::stopping() {
        // No session starts under a stop: the caller finds the stop (round.rs cut_short).
        return AgentRun { text: String::new(), full: String::new(), rc: 143, empty: true, error: String::new(), stalled: None };
    }
    let err_path = logf.with_file_name(format!("{}.err", logf.file_name().unwrap().to_string_lossy()));
    let stdout = std::fs::File::create(logf).ok();
    let stderr = std::fs::File::create(&err_path).ok();
    let timeout_s = timeout.to_string();
    let rc;
    let full;
    let mut never_answered = false;
    let mut errors = String::new();
    let mut stalled = None;
    let r = repo.resolve(model);
    if r.harness == "aider" {
        // Aider explores nothing: it edits the files it is handed, so the files are the
        // ones the bead's DESCRIPTION names that exist in the worktree. The server is the
        // provider's baseURL in opencode's config, spoken as openai/<model>; local servers
        // ignore the key. Aider's scratch (.aider*) leaves the worktree, or settle_worktree
        // would commit it; the chat goes beside the log.
        let provider = r.provider.via.as_str();
        let model_name = r.model.as_str();
        let (base, key) = opencode_provider(provider);
        if base.is_empty() {
            log(&format!(
                "{}: no baseURL for opencode provider {provider} in opencode.json; aider uses its own OPENAI_API_BASE",
                repo.slug
            ));
        }
        // Aider adds any repo file a message names (the gate command names test/run.sh,
        // install.sh, ...) and --yes-always says yes: a 32k model drowned on 67k tokens
        // before its first edit. The ignore file hides every other file from aider, so
        // the named ones are all it can add or map. Diff edits: a whole-file rewrite of a
        // thousand-line file does not fit the context either.
        let brief = bead_json
            .and_then(|j| j.get(0))
            .and_then(|b| b.get("id"))
            .and_then(|i| i.as_str())
            .and_then(|id| repo.research_of(id))
            .unwrap_or_default();
        let files = files_named(bead_json, &brief, dir);
        let ignore = logf.with_file_name(format!("{}.aiderignore", logf.file_name().unwrap().to_string_lossy()));
        write_file(&ignore, &aider_ignore(&files));
        let mut c = cmd("timeout");
        c.args(["--foreground", &timeout_s, "aider", "--yes-always", "--no-auto-commits", "--no-gitignore"]);
        // A URL in the bead is text, not a page to fetch: --yes-always had aider scrape
        // one (bl-iej.2.1's http://127.0.0.1:1/health) and agree to install playwright.
        c.arg("--no-detect-urls");
        c.args(["--model", &format!("openai/{model_name}")]);
        c.args(["--edit-format", "diff"]);
        c.arg("--aiderignore").arg(&ignore);
        c.arg("--chat-history-file").arg(format!("{}.chat.md", logf.display()));
        c.arg("--input-history-file").arg(format!("{}.input", logf.display()));
        // One message, one reply, then aider exits: a reply that only says what it will
        // look at next is a round spent (bl-e10.3). The prompt is written for an agent
        // that explores; this one has its files already.
        c.arg("--message").arg(format!("{prompt}{AIDER_EDIT_NOW}"));
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
        rc = run_to_files(&mut c, stdout, stderr, None);
        clean_aider(dir);
        full = read_to_string(logf).unwrap_or_default();
    } else if r.harness == "claude-code" {
        let alias = r.model.as_str();
        let sys = agent_body(agent);
        let mut c = cmd("timeout");
        c.args(["--foreground", &timeout_s, "claude", "-p", prompt, "--model", alias, "--output-format", "json"]);
        c.args(claude_tool_flags(agent));
        c.args(["--append-system-prompt", &sys, "--no-session-persistence"]);
        // No background jobs: a -p session ends when the model stops, and a job it left
        // running is orphaned (bl-5v2's third Sonnet round started an `opencode run` in the
        // background, said it would pick it back up, and ended).
        c.env("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", "1");
        c.current_dir(dir);
        rc = run_to_files(&mut c, stdout, stderr, None);
        let raw = read_to_string(logf).unwrap_or_default();
        let v = serde_json::from_str::<Value>(&raw).ok();
        let result = v.as_ref().and_then(|v| v.get("result").and_then(|r| r.as_str()).map(str::to_string)).unwrap_or_default();
        // Claude Code answers an expired sign-in or an API refusal with a JSON error and
        // not one token spent: that is the harness failing, not the model's round. Say
        // so (the caller holds the bead) and forget the sign-in probe so the next pick
        // asks again rather than trust a minute-old "signed in".
        let api_error = v
            .as_ref()
            .map(|v| {
                v.get("is_error").and_then(|b| b.as_bool()).unwrap_or(false)
                    && v.pointer("/usage/input_tokens").and_then(|n| n.as_u64()).unwrap_or(0) == 0
            })
            .unwrap_or(false);
        if api_error {
            log(&format!("{}: claude did nothing: {}", repo.slug, result.lines().next().unwrap_or("")));
            forget_probes();
            let _ = std::fs::write(&err_path, result.as_bytes());
            let _ = std::fs::write(logf, b"");
        }
        full = result;
    } else if r.harness == "command" {
        let mut c = cmd("timeout");
        c.args(["--foreground", &timeout_s, "sh", "-c", &command_line(&r.provider.command, &r.provider.model_flag, &r.model)]);
        c.current_dir(dir);
        c.env("BEAD_ROLE", agent.strip_prefix("bead-").unwrap_or(agent));
        c.env("BEAD_MODEL", &r.model);
        c.env("BEAD_AGENT_PROMPT", agent_body(agent));
        c.env("BEAD_TIMEOUT", &timeout_s);
        rc = run_to_files(&mut c, stdout, stderr, Some(prompt));
        full = read_to_string(logf).unwrap_or_default();
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
        let watched = run_watched(&mut c, stdout, stderr, repo, dir, logf);
        rc = watched.0;
        stalled = watched.1;
        // The client is gone (timeout, a kill); with attach the server would keep working
        // the session for nobody. Its log may still be empty, so ask the server by directory.
        // Under a stop the signal thread decides (a restart keeps the session to rejoin).
        // A client killed by a signal (128+; `timeout` itself exits 124) usually died of
        // the same TERM that is a step from raising the flag: a moment before deciding.
        if rc >= 128 && !signals::stopping() {
            crate::util::sleep_secs(0.3);
        }
        if rc != 0 && !signals::stopping() && stalled.is_none() {
            abort_sessions(repo, dir);
        }
        let raw = read_to_string(logf).unwrap_or_default();
        let mut t = parse_transcript(&raw);
        // The client can exit as the session finishes, before the reply's text reaches the
        // log (bl-tka.2's reviews on 25 Sep: a step_start, then exit 0; the server had a
        // whole REJECT). With events but no text, ask the server for the last reply.
        if t.texts.is_empty() && rc == 0 && !repo.attach.is_empty() {
            let reply = session_id_of(&raw)
                .and_then(|sid| crate::shell::curl_get(&format!("{}/session/{sid}/message", repo.attach), None, 5))
                .and_then(|body| serde_json::from_str::<Value>(&body).ok())
                .and_then(|v| last_reply_text(&v));
            if let Some(text) = reply {
                log(&format!("{}: {title}: the client lost the reply's text; taken from the server", repo.slug));
                t.texts.push(text);
            }
        }
        full = t.texts.join("\n");
        never_answered = t.never_answered();
        errors = t.errors.join("; ");
    }
    // Nothing from the model: the file is empty (the client died before a word), or it
    // holds nothing but the harness's own error events. The reason is the harness's:
    // its errors, else its stderr.
    let empty = never_answered || std::fs::metadata(logf).map(|m| m.len() == 0).unwrap_or(true);
    let error = if !errors.is_empty() {
        errors
    } else if empty {
        tail_lines(&read_to_string(&err_path).unwrap_or_default(), 5)
    } else {
        String::new()
    };
    AgentRun { text: tail_lines(&full, 20), full, rc, empty, error, stalled }
}

/// Run with stdout/stderr to files, registering the child so a TERM to the supervisor
/// reaches it first; `stdin`, when given, is written to the child's stdin and closed.
/// Returns the exit code (124 is `timeout`'s).
fn run_to_files(c: &mut std::process::Command, out: Option<std::fs::File>, err: Option<std::fs::File>, stdin: Option<&str>) -> i32 {
    use std::process::Stdio;
    c.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() });
    c.stdout(out.map(Stdio::from).unwrap_or_else(Stdio::null));
    c.stderr(err.map(Stdio::from).unwrap_or_else(Stdio::null));
    match c.spawn() {
        Ok(mut child) => {
            signals::child_started(child.id());
            // the handle drops at the end of the block: the child reads EOF before we wait
            if let (Some(text), Some(mut w)) = (stdin, child.stdin.take()) {
                let _ = std::io::Write::write_all(&mut w, text.as_bytes());
            }
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

/// The command harness's command line: the provider's `command`, and when it sets a
/// `model_flag`, a space and the flag with every `{model}` replaced by the model.
pub fn command_line(command: &str, model_flag: &str, model: &str) -> String {
    if model_flag.is_empty() {
        command.to_string()
    } else {
        format!("{command} {}", model_flag.replace("{model}", model))
    }
}

/// Compactions, and tool calls since the last edit, in an opencode `--format json`
/// transcript so far: a `text` event with `part.metadata.compaction_continue` is a
/// compaction; a `tool` part on a `tool_use` event whose `tool` is `write`, `edit` or
/// `patch` resets the run since the last edit to zero, any other tool call adds one.
/// (bl-uhl: bl-cyx.20260921T200858.worker.jsonl — 193 reads, 91 compactions, 0 edits,
/// the whole worker_timeout burned in a loop the model never broke out of.)
pub fn count_stall(raw: &str) -> (u64, u64) {
    let mut compactions = 0u64;
    let mut since_edit = 0u64;
    for line in raw.lines().filter(|l| !l.trim().is_empty()) {
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match v.get("type").and_then(|t| t.as_str()) {
            Some("text") => {
                if v.pointer("/part/metadata/compaction_continue").and_then(|b| b.as_bool()).unwrap_or(false) {
                    compactions += 1;
                }
            }
            Some("tool_use") => {
                let tool = v.pointer("/part/tool").and_then(|s| s.as_str()).unwrap_or("");
                if matches!(tool, "write" | "edit" | "patch") {
                    since_edit = 0;
                } else {
                    since_edit += 1;
                }
            }
            _ => {}
        }
    }
    (compactions, since_edit)
}

/// Runs the opencode client with a watchdog: while it runs, `count_stall` polls the
/// transcript every 0.2 s. Past `stall_compactions` compactions or `stall_steps` tool
/// calls since the last edit (either at 0 disables that check), the watchdog aborts the
/// session on the attached server and kills the client — the round ends stalled well
/// under `worker_timeout`, not at its clock. Returns the exit code and, when the
/// watchdog tripped, its reason.
fn run_watched(
    c: &mut std::process::Command,
    out: Option<std::fs::File>,
    err: Option<std::fs::File>,
    repo: &Repo,
    dir: &Path,
    logf: &Path,
) -> (i32, Option<String>) {
    use std::process::Stdio;
    c.stdin(Stdio::null());
    c.stdout(out.map(Stdio::from).unwrap_or_else(Stdio::null));
    c.stderr(err.map(Stdio::from).unwrap_or_else(Stdio::null));
    let mut child = match c.spawn() {
        Ok(child) => child,
        Err(e) => {
            log(&format!("cannot start {:?}: {e}", c.get_program()));
            return (127, None);
        }
    };
    let pid = child.id();
    signals::child_started(pid);
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let watchdog = if repo.stall_compactions > 0 || repo.stall_steps > 0 {
        let (compactions_limit, steps_limit) = (repo.stall_compactions, repo.stall_steps);
        let (logf, dir, attach, slug) = (logf.to_path_buf(), dir.to_path_buf(), repo.attach.clone(), repo.slug.clone());
        let stop2 = stop.clone();
        Some(std::thread::spawn(move || {
            while !stop2.load(std::sync::atomic::Ordering::SeqCst) {
                crate::util::sleep_secs(0.2);
                let (compactions, since_edit) = count_stall(&read_to_string(&logf).unwrap_or_default());
                let tripped = (compactions_limit > 0 && compactions > compactions_limit) || (steps_limit > 0 && since_edit > steps_limit);
                if tripped {
                    let reason = format!("stalled: {compactions} compactions, {since_edit} tool calls without an edit");
                    log(&format!("{slug}: aborting session: {reason}"));
                    abort_sessions_on(&attach, &slug, &dir);
                    unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
                    return Some(reason);
                }
            }
            None
        }))
    } else {
        None
    };
    let st = child.wait();
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    signals::child_ended(pid);
    let rc = match st {
        Ok(s) => s.code().unwrap_or(128 + s.signal_number()),
        Err(_) => 1,
    };
    let stalled = watchdog.and_then(|h| h.join().ok()).flatten();
    (rc, stalled)
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
    agent_body_of(&read_to_string(&p).unwrap_or_default())
}

pub fn agent_body_of(text: &str) -> String {
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
    opencode_provider_in(&path, provider)
}

pub fn opencode_provider_in(path: &Path, provider: &str) -> (String, String) {
    let v: Value = match read_to_string(path).and_then(|s| serde_json::from_str(&s).ok()) {
        Some(v) => v,
        None => return (String::new(), String::new()),
    };
    let opts = v.pointer(&format!("/provider/{provider}/options"));
    let get = |k: &str| opts.and_then(|o| o.get(k)).and_then(|s| s.as_str()).unwrap_or("").to_string();
    (get("baseURL"), get("apiKey"))
}

/// What aider's message adds to the worker's prompt.
const AIDER_EDIT_NOW: &str = "\n\nThe files to change are already in this chat, in full. Reply now with the SEARCH/REPLACE blocks that make the change; there is no second turn to look around in. Keep each SEARCH short: one to three lines copied exactly, character for character, from the file.";

/// An aiderignore that hides every file but these: `*`, then one `!path` per file. (A
/// `!*/` would re-include every file under any directory.)
fn aider_ignore(files: &[String]) -> String {
    let mut s = String::from("*\n");
    for f in files {
        s.push_str(&format!("!{f}\n"));
    }
    s
}

/// The files a bead's DESCRIPTION names: every whitespace-separated token with a slash or
/// a dot, trimmed of punctuation at either end, that exists in the worktree; plus the
/// brief's own Files section ([`brief_files`]); sorted, unique.
fn files_named(bead_json: Option<&Value>, brief: &str, dir: &Path) -> Vec<String> {
    let desc = bead_json.and_then(|j| j.get(0)).and_then(|b| b.get("description")).and_then(|d| d.as_str()).unwrap_or("");
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
    files.extend(brief_files(brief, dir).0);
    files.sort();
    files.dedup();
    files
}

/// A line that ends a Files (or any) section: a markdown heading (`#...`), or a line that
/// is a single word ending in `:` (`Shape:`).
fn is_section_heading(line: &str) -> bool {
    let l = line.trim();
    if l.is_empty() {
        return false;
    }
    if l.starts_with('#') {
        return true;
    }
    let mut words = l.split_whitespace();
    matches!((words.next(), words.next()), (Some(w), None) if w.ends_with(':'))
}

/// A line starting the brief's Files section: `Files:` at its start, or a markdown heading
/// naming Files (`## Files`).
fn is_files_heading(line: &str) -> bool {
    let l = line.trim_start();
    if l.starts_with("Files:") {
        return true;
    }
    l.starts_with('#') && l.trim_start_matches('#').trim_start().starts_with("Files")
}

/// A list line's first token with its marker (`-`, `*`, `1.`) stripped.
fn strip_list_marker(line: &str) -> &str {
    if let Some(rest) = line.strip_prefix('-').or_else(|| line.strip_prefix('*')) {
        return rest.trim_start();
    }
    if let Some(dot) = line.find('.') {
        if dot > 0 && line[..dot].chars().all(|c| c.is_ascii_digit()) {
            return line[dot + 1..].trim_start();
        }
    }
    line
}

/// The brief's Files section (see [`is_files_heading`]), one path per line, split into
/// (those that exist in `dir`, those that don't); each sorted, unique.
pub fn brief_files(brief: &str, dir: &Path) -> (Vec<String>, Vec<String>) {
    let lines: Vec<&str> = brief.lines().collect();
    let mut files = Vec::new();
    let mut missing = Vec::new();
    if let Some(start) = lines.iter().position(|l| is_files_heading(l)) {
        for line in lines.iter().skip(start + 1) {
            if is_section_heading(line) {
                break;
            }
            let rest = strip_list_marker(line.trim());
            let Some(tok) = rest.split_whitespace().next() else { continue };
            let tok = tok.trim_start_matches(|c: char| !(c.is_ascii_alphanumeric() || "_./".contains(c)));
            let tok = tok.trim_end_matches(|c: char| !(c.is_ascii_alphanumeric() || "_/-".contains(c)));
            if tok.is_empty() || !(tok.contains('/') || tok.contains('.')) {
                continue;
            }
            if dir.join(tok).is_file() {
                files.push(tok.to_string());
            } else {
                missing.push(tok.to_string());
            }
        }
    }
    files.sort();
    files.dedup();
    missing.sort();
    missing.dedup();
    (files, missing)
}

/// `abort_sessions DIR`: stop every session the attached server is still running under
/// DIR. One round owns a worktree, so anything busy there is this round's, or an orphan
/// of an earlier one; either way nothing is waiting for it.
pub fn abort_sessions(repo: &Repo, dir: &Path) {
    abort_sessions_on(&repo.attach, &repo.slug, dir);
}

pub fn abort_sessions_on(attach: &str, slug: &str, dir: &Path) {
    // Only a directory on disk. The attached server files a directory it is first asked
    // about before it exists under its global project (worktree "/") for as long as it
    // runs, and the worker's edit "../*" deny never fires there. research_one and dev_one
    // abort before make_worktree, and a stop aborts the lane's worktree (signals.rs) even
    // before it is made. The loop removes a worktree only after its session has ended, so
    // a missing one has nothing of the loop's running in it.
    if !dir.is_dir() {
        return;
    }
    for sid in sessions_on(attach, dir) {
        log(&format!("{slug}: aborting session {sid} on {attach}"));
        crate::shell::curl_post(&format!("{attach}/session/{sid}/abort"), 5);
    }
}

/// The session a `--format json` transcript belongs to: the first event's `sessionID`.
fn session_id_of(raw: &str) -> Option<String> {
    raw.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find_map(|v| v.get("sessionID").and_then(|s| s.as_str()).map(str::to_string))
}

/// The text of the last assistant message in `GET /session/SID/message`, its text parts
/// joined; `None` when there is none or it is blank.
fn last_reply_text(messages: &Value) -> Option<String> {
    let last = messages.as_array()?.iter().rev().find(|m| m.pointer("/info/role").and_then(|r| r.as_str()) == Some("assistant"))?;
    let text: Vec<&str> = last
        .get("parts")?
        .as_array()?
        .iter()
        .filter(|p| p.get("type").and_then(|t| t.as_str()) == Some("text"))
        .filter_map(|p| p.get("text").and_then(|t| t.as_str()))
        .collect();
    let joined = text.join("\n");
    if joined.trim().is_empty() {
        None
    } else {
        Some(joined)
    }
}

/// The sessions the server is running under `dir`, from `GET /session/status`
/// (`{"ses_x": {"type": "busy"}}` per running one), sorted.
fn sessions_on(attach: &str, dir: &Path) -> Vec<String> {
    if attach.is_empty() || !crate::util::have("curl") {
        return Vec::new();
    }
    let dir_s = dir.to_string_lossy();
    let status = crate::shell::curl_get(&format!("{attach}/session/status"), Some(&dir_s), 5).unwrap_or_default();
    let v: Value = serde_json::from_str(&status).unwrap_or(Value::Null);
    let mut ids: Vec<String> = v.as_object().map(|o| o.keys().cloned().collect()).unwrap_or_default();
    ids.sort();
    ids
}

/// A session still running under this worktree, if any: what a restart finds when the
/// server outlived the loop — to rejoin, not abort.
pub fn running_session(repo: &Repo, dir: &Path) -> Option<String> {
    sessions_on(&repo.attach, dir).into_iter().next()
}

/// The round a session's title says it is, for this bead: `ID · worker · …` (a round or its
/// gate fix), `ID · reviewer · …`, `ID · research · …`. `None` for another bead's session or
/// one that is not a round (the brief, the post-mortem). The title is the one record of a
/// session's kind that survives a plain stop: a plain stop deletes the lane markers, a
/// restart keeps them.
pub fn session_kind(id: &str, title: &str) -> Option<&'static str> {
    let rest = title.strip_prefix(id)?.strip_prefix(" · ")?;
    ["worker", "reviewer", "research"].into_iter().find(|k| rest == *k || rest.starts_with(&format!("{k} ·")))
}

/// The N in a title's `round N` segment (`ID · worker · round N`, `… · round N · gate fix`,
/// `… · round N · seat 2`). `None` when no segment parses, including the gate fix's own
/// title (`ID · worker · gate fix`, no round of its own) and the brief.
pub fn session_round(title: &str) -> Option<u64> {
    title.split(" · ").find_map(|seg| seg.strip_prefix("round ")?.parse().ok())
}

/// `GET /session/SID`'s title; `None` when the server does not say.
pub fn session_title(repo: &Repo, sid: &str) -> Option<String> {
    let body = crate::shell::curl_get(&format!("{}/session/{sid}", repo.attach), None, 5)?;
    let v: Value = serde_json::from_str(&body).ok()?;
    v.get("title").and_then(|t| t.as_str()).map(str::to_string)
}

/// Whether the session a rejoin marker names is the round about to wait on it — this
/// bead, this kind, this round number, and (when the server says) this round's model. A
/// session the server titles as some other round (a research round rejoined as the
/// worker's, 25 Sep: bl-tka.2's worker round read the researcher's transcript and was
/// charged "no commit") is aborted and not rejoined; the round starts its own. So is a
/// round whose model runs outside opencode (claude-code, aider) — that round's own client
/// died with the process at the stop, so any session under its worktree is some other
/// round's, opencode's own. A missing title or model from the server is trusted, as
/// before either was read.
pub fn rejoin_fits(repo: &Repo, id: &str, sid: &str, kind: &str, round: u64, model: &str) -> bool {
    let slug = &repo.slug;
    let abort = || crate::shell::curl_post(&format!("{}/session/{sid}/abort", repo.attach), 5);
    let harness = repo.resolve(model).harness;
    if harness != "opencode" {
        log(&format!(
            "{slug}: {id}: session {sid} is not this round's: {model} runs under {harness}, not opencode; aborting it rather than rejoining"
        ));
        abort();
        return false;
    }
    let body = crate::shell::curl_get(&format!("{}/session/{sid}", repo.attach), None, 5).unwrap_or_default();
    let v: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    if let Some(title) = v.get("title").and_then(|t| t.as_str()) {
        if session_kind(id, title) != Some(kind) {
            log(&format!("{slug}: {id}: session {sid} is \"{title}\", not a {kind} round; aborting it rather than rejoining"));
            abort();
            return false;
        }
        if session_round(title) != Some(round) {
            log(&format!("{slug}: {id}: session {sid} is \"{title}\", not round {round}; aborting it rather than rejoining"));
            abort();
            return false;
        }
    }
    if let (Some(p), Some(m)) = (v.pointer("/model/providerID").and_then(|x| x.as_str()), v.pointer("/model/id").and_then(|x| x.as_str())) {
        if format!("{p}/{m}") != model {
            log(&format!("{slug}: {id}: session {sid} ran {p}/{m}, not {model}; aborting it rather than rejoining"));
            abort();
            return false;
        }
    }
    true
}

/// A session that said DONE (or APPROVE) between the stop and this start: not busy now,
/// so `running_session` misses it, but its result is sitting on the server unread. From
/// `GET /session?directory=DIR` (newest first): the newest one, if its title is this
/// round's (`session_kind` is `kind` and `session_round` is `round`) and it was updated
/// after `cutoff` (the lane marker's mtime at the stop, epoch seconds) — the round that
/// was running when the marker was written, not some older session the worktree happens
/// to still carry.
pub fn finished_session(repo: &Repo, id: &str, dir: &Path, kind: &str, round: u64, cutoff: i64) -> Option<String> {
    let attach = repo.attach.as_str();
    if attach.is_empty() || !crate::util::have("curl") {
        return None;
    }
    let dir_s = dir.to_string_lossy();
    let body = crate::shell::curl_get(&format!("{attach}/session"), Some(&dir_s), 5)?;
    let list: Value = serde_json::from_str(&body).ok()?;
    let newest = list.as_array()?.first()?;
    let title = newest.get("title").and_then(|t| t.as_str()).unwrap_or("");
    if session_kind(id, title) != Some(kind) || session_round(title) != Some(round) {
        return None;
    }
    let updated = newest.pointer("/time/updated").and_then(|t| t.as_f64()).unwrap_or(0.0) as i64;
    if updated < cutoff * 1000 {
        return None;
    }
    let sid = newest.get("id").and_then(|v| v.as_str())?;
    let msgs = crate::shell::curl_get(&format!("{attach}/session/{sid}/message"), None, 10)?;
    let v: Value = serde_json::from_str(&msgs).ok()?;
    if !session_done(&v) {
        return None;
    }
    Some(sid.to_string())
}

/// Whether a session's last assistant message ended: a numeric `info.time.completed`, no
/// `info.error`, and an `info.finish` that is a string other than `"tool-calls"` (a step
/// that called a tool expects another step; a missing or null finish is not an ended
/// step). A session the server died under (bl-grj.1, 25 Sep) is cut off mid-step, not
/// finished: its last assistant message has `completed` and `finish` both null. `false`
/// with no assistant message.
fn session_done(messages: &Value) -> bool {
    let Some(last) =
        messages.as_array().into_iter().flatten().rfind(|m| m.pointer("/info/role").and_then(|r| r.as_str()) == Some("assistant"))
    else {
        return false;
    };
    let info = last.pointer("/info");
    let completed = info.and_then(|i| i.pointer("/time/completed")).is_some_and(|c| c.is_number());
    let no_error = info.and_then(|i| i.get("error")).is_none();
    let finish_ended = info.and_then(|i| i.get("finish")).and_then(|f| f.as_str()).is_some_and(|f| f != "tool-calls");
    completed && no_error && finish_ended
}

fn rejoin_poll() -> f64 {
    std::env::var("BEAD_LOOP_REJOIN_POLL").ok().and_then(|s| s.parse().ok()).unwrap_or(5.0)
}

/// Wait on a session the server is already running (a worker or reviewer round the last
/// loop process started and a restart left on the server), then read what it said. The
/// same `AgentRun` `run_agent` returns — the log file gets the text parts in the client's
/// jsonl shape, so nothing after the round can tell the difference. The round's timeout
/// counts from the session's start (`GET /session/SID`, time.created); past it the
/// session is aborted and the run is 124, as `timeout` would have made it. Under a stop
/// the run is 143 (the caller cuts the round short; the session goes on for the next
/// process to rejoin).
pub fn rejoin_session(repo: &Repo, sid: &str, dir: &Path, logf: &Path, timeout: u64) -> AgentRun {
    let attach = repo.attach.as_str();
    let started_ms = crate::shell::curl_get(&format!("{attach}/session/{sid}"), None, 5)
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.pointer("/time/created").and_then(|t| t.as_i64()))
        .unwrap_or_else(|| crate::util::now() * 1000);
    let deadline = started_ms / 1000 + timeout as i64;
    let mut rc = 0;
    loop {
        if signals::stopping() {
            rc = 143;
            break;
        }
        // By directory: the server answers `{}` to the bare status, whatever is running.
        let busy = sessions_on(attach, dir).iter().any(|s| s == sid);
        if !busy {
            break;
        }
        if crate::util::now() >= deadline {
            log(&format!("{}: session {sid} past its {timeout} s; aborting it", repo.slug));
            crate::shell::curl_post(&format!("{attach}/session/{sid}/abort"), 5);
            rc = 124;
            break;
        }
        crate::util::sleep_secs(rejoin_poll());
    }
    // What the model said, in the order it said it: the assistant messages' text parts.
    let msgs = crate::shell::curl_get(&format!("{attach}/session/{sid}/message"), None, 10).unwrap_or_default();
    let v: Value = serde_json::from_str(&msgs).unwrap_or(Value::Null);
    let texts: Vec<String> = v
        .as_array()
        .into_iter()
        .flatten()
        .filter(|m| m.pointer("/info/role").and_then(|r| r.as_str()) == Some("assistant"))
        .flat_map(|m| m.get("parts").and_then(|p| p.as_array()).cloned().unwrap_or_default())
        .filter(|p| p.get("type").and_then(|t| t.as_str()) == Some("text"))
        .filter_map(|p| p.get("text").and_then(|t| t.as_str()).map(str::to_string))
        .filter(|t| !t.is_empty())
        .collect();
    let lines: String = texts
        .iter()
        .map(|t| {
            serde_json::json!({"type": "text", "part": {"text": t}}).to_string()
                + "
"
        })
        .collect();
    let _ = std::fs::write(logf, lines.as_bytes());
    let full = texts.join(
        "
",
    );
    let empty = full.is_empty();
    log(&format!(
        "{}: rejoined session {sid}: {} after {} s{}",
        repo.slug,
        match rc {
            0 => "finished",
            124 => "timed out",
            _ => "still running (stop)",
        },
        crate::util::now() - started_ms / 1000,
        if empty { ", no text" } else { "" }
    ));
    AgentRun { text: tail_lines(&full, 20), full, rc, empty, error: String::new(), stalled: None }
}

// ---- can this model run right now? ------------------------------------------------
// claude_ok: whether a claude/* round can run at all — Claude Code signed in on this box.
// A round started while signed out dies in seconds and would cost the bead a failure for
// nothing, so a lane leaves such a bead in its queue instead and says so. The answer is
// kept for a minute (the resident loop asks on every wake; the bash asked once a process).
static CLAUDE_OK: Mutex<Option<(i64, bool)>> = Mutex::new(None);
static PROBES: Mutex<Option<HashMap<String, (i64, bool)>>> = Mutex::new(None);

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

/// Whether a provider's `probe` url answers, cached for a minute per url.
pub fn probe_ok(url: &str) -> bool {
    let now = crate::util::now();
    let mut g = PROBES.lock().unwrap();
    let map = g.get_or_insert_with(HashMap::new);
    if let Some((at, ok)) = map.get(url) {
        if now - at < 60 {
            return *ok;
        }
    }
    let ok = crate::shell::curl_get(url, None, 5).is_some();
    map.insert(url.to_string(), (now, ok));
    ok
}

/// Forget the cached answer: the page's Sign in, or a wake, asks again.
pub fn forget_probes() {
    *CLAUDE_OK.lock().unwrap() = None;
    *PROBES.lock().unwrap() = None;
}

/// `runnable(repo, MODEL)`: whether a model can run now.
pub fn runnable(repo: &Repo, model: &str) -> bool {
    let r = repo.resolve(model);
    if r.harness == "claude-code" {
        claude_ok()
    } else if !r.provider.probe.is_empty() {
        probe_ok(&r.provider.probe)
    } else {
        true
    }
}

/// Why `runnable` said no, for the wait message.
pub fn why_not(repo: &Repo, model: &str) -> String {
    let r = repo.resolve(model);
    if r.harness == "claude-code" {
        "Claude — it is signed out on this box (claude auth login)".to_string()
    } else {
        format!("{} — its probe {} fails", r.provider.name, r.provider.probe)
    }
}

/// The probe for one named provider, and what it checked: `(ok, why)`. `None` when the
/// provider has nothing to probe (no `probe` url, and not Claude Code).
pub fn probe_of(repo: &Repo, provider: &str) -> Option<(bool, String)> {
    let p = repo.providers.iter().find(|p| p.name == provider).cloned().unwrap_or_else(|| crate::config::Provider::implicit(provider));
    if p.harness == "claude-code" {
        Some((claude_ok(), "signed out".into()))
    } else if !p.probe.is_empty() {
        Some((probe_ok(&p.probe), p.probe.clone()))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn files_named_are_the_ones_the_description_names_that_exist() {
        let d = crate::config::scratch("files-named");
        std::fs::create_dir_all(d.join("lib")).unwrap();
        for f in ["work.txt", "README", "lib/x.ts"] {
            std::fs::write(d.join(f), "").unwrap();
        }
        let bead =
            serde_json::json!([{"description": "Edit work.txt (leave README alone); see docs/none.md, then lib/x.ts: and `work.txt`."}]);
        assert_eq!(
            files_named(Some(&bead), "", &d),
            vec!["lib/x.ts", "work.txt"],
            "sorted, unique, punctuation trimmed; README has no dot or slash"
        );
        assert!(files_named(None, "", &d).is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn research_files_are_the_brief_paths_that_exist() {
        let d = crate::config::scratch("research-files");
        std::fs::create_dir_all(d.join("lib")).unwrap();
        std::fs::write(d.join("work.txt"), "").unwrap();
        std::fs::write(d.join("lib/x.ts"), "").unwrap();
        let brief = "Files:\n- work.txt: append one line\n- lib/x.ts\n- docs/none.md: new\n\nShape:\n- other.txt\n";
        assert_eq!(brief_files(brief, &d), (vec!["lib/x.ts".to_string(), "work.txt".to_string()], vec!["docs/none.md".to_string()]));
        let bead = serde_json::json!([{"description": "Edit work.txt"}]);
        assert_eq!(files_named(Some(&bead), brief, &d), vec!["lib/x.ts", "work.txt"]);
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn command_line_appends_the_model_flag() {
        assert_eq!(command_line("h.sh", "", "m"), "h.sh", "no model_flag: the command alone");
        assert_eq!(command_line("h.sh", "--model {model}", "m"), "h.sh --model m");
    }
    #[test]
    fn a_lost_reply_is_found_on_the_server() {
        let raw = "{\"type\":\"step_start\",\"sessionID\":\"ses_a\",\"part\":{}}\n{\"type\":\"step_start\",\"sessionID\":\"ses_a\"}";
        assert_eq!(session_id_of(raw), Some("ses_a".into()), "the first event's session");
        assert_eq!(session_id_of("not json\n"), None);
        let msgs = serde_json::json!([
            {"info": {"role": "user"}, "parts": [{"type": "text", "text": "Review this"}]},
            {"info": {"role": "assistant"}, "parts": [{"type": "text", "text": "reading"}]},
            {"info": {"role": "assistant"}, "parts": [{"type": "step-start"}, {"type": "reasoning", "text": "hm"}, {"type": "text", "text": "REJECT: x.rs:1"}, {"type": "text", "text": "For the worker: y"}]}
        ]);
        assert_eq!(
            last_reply_text(&msgs),
            Some("REJECT: x.rs:1\nFor the worker: y".into()),
            "the last assistant message's text parts, not its reasoning"
        );
        let blank = serde_json::json!([{"info": {"role": "assistant"}, "parts": [{"type": "step-start"}]}]);
        assert_eq!(last_reply_text(&blank), None, "no text: nothing recovered");
        assert_eq!(last_reply_text(&serde_json::json!({})), None);
    }
    #[test]
    fn aider_ignore_hides_all_but_the_named_files() {
        assert_eq!(aider_ignore(&["src/round.rs".into(), "work.txt".into()]), "*\n!src/round.rs\n!work.txt\n");
        assert_eq!(aider_ignore(&[]), "*\n", "nothing named: nothing to add");
    }
    #[test]
    fn opencode_provider_from_its_config() {
        let d = crate::config::scratch("opencode-json");
        let f = d.join("opencode.json");
        assert_eq!(opencode_provider_in(&f, "stub"), (String::new(), String::new()), "no file: nothing");
        std::fs::write(&f, r#"{"provider":{"stub":{"options":{"baseURL":"http://stub.test/v1","apiKey":"not-needed"}}, "bare":{}}}"#)
            .unwrap();
        assert_eq!(opencode_provider_in(&f, "stub"), ("http://stub.test/v1".into(), "not-needed".into()));
        assert_eq!(opencode_provider_in(&f, "bare"), (String::new(), String::new()), "a provider without options");
        assert_eq!(opencode_provider_in(&f, "nope"), (String::new(), String::new()));
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn a_session_is_done_only_when_its_last_step_ended() {
        let done = |time: Value, finish: Option<&str>, error: Option<Value>| {
            let mut info = serde_json::json!({"role": "assistant", "time": time});
            if let Some(f) = finish {
                info["finish"] = serde_json::json!(f);
            }
            if let Some(e) = error {
                info["error"] = e;
            }
            session_done(&serde_json::json!([{"info": info, "parts": []}]))
        };
        assert!(done(serde_json::json!({"created": 1, "completed": 2}), Some("stop"), None));
        assert!(done(serde_json::json!({"created": 1, "completed": 2}), Some("length"), None));
        assert!(!done(serde_json::json!({"created": 1}), None, None), "bl-grj.1's session: no completed, no finish");
        assert!(!done(serde_json::json!({"created": 1, "completed": 2}), None, None), "no finish");
        assert!(!done(serde_json::json!({"created": 1, "completed": 2}), Some("tool-calls"), None), "expects another step");
        assert!(
            !done(
                serde_json::json!({"created": 1, "completed": 2}),
                Some("stop"),
                Some(serde_json::json!({"name": "MessageAbortedError"}))
            ),
            "aborted mid-step"
        );
        let user_only = serde_json::json!([{"info": {"role": "user"}, "parts": []}]);
        assert!(!session_done(&user_only));
        assert!(!session_done(&serde_json::json!([])));
    }
    #[test]
    fn a_session_title_names_its_round() {
        assert_eq!(session_kind("t-1", "t-1 · worker · round 2"), Some("worker"));
        assert_eq!(session_kind("t-1", "t-1 · worker · gate fix"), Some("worker"), "the gate fix is the worker's");
        assert_eq!(session_kind("t-1", "t-1 · reviewer · round 1"), Some("reviewer"));
        assert_eq!(session_kind("t-1", "t-1 · research · round 1"), Some("research"));
        assert_eq!(session_kind("t-1", "t-1 · brief"), None, "not a round");
        assert_eq!(session_kind("t-1", "t-10 · worker · round 1"), None, "another bead's");
        assert_eq!(session_kind("bl-tka.2", "bl-tka.2 · research · round 1"), Some("research"));
    }

    #[test]
    fn session_round_reads_round_n() {
        assert_eq!(session_round("t-1 · reviewer · round 2"), Some(2));
        assert_eq!(session_round("t-1 · worker · round 3 · gate fix"), Some(3));
        assert_eq!(session_round("t-1 · reviewer · round 3 · seat 2"), Some(3), "bl-iej.8.2's seat title");
        assert_eq!(session_round("t-1 · worker · gate fix"), None, "no round of its own");
        assert_eq!(session_round("t-1 · brief"), None);
    }

    #[test]
    fn agent_body_is_what_follows_the_frontmatter() {
        assert_eq!(agent_body_of("---\nname: x\n---\nYou are the reviewer.\n\nBe strict.\n"), "You are the reviewer.\n\nBe strict.\n");
        assert_eq!(agent_body_of("no frontmatter"), "", "nothing before a second ---");
        assert_eq!(agent_body_of(""), "");
        let real = agent_body_of(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/agents/bead-worker.md")).unwrap());
        assert!(real.contains("delegated developer for one bead"), "the worker agent's body is the system prompt");
        let real = agent_body_of(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/agents/bead-reviewer.md")).unwrap());
        assert!(real.contains("senior reviewer"));
    }
    #[test]
    fn a_claude_round_sees_only_its_tools() {
        let w = claude_tool_flags("bead-worker").join(" ");
        assert!(w.starts_with("--tools Read,Edit,Write,Glob,Grep,Bash,Skill --allowedTools "), "{w}");
        assert!(w.contains("--disallowedTools Skill(bead-workflow),Skill(beads),Skill(delegate),Skill(workstation)"), "{w}");
        assert!(w.ends_with(" --strict-mcp-config"), "{w}");
        for a in ["bead-reviewer", "bead-prechecker", "bead-researcher", "bead-briefer"] {
            let r = claude_tool_flags(a).join(" ");
            assert!(r.starts_with("--tools Read,Glob,Grep,Bash --allowedTools Read,Glob,Grep,Bash(git diff *),"), "{a}: {r}");
            assert!(!r.contains("Edit") && !r.contains("Write") && !r.contains("Skill"), "{a} only reads: {r}");
            assert!(!r.contains("Bash(git *)"), "{a}: git's reading commands only: {r}");
            assert!(r.ends_with(" --strict-mcp-config"), "{a}: {r}");
        }
    }
    #[test]
    fn count_stall_counts_compactions_and_tool_calls_since_the_last_edit() {
        let text = |compact: bool| {
            if compact {
                r#"{"type":"text","part":{"type":"text","metadata":{"compaction_continue":true},"text":"Continue"}}"#.to_string()
            } else {
                r#"{"type":"text","part":{"type":"text","text":"hello"}}"#.to_string()
            }
        };
        let tool = |name: &str| format!(r#"{{"type":"tool_use","part":{{"type":"tool","tool":"{name}"}}}}"#);
        let raw = [text(false), tool("read"), tool("glob"), text(true), tool("read"), tool("bash"), text(true)].join("\n");
        assert_eq!(count_stall(&raw), (2, 4), "2 compactions; 4 tool calls, none of them an edit");
        let raw = format!("{raw}\n{}\n{}", tool("edit"), tool("read"));
        assert_eq!(count_stall(&raw), (2, 1), "edit resets the run; one read since");
        assert_eq!(count_stall(""), (0, 0));
        assert_eq!(count_stall("not json\n{}"), (0, 0), "lines this parser does not know are skipped, not counted");
    }
    #[test]
    fn a_transcript_of_errors_alone_is_a_round_the_model_never_answered() {
        // The one event inq-85h.17's review left on 21 Sep 2026, as opencode printed it.
        let real = r#"{"type":"error","timestamp":1789953019292,"sessionID":"ses_f3e7c72bbffe8Z0a3YGAoGjCfQ","error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details.","ref":"err_502a8619"}}}"#;
        let t = parse_transcript(real);
        assert!(t.never_answered(), "no text, no tool: the model never ran");
        assert_eq!(t.errors, vec!["UnknownError: Unexpected server error. Check server logs for details. (ref err_502a8619)"]);
        let reset = r#"{"type":"error","timestamp":1,"sessionID":"ses_x","error":{"code":"ECONNRESET","path":"http://127.0.0.1:4096/session/ses_x/message","errno":0}}"#;
        assert_eq!(
            parse_transcript(reset).errors,
            vec!["ECONNRESET http://127.0.0.1:4096/session/ses_x/message"],
            "a socket error has a code, not a name"
        );
        assert_eq!(
            parse_transcript(r#"{"type":"error","error":{"name":"ProviderModelNotFoundError"}}"#).errors,
            vec!["ProviderModelNotFoundError"]
        );
        assert_eq!(
            parse_transcript(r#"{"type":"error","error":"gone"}"#).errors,
            vec!["\"gone\""],
            "an unknown shape: the JSON as it came"
        );
        let worked = format!("{{\"type\":\"step_start\"}}\n{{\"type\":\"tool_use\",\"part\":{{}}}}\n{real}");
        let t = parse_transcript(&worked);
        assert!(!t.never_answered(), "an error after the model worked is the round's own");
        assert_eq!(t.errors.len(), 1, "but still on record");
        let said = format!("{real}\n{{\"type\":\"text\",\"part\":{{\"text\":\"APPROVE: fine\"}}}}");
        let t = parse_transcript(&said);
        assert!(!t.never_answered());
        assert_eq!(t.texts, vec!["APPROVE: fine"]);
        assert!(parse_transcript("").never_answered(), "nothing at all: the same");
        assert!(parse_transcript("\n\n").never_answered());
        assert!(!parse_transcript("not json\n").never_answered(), "a line this parser does not know is something said");
    }
    #[test]
    fn only_claude_models_need_a_probe() {
        let d = crate::config::scratch("runnable");
        let mut repo = crate::config::test_repo(&d, &["stub/worker"]);
        assert!(runnable(&repo, "stub/worker"));
        assert!(runnable(&repo, "aider:stub/worker"));
        assert!(runnable(&repo, ""));
        repo.providers
            .push(crate::config::Provider { probe: "http://127.0.0.1:1/health".into(), ..crate::config::Provider::implicit("down") });
        assert!(!runnable(&repo, "down/m"));
        assert!(why_not(&repo, "down/m").contains("down — its probe"));
    }
}
