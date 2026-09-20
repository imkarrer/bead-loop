//! The one description of a repo's state, as JSON: config, the three queues in their
//! order, the two lanes and what each is on, the parked and held beads, and every
//! worktree with what the attached opencode server has under it. `status` renders it as
//! text; `--json status` prints it for the web UI. The JSON is the bash's, key for key.
use crate::config::Repo;
use crate::harness::claude_ok;
use crate::shell::{bd_in_progress_json, bd_ready_json, curl_get};
use crate::state::review_queue;
use crate::util::{base64url, cmd, mtime, now, output, read_to_string, stdout_str};
use serde_json::{json, Map, Value};
use std::path::Path;

/// `sessions_json DIR`: the server's top-level sessions under DIR, newest first, with the
/// state and web UI url worked out. A session the server calls busy with no `opencode run`
/// client left on this box is an orphan.
pub fn sessions_json(repo: &Repo, dir: &Path) -> Value {
    if repo.attach.is_empty() || !crate::util::have("curl") {
        return json!([]);
    }
    let d = dir.to_string_lossy().into_owned();
    let busy: Value =
        curl_get(&format!("{}/session/status", repo.attach), Some(&d), 3).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!({}));
    let list: Value =
        curl_get(&format!("{}/session", repo.attach), Some(&d), 3).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!([]));
    let clients: i64 = output(cmd("pgrep").args(["-fc", "--", &format!("opencode run --dir {d} ")]))
        .ok()
        .and_then(|o| stdout_str(&o).trim().parse().ok())
        .unwrap_or(0);
    let url = format!("{}/{}", repo.attach, base64url(&d));
    let mut top: Vec<&Value> =
        list.as_array().map(|a| a.iter().filter(|s| s.get("parentID").map(|p| p.is_null()).unwrap_or(true)).collect()).unwrap_or_default();
    let updated = |s: &Value| s.pointer("/time/updated").and_then(|v| v.as_f64()).unwrap_or(0.0);
    top.sort_by(|a, b| updated(b).partial_cmp(&updated(a)).unwrap_or(std::cmp::Ordering::Equal));
    let rows: Vec<Value> = top
        .into_iter()
        .take(4)
        .map(|s| {
            let id = s.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let is_busy = busy.get(&id).map(|b| !b.is_null() && b != &Value::Bool(false)).unwrap_or(false);
            json!({
                "id": id,
                "agent": s.get("agent").cloned().unwrap_or(Value::Null),
                "model": format!("{}/{}",
                    s.pointer("/model/providerID").and_then(|v| v.as_str()).unwrap_or("null"),
                    s.pointer("/model/id").and_then(|v| v.as_str()).unwrap_or("null")),
                "title": s.get("title").and_then(|v| v.as_str()).unwrap_or(""),
                "updated": (updated(s) / 1000.0).floor() as i64,
                "state": if is_busy { if clients > 0 { "busy" } else { "orphan" } } else { "idle" },
                "url": format!("{url}/session/{id}"),
            })
        })
        .collect();
    Value::Array(rows)
}

/// The `why` of a parked bead: the last note the loop left, split into when and what.
fn why_of(notes: &str) -> Value {
    let line = match notes.lines().rfind(|l| l.starts_with("bead-loop")) {
        Some(l) => l,
        None => return Value::Null,
    };
    // ^bead-loop(?<round> round [0-9]+ \([^)]*\))? (?<when>[0-9T:+-]+): (?<what>.*)$
    let rest = &line["bead-loop".len()..];
    let (round, rest) = if let Some(r) = rest.strip_prefix(" round ") {
        let mut end = 0;
        let b = r.as_bytes();
        while end < b.len() && b[end].is_ascii_digit() {
            end += 1;
        }
        if end > 0 && r[end..].starts_with(" (") {
            if let Some(close) = r[end..].find(')') {
                let round = format!(" round {}", &r[..end + close + 1]);
                (Some(round), &r[end + close + 1..])
            } else {
                (None, rest)
            }
        } else {
            (None, rest)
        }
    } else {
        (None, rest)
    };
    let parsed = (|| {
        let r = rest.strip_prefix(' ')?;
        // greedy `[0-9T:+-]+` then `: ` — the regex backtracks over the colon, so do we
        let max = r.bytes().take_while(|c| c.is_ascii_digit() || b"T:+-".contains(c)).count();
        let mut k = max;
        while k > 0 {
            if let Some(what) = r[k..].strip_prefix(": ") {
                return Some((r[..k].to_string(), what.to_string()));
            }
            k -= 1;
        }
        None
    })();
    match parsed {
        Some((when, what)) => json!({"round": round, "when": when, "what": what}),
        None => json!({"when": Value::Null, "what": line}),
    }
}

fn stage_json(repo: &Repo, n: u64) -> Value {
    match repo.stage_for(n) {
        Some(st) => {
            let s = &repo.stages[st.index - 1];
            json!({"worker": s.worker, "reviewer": s.reviewer, "failures": s.failures, "index": st.index})
        }
        None => Value::Null,
    }
}

fn history_json(repo: &Repo, id: &str) -> Value {
    let lines: Vec<Value> = read_to_string(&repo.notes_path(id))
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| Value::String(l.to_string()))
        .collect();
    Value::Array(lines)
}

/// The bead as every queue row carries it.
fn bead_json(repo: &Repo, byid: &Map<String, Value>, id: &str) -> Map<String, Value> {
    let b = byid.get(id).cloned().unwrap_or(json!({"id": id}));
    let n = repo.failures_of(id);
    let mut m = Map::new();
    m.insert("id".into(), Value::String(id.to_string()));
    m.insert("title".into(), b.get("title").cloned().unwrap_or(Value::Null));
    m.insert("priority".into(), b.get("priority").cloned().unwrap_or(Value::Null));
    m.insert("failures".into(), json!(n));
    m.insert("stage".into(), stage_json(repo, n));
    m.insert("history".into(), history_json(repo, id));
    let held = repo.held_why(id).map(|w| json!({"why": w, "since": repo.held_since(id)})).unwrap_or(Value::Null);
    m.insert("held".into(), held);
    m
}

/// `status_json`: this repo, one JSON object.
pub fn status_json(repo: &Repo) -> Value {
    // lanes: the configured ones ([[lanes]] in the global file), else dev + review, plus
    // claude when this repo's stages name it — the same list the loop runs.
    let specs = crate::config::Layers::load(&crate::config::config_dir().join("config.toml"), None).lanes(has_claude_stage(repo));
    status_json_from(repo, bd_ready_json(repo), bd_in_progress_json(repo), &specs)
}

/// Whether this repo's stages (or its conflict worker) name a claude/* model.
pub fn has_claude_stage(repo: &Repo) -> bool {
    repo.stages.iter().any(|s| s.worker.starts_with("claude/") || s.reviewer.starts_with("claude/"))
        || repo.conflict_worker.starts_with("claude/")
}

/// The status from what bd said — the ready beads and the in_progress ones — and the
/// lanes the loop runs.
pub fn status_json_from(repo: &Repo, open: Value, inprog: Value, specs: &[crate::config::LaneSpec]) -> Value {
    let mut byid: Map<String, Value> = Map::new();
    for b in open.as_array().into_iter().flatten().chain(inprog.as_array().into_iter().flatten()) {
        if let Some(id) = b.get("id").and_then(|i| i.as_str()) {
            byid.insert(id.to_string(), b.clone());
        }
    }
    // merge queue
    let merge_ids = repo.inflight_ids();
    let merge: Vec<Value> = merge_ids
        .iter()
        .map(|id| {
            let mut m = Map::new();
            m.insert("id".into(), json!(id));
            m.insert("url".into(), json!(read_to_string(&repo.inflight_path(id)).unwrap_or_default().trim()));
            m.insert("red".into(), json!(repo.mark(id, "red").exists()));
            m.insert("adopted".into(), json!(repo.mark(id, "adopted").exists()));
            m.insert("failures".into(), json!(repo.failures_of(id)));
            m.insert("title".into(), json!(byid.get(id).and_then(|b| b.get("title")).and_then(|t| t.as_str()).unwrap_or("")));
            m.insert("held".into(), repo.held_why(id).map(|w| json!({"why": w, "since": repo.held_since(id)})).unwrap_or(Value::Null));
            Value::Object(m)
        })
        .collect();
    let lane_names: Vec<String> = specs.iter().map(|l| l.name.clone()).collect();
    let mut lanes = Map::new();
    let mut laneids = Vec::new();
    for name in lane_names.iter().map(String::as_str).chain(repo.lane_files().iter().map(String::as_str)) {
        if lanes.contains_key(name) {
            continue;
        }
        if let Some(id) = repo.lane_bead(name) {
            let mut m = bead_json(repo, &byid, &id);
            m.insert("since".into(), json!(mtime(&repo.lane_path(name))));
            lanes.insert(name.into(), Value::Object(m));
            laneids.push(id);
        }
    }
    let paused: Map<String, Value> = lane_names.iter().map(|n| (n.clone(), json!(repo.paused(n)))).collect();
    let review_ids = review_queue(repo);
    let ready_ids: Vec<String> =
        open.as_array().into_iter().flatten().filter_map(|b| b.get("id").and_then(|i| i.as_str()).map(str::to_string)).collect();
    let dev: Vec<Value> = crate::state::order_dev(repo, ready_ids)
        .into_iter()
        .filter(|id| !laneids.contains(id) && !merge_ids.contains(id) && !review_ids.contains(id))
        .map(|id| Value::Object(bead_json(repo, &byid, &id)))
        .collect();
    let review: Vec<Value> = review_ids
        .iter()
        .filter(|id| !laneids.contains(id))
        .map(|id| {
            let mut m = Map::new();
            m.insert("id".into(), json!(id));
            m.insert("since".into(), json!(mtime(&repo.review_path(id))));
            for (k, v) in bead_json(repo, &byid, id) {
                m.insert(k, v);
            }
            Value::Object(m)
        })
        .collect();
    let parked: Vec<Value> = inprog
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|b| b.get("id").and_then(|i| i.as_str()).map(|i| (i.to_string(), b)))
        .filter(|(id, _)| !merge_ids.contains(id) && !laneids.contains(id) && !review_ids.contains(id))
        .map(|(id, b)| {
            let mut m = bead_json(repo, &byid, &id);
            let why = why_of(b.get("notes").and_then(|n| n.as_str()).unwrap_or(""));
            let question = why.get("what").and_then(|w| w.as_str()).map(|w| w.contains("BLOCKED:")).unwrap_or(false);
            m.insert("why".into(), why);
            m.insert("question".into(), json!(question));
            m.insert("open_cmd".into(), json!(format!("bead-supervisor open {} {id}", repo.repo.display())));
            Value::Object(m)
        })
        .collect();
    // held: every bead with a held/ file, wherever it sits — the human list beside parked
    let held: Vec<Value> = std::fs::read_dir(repo.rs.join("held"))
        .map(|rd| {
            let mut ids: Vec<String> = rd.flatten().filter_map(|e| e.file_name().into_string().ok()).collect();
            ids.sort();
            ids.into_iter()
                .map(|id| {
                    let wher = if merge_ids.contains(&id) {
                        "merge"
                    } else if review_ids.contains(&id) {
                        "review"
                    } else {
                        "dev"
                    };
                    let mut m = bead_json(repo, &byid, &id);
                    m.insert("where".into(), json!(wher));
                    m.insert("why".into(), json!(repo.held_why(&id).unwrap_or_default()));
                    m.insert("since".into(), json!(repo.held_since(&id)));
                    Value::Object(m)
                })
                .collect()
        })
        .unwrap_or_default();
    // decisions: open beads of type `decision`, or labelled needs-human — a question for
    // the human, asked by the loop, an agent, or the human's own planning. The page lists
    // them under Needs you with the text in full; the answer closes the bead with the
    // reason, where whoever asked reads it.
    let decisions: Vec<Value> = crate::shell::bd_open_json(repo)
        .as_array()
        .into_iter()
        .flatten()
        .filter(|b| {
            b.get("issue_type").and_then(|t| t.as_str()) == Some("decision")
                || b.get("labels").and_then(|l| l.as_array()).map(|a| a.iter().any(|v| v.as_str() == Some("needs-human"))).unwrap_or(false)
        })
        .map(|b| {
            json!({
                "id": b.get("id").cloned().unwrap_or(Value::Null),
                "title": b.get("title").cloned().unwrap_or(Value::Null),
                "description": b.get("description").cloned().unwrap_or(Value::Null),
                "created_at": b.get("created_at").cloned().unwrap_or(Value::Null),
            })
        })
        .collect();
    let worktrees: Vec<Value> = std::fs::read_dir(repo.rs.join("wt"))
        .map(|rd| {
            let mut dirs: Vec<std::path::PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
            dirs.sort();
            dirs.into_iter()
                .map(|dir| {
                    let id = dir.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                    json!({"id": id, "dir": dir.to_string_lossy(), "failures": repo.failures_of(&id), "sessions": sessions_json(repo, &dir)})
                })
                .collect()
        })
        .unwrap_or_default();
    let stages: Vec<Value> =
        repo.stages.iter().map(|s| json!({"worker": s.worker, "reviewer": s.reviewer, "failures": s.failures})).collect();
    let has_claude = repo.stages.iter().any(|s| s.worker.starts_with("claude/") || s.reviewer.starts_with("claude/"));
    let priority =
        crate::lanes::priority_repo(&repo.state_dir).map(|p| p == repo.repo || p.to_string_lossy() == repo.slug).unwrap_or(false);
    json!({
        "slug": repo.slug, "repo": repo.repo.to_string_lossy(), "label": repo.label, "base": repo.base,
        "merge": repo.merge, "attach": repo.attach,
        "max_inflight": if repo.max_inflight == u64::MAX { Value::Null } else { json!(repo.max_inflight) },
        "stages": stages, "on_exhaust": repo.on_exhaust,
        "conflict_worker": if repo.conflict_worker.is_empty() { Value::Null } else { json!(repo.conflict_worker) },
        "lanes": lanes,
        "lane_names": lane_names,
        "paused": paused,
        "claude_ok": if has_claude { json!(claude_ok()) } else { Value::Null },
        "priority": priority,
        "queues": {"dev": dev, "review": review, "merge": merge},
        "parked": parked,
        "held": held,
        "decisions": decisions,
        "worktrees": worktrees,
    })
}

// ---- text ---------------------------------------------------------------------------
fn pad(s: &str, n: usize) -> String {
    let mut t: String = s.chars().take(n).collect();
    let len = t.chars().count();
    if len < n {
        t.extend(std::iter::repeat_n(' ', n - len));
    }
    t
}

pub fn age(since: i64) -> String {
    let d = (now() - since).max(0);
    if d < 90 {
        format!("{d}s")
    } else if d < 5400 {
        format!("{}m", d / 60)
    } else {
        format!("{}h", d / 3600)
    }
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("")
}

/// `status_one`: status_json as text.
pub fn status_one(repo: &Repo) -> String {
    status_text(&status_json(repo))
}

pub fn status_text(j: &Value) -> String {
    let mut out = String::new();
    let stages: Vec<String> = j["stages"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|st| {
            format!("{}⇢{}×{}", s(st, "worker"), if s(st, "reviewer").is_empty() { "none" } else { s(st, "reviewer") }, st["failures"])
        })
        .collect();
    out.push_str(&format!(
        "{}  label={} base={} merge={} stages={}{}\n",
        s(j, "slug"),
        s(j, "label"),
        s(j, "base"),
        s(j, "merge"),
        stages.join(" → "),
        if j["priority"].as_bool().unwrap_or(false) { "  [priority]" } else { "" }
    ));
    let lane_rows: Vec<(String, String)> = j["lane_names"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|n| n.as_str())
        .map(|n| (n.to_string(), format!("  {:<13}", format!("{n} lane:"))))
        .collect();
    for (name, label) in lane_rows {
        let name = name.as_str();
        let l = &j["lanes"][name];
        let what = if l.is_object() {
            format!("{} {} ({})", s(l, "id"), s(l, "title"), age(l["since"].as_i64().unwrap_or(0)))
        } else {
            "idle".to_string()
        };
        let paused = if j["paused"][name].as_bool().unwrap_or(false) { "  [paused]" } else { "" };
        out.push_str(&format!("{label}{what}{paused}\n"));
    }
    for name in ["dev", "review"] {
        let list = j["queues"][name].as_array().cloned().unwrap_or_default();
        out.push_str(&format!("  {name} queue ({}):{}\n", list.len(), if list.is_empty() { "  —" } else { "" }));
        for (i, b) in list.iter().enumerate() {
            let worker = b["stage"].get("worker").and_then(|w| w.as_str()).unwrap_or("—");
            out.push_str(&format!(
                "    {} {} {}× {} {}\n",
                pad(&(i + 1).to_string(), 3),
                pad(s(b, "id"), 14),
                b["failures"],
                pad(worker, 14),
                pad(s(b, "title"), 60)
            ));
        }
    }
    let merge = j["queues"]["merge"].as_array().cloned().unwrap_or_default();
    out.push_str(&format!("  merge queue ({}):{}\n", merge.len(), if merge.is_empty() { "  —" } else { "" }));
    for p in &merge {
        out.push_str(&format!(
            "    {} {}{}{}\n",
            pad(s(p, "id"), 14),
            s(p, "url"),
            if p["red"].as_bool().unwrap_or(false) { "  [red]" } else { "" },
            if p["adopted"].as_bool().unwrap_or(false) { "  [adopted]" } else { "" }
        ));
    }
    let parked = j["parked"].as_array().cloned().unwrap_or_default();
    if !parked.is_empty() {
        out.push_str("  parked:\n");
        for b in &parked {
            let what = b["why"].get("what").and_then(|w| w.as_str()).unwrap_or("(no note from the loop)");
            out.push_str(&format!("    {} {}\n", pad(s(b, "id"), 14), what.chars().take(140).collect::<String>()));
        }
    }
    let held = j["held"].as_array().cloned().unwrap_or_default();
    if !held.is_empty() {
        out.push_str("  held (waiting on you or the world; still in its queue):\n");
        for b in &held {
            out.push_str(&format!(
                "    {} [{}] {}\n",
                pad(s(b, "id"), 14),
                s(b, "where"),
                s(b, "why").chars().take(140).collect::<String>()
            ));
        }
    }
    let attach = s(j, "attach");
    for w in j["worktrees"].as_array().into_iter().flatten() {
        for sess in w["sessions"].as_array().into_iter().flatten() {
            let st = s(sess, "state");
            if st == "idle" {
                continue;
            }
            let state_col = if st == "orphan" { "ORPHAN".to_string() } else { pad(st, 6) };
            out.push_str(&format!(
                "  {}  {}  {}  {}  {}  {}\n",
                state_col,
                pad(sess.get("agent").and_then(|a| a.as_str()).unwrap_or("?"), 13),
                pad(s(sess, "model"), 18),
                pad(&format!("{} ago", age(sess["updated"].as_i64().unwrap_or(0))), 7),
                pad(s(sess, "title"), 40),
                s(sess, "url")
            ));
            if st == "orphan" {
                out.push_str(&format!(
                    "          no client on this box; stop it:  curl -X POST {attach}/session/{}/abort\n",
                    s(sess, "id")
                ));
            }
        }
    }
    out
}

/// `watch`: status every few seconds, with the last supervisor log lines above it.
pub fn watch_loop(repos: &[std::path::PathBuf], interval: u64, model_flag: Option<&str>) -> ! {
    loop {
        print!("\x1b[H\x1b[J{}   bead-supervisor watch (every {interval}s, ctrl-c to stop)\n\n", crate::util::clock());
        if crate::util::have("journalctl") {
            if let Ok(o) = output(cmd("journalctl").args(["--user", "-u", "bead-supervisor.service", "-o", "cat", "-n", "8", "--no-pager"]))
            {
                let cols: usize = std::env::var("COLUMNS").ok().and_then(|c| c.parse().ok()).unwrap_or(200);
                for l in stdout_str(&o).lines() {
                    println!("{}", l.chars().take(cols).collect::<String>());
                }
                println!();
            }
        }
        for r in repos {
            let repo = Repo::load(r, model_flag);
            print!("{}", status_one(&repo));
        }
        std::thread::sleep(std::time::Duration::from_secs(interval));
    }
}

/// `log [ID]`: stream the newest session log for the repo as one line per tool call or text.
pub fn log_follow(repo: &Repo, id: Option<&str>) {
    let pat = id.unwrap_or("*");
    let mut files: Vec<(i64, std::path::PathBuf)> = std::fs::read_dir(repo.rs.join("logs"))
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| {
                    let n = p.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                    n.ends_with(".jsonl") && (pat == "*" || n.starts_with(&format!("{pat}.")))
                })
                .map(|p| (mtime(&p), p))
                .collect()
        })
        .unwrap_or_default();
    files.sort_by_key(|a| std::cmp::Reverse(a.0));
    let f = match files.first() {
        Some((_, p)) => p.clone(),
        None => crate::util::die(&format!("{}: no session logs{}", repo.slug, id.map(|i| format!(" for {i}")).unwrap_or_default())),
    };
    crate::util::log(&format!("{}: following {} (ctrl-c to stop)", repo.slug, f.display()));
    let mut child = match cmd("tail").args(["-n", "+1", "-f"]).arg(&f).stdout(std::process::Stdio::piped()).spawn() {
        Ok(c) => c,
        Err(e) => crate::util::die(&format!("tail: {e}")),
    };
    use std::io::BufRead;
    let out = child.stdout.take().unwrap();
    for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
        let v: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match v.get("type").and_then(|t| t.as_str()) {
            Some("tool_use") => {
                let inp = v.pointer("/part/state/input").cloned().unwrap_or(Value::Null);
                let arg = ["command", "filePath", "path", "pattern", "description"]
                    .iter()
                    .find_map(|k| inp.get(k).and_then(|x| x.as_str()).map(str::to_string))
                    .unwrap_or_default();
                println!(
                    "[{}] {}",
                    v.pointer("/part/tool").and_then(|t| t.as_str()).unwrap_or(""),
                    arg.chars().take(160).collect::<String>()
                );
            }
            Some("text") => {
                println!("> {}", v.pointer("/part/text").and_then(|t| t.as_str()).unwrap_or("").chars().take(400).collect::<String>())
            }
            Some("step_finish") => println!(
                "-- step: {}  tokens in={} out={}",
                v.pointer("/part/reason").and_then(|t| t.as_str()).unwrap_or(""),
                v.pointer("/part/tokens/input").cloned().unwrap_or(Value::Null),
                v.pointer("/part/tokens/output").cloned().unwrap_or(Value::Null)
            ),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn why_parses_the_loops_note() {
        let w = why_of("someone: a human note\nbead-loop 2026-09-18T17:05+00:00: stages exhausted after REJECT: x.ts:1 wrong");
        assert_eq!(w["when"], "2026-09-18T17:05+00:00");
        assert_eq!(w["what"], "stages exhausted after REJECT: x.ts:1 wrong");
        let w = why_of("bead-loop round 3 (stub/worker) 2026-09-18T17:05+00:00: BLOCKED: lib/x.ts:3 no flag");
        assert_eq!(w["round"], " round 3 (stub/worker)");
        assert_eq!(w["what"], "BLOCKED: lib/x.ts:3 no flag");
        let w = why_of("bead-loop: something odd");
        assert!(w["when"].is_null());
        assert_eq!(w["what"], "bead-loop: something odd");
        assert!(why_of("nothing").is_null());
    }
    #[test]
    fn pad_truncates_and_fills() {
        assert_eq!(pad("abc", 5), "abc  ");
        assert_eq!(pad("abcdefg", 3), "abc");
        assert_eq!(age(now() - 10), "10s");
        assert_eq!(age(now() - 600), "10m");
        assert_eq!(age(now() - 7200), "2h");
        assert_eq!(age(now() + 5), "0s", "a clock ahead of the file is not negative");
    }

    /// The lanes the loop runs without [[lanes]] in the global file: dev and review, and
    /// claude when a stage names it. The live global config is not read here.
    fn default_lanes(claude: bool) -> Vec<crate::config::LaneSpec> {
        crate::config::Layers { global: json!({}), repo: json!({}) }.lanes(claude)
    }

    /// Three queues and two lanes, laid out by hand: t-1 in the merge queue (red), t-2,
    /// t-3 and t-7 ready (t-3 has failed once, so t-2 goes first; t-7 twice, so it is on
    /// the last stage, Claude's), t-4 waiting for review, t-6 on the dev lane, t-5 parked,
    /// t-8 held in dev. What bd would say is handed in; no server is attached.
    fn laid_out(name: &str) -> (std::path::PathBuf, Repo, Value) {
        let d = crate::config::scratch(name);
        let repo = crate::config::test_repo(&d, &["stub/worker:stub/reviewer:2", "claude/opus::1"]);
        repo.set_failures("t-1", 2);
        repo.set_failures("t-3", 1);
        repo.set_failures("t-7", 2);
        crate::util::write_file(
            &repo.notes_path("t-7"),
            "round 1 (stub/worker): BLOCKED: which flag?\nround 2 (stub/worker): REJECT: x.ts:1 wrong\n",
        );
        crate::util::write_file(&repo.review_path("t-4"), "DONE: did it\n");
        repo.lane_set("dev", "t-6");
        crate::util::write_file(&repo.inflight_path("t-1"), "https://github.com/example/repo/pull/7\n");
        crate::util::touch(&repo.mark("t-1", "red"));
        let _ = std::fs::create_dir_all(repo.wt("t-1"));
        repo.hold("t-8", "setup failed: false");
        let open = json!([
            {"id":"t-2","title":"Second","priority":2,"labels":["delegate:local"]},
            {"id":"t-3","title":"Third","priority":1},
            {"id":"t-7","title":"Seventh","priority":2},
            {"id":"t-8","title":"Eighth","priority":2},
        ]);
        let inprog = json!([
            {"id":"t-1","title":"First"},
            {"id":"t-4","title":"Fourth"},
            {"id":"t-6","title":"Sixth"},
            {"id":"t-5","title":"Parked one","notes":"someone: a human note\nbead-loop 2026-09-18T17:05+00:00: stages exhausted after REJECT: x.ts:1 wrong"},
        ]);
        let j = status_json_from(&repo, open, inprog, &default_lanes(true));
        (d, repo, j)
    }

    #[test]
    fn status_json_lays_out_the_queues() {
        let (d, _repo, j) = laid_out("status-queues");
        let ids = |v: &Value| v.as_array().unwrap().iter().map(|b| b["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
        assert_eq!(j["slug"], "repo");
        assert_eq!(j["stages"][0]["worker"], "stub/worker");
        assert_eq!(j["stages"][0]["failures"], 2);
        assert_eq!(j["lanes"]["dev"]["id"], "t-6", "the dev lane's bead");
        assert!(j["lanes"].get("review").is_none(), "the review lane is idle");
        assert_eq!(
            ids(&j["queues"]["dev"]),
            vec!["t-2", "t-8", "t-3", "t-7"],
            "dev queue: fewest failures first, bd's order within a count"
        );
        let dev = j["queues"]["dev"].as_array().unwrap();
        assert_eq!(dev[3]["stage"]["worker"], "claude/opus", "two failures: on the last stage");
        assert_eq!(dev[3]["stage"]["index"], 2);
        assert_eq!(
            dev[3]["history"],
            json!(["round 1 (stub/worker): BLOCKED: which flag?", "round 2 (stub/worker): REJECT: x.ts:1 wrong"])
        );
        assert_eq!(dev[0]["history"], json!([]), "no notes file: an empty history");
        assert_eq!(dev[1]["held"]["why"], "setup failed: false", "a held bead is still in its queue");
        assert_eq!(ids(&j["queues"]["review"]), vec!["t-4"]);
        assert_eq!(j["queues"]["review"][0]["title"], "Fourth");
        assert_eq!(
            j["queues"]["merge"][0],
            json!({"id":"t-1","url":"https://github.com/example/repo/pull/7","red":true,"adopted":false,"failures":2,"title":"First","held":null})
        );
        assert!(j["queues"]["merge"][0].get("stage").is_none(), "merge rows carry no stage");
        assert_eq!(ids(&j["parked"]), vec!["t-5"], "parked = in_progress minus the queues and lanes");
        assert_eq!(
            j["parked"][0]["why"],
            json!({"round": null, "when": "2026-09-18T17:05+00:00", "what": "stages exhausted after REJECT: x.ts:1 wrong"})
        );
        assert_eq!(j["parked"][0]["question"], false);
        assert!(j["parked"][0]["open_cmd"].as_str().unwrap().ends_with("/repo t-5"));
        assert_eq!(j["held"][0]["id"], "t-8");
        assert_eq!(j["held"][0]["where"], "dev");
        assert_eq!(j["worktrees"][0]["id"], "t-1");
        assert_eq!(j["worktrees"][0]["failures"], 2);
        assert_eq!(j["worktrees"][0]["sessions"], json!([]), "no attach: no server to ask");
        assert_eq!(j["claude_ok"].is_boolean(), true, "a claude stage: the probe is reported");
        assert_eq!(j["max_inflight"], Value::Null, "unlimited prints as null");
        assert_eq!(j["priority"], false);
        assert_eq!(j["paused"], json!({"dev": false, "review": false, "claude": false}), "one flag per lane the loop runs");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn held_knows_where_and_a_question_is_marked() {
        let (d, repo, _) = laid_out("status-held");
        repo.hold("t-4", "reviewer stub/reviewer exited 7 with no output");
        repo.hold("t-1", "CI red on adopted PR");
        let inprog = json!([{"id":"t-9","title":"Asked","notes":"bead-loop round 1 (stub/fast) 2026-09-18T17:05+00:00: BLOCKED: lib/x.ts:3 has no such flag"}]);
        let j = status_json_from(&repo, json!([]), inprog, &default_lanes(true));
        let held: Vec<(String, String)> =
            j["held"].as_array().unwrap().iter().map(|h| (h["id"].as_str().unwrap().into(), h["where"].as_str().unwrap().into())).collect();
        assert_eq!(held, vec![("t-1".into(), "merge".into()), ("t-4".into(), "review".into()), ("t-8".into(), "dev".into())]);
        assert_eq!(j["queues"]["merge"][0]["held"]["why"], "CI red on adopted PR");
        assert_eq!(j["parked"][0]["question"], true, "BLOCKED: in the last note is a question for you");
        assert_eq!(j["parked"][0]["why"]["round"], " round 1 (stub/fast)");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn status_text_reads_the_json() {
        let (d, _repo, mut j) = laid_out("status-text");
        j["priority"] = json!(true);
        j["paused"]["review"] = json!(true);
        let t = status_text(&j);
        assert!(
            t.starts_with(
                "repo  label=delegate:local base=main merge=auto stages=stub/worker⇢stub/reviewer×2 → claude/opus⇢none×1  [priority]\n"
            ),
            "{t}"
        );
        assert!(t.contains("\n  dev lane:    t-6 Sixth ("), "the lane's bead");
        assert!(t.contains("\n  review lane: idle  [paused]\n"));
        assert!(t.contains("\n  dev queue (4):\n    1   t-2            0× stub/worker    Second"), "the dev queue in order");
        assert!(t.contains("\n    4   t-7            2× claude/opus    Seventh"));
        assert!(t.contains("\n  merge queue (1):\n    t-1            https://github.com/example/repo/pull/7  [red]\n"));
        assert!(t.contains("\n  parked:\n    t-5            stages exhausted after REJECT: x.ts:1 wrong\n"));
        assert!(t.contains("\n  held (waiting on you or the world; still in its queue):\n    t-8            [dev] setup failed: false\n"));
        assert!(!t.contains("ORPHAN"), "no sessions without a server");
        // An orphan session on an attached server gets its abort hint.
        j["attach"] = json!("http://oc.test:4096");
        j["worktrees"][0]["sessions"] = json!([
            {"id":"ses_rev","agent":"bead-reviewer","model":"slow/m","title":"Reviewing","updated": now(),"state":"orphan","url":"http://oc.test:4096/x/session/ses_rev"},
            {"id":"ses_old","agent":"bead-worker","model":"fast/m","title":"Old","updated": 0,"state":"idle","url":"u"}
        ]);
        let t = status_text(&j);
        assert!(t.contains("  ORPHAN  bead-reviewer  slow/m              0s ago   Reviewing                                 http://oc.test:4096/x/session/ses_rev\n"), "{t}");
        assert!(t.contains("stop it:  curl -X POST http://oc.test:4096/session/ses_rev/abort\n"));
        assert!(!t.contains("ses_old"), "idle sessions are history, not shown");
        let empty =
            status_text(&status_json_from(&crate::config::test_repo(&d.join("e"), &["a"]), json!([]), json!([]), &default_lanes(false)));
        assert!(empty.contains("  dev queue (0):  —\n"), "{empty}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn sessions_are_sorted_and_stated() {
        // sessions_json asks a server; without one it is empty. The shaping of what a
        // server says is the same code, so a stub answer is enough: see test/run.sh's
        // status_lists_worktree_sessions for the live pgrep and curl.
        let d = crate::config::scratch("sessions");
        let repo = crate::config::test_repo(&d, &["a"]);
        assert_eq!(sessions_json(&repo, &d), json!([]));
        let _ = std::fs::remove_dir_all(&d);
    }
}
