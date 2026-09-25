//! The scoreboard: how well the workflow works, from what it already writes down.
//!
//! Nothing here is new bookkeeping. The bead carries the record — `started_at` when
//! the loop first claimed it, `closed_at` and a `bead-loop: URL merged` close reason
//! when it landed, one `bead-loop round N (model) DATE: why` note per send-back, and
//! a dated note for every hold, rebase, escalation and answer — and the state dir's
//! `logs/` has one `ID.STAMP.worker.jsonl` / `.review.jsonl` per model session (the
//! stamp is when it started, the mtime when it ended, an empty file a session the
//! server never answered). `stats` reads both and sums them over four windows.
//!
//! What the numbers mean: *landed* is a bead the loop merged and closed; *first try*
//! landed with no send-back; *local* landed on a stage whose worker's provider is not metered;
//! *rounds per landed* counts send-backs plus the round that landed; *time to land*
//! runs from the first claim to the merge. Send-backs are split by the reason the
//! note gives and by the model that was working. Model time is the sum of the
//! sessions' durations by role; an *empty* round is a session the harness or server
//! never answered — a signed-out Claude, a model server down — retried by the loop.
//! Model cost is the sum of what each session's own transcript says it spent: Claude
//! Code's `total_cost_usd` on its result line, opencode's (and so aider's, which runs
//! on an opencode provider) per-step `cost` in its `step_finish` events — nothing
//! estimated from token counts, only what the harness already priced. A local, unmetered
//! model naturally sums to $0.
use crate::config::Repo;
use crate::util::{mtime, now, read_to_string};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

/// One model session from the state dir's logs/.
#[derive(Clone, Debug, PartialEq)]
pub struct LogRound {
    pub id: String,
    pub start: i64,
    pub end: i64,
    /// worker | review
    pub role: &'static str,
    /// the gate fix session of a dev round: its time counts, it is not a round of its own
    pub fix: bool,
    /// fewer than two lines: the server never answered
    pub empty: bool,
    /// what the session's own transcript says it spent, in USD; 0 for a local model
    pub cost_usd: f64,
}

/// A session's own transcript, summed: Claude Code writes one result line carrying
/// `total_cost_usd`; opencode (aider's provider too) writes one `step_finish` event per
/// step, each with its own `cost` — summed across the session, since each is that step's
/// share, not a running total. Anything else (a harness error, an empty file) costs $0.
fn round_cost(raw: &str) -> f64 {
    let mut sum = 0.0;
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(c) = v.get("total_cost_usd").and_then(|c| c.as_f64()) {
            sum += c;
        } else if v.get("type").and_then(|t| t.as_str()) == Some("step_finish") {
            sum += v.pointer("/part/cost").and_then(|c| c.as_f64()).unwrap_or(0.0);
        }
    }
    sum
}

/// What one note line says happened, and when.
#[derive(Clone, Debug, PartialEq)]
enum Event {
    /// a round that failed: the reason and the model that was working
    SendBack {
        at: i64,
        round: u64,
        model: String,
        reason: &'static str,
    },
    Hold(i64),
    Rebase(i64),
    Escalate(i64),
    Answer(i64),
    Interrupted(i64),
}

impl Event {
    fn at(&self) -> i64 {
        match self {
            Event::SendBack { at, .. } => *at,
            Event::Hold(t) | Event::Rebase(t) | Event::Escalate(t) | Event::Answer(t) | Event::Interrupted(t) => *t,
        }
    }
}

/// The reason a send-back note gives, as the scoreboard groups it.
fn reason_of(text: &str) -> &'static str {
    let t = text.trim_start();
    if t.starts_with("BLOCKED:") || t.starts_with("gate fix round: BLOCKED:") {
        "blocked"
    } else if t.starts_with("worker made no commit") {
        "no commit"
    } else if t.starts_with("gate failed") {
        "gate"
    } else if t.starts_with("review (") {
        "review"
    } else if t.starts_with("CI red") {
        "CI red"
    } else if t.starts_with("worker exited 124") {
        "timed out"
    } else if t.starts_with("worker exited") || t.starts_with("reviewer exited") {
        "crashed"
    } else {
        "other"
    }
}

/// `YYYY-MM-DDTHH:MM[:SS](Z|±HH:MM)` — bd's timestamps and `date -Iminutes` — as epoch
/// seconds. Anything else is None.
pub fn parse_iso(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let num = |from: usize, len: usize| -> Option<i64> {
        let part = b.get(from..from + len)?;
        if !part.iter().all(|c| c.is_ascii_digit()) {
            return None;
        }
        std::str::from_utf8(part).ok()?.parse().ok()
    };
    if b.len() < 16 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' {
        return None;
    }
    let (y, mo, d, h, mi) = (num(0, 4)?, num(5, 2)?, num(8, 2)?, num(11, 2)?, num(14, 2)?);
    let mut i = 16;
    let mut sec = 0;
    if b.get(i) == Some(&b':') {
        sec = num(i + 1, 2)?;
        i += 3;
    }
    let off = match b.get(i) {
        Some(b'Z') => 0,
        Some(&sign @ (b'+' | b'-')) => {
            let oh = num(i + 1, 2)?;
            let om = if b.get(i + 3) == Some(&b':') { num(i + 4, 2)? } else { 0 };
            let o = oh * 3600 + om * 60;
            if sign == b'-' {
                -o
            } else {
                o
            }
        }
        _ => return None,
    };
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    Some(days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - off)
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// `YYYYMMDDTHHMMSS`, a round's log stamp, which util::stamp wrote in local time.
pub fn parse_stamp(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 15 || b[8] != b'T' || !b.iter().enumerate().all(|(i, c)| i == 8 || c.is_ascii_digit()) {
        return None;
    }
    let n = |from: usize, len: usize| -> i32 { s[from..from + len].parse().unwrap_or(0) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = n(0, 4) - 1900;
    tm.tm_mon = n(4, 2) - 1;
    tm.tm_mday = n(6, 2);
    tm.tm_hour = n(9, 2);
    tm.tm_min = n(11, 2);
    tm.tm_sec = n(13, 2);
    tm.tm_isdst = -1;
    let t = unsafe { libc::mktime(&mut tm) };
    if t < 0 {
        None
    } else {
        Some(t)
    }
}

/// The notes of one bead as events. A line the loop did not write is skipped.
fn events_of(notes: &str) -> Vec<Event> {
    let mut out = Vec::new();
    for line in notes.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("operator ") {
            if let Some((when, _)) = rest.split_once(": ") {
                if let Some(t) = parse_iso(when) {
                    out.push(Event::Answer(t));
                }
            }
            continue;
        }
        let rest = match line.strip_prefix("bead-loop ") {
            Some(r) => r,
            None => continue,
        };
        if let Some(r) = rest.strip_prefix("round ") {
            // round N (model) WHEN: why
            let (n, r) = match r.split_once(' ') {
                Some((n, r)) => (n.parse::<u64>().ok(), r),
                None => continue,
            };
            let (model, r) = match r.strip_prefix('(').and_then(|r| r.split_once(") ")) {
                Some(x) => x,
                None => continue,
            };
            if let Some((when, why)) = r.split_once(": ") {
                if let (Some(n), Some(at)) = (n, parse_iso(when)) {
                    out.push(Event::SendBack { at, round: n, model: model.to_string(), reason: reason_of(why) });
                }
            }
            continue;
        }
        let (when, what) = match rest.split_once(": ") {
            Some(x) => x,
            None => continue,
        };
        let at = match parse_iso(when) {
            Some(t) => t,
            None => continue,
        };
        if what.starts_with("held, no failure charged") || what.starts_with("waiting on you") {
            out.push(Event::Hold(at));
        } else if what.contains(" conflicts with ") {
            out.push(Event::Rebase(at));
        } else if what.starts_with("escalated by hand") {
            out.push(Event::Escalate(at));
        } else if what.starts_with("round interrupted") {
            out.push(Event::Interrupted(at));
        }
    }
    out
}

/// The way a bead the loop worked ended.
#[derive(Clone, Copy, Debug, PartialEq)]
enum How {
    /// merged and closed by the loop
    Landed,
    /// closed by someone else after the loop had worked it
    ByHand,
    /// still open, in progress, or parked
    Open,
}

struct Bead {
    id: String,
    slug: String,
    title: String,
    started: Option<i64>,
    closed: Option<i64>,
    how: How,
    url: Option<String>,
    /// the failure count at the end: the state dir's, else the highest round noted
    failures: u64,
    /// the worker of the stage that count lands on
    worker: String,
    /// the worker's provider costs money: `cost = "metered"`
    metered: bool,
    events: Vec<Event>,
    /// `bead-loop: URL was closed without merging` — no date on that note; the bead's updated_at
    closed_unmerged: Option<i64>,
}

fn bead_of(repo: &Repo, b: &Value) -> Option<Bead> {
    let s = |k: &str| b.get(k).and_then(|v| v.as_str()).unwrap_or("");
    let notes = s("notes");
    let reason = s("close_reason");
    let touched = notes.contains("bead-loop") || notes.contains("\noperator ") || reason.starts_with("bead-loop");
    if !touched {
        return None;
    }
    let id = s("id").to_string();
    let events = events_of(notes);
    let closed = parse_iso(s("closed_at")).filter(|_| s("status") == "closed");
    let how = if closed.is_none() {
        How::Open
    } else if reason.starts_with("bead-loop: ") && reason.contains(" merged") {
        How::Landed
    } else {
        How::ByHand
    };
    let url =
        reason.strip_prefix("bead-loop: ").and_then(|r| r.split_whitespace().next()).filter(|u| u.starts_with("http")).map(str::to_string);
    let noted = events.iter().filter_map(|e| if let Event::SendBack { round, .. } = e { Some(*round) } else { None }).max().unwrap_or(0);
    let failures = if repo.rs.join("failures").join(&id).exists() { repo.failures_of(&id) } else { noted };
    let worker = repo.stage_for(failures).map(|st| st.model).unwrap_or_else(|| "exhausted".into());
    let metered = repo.resolve(&worker).provider.cost == "metered";
    let closed_unmerged = if notes.contains("was closed without merging") { parse_iso(s("updated_at")).or(closed) } else { None };
    Some(Bead {
        id,
        slug: repo.slug.clone(),
        title: s("title").to_string(),
        started: parse_iso(s("started_at")).or_else(|| events.iter().map(Event::at).min()).or_else(|| parse_iso(s("created_at"))),
        closed,
        how,
        url,
        failures,
        worker,
        metered,
        events,
        closed_unmerged,
    })
}

/// The sessions under `logs/`: `ID.STAMP.KIND.jsonl`, KIND one of worker, worker-gate,
/// review — or the older loop's worker2, review1, review2.
pub fn log_rounds(repo: &Repo) -> Vec<LogRound> {
    let mut out = Vec::new();
    let rd = match std::fs::read_dir(repo.rs.join("logs")) {
        Ok(rd) => rd,
        Err(_) => return out,
    };
    for e in rd.flatten() {
        let name = match e.file_name().into_string() {
            Ok(n) => n,
            Err(_) => continue,
        };
        let stem = match name.strip_suffix(".jsonl") {
            Some(s) => s,
            None => continue,
        };
        // from the right: KIND, STAMP, then the id (which may itself contain dots)
        let (rest, kind) = match stem.rsplit_once('.') {
            Some(x) => x,
            None => continue,
        };
        let (id, stamp) = match rest.rsplit_once('.') {
            Some(x) => x,
            None => continue,
        };
        let role = if kind.starts_with("worker") {
            "worker"
        } else if kind.starts_with("review") {
            "review"
        } else {
            continue;
        };
        let start = match parse_stamp(stamp) {
            Some(t) => t,
            None => continue,
        };
        let path = e.path();
        let end = mtime(&path).max(start);
        let raw = read_to_string(&path).unwrap_or_default();
        let lines = raw.lines().filter(|l| !l.trim().is_empty()).count();
        out.push(LogRound {
            id: id.to_string(),
            start,
            end,
            role,
            fix: kind == "worker-gate",
            empty: lines < 2,
            cost_usd: round_cost(&raw),
        });
    }
    out.sort_by(|a, b| a.start.cmp(&b.start).then(a.id.cmp(&b.id)).then(a.fix.cmp(&b.fix)));
    out
}

/// One repo's raw material for the scoreboard.
pub struct Input<'a> {
    pub repo: &'a Repo,
    pub beads: Vec<Value>,
    pub rounds: Vec<LogRound>,
}

/// The windows, longest last: `all` is everything since the first event.
const WINDOWS: [(&str, i64); 4] = [("24h", 86400), ("7d", 7 * 86400), ("30d", 30 * 86400), ("all", i64::MAX)];

fn median(v: &mut [f64]) -> Option<f64> {
    if v.is_empty() {
        return None;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    Some(if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 })
}
fn mean(v: &[f64]) -> Option<f64> {
    if v.is_empty() {
        None
    } else {
        Some(v.iter().sum::<f64>() / v.len() as f64)
    }
}
fn summary(mut v: Vec<f64>) -> Value {
    json!({"n": v.len(), "median": median(&mut v), "mean": mean(&v)})
}
fn bump(m: &mut BTreeMap<String, u64>, k: &str) {
    *m.entry(k.to_string()).or_insert(0) += 1;
}
fn counts(m: &BTreeMap<String, u64>) -> Value {
    Value::Object(m.iter().map(|(k, v)| (k.clone(), json!(v))).collect())
}

/// The scoreboard for one window: events at or after `from`.
fn window_json(beads: &[Bead], rounds: &[(String, LogRound)], from: i64, now: i64, since: i64) -> Value {
    let inside = |t: i64| t >= from && t <= now;
    let mut landed = 0u64;
    let mut first_try = 0u64;
    let mut local = 0u64;
    let mut by_hand = 0u64;
    let mut closed_unmerged = 0u64;
    let mut landed_by: BTreeMap<String, u64> = BTreeMap::new();
    let mut rounds_per: Vec<f64> = Vec::new();
    let mut ttl: Vec<f64> = Vec::new();
    let mut worked: std::collections::BTreeSet<String> = Default::default();
    let mut send_backs = 0u64;
    let mut by_reason: BTreeMap<String, u64> = BTreeMap::new();
    let mut by_model: BTreeMap<String, (u64, BTreeMap<String, u64>)> = BTreeMap::new();
    let (mut holds, mut rebases, mut escalations, mut answers, mut interrupted) = (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut by_repo: BTreeMap<String, (u64, u64, std::collections::BTreeSet<String>)> = BTreeMap::new();
    for b in beads {
        let key = format!("{}/{}", b.slug, b.id);
        let repo = by_repo.entry(b.slug.clone()).or_default();
        if let Some(c) = b.closed.filter(|c| inside(*c)) {
            worked.insert(key.clone());
            repo.2.insert(b.id.clone());
            match b.how {
                How::Landed => {
                    landed += 1;
                    repo.0 += 1;
                    let n = b.events.iter().filter(|e| matches!(e, Event::SendBack { .. })).count() as u64;
                    if n == 0 {
                        first_try += 1;
                    }
                    if !b.metered {
                        local += 1;
                    }
                    bump(&mut landed_by, &b.worker);
                    rounds_per.push((n + 1) as f64);
                    if let Some(st) = b.started {
                        ttl.push((c - st).max(0) as f64);
                    }
                }
                How::ByHand => by_hand += 1,
                How::Open => {}
            }
        }
        if b.closed_unmerged.map(inside).unwrap_or(false) {
            closed_unmerged += 1;
        }
        for e in &b.events {
            if !inside(e.at()) {
                continue;
            }
            worked.insert(key.clone());
            repo.2.insert(b.id.clone());
            match e {
                Event::SendBack { model, reason, .. } => {
                    send_backs += 1;
                    repo.1 += 1;
                    bump(&mut by_reason, reason);
                    let m = by_model.entry(model.clone()).or_default();
                    m.0 += 1;
                    bump(&mut m.1, reason);
                }
                Event::Hold(_) => holds += 1,
                Event::Rebase(_) => rebases += 1,
                Event::Escalate(_) => escalations += 1,
                Event::Answer(_) => answers += 1,
                Event::Interrupted(_) => interrupted += 1,
            }
        }
    }
    let (mut worker_s, mut review_s, mut worker_rounds, mut review_rounds, mut empty) = (0i64, 0i64, 0u64, 0u64, 0u64);
    let (mut worker_usd, mut review_usd) = (0.0f64, 0.0f64);
    for (_, r) in rounds.iter().filter(|(_, r)| inside(r.start)) {
        let d = (r.end.min(now) - r.start).max(0);
        if r.role == "worker" {
            worker_s += d;
            worker_usd += r.cost_usd;
        } else {
            review_s += d;
            review_usd += r.cost_usd;
        }
        if r.fix {
            continue;
        }
        if r.empty {
            empty += 1;
        } else if r.role == "worker" {
            worker_rounds += 1;
        } else {
            review_rounds += 1;
        }
    }
    let span = if from == i64::MIN { (now - since).max(0) } else { (now - from).min((now - since).max(0)) };
    json!({
        "span_s": span,
        "landed": landed, "landed_first_try": first_try, "landed_local": local, "landed_by": counts(&landed_by),
        "closed_by_hand": by_hand, "closed_unmerged": closed_unmerged,
        "rounds_per_landed": summary(rounds_per),
        "time_to_land_s": summary(ttl),
        "worked": worked.len(),
        "send_backs": {
            "total": send_backs,
            "by_reason": counts(&by_reason),
            "by_model": Value::Object(by_model.iter().map(|(m, (n, r))| (m.clone(), json!({"total": n, "by_reason": counts(r)}))).collect()),
        },
        "holds": holds, "rebases": rebases, "escalations": escalations, "answers": answers, "interrupted": interrupted,
        "model_time": {"worker_s": worker_s, "review_s": review_s, "worker_usd": worker_usd, "review_usd": review_usd, "worker_rounds": worker_rounds, "review_rounds": review_rounds, "empty_rounds": empty},
        "by_repo": Value::Object(by_repo.iter().map(|(s, (l, sb, w))| (s.clone(), json!({"landed": l, "send_backs": sb, "worked": w.len()}))).collect()),
    })
}

/// `stats_from`: the scoreboard from what bd said and what logs/ holds, as of `now`.
pub fn stats_from(inputs: &[Input], now: i64) -> Value {
    let mut beads: Vec<Bead> = Vec::new();
    let mut rounds: Vec<(String, LogRound)> = Vec::new();
    for inp in inputs {
        beads.extend(inp.beads.iter().filter_map(|b| bead_of(inp.repo, b)));
        rounds.extend(inp.rounds.iter().map(|r| (inp.repo.slug.clone(), r.clone())));
    }
    let since = beads
        .iter()
        .flat_map(|b| b.started.into_iter().chain(b.events.iter().map(Event::at)))
        .chain(rounds.iter().map(|(_, r)| r.start))
        .min()
        .unwrap_or(now);
    let mut windows = Map::new();
    for (name, len) in WINDOWS {
        let from = if len == i64::MAX { i64::MIN } else { now - len };
        windows.insert(name.into(), window_json(&beads, &rounds, from, now, since));
    }
    // Every bead the loop finished, newest first: what the page lists under the tiles.
    let mut finished: Vec<&Bead> = beads.iter().filter(|b| b.how != How::Open).collect();
    finished.sort_by(|a, b| b.closed.cmp(&a.closed).then(a.id.cmp(&b.id)));
    let finished: Vec<Value> = finished
        .iter()
        .take(50)
        .map(|b| {
            let n = b.events.iter().filter(|e| matches!(e, Event::SendBack { .. })).count() as u64;
            json!({
                "id": b.id, "slug": b.slug, "title": b.title, "url": b.url,
                "closed": b.closed, "started": b.started,
                "how": match b.how { How::Landed => "landed", How::ByHand => "by hand", How::Open => "open" },
                "rounds": n + 1, "failures": b.failures, "worker": b.worker,
                "time_to_land_s": match (b.started, b.closed) { (Some(s), Some(c)) => json!((c - s).max(0)), _ => Value::Null },
                "answers": b.events.iter().filter(|e| matches!(e, Event::Answer(_))).count(),
                "escalated": b.events.iter().any(|e| matches!(e, Event::Escalate(_))),
            })
        })
        .collect();
    json!({
        "now": now, "since": since,
        "repos": inputs.iter().map(|i| json!(i.repo.slug)).collect::<Vec<_>>(),
        "windows": Value::Object(windows),
        "finished": finished,
    })
}

/// `stats_json`: the scoreboard over these repos, from bd and the state dir.
pub fn stats_json(repos: &[Repo]) -> Value {
    let inputs: Vec<Input> = repos
        .iter()
        .map(|repo| {
            // every bead the loop touched: the closed ones carry the landings, the open
            // and in-progress ones the rounds still being paid for
            let mut beads = Vec::new();
            for status in ["closed", "in_progress", "open"] {
                let out = crate::shell::bd_out(repo, &["list", "--status", status, "--json", "-n", "0"]);
                if let Ok(Value::Array(a)) = serde_json::from_str::<Value>(&out) {
                    beads.extend(a);
                }
            }
            Input { repo, beads, rounds: log_rounds(repo) }
        })
        .collect();
    stats_from(&inputs, now())
}

fn hm(s: f64) -> String {
    let m = (s / 60.0).round() as i64;
    if m < 60 {
        format!("{m}m")
    } else if m < 60 * 48 {
        format!("{}h{:02}", m / 60, m % 60)
    } else {
        format!("{:.1}d", m as f64 / 1440.0)
    }
}

/// `stats_text`: the scoreboard as a few lines per window.
pub fn stats_text(j: &Value) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "scoreboard: {}  (since {})\n",
        j["repos"].as_array().map(|a| a.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join(", ")).unwrap_or_default(),
        hm((j["now"].as_i64().unwrap_or(0) - j["since"].as_i64().unwrap_or(0)) as f64) + " ago"
    ));
    for (name, _) in WINDOWS {
        let w = &j["windows"][name];
        let n = |k: &str| w[k].as_u64().unwrap_or(0);
        let landed = n("landed");
        let pct = |k: &str| (n(k) * 100).checked_div(landed).map(|p| format!("{p}%")).unwrap_or_else(|| "-".into());
        out.push_str(&format!(
            "  {:<4} landed {landed} (first try {}, without Claude {})  rounds/landed {}  time to land {}  send-backs {}  holds {}  empty rounds {}  needed you {}\n",
            name,
            pct("landed_first_try"),
            pct("landed_local"),
            w["rounds_per_landed"]["median"].as_f64().map(|m| format!("{m:.1}")).unwrap_or("-".into()),
            w["time_to_land_s"]["median"].as_f64().map(hm).unwrap_or("-".into()),
            w["send_backs"]["total"],
            n("holds"),
            w["model_time"]["empty_rounds"],
            n("answers") + n("escalations"),
        ));
        let reasons =
            w["send_backs"]["by_reason"].as_object().map(|m| m.iter().map(|(k, v)| format!("{k} {v}")).collect::<Vec<_>>().join(", "));
        if let Some(r) = reasons.filter(|r| !r.is_empty()) {
            out.push_str(&format!("       send-backs by reason: {r}\n"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_times_parse() {
        assert_eq!(parse_iso("1970-01-02T00:00:00Z"), Some(86400));
        assert_eq!(parse_iso("2026-09-20T03:51+00:00"), Some(1789876260), "date -Iminutes: no seconds, an offset");
        assert_eq!(parse_iso("2026-09-20T03:51:11Z"), Some(1789876271), "bd's");
        assert_eq!(parse_iso("2026-09-20T05:51+02:00"), Some(1789876260), "the offset is taken off");
        assert_eq!(parse_iso("2026-09-20T01:51-02:00"), Some(1789876260));
        assert_eq!(parse_iso("2026-09-20"), None);
        assert_eq!(parse_iso("2026-13-20T03:51Z"), None);
        assert_eq!(parse_iso(""), None);
    }

    #[test]
    fn a_log_stamp_is_local_time() {
        let t = parse_stamp("20260920T035111").unwrap();
        // whatever the zone, the same instant rendered back by util::stamp's clock
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        unsafe { libc::localtime_r(&t, &mut tm) };
        assert_eq!((tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec), (2026, 9, 20, 3, 51, 11));
        assert_eq!(parse_stamp("2026092T035111"), None);
        assert_eq!(parse_stamp("20260920-035111"), None);
    }

    #[test]
    fn reasons_are_grouped_by_the_note_the_loop_wrote() {
        assert_eq!(reason_of("BLOCKED: lib/x.ts:3 has no such flag"), "blocked");
        assert_eq!(reason_of("gate fix round: BLOCKED: the gate wants a db"), "blocked");
        assert_eq!(reason_of("worker made no commit. Last words: hm"), "no commit");
        assert_eq!(reason_of("gate failed twice: npm test\n  1 failed"), "gate");
        assert_eq!(reason_of("review (acbox/coder) rejected:\nREJECT: no test"), "review");
        assert_eq!(reason_of("CI red on https://x/pull/1: test=FAILURE"), "CI red");
        assert_eq!(reason_of("worker exited 124 (timeout=3600 s). Log: /x"), "timed out");
        assert_eq!(reason_of("worker exited 1 (timeout=3600 s). Log: /x"), "crashed");
        assert_eq!(reason_of("reviewer exited 2. Log: /x"), "crashed");
        assert_eq!(reason_of("something new"), "other");
    }

    #[test]
    fn notes_become_events() {
        let notes = "2026-09-20: the spec is lib/x.test.ts\n\
            bead-loop round 1 (devbox/coder) 2026-09-20T04:55+00:00: gate failed twice: npm test\n\
            more of the gate's output\n\
            bead-loop round 2 (devbox/coder) 2026-09-20T05:10+00:00: review (acbox/coder) rejected:\n\
            REJECT: no test\n\
            bead-loop 2026-09-20T06:00+00:00: held, no failure charged: worker exited 1 with no output\n\
            bead-loop 2026-09-20T06:30+00:00: https://x/pull/7 conflicts with main; back to dev for a rebase by claude/sonnet\n\
            bead-loop 2026-09-20T07:00+00:00: escalated by hand to the last stage (worker claude/sonnet, reviewer claude/sonnet)\n\
            operator 2026-09-20T07:05+00:00: use the flag\n\
            bead-loop 2026-09-20T07:10+00:00: round interrupted by a stop; back in the dev queue, no failure charged\n\
            bead-loop 2026-09-20T07:20+00:00: waiting on you: https://x/pull/7 reports no CI checks\n\
            bead-loop: https://x/pull/7 was closed without merging; left in_progress for you\n";
        let ev = events_of(notes);
        assert_eq!(
            ev,
            vec![
                Event::SendBack { at: parse_iso("2026-09-20T04:55Z").unwrap(), round: 1, model: "devbox/coder".into(), reason: "gate" },
                Event::SendBack { at: parse_iso("2026-09-20T05:10Z").unwrap(), round: 2, model: "devbox/coder".into(), reason: "review" },
                Event::Hold(parse_iso("2026-09-20T06:00Z").unwrap()),
                Event::Rebase(parse_iso("2026-09-20T06:30Z").unwrap()),
                Event::Escalate(parse_iso("2026-09-20T07:00Z").unwrap()),
                Event::Answer(parse_iso("2026-09-20T07:05Z").unwrap()),
                Event::Interrupted(parse_iso("2026-09-20T07:10Z").unwrap()),
                Event::Hold(parse_iso("2026-09-20T07:20Z").unwrap()),
            ]
        );
        assert!(events_of("nothing from the loop here\n").is_empty());
    }

    /// A bead as bd lists it.
    fn bead(id: &str, status: &str, started: &str, closed: &str, reason: &str, notes: &str) -> Value {
        json!({"id": id, "title": format!("Bead {id}"), "status": status, "created_at": "2026-09-10T00:00:00Z",
               "started_at": if started.is_empty() { Value::Null } else { json!(started) },
               "closed_at": if closed.is_empty() { Value::Null } else { json!(closed) },
               "updated_at": if closed.is_empty() { "2026-09-19T00:00:00Z" } else { closed },
               "close_reason": reason, "notes": notes})
    }

    #[test]
    fn the_scoreboard_over_a_weeks_beads() {
        let d = crate::config::scratch("stats");
        let repo = crate::config::test_repo(&d, &["fast:rev:2", "claude/sonnet:claude/sonnet:1"]);
        let now = parse_iso("2026-09-20T23:00:00Z").unwrap();
        let landed = "bead-loop: https://x/pull/1 merged; checks at merge: ci=SUCCESS";
        let beads =
            vec![
            // first try, 2 h from claim to merge, yesterday
            bead("t-1", "closed", "2026-09-19T10:00:00Z", "2026-09-19T12:00:00Z", landed, ""),
            // two send-backs, landed by the fast worker (failures 2 → still stage 1? no: 2 lands on stage 2)
            bead("t-2", "closed", "2026-09-19T00:00:00Z", "2026-09-19T20:00:00Z", landed,
                 "bead-loop round 1 (fast) 2026-09-19T01:00+00:00: worker made no commit. Last words: x\n\
                  bead-loop round 2 (fast) 2026-09-19T02:00+00:00: gate failed twice: make\n"),
            // landed eight days ago: outside 7d, inside 30d
            bead("t-3", "closed", "2026-09-12T00:00:00Z", "2026-09-12T04:00:00Z", landed, ""),
            // worked by the loop, closed by hand
            bead("t-4", "closed", "2026-09-19T00:00:00Z", "2026-09-19T05:00:00Z", "did it myself",
                 "bead-loop round 1 (fast) 2026-09-19T01:30+00:00: BLOCKED: which flag?\noperator 2026-09-19T02:00+00:00: the blue one\n"),
            // still open, one hold and a rebase today
            bead("t-5", "open", "2026-09-20T08:00:00Z", "", "",
                 "bead-loop 2026-09-20T09:00+00:00: held, no failure charged: server down\n\
                  bead-loop 2026-09-20T10:00+00:00: https://x/pull/5 conflicts with main; back to dev for a rebase by claude/sonnet\n"),
            // never touched by the loop
            bead("t-9", "closed", "", "2026-09-19T12:00:00Z", "done by hand", "a note of my own"),
        ];
        // t-2's count in the state dir says 2 (the notes agree); the others have no file
        repo.set_failures("t-2", 2);
        let h = |n: i64| now - n * 3600;
        let rounds = vec![
            LogRound { id: "t-1".into(), start: h(26), end: h(25), role: "worker", fix: false, empty: false, cost_usd: 0.25 },
            LogRound { id: "t-1".into(), start: h(25), end: h(25) + 1800, role: "worker", fix: true, empty: false, cost_usd: 0.125 },
            LogRound { id: "t-1".into(), start: h(24), end: h(24) + 600, role: "review", fix: false, empty: false, cost_usd: 0.5 },
            LogRound { id: "t-5".into(), start: h(3), end: h(3), role: "worker", fix: false, empty: true, cost_usd: 0.0 },
            LogRound {
                id: "t-3".into(),
                start: now - 8 * 86400,
                end: now - 8 * 86400 + 3600,
                role: "worker",
                fix: false,
                empty: false,
                cost_usd: 1.0,
            },
        ];
        let j = stats_from(&[Input { repo: &repo, beads, rounds }], now);
        let w7 = &j["windows"]["7d"];
        assert_eq!(w7["landed"], 2, "t-1 and t-2; t-3 is older, t-4 was by hand");
        assert_eq!(w7["landed_first_try"], 1);
        assert_eq!(w7["landed_local"], 1, "t-2's two failures land on the claude stage");
        assert_eq!(w7["landed_by"], json!({"claude/sonnet": 1, "fast": 1}));
        assert_eq!(w7["closed_by_hand"], 1);
        assert_eq!(w7["rounds_per_landed"], json!({"n": 2, "median": 2.0, "mean": 2.0}), "1 and 3 rounds");
        assert_eq!(w7["time_to_land_s"]["median"], json!(11.0 * 3600.0), "2 h and 20 h");
        assert_eq!(w7["worked"], 4, "t-1, t-2, t-4, t-5");
        assert_eq!(w7["send_backs"]["total"], 3);
        assert_eq!(w7["send_backs"]["by_reason"], json!({"blocked": 1, "gate": 1, "no commit": 1}));
        assert_eq!(w7["send_backs"]["by_model"]["fast"]["total"], 3);
        assert_eq!(w7["holds"], 1);
        assert_eq!(w7["rebases"], 1);
        assert_eq!(w7["answers"], 1);
        assert_eq!(
            w7["model_time"],
            json!({"worker_s": 5400, "review_s": 600, "worker_usd": 0.375, "review_usd": 0.5, "worker_rounds": 1, "review_rounds": 1, "empty_rounds": 1}),
            "the fix session's time and cost count, not as a round; the empty one is counted apart; t-3's is outside"
        );
        assert_eq!(w7["by_repo"]["repo"]["landed"], 2);
        let w24 = &j["windows"]["24h"];
        assert_eq!(w24["landed"], 0, "both landed more than a day ago");
        assert_eq!(w24["holds"], 1);
        assert_eq!(w24["model_time"]["empty_rounds"], 1);
        assert_eq!(w24["span_s"], 86400);
        let w30 = &j["windows"]["30d"];
        assert_eq!(w30["landed"], 3);
        assert_eq!(w30["model_time"]["worker_rounds"], 2);
        assert_eq!(w30["model_time"]["worker_usd"], 1.375, "t-3's round, outside 7d, is inside 30d");
        assert_eq!(j["windows"]["all"]["landed"], 3);
        assert_eq!(j["since"], json!(parse_iso("2026-09-12T00:00:00Z").unwrap()), "the first claim");
        assert_eq!(j["windows"]["all"]["span_s"], now - parse_iso("2026-09-12T00:00:00Z").unwrap());
        let fin = j["finished"].as_array().unwrap();
        assert_eq!(
            fin.iter().map(|b| b["id"].as_str().unwrap()).collect::<Vec<_>>(),
            vec!["t-2", "t-1", "t-4", "t-3"],
            "newest first, t-5 open, t-9 not the loop's"
        );
        assert_eq!(fin[0]["how"], "landed");
        assert_eq!(fin[0]["rounds"], 3);
        assert_eq!(fin[0]["worker"], "claude/sonnet");
        assert_eq!(fin[0]["url"], "https://x/pull/1");
        assert_eq!(fin[2]["how"], "by hand");
        assert_eq!(fin[2]["answers"], 1);
        assert_eq!(fin[1]["time_to_land_s"], 7200);
        let text = stats_text(&j);
        assert!(text.contains("7d   landed 2 (first try 50%, without Claude 50%)"), "{text}");
        assert!(text.contains("send-backs by reason: blocked 1, gate 1, no commit 1"), "{text}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn log_rounds_read_the_state_dir() {
        let d = crate::config::scratch("stats-logs");
        let repo = crate::config::test_repo(&d, &["a"]);
        let logs = repo.rs.join("logs");
        let w = |name: &str, body: &str| std::fs::write(logs.join(name), body).unwrap();
        w("t-1.2.20260919T100000.setup", "npm ci");
        w("t-1.2.20260919T100000.worker.jsonl", "{\"a\":1}\n{\"b\":2}\n");
        w("t-1.2.20260919T100000.worker.jsonl.err", "");
        w("t-1.2.20260919T100000.gate", "ok");
        w("t-1.2.20260919T100000.worker-gate.jsonl", "{\"a\":1}\n{\"b\":2}\n");
        w("t-1.2.20260919T110000.review.jsonl", "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n");
        w("t-7.20260919T120000.worker.jsonl", "");
        w("t-8.20260918T120000.review1.jsonl", "{\"type\":\"system\"}\n{\"is_error\":false,\"total_cost_usd\":0.42}\n");
        w("junk.txt", "");
        let r = log_rounds(&repo);
        let ids: Vec<(&str, &str, bool, bool)> = r.iter().map(|x| (x.id.as_str(), x.role, x.fix, x.empty)).collect();
        assert_eq!(
            ids,
            vec![
                ("t-8", "review", false, false),
                ("t-1.2", "worker", false, false),
                ("t-1.2", "worker", true, false),
                ("t-1.2", "review", false, false),
                ("t-7", "worker", false, true)
            ],
            "by start; a dotted id survives; setup/gate/err are not sessions"
        );
        assert_eq!(r[0].cost_usd, 0.42, "Claude Code's result line");
        assert_eq!(r[1].cost_usd, 0.0, "no cost field: nothing priced this");
        assert_eq!(r[1].start, parse_stamp("20260919T100000").unwrap());
        assert!(r[1].end >= r[1].start);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn round_cost_reads_either_transcript_shape() {
        assert_eq!(round_cost(""), 0.0, "no session ran");
        assert_eq!(round_cost("{\"a\":1}\n{\"b\":2}\n"), 0.0, "neither shape: an opencode transcript of tool events, no cost");
        assert_eq!(round_cost("{\"is_error\":false,\"total_cost_usd\":1.5,\"usage\":{}}\n"), 1.5, "Claude Code's one result line");
        assert_eq!(
            round_cost(
                "{\"type\":\"step_start\"}\n\
                 {\"type\":\"step_finish\",\"part\":{\"tokens\":{\"total\":10},\"cost\":0.125}}\n\
                 {\"type\":\"tool_use\"}\n\
                 {\"type\":\"step_finish\",\"part\":{\"tokens\":{\"total\":20},\"cost\":0.375}}\n"
            ),
            0.5,
            "opencode: each step_finish's own cost, summed across the session"
        );
    }
}
