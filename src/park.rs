//! Parking: the moment the loop gives a bead to its owner. Two things make that moment
//! answerable — a **question** and the **history** behind it.
//!
//! - `failures/ID.rounds.jsonl` is the history: one record per send-back — the round,
//!   its worker and stage, when, the whole note (the BLOCKED line, the rejection with its
//!   work order, the gate's output) and the round's log files. The worker's prompt reads
//!   the last three of it as before; the page reads all of it. (Beads from before have
//!   `failures/ID.notes`, one line per round; it is read when there is no record.)
//! - `parked/ID` is the question: why the bead was parked (BLOCKED at the last stage,
//!   stages exhausted, its PR closed), the stage it stopped on, and what its owner has to
//!   decide — written by the **brief**: one call to `brief_model` (the last stage's
//!   worker by default) that reads the rounds and their logs and answers WHAT HAPPENED,
//!   WHY and QUESTION. Without a model (`brief_model = "none"`, Claude signed out, the
//!   call failing) the question is the loop's own, from the reason. The question also
//!   goes on the bead as a note, so the next round reads the answer under it, and so
//!   `bead-supervisor open` opens Claude Code with it.
use crate::config::Repo;
use crate::harness::{run_agent, runnable};
use crate::round::render_bead;
use crate::shell::{bd_note, bd_show};
use crate::util::{append_file, cut_bytes, date_iminutes, first_line, log, now, read_to_string, stamp, tail_lines, write_file};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Seconds the brief may take: a summary, not a round.
const BRIEF_TIMEOUT: u64 = 600;

/// Why a bead is parked.
#[derive(Clone, Debug, PartialEq)]
pub enum Reason {
    /// the last stage said BLOCKED: a claim in the bead is false, or a decision is the owner's
    Blocked,
    /// every stage has had its failures and `on_exhaust = "park"`
    Exhausted,
    /// the PR was closed on GitHub without merging
    PrClosed(String),
}

impl Reason {
    pub fn key(&self) -> &'static str {
        match self {
            Reason::Blocked => "blocked",
            Reason::Exhausted => "exhausted",
            Reason::PrClosed(_) => "pr_closed",
        }
    }
}

// ---- the rounds: one record per send-back -------------------------------------------

impl Repo {
    pub fn rounds_path(&self, id: &str) -> PathBuf {
        self.rs.join("failures").join(format!("{id}.rounds.jsonl"))
    }
    pub fn parked_path(&self, id: &str) -> PathBuf {
        self.rs.join("parked").join(id)
    }
    /// The parked record, when the loop parked this bead (a bead `in_progress` with none
    /// was parked by hand, or by a stop).
    pub fn parked_record(&self, id: &str) -> Option<Value> {
        read_to_string(&self.parked_path(id)).and_then(|s| serde_json::from_str(&s).ok())
    }
    /// The bead leaves the human queue: an answer, an escalation, a claim.
    pub fn unpark(&self, id: &str) {
        let _ = std::fs::remove_file(self.parked_path(id));
    }
}

/// The log files of a round, by their names under `logs/`: everything with the round's
/// stem (`ID.STAMP`), the harness's stderr aside.
pub fn logs_of(repo: &Repo, stem: Option<&Path>) -> Vec<String> {
    let stem = match stem.and_then(|p| p.file_name()).map(|n| format!("{}.", n.to_string_lossy())) {
        Some(s) => s,
        None => return vec![],
    };
    let mut v: Vec<String> = std::fs::read_dir(repo.rs.join("logs"))
        .map(|rd| {
            rd.flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| n.starts_with(&stem) && !n.ends_with(".err")).collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// `record_round`: a send-back, as the history keeps it.
pub fn record_round(repo: &Repo, id: &str, n: u64, model: &str, note: &str, stem: Option<&Path>) {
    let rec = json!({
        "round": n,
        "model": model,
        "stage": repo.stage_for(n - 1).map(|s| s.index),
        "when": date_iminutes(),
        "note": cut_bytes(note, 8000),
        "logs": logs_of(repo, stem),
    });
    append_file(&repo.rounds_path(id), &format!("{rec}\n"));
}

/// The rounds of a bead, oldest first. From the record; from the older one-line notes
/// when there is none (`round N (model): note`).
pub fn rounds(repo: &Repo, id: &str) -> Vec<Value> {
    if let Some(s) = read_to_string(&repo.rounds_path(id)) {
        return s.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    }
    read_to_string(&repo.notes_path(id))
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let parsed = l.strip_prefix("round ").and_then(|r| {
                let (n, rest) = r.split_once(" (")?;
                let (model, note) = rest.split_once("): ")?;
                Some(json!({"round": n.parse::<u64>().ok(), "model": model, "note": note}))
            });
            parsed.unwrap_or_else(|| json!({"note": l}))
        })
        .collect()
}

/// One line per round — `round N (model): note` — the shape the worker's prompt has
/// always carried under <previous-attempts>.
pub fn round_line(r: &Value) -> String {
    let note: String = r.get("note").and_then(|n| n.as_str()).unwrap_or("").replace('\n', " ");
    match (r.get("round").and_then(|n| n.as_u64()), r.get("model").and_then(|m| m.as_str())) {
        (Some(n), Some(m)) => format!("round {n} ({m}): {}", cut_bytes(&note, 2000)),
        _ => cut_bytes(&note, 2000).to_string(),
    }
}

/// The last `n` rounds for the prompt.
pub fn history(repo: &Repo, id: &str, n: usize) -> String {
    let all = rounds(repo, id);
    let start = all.len().saturating_sub(n);
    all[start..].iter().map(round_line).collect::<Vec<_>>().join("\n")
}

// ---- the question -----------------------------------------------------------------

/// The stage table in a line: `devbox/coder ⇢ acbox/coder ×3 → claude/sonnet ×1`.
fn stages_line(repo: &Repo) -> String {
    repo.stages
        .iter()
        .map(|s| {
            let r = if s.reviewer.is_empty() { String::new() } else { format!(" ⇢ {}", s.reviewer) };
            format!("{}{r} ×{}", s.worker, s.failures)
        })
        .collect::<Vec<_>>()
        .join(" → ")
}

/// The loop's own question, from the reason: what it can say without a model.
pub fn question_for(repo: &Repo, reason: &Reason, rounds: &[Value]) -> String {
    let last = rounds.last();
    let last_note = last.and_then(|r| r.get("note")).and_then(|n| n.as_str()).unwrap_or("");
    let last_model = last.and_then(|r| r.get("model")).and_then(|m| m.as_str()).unwrap_or("the worker");
    match reason {
        Reason::Blocked => {
            let line = last_note.lines().find(|l| l.contains("BLOCKED:")).unwrap_or(last_note);
            let line = line[line.find("BLOCKED:").unwrap_or(0)..].trim();
            format!(
                "The last stage ({last_model}) stopped: {line} — Answer what it needs to know, fix the bead's text if a claim in it is false, or take it yourself."
            )
        }
        Reason::Exhausted => format!(
            "{} round{} ended in send-backs across every stage ({}); the last: {}. What should change before another round — the bead's description or criteria, the code or the environment it runs in — or is it yours to take?",
            rounds.len(),
            if rounds.len() == 1 { "" } else { "s" },
            stages_line(repo),
            cut_bytes(first_line(last_note), 300)
        ),
        Reason::PrClosed(url) => format!(
            "{url} was closed without merging. Is the bead done another way (close it), or should it be worked again — say what should change, or Reopen it as is?"
        ),
    }
}

/// The brief's prompt: the bead, the stages, every round with its note and the tail of
/// its logs, and the shape of the answer.
pub fn brief_prompt(repo: &Repo, bead: &Value, reason: &Reason, rounds: &[Value], log_tails: &[(String, String)]) -> String {
    let because = match reason {
        Reason::Blocked => "the last stage stopped with BLOCKED".to_string(),
        Reason::Exhausted => format!("every stage has had its turn ({} rounds, all sent back)", rounds.len()),
        Reason::PrClosed(url) => format!("its pull request {url} was closed on GitHub without merging"),
    };
    let mut r = String::new();
    for x in rounds {
        r.push_str(&format!(
            "round {} · {} (stage {}) · {}:\n{}\n",
            x.get("round").and_then(|n| n.as_u64()).map(|n| n.to_string()).unwrap_or_else(|| "?".into()),
            x.get("model").and_then(|m| m.as_str()).unwrap_or("?"),
            x.get("stage").and_then(|s| s.as_u64()).map(|s| s.to_string()).unwrap_or_else(|| "?".into()),
            x.get("when").and_then(|w| w.as_str()).unwrap_or("?"),
            x.get("note").and_then(|n| n.as_str()).unwrap_or("")
        ));
        let logs: Vec<&str> =
            x.get("logs").and_then(|l| l.as_array()).map(|a| a.iter().filter_map(|v| v.as_str()).collect()).unwrap_or_default();
        if !logs.is_empty() {
            r.push_str(&format!("logs (under {}): {}\n", repo.rs.join("logs").display(), logs.join(", ")));
        }
        r.push('\n');
    }
    let mut tails = String::new();
    for (name, tail) in log_tails {
        if !tail.trim().is_empty() {
            tails.push_str(&format!("--- {name}, the end:\n{tail}\n\n"));
        }
    }
    format!(
        "The automated loop has parked the bead below for its owner: {because}. Write the brief the owner reads before deciding what to do — they have watched none of the rounds.\n\n<bead>\n{}\n</bead>\n\nThe stages, in order: {}\n\n<rounds>\n{}</rounds>\n\n<logs>\n{}</logs>\n\nSay what each round tried and why it was sent back — from the logs, not the notes alone — then the pattern across them and the likeliest cause: a claim in the bead that is false, a criterion the code cannot meet as written, something missing in the environment, or the model. Then the question: what the owner has to decide or supply so that the next round lands, as one to three concrete questions, each with its options and what each would mean. If the answer is plainly \"close the bead\" or \"the bead is wrong about X\", say so. Read any file or log you need; change nothing.\n\nAnswer in exactly this shape, nothing before it:\nWHAT HAPPENED:\n<a paragraph, or one line per round>\nWHY:\n<a paragraph>\nQUESTION:\n<the question or questions>",
        render_bead(bead),
        stages_line(repo),
        r,
        tails
    )
}

/// The brief's three sections. `None` when the text has no QUESTION: line — the model
/// did not answer in shape, and the loop's own question stands.
pub fn parse_brief(text: &str) -> Option<(String, String)> {
    let start = text.find("WHAT HAPPENED:")?;
    let text = &text[start..];
    let q = text.find("\nQUESTION:").map(|i| i + 1).or_else(|| text.starts_with("QUESTION:").then_some(0))?;
    let question = text[q + "QUESTION:".len()..].trim().to_string();
    let happened = text[..q].trim_end().to_string();
    if question.is_empty() {
        return None;
    }
    Some((happened, question))
}

/// `brief_model`: the model that writes the brief — the config's, else the last stage's
/// worker; `none` turns it off.
pub fn brief_model(repo: &Repo) -> Option<String> {
    let m = if repo.brief_model.is_empty() {
        repo.stages.last().map(|s| s.worker.clone()).unwrap_or_default()
    } else {
        repo.brief_model.clone()
    };
    if m.is_empty() || m == "none" {
        None
    } else {
        Some(m.trim_start_matches("aider:").to_string())
    }
}

/// The end of a round's log, rendered: an opencode session as one line per tool call
/// or text, a Claude Code result as its text, anything else as it is.
pub fn log_tail(path: &Path, lines: usize) -> String {
    let raw = read_to_string(path).unwrap_or_default();
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if !name.ends_with(".jsonl") {
        return tail_lines(&raw, lines);
    }
    if let Ok(v) = serde_json::from_str::<Value>(&raw) {
        if let Some(r) = v.get("result").and_then(|r| r.as_str()) {
            return tail_lines(r, lines);
        }
    }
    let rendered: Vec<String> =
        raw.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()).filter_map(|v| crate::status::log_line(&v)).collect();
    tail_lines(&rendered.join("\n"), lines)
}

/// `park`: the bead is the owner's now. The brief runs first (the worktree, when the
/// caller still has one, is where it runs, so `git diff` shows what was tried), then the
/// record is written and the question noted on the bead.
pub fn park(repo: &Repo, id: &str, reason: Reason, wt: Option<&Path>) {
    let rounds = rounds(repo, id);
    let n = repo.failures_of(id);
    let mut question = question_for(repo, &reason, &rounds);
    let mut brief: Option<String> = None;
    let mut brief_model_used: Option<String> = None;
    let mut brief_log: Option<String> = None;
    if let Some(model) = brief_model(repo) {
        if runnable(&model) {
            let bead = bd_show(repo, id);
            let tails: Vec<(String, String)> = rounds
                .iter()
                .flat_map(|r| {
                    let round = r.get("round").and_then(|n| n.as_u64()).unwrap_or(0);
                    r.get("logs")
                        .and_then(|l| l.as_array())
                        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect::<Vec<_>>())
                        .unwrap_or_default()
                        .into_iter()
                        .map(move |f| (round, f))
                })
                .map(|(round, f)| {
                    (format!("round {round}: {f}"), cut_bytes(&log_tail(&repo.rs.join("logs").join(&f), 30), 4000).to_string())
                })
                .collect();
            let prompt = brief_prompt(repo, &bead, &reason, &rounds, &tails);
            let dir: PathBuf = match wt {
                Some(w) if w.join(".git").exists() => w.to_path_buf(),
                _ => repo.repo.clone(),
            };
            let logf = repo.rs.join("logs").join(format!("{id}.{}.brief.jsonl", stamp()));
            log(&format!("{}: {id}: brief by {model}", repo.slug));
            let r = run_agent(repo, "bead-briefer", &model, &dir, &logf, &prompt, &format!("{id} · brief"), BRIEF_TIMEOUT, Some(&bead));
            brief_log = logf.file_name().map(|f| f.to_string_lossy().into_owned());
            if r.rc == 0 && !r.full.trim().is_empty() {
                brief_model_used = Some(model.clone());
                match parse_brief(&r.full) {
                    Some((happened, q)) => {
                        brief = Some(happened);
                        question = q;
                    }
                    None => brief = Some(r.full.trim().to_string()),
                }
            } else {
                log(&format!("{}: {id}: the brief did not come ({model} exited {}); the loop's own question stands", repo.slug, r.rc));
            }
        } else {
            log(&format!("{}: {id}: no brief — {model} cannot run now (Claude signed out); the loop's own question stands", repo.slug));
        }
    }
    // The stage it stopped on: a send-back has just counted (the round ran one failure
    // ago); a closed PR charged nothing, so the bead is still on the stage its count names.
    let stopped_at = if matches!(reason, Reason::PrClosed(_)) { n } else { n.saturating_sub(1) };
    let stage = repo.stage_for(stopped_at).map(|s| json!({"index": s.index, "worker": s.model, "reviewer": s.review}));
    let rec = json!({
        "when": date_iminutes(),
        "at": now(),
        "reason": reason.key(),
        "failures": n,
        "stage": stage,
        "stopped_on": rounds.last().and_then(|r| r.get("note")).cloned().unwrap_or(Value::Null),
        "question": question,
        "brief": brief,
        "brief_model": brief_model_used,
        "brief_log": brief_log,
        "pr": match &reason { Reason::PrClosed(u) => Value::String(u.clone()), _ => Value::Null },
    });
    write_file(&repo.parked_path(id), &format!("{rec}\n"));
    let because = match &reason {
        Reason::Blocked => "BLOCKED at the last stage".to_string(),
        Reason::Exhausted => format!("stages exhausted after {} rounds", rounds.len()),
        Reason::PrClosed(url) => format!("{url} was closed without merging"),
    };
    bd_note(repo, id, &format!("bead-loop {}: parked ({because}). {}", date_iminutes(), cut_bytes(&question, 2000)));
    log(&format!("{}: {id}: parked ({because}): {}", repo.slug, cut_bytes(first_line(&question), 200)));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rounds_are_a_record_and_the_prompt_reads_the_last_three() {
        let d = crate::config::scratch("rounds");
        let repo = crate::config::test_repo(&d, &["fast:rev:2", "slow::1"]);
        std::fs::write(repo.rs.join("logs/t-1.20260920T010101.worker.jsonl"), "{}\n").unwrap();
        std::fs::write(repo.rs.join("logs/t-1.20260920T010101.worker.jsonl.err"), "").unwrap();
        std::fs::write(repo.rs.join("logs/t-1.20260920T010101.gate"), "boom\n").unwrap();
        std::fs::write(repo.rs.join("logs/t-1.20260920T020202.review.jsonl"), "").unwrap();
        let stem = repo.rs.join("logs/t-1.20260920T010101");
        record_round(&repo, "t-1", 1, "fast", "gate failed twice: false\nboom", Some(&stem));
        record_round(&repo, "t-1", 2, "fast", "review (rev) rejected:\nREJECT: x", Some(&repo.rs.join("logs/t-1.20260920T020202")));
        record_round(&repo, "t-1", 3, "slow", "BLOCKED: which flag?", None);
        record_round(&repo, "t-1", 4, "slow", "worker made no commit", None);
        let r = rounds(&repo, "t-1");
        assert_eq!(r.len(), 4);
        assert_eq!(r[0]["logs"], json!(["t-1.20260920T010101.gate", "t-1.20260920T010101.worker.jsonl"]), "the round's files, no .err");
        assert_eq!(r[0]["stage"], 1);
        assert_eq!(r[2]["stage"], 2, "round 3 ran on the stage two failures land on");
        assert_eq!(r[1]["logs"], json!(["t-1.20260920T020202.review.jsonl"]));
        assert_eq!(r[3]["logs"], json!([]));
        assert!(r[0]["when"].as_str().unwrap().starts_with("20"));
        assert_eq!(
            history(&repo, "t-1", 3),
            "round 2 (fast): review (rev) rejected: REJECT: x\nround 3 (slow): BLOCKED: which flag?\nround 4 (slow): worker made no commit",
            "one line per round, the last three"
        );
        assert_eq!(history(&repo, "t-9", 3), "", "no rounds: nothing");
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn older_beads_have_notes_lines() {
        let d = crate::config::scratch("rounds-notes");
        let repo = crate::config::test_repo(&d, &["fast::3"]);
        write_file(
            &repo.notes_path("t-1"),
            "round 1 (stub/worker): BLOCKED: which flag?\nround 2 (stub/worker): REJECT: x.ts:1 wrong\nodd line\n",
        );
        let r = rounds(&repo, "t-1");
        assert_eq!(r[0], json!({"round": 1, "model": "stub/worker", "note": "BLOCKED: which flag?"}));
        assert_eq!(r[1]["round"], 2);
        assert_eq!(r[2], json!({"note": "odd line"}), "a line that is not a round is kept as its note");
        assert_eq!(history(&repo, "t-1", 2), "round 2 (stub/worker): REJECT: x.ts:1 wrong\nodd line");
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn the_loops_own_question_names_the_reason() {
        let d = crate::config::scratch("question");
        let repo = crate::config::test_repo(&d, &["fast:rev:2", "claude/sonnet:claude/sonnet:1"]);
        let r = vec![
            json!({"round": 1, "model": "fast", "note": "worker made no commit"}),
            json!({"round": 3, "model": "claude/sonnet", "note": "I looked.\nBLOCKED: lib/x.ts:3 has no such flag"}),
        ];
        let q = question_for(&repo, &Reason::Blocked, &r);
        assert!(q.starts_with("The last stage (claude/sonnet) stopped: BLOCKED: lib/x.ts:3 has no such flag — Answer"), "{q}");
        let q = question_for(&repo, &Reason::Exhausted, &r);
        assert!(
            q.starts_with(
                "2 rounds ended in send-backs across every stage (fast ⇢ rev ×2 → claude/sonnet ⇢ claude/sonnet ×1); the last: I looked.."
            ),
            "{q}"
        );
        assert!(q.ends_with("or is it yours to take?"));
        let q = question_for(&repo, &Reason::PrClosed("https://x/pull/7".into()), &[]);
        assert!(q.starts_with("https://x/pull/7 was closed without merging."));
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn brief_parses_in_shape_or_not_at_all() {
        let t = "Some preamble.\nWHAT HAPPENED:\nround 1 tried x.\nround 2 tried y.\nWHY:\nthe flag does not exist.\nQUESTION:\nAdd --dry-run, or drop the criterion?\nEither works.\n";
        let (h, q) = parse_brief(t).unwrap();
        assert_eq!(h, "WHAT HAPPENED:\nround 1 tried x.\nround 2 tried y.\nWHY:\nthe flag does not exist.");
        assert_eq!(q, "Add --dry-run, or drop the criterion?\nEither works.");
        assert!(parse_brief("I think it is fine.").is_none(), "no shape: no brief");
        assert!(parse_brief("WHAT HAPPENED:\nx\nQUESTION:\n").is_none(), "an empty question is none");
        let (_, q) = parse_brief("WHAT HAPPENED: x\nWHY: y\nQUESTION: one line?").unwrap();
        assert_eq!(q, "one line?", "the question on the same line");
    }
    #[test]
    fn brief_model_is_the_last_stages_worker_unless_set() {
        let d = crate::config::scratch("brief-model");
        let mut repo = crate::config::test_repo(&d, &["fast::2", "slow::1"]);
        assert_eq!(brief_model(&repo).as_deref(), Some("slow"), "the last stage's worker");
        repo.stages[1].worker = "aider:slow".into();
        assert_eq!(brief_model(&repo).as_deref(), Some("slow"), "out of aider: a brief is not an edit");
        repo.brief_model = "claude/opus".into();
        assert_eq!(brief_model(&repo).as_deref(), Some("claude/opus"));
        repo.brief_model = "none".into();
        assert!(brief_model(&repo).is_none());
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn brief_prompt_carries_rounds_and_log_tails() {
        let d = crate::config::scratch("brief-prompt");
        let repo = crate::config::test_repo(&d, &["fast:rev:1"]);
        let bead = json!([{"id":"t-1","title":"T","description":"D"}]);
        let r = vec![
            json!({"round": 1, "model": "fast", "stage": 1, "when": "2026-09-20T01:01+00:00", "note": "gate failed twice: false\nboom", "logs": ["t-1.s.gate"]}),
        ];
        let p = brief_prompt(
            &repo,
            &bead,
            &Reason::Exhausted,
            &r,
            &[("round 1: t-1.s.gate".into(), "boom".into()), ("round 1: t-1.s.worker.jsonl".into(), "  ".into())],
        );
        assert!(p.starts_with(
            "The automated loop has parked the bead below for its owner: every stage has had its turn (1 rounds, all sent back)."
        ));
        assert!(p.contains("<bead>\nid: t-1\n"));
        assert!(p.contains("The stages, in order: fast ⇢ rev ×1"));
        assert!(p.contains("<rounds>\nround 1 · fast (stage 1) · 2026-09-20T01:01+00:00:\ngate failed twice: false\nboom\nlogs (under "));
        assert!(p.contains("--- round 1: t-1.s.gate, the end:\nboom\n"), "{p}");
        assert!(!p.contains("worker.jsonl, the end"), "an empty tail is left out");
        assert!(p.ends_with("QUESTION:\n<the question or questions>"));
        let p = brief_prompt(&repo, &bead, &Reason::PrClosed("https://x/pull/7".into()), &[], &[]);
        assert!(p.contains("its pull request https://x/pull/7 was closed on GitHub without merging"));
        let _ = std::fs::remove_dir_all(&d);
    }
    #[test]
    fn log_tail_renders_each_kind() {
        let d = crate::config::scratch("log-tail");
        let oc = d.join("x.worker.jsonl");
        std::fs::write(&oc, "{\"type\":\"text\",\"part\":{\"text\":\"I looked.\"}}\n{\"type\":\"tool_use\",\"part\":{\"tool\":\"bash\",\"state\":{\"input\":{\"command\":\"ls\"}}}}\nnot json\n{\"type\":\"text\",\"part\":{\"text\":\"DONE: x\"}}\n").unwrap();
        assert_eq!(log_tail(&oc, 2), "[bash] ls\n> DONE: x");
        let cc = d.join("x.review.jsonl");
        std::fs::write(&cc, "{\"type\":\"result\",\"result\":\"a\\nb\\nAPPROVE: c\"}").unwrap();
        assert_eq!(log_tail(&cc, 2), "b\nAPPROVE: c", "a Claude Code result is its text");
        let g = d.join("x.gate");
        std::fs::write(&g, "1\n2\n3\n").unwrap();
        assert_eq!(log_tail(&g, 2), "2\n3");
        assert_eq!(log_tail(&d.join("none"), 2), "");
        let _ = std::fs::remove_dir_all(&d);
    }
}
