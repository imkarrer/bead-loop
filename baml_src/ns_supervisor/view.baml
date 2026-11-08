// What the supervisor shows of itself: each tick it writes STATE/view.json, every bead it
// carries as the page draws it, from its own state (the place, the hold, what `bd ready`
// lists, the round in flight), not a second fold of the logs. The page reads this file
// and adds only what is the page's own: the config, the lane slots, systemd, the journal.

class FStage {
    index: int,
    worker: string,
    reviewer: string,
}

class FHeld {
    why: string,
}

class FRound {
    round: int?,
    model: string?,
    stage: int?,
    when: string?,
    note: string,
    logs: string[],
}

class FParked {
    reason: string,
    question: string,
    when: string,
    stage: FStage?,
    brief: string?,
    brief_model: string?,
    stopped_on: string?,
}

class FProposal {
    compare_url: string,
    title: string,
    body: string,
}

/// One bead wherever it sits; each node of the page reads the fields it needs.
class FBead {
    id: string,
    title: string,
    /// Where the page puts it: dev, review, publish, merge, parked, or running (on a lane).
    place: string,
    failures: int,
    stage: FStage?,
    research: string?,
    held: FHeld?,
    since: int,
    history: FRound[],
    notes: string,
    url: string?,
    merge_mode: string?,
    awaiting_since: int?,
    adopted: bool,
    red: bool,
    parked: FParked?,
    open_cmd: string?,
    waiting: string[],
    proposal: FProposal?,
    /// On a lane: its step (work, review, research), its model, its last tool calls.
    step: string?,
    model: string?,
    tail: string[],
    where: string?,
    why: string?,
    /// Its branch holds work that passed the gate: a parked bead can go to a PR.
    has_work: bool,
    /// Its newest event and its words: what a lever on the page comes back with.
    last: string,
}

/// One round of a bead, from its event log: what kind, on which model, when it was picked
/// (and how long the bead had waited for that), when it ended and what it came to.
class FRoundRec {
    kind: string,
    model: string,
    picked_at: int,
    ended_at: int,
    /// The kind of the event that ended it (gate_passed, rejected, infra, ...).
    outcome: string,
    /// That event's words: the REJECT line, the hold's words.
    words: string,
    /// From the event before the pick to the pick: the wait for a free lane.
    waited_s: int,
}

/// One bead's life, as the scoreboard counts it.
class FTally {
    slug: string,
    id: string,
    title: string,
    first_at: int,
    landed_at: int,
    url: string?,
    charged: bool,
    local: bool,
    worker: string,
    rounds: int,
    answers: int[],
    escalations: int[],
    holds: int[],
    rebases: int[],
    closed_unmerged: int[],
    worker_rounds: int[],
    review_rounds: int[],
    prechecks: int[],
    send_backs: FSend[],
    /// Its rounds in order; filled by `ftally`.
    round_log: FRoundRec[],
}

class FSend {
    at: int,
    kind: string,
    model: string,
}

/// STATE/view.json.
class View {
    at: int,
    beads: FBead[],
    tallies: FTally[],
}

// ---- small pieces -------------------------------------------------------------------

/// Days since 1970 to a civil date (Howard Hinnant's algorithm), so a time reads as
/// `2026-11-08T05:03:00` with no process started for it.
function iso_of(at: int) -> string throws never {
    if (at <= 0) {
        return "";
    }
    let days = at / 86400;
    let secs = at - days * 86400;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if (mp < 10) {
        mp + 3
    } else {
        mp - 9
    };
    let year = if (m <= 2) {
        y + 1
    } else {
        y
    };
    `${year}-${two(m)}-${two(d)}T${two(secs / 3600)}:${two((secs % 3600) / 60)}:${two(secs % 60)}`
}

function two(n: int) -> string throws never {
    if (n < 10) {
        `0${n}`
    } else {
        `${n}`
    }
}

/// The stage a failure count puts a bead on, numbered from 1; null when they are spent.
function fstage(p: root.machine.Policy, failures: int) -> FStage? throws never {
    let st = root.machine.stage_for(p, failures);
    if let s: root.machine.Stage = st {
        let i = 0;
        for (let x in p.stages) {
            i = i + 1;
            if (
                x.worker == s.worker
                    && x.reviewer == s.reviewer
                    && x.attempts == s.attempts
                    && x.name == s.name
            ) {
                return FStage { index: i, worker: s.worker, reviewer: s.reviewer };
            }
        }
    }
    null
}

function fbead(id: string, title: string, failures: int, since: int) -> FBead throws never {
    FBead {
        id: id,
        title: title,
        place: "dev",
        failures: failures,
        stage: null,
        research: null,
        held: null,
        since: since,
        history: [],
        notes: "",
        url: null,
        merge_mode: null,
        awaiting_since: null,
        adopted: false,
        red: false,
        parked: null,
        open_cmd: null,
        waiting: [],
        proposal: null,
        step: null,
        model: null,
        tail: [],
        where: null,
        why: null,
        has_work: false,
        last: "",
    }
}

/// Why a bead parked, in the page's three words.
function park_reason(question: string) -> string throws never {
    if (question.starts_with("PR closed")) {
        "pr_closed"
    } else if (question.starts_with("BLOCKED") || question.includes("held ")) {
        "blocked"
    } else {
        "exhausted"
    }
}

/// An event's kind and its words, as JSON gives them: every event has a `kind`.
class EventWords {
    kind: string,
    words: string?,
    line: string?,
    text: string?,
    block: string?,
    errors: string?,
    url: string?,
    compare_url: string?,
    sha: string?,
    checks: string?,
    why: string?,
    problems: string?,
}

class Said {
    kind: string,
    text: string,
}

function said_of(e: root.machine.Event) -> Said throws never {
    let json = baml.json.stringify(e) catch_all (x) {
        _ => "{}",
    };
    let w = baml.json.decode<EventWords>(json) catch_all (x) {
        _ => {
            return Said { kind: "?", text: "" };
        },
    };
    let text = w.text ?? w.errors ?? w.block ?? w.words ?? w.line ?? w.problems ?? w.checks ?? w.why ?? w.url
        ?? w.compare_url
        ?? w.sha
        ?? "";
    Said { kind: w.kind, text: text }
}

/// A send-back: the machine's own union of what is charged, not a list of names.
function charged(e: root.machine.Event) -> bool throws never {
    e is root.machine.ModelOutcome
}

/// What each round left, newest last: the send-backs and holds with their words, and the
/// bead's round logs under the last.
function history_of(
    timed: TimedEvent[],
    p: root.machine.Policy,
    logs: string[],
) -> FRound[] throws never {
    let out: FRound[] = [];
    let b = root.machine.Bead.new("x");
    let round = 0;
    for (let t in timed) {
        let v = said_of(t.event);
        if (t.event is root.machine.Picked || t.event is root.machine.ReviewPicked) {
            round = round + 1;
        }
        let worth = charged(t.event)
            || t.event is root.machine.Infra
            || t.event is root.machine.Answered
            || t.event is root.machine.ResearchBlocked;
        if (worth) {
            let st = fstage(p, b.failures);
            let model = if (t.event is root.machine.Rejected || t.event is root.machine.ReviewerCrashed) {
                st?.reviewer
            } else {
                st?.worker
            };
            out.push(
                FRound {
                    round: round,
                    model: model,
                    stage: st?.index,
                    when: iso_of(t.at),
                    note: `${v.kind}: ${v.text}`,
                    logs: [],
                },
            );
        }
        b = root.machine.step(b, t.event, p).bead;
    }
    if (logs.length() > 0) {
        out.push(
            FRound {
                round: null,
                model: null,
                stage: null,
                when: null,
                note: "the round logs, newest first",
                logs: logs,
            },
        );
    }
    out
}

/// One bead's life for the scoreboard.
function ftally(
    slug: string,
    id: string,
    timed: TimedEvent[],
    p: root.machine.Policy,
) -> FTally throws never {
    let t = FTally {
        slug: slug,
        id: id,
        title: "",
        first_at: 0,
        landed_at: 0,
        url: null,
        charged: false,
        local: true,
        worker: "",
        rounds: 0,
        answers: [],
        escalations: [],
        holds: [],
        rebases: [],
        closed_unmerged: [],
        worker_rounds: [],
        review_rounds: [],
        prechecks: [],
        send_backs: [],
        round_log: [],
    };
    let b = root.machine.Bead.new(id);
    let open: FRoundRec? = null;
    let prev_at: int? = null;
    for (let e in timed) {
        let v = said_of(e.event);
        let st = fstage(p, b.failures);
        let ev = e.event;
        let waited = e.at - (prev_at ?? e.at);
        if (
            ev is root.machine.Picked
                || ev is root.machine.ReviewPicked
                || ev is root.machine.ResearchPicked
        ) {
            let kind = if (ev is root.machine.ReviewPicked) {
                "review"
            } else if (ev is root.machine.ResearchPicked) {
                "research"
            } else {
                "work"
            };
            let model = if (ev is root.machine.ReviewPicked) {
                st?.reviewer ?? ""
            } else if (ev is root.machine.ResearchPicked) {
                p.research
            } else {
                st?.worker ?? ""
            };
            open
                = FRoundRec {
                    kind: kind,
                    model: model,
                    picked_at: e.at,
                    ended_at: 0,
                    outcome: "",
                    words: "",
                    waited_s: waited,
                };
        } else if (!(ev is root.machine.Committed)) {
            if let o: FRoundRec = open {
                o.ended_at = e.at;
                o.outcome = v.kind;
                o.words
                    = if (v.text.length() > 200) {
                        v.text.slice(0, 200)
                    } else {
                        v.text
                    };
                t.round_log.push(o);
                open = null;
            }
        }
        prev_at = e.at;
        if (t.first_at == 0 && (ev is root.machine.Picked || ev is root.machine.ResearchPicked)) {
            t.first_at = e.at;
        }
        if (ev is root.machine.Picked) {
            t.worker_rounds.push(e.at);
            t.worker = st?.worker ?? t.worker;
            if ((st?.worker ?? "").starts_with("claude/")) {
                t.local = false;
            }
        }
        if (ev is root.machine.ReviewPicked) {
            t.review_rounds.push(e.at);
        }
        if (ev is root.machine.Answered) {
            t.answers.push(e.at);
        }
        if (ev is root.machine.Escalated) {
            t.escalations.push(e.at);
        }
        if (ev is root.machine.Infra) {
            t.holds.push(e.at);
        }
        if (ev is root.machine.Conflicting) {
            t.rebases.push(e.at);
        }
        if (ev is root.machine.PrClosed) {
            t.closed_unmerged.push(e.at);
        }
        if (ev is root.machine.PrecheckSentBack) {
            t.prechecks.push(e.at);
        }
        if (ev is root.machine.PrOpened || ev is root.machine.PrAdopted) {
            t.url = v.text;
        }
        if (charged(ev)) {
            let model = if (ev is root.machine.Rejected || ev is root.machine.ReviewerCrashed) {
                st?.reviewer ?? ""
            } else {
                st?.worker ?? ""
            };
            t.send_backs.push(FSend { at: e.at, kind: v.kind, model: model });
            if (t.landed_at == 0) {
                t.charged = true;
            }
        }
        b = root.machine.step(b, ev, p).bead;
        if (
            b.place is root.machine.Closed
                && t.landed_at == 0
                && (ev is root.machine.PrMerged || ev is root.machine.MergedOutside)
        ) {
            t.landed_at
                = if (e.at > 0) {
                    e.at
                } else {
                    1
                };
            if (v.text.length() > 0) {
                t.url = v.text;
            }
        }
    }
    t.rounds = b.rounds;
    t
}

// ---- a round's tool calls -----------------------------------------------------------

class ToolCall {
    name: string?,
    args: string?,
}

/// `read_file fugazy_publish/config.py`: the tool and its first argument, short.
function call_line(c: ToolCall) -> string throws never {
    let args = c.args ?? "";
    let first = (args.split("\":\"").at(1) ?? args).split("\"").at(0) ?? "";
    let short = if (first.length() > 100) {
        first.slice(0, 100)
    } else {
        first
    };
    `${c.name ?? "?"} ${short}`
}

/// The tool calls in one line of a Claude round's log: Claude Code's own stream, teed in by
/// the wrapper (ns_agents/claude.baml). Any other line has none.
function claude_calls(line: string) -> ToolCall[] throws never {
    let none: ToolCall[] = [];
    if (!line.starts_with("{\"type\":\"assistant\"")) {
        return none;
    }
    let raw = baml.json.parse(line) catch_all (e) {
        _ => {
            return none;
        },
    };
    let out: ToolCall[] = [];
    for (let b in baml.json.path_or<json[]>(raw, ".message.content", [])) {
        let name = baml.json.path_or<string>(b, ".name", "?");
        // StructuredOutput is how Claude Code hands back the answer, not a tool it used.
        if (baml.json.path_or<string>(b, ".type", "") == "tool_use" && name != "StructuredOutput") {
            let input = baml.json.path_or<json>(b, ".input", {});
            out.push(
                ToolCall {
                    name: name,
                    args: baml.json.stringify(input) catch_all (e) {
                        _ => "",
                    },
                },
            );
        }
    }
    out
}

/// The last `n` tool calls in a round's log.
function last_calls(log_file: string, n: int) -> string[] throws never {
    let none: string[] = [];
    let text = baml.fs.read(log_file) catch_all (e) {
        _ => {
            return none;
        },
    };
    let calls: string[] = [];
    for (let line in text.split("\n")) {
        if (line.starts_with("{\"type\":\"assistant\"")) {
            for (let c in claude_calls(line)) {
                calls.push(call_line(c));
            }
        } else if (line.starts_with("{\"name\"") || line.includes("\"args\":")) {
            let c = baml.json.decode<ToolCall>(line) catch_all (e) {
                _ => ToolCall { name: null, args: null },
            };
            if (c.name != null) {
                calls.push(call_line(c));
            }
        }
    }
    let from = if (calls.length() > n) {
        calls.length() - n
    } else {
        0
    };
    calls.slice(from, calls.length())
}

// ---- the view -----------------------------------------------------------------------

/// A bead as bd has it: from the tickets, or asked once of the world and kept.
function bead_ticket(s: Supervisor, id: string) -> root.world.Ticket throws never {
    let known = s.known.get(id);
    if let t: root.world.Ticket = known {
        return t;
    }
    let asked = s.world.ticket_of(id);
    let _ = s.known.set(id, asked);
    asked
}

function title(s: Supervisor, id: string) -> string throws never {
    bead_ticket(s, id).title
}

/// One bead as the page draws it: null when it is closed, or waiting in a queue bd no
/// longer lists for the loop (it would not be picked, so it is not shown there).
function view_of(
    s: Supervisor,
    b: root.machine.Bead,
    alive: root.world.RoundRunning[],
    now: int,
) -> FBead? throws never {
    if (b.place is root.machine.Closed) {
        return null;
    }
    let waiting = b.place is root.machine.Ready || b.place is root.machine.InReview;
    if (waiting && !s.ready.includes(b.id)) {
        return null;
    }
    let p = s.policy;
    let timed = s.log.timed(b.id);
    let since = timed.at(timed.length() - 1)?.at ?? now;
    let x = fbead(b.id, title(s, b.id), b.failures, since);
    x.stage = fstage(p, b.failures);
    x.notes = b.last_note ?? "";
    x.has_work = b.kept;
    if let newest: TimedEvent = timed.at(timed.length() - 1) {
        let w = said_of(newest.event);
        x.last
            = if (w.text.length() > 0) {
                `${w.kind}: ${w.text}`
            } else {
                w.kind
            };
    }
    x.history = history_of(timed, p, s.log.round_logs(b.id));
    if (p.research.length() > 0) {
        x.research
            = if (b.brief == null) {
                "pending"
            } else {
                "done"
            };
    }
    if let h: root.machine.Hold = b.hold {
        x.held = FHeld { why: h.words };
        x.why = h.words;
        x.where
            = if (b.place is root.machine.Merging) {
                "merge"
            } else if (b.place is root.machine.InReview || b.place is root.machine.Reviewing) {
                "review"
            } else {
                "dev"
            };
    }
    let on: root.world.RoundRunning[] = alive.filter((r) -> {
        r.id == b.id
    });
    if let r: root.world.RoundRunning = on.at(0) {
        x.place = "running";
        x.step = root.world.kind_name(r.kind);
        x.model = r.model;
        if (r.since > 0) {
            x.since = r.since;
        }
        x.tail = last_calls(r.log, 6);
        return x;
    }
    match (b.place) {
        let q: root.machine.InReview => {
            x.place = "review";
        },
        let q: root.machine.Reviewing => {
            x.place = "review";
        },
        let q: root.machine.Publishable => {
            x.place = "publish";
            x.proposal
                = FProposal {
                    compare_url: q.compare_url,
                    title: x.title,
                    body: bead_ticket(s, b.id).description,
                };
        },
        let q: root.machine.Merging => {
            x.place = "merge";
            x.url = q.pr;
            x.merge_mode = root.machine.merge_name(p.merge);
            x.adopted = q.adopted;
            let opened = since;
            for (let t in timed) {
                if (t.event is root.machine.PrOpened || t.event is root.machine.PrAdopted) {
                    opened = t.at;
                }
            }
            x.awaiting_since = opened;
        },
        let q: root.machine.Parked => {
            x.place = "parked";
            let brief = s.log.side(b.id, "park.md");
            x.parked
                = FParked {
                    reason: park_reason(q.question),
                    question: q.question,
                    when: iso_of(since),
                    stage: fstage(
                        p,
                        if (b.failures > 0) {
                            b.failures - 1
                        } else {
                            0
                        },
                    ),
                    brief: if (brief.length() > 0) {
                        brief
                    } else {
                        null
                    },
                    brief_model: null,
                    stopped_on: null,
                };
        },
        _ => {
            x.place = "dev";
        },
    }
    x
}

/// The view, written each tick. A closed bead's tally is counted once and kept: its log
/// does not change.
function write_view(s: Supervisor, alive: root.world.RoundRunning[]) -> void throws never {
    let now = unix_seconds();
    let beads: FBead[] = [];
    let tallies: FTally[] = [];
    let slug = repo_name(s.group);
    for (let b in s.beads) {
        let v = view_of(s, b, alive, now);
        if let x: FBead = v {
            beads.push(x);
        }
        let kept = s.tallies.get(b.id);
        if let t: FTally = kept {
            tallies.push(t);
        } else {
            let t = ftally(slug, b.id, s.log.timed(b.id), s.policy);
            t.title = title(s, b.id);
            if (b.place is root.machine.Closed) {
                let _ = s.tallies.set(b.id, t);
            }
            tallies.push(t);
        }
    }
    let text = baml.json.stringify(View { at: now, beads: beads, tallies: tallies }) catch_all (e) {
        _ => {
            return;
        },
    };
    s.log.put_view(text);
}

test "a time reads as its civil date" {
    assert.equal(iso_of(0), "");
    assert.equal(iso_of(86400), "1970-01-02T00:00:00");
    assert.equal(iso_of(1794117081), "2026-11-08T05:51:21")
}

test "a park's reason is the page's word for it" {
    assert.equal(park_reason("BLOCKED: no such file"), "blocked");
    assert.equal(park_reason("PR closed unmerged: u"), "pr_closed");
    assert.equal(park_reason("the stages are exhausted"), "exhausted")
}

test "a send-back is the machine's ModelOutcome, nothing else" {
    assert.is_true(charged(root.machine.NoCommit { kind: "no_commit" }));
    assert.is_true(!charged(root.machine.Picked { kind: "picked" }))
}
