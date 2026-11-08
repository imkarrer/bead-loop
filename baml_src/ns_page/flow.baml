// The page's state, in the shape ui/index.html reads: the Rust loop's page, kept as it
// was (a band per stage, the queues as nodes, the edges between them), fed from the BAML
// loop's logs. Built afresh on every request from each repo's event log, the rounds in
// flight, the bead titles bd lists, and systemd. Nothing here starts or takes anything.

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

/// One bead wherever it sits; each node reads the fields it needs.
class FBead {
    id: string,
    title: string,
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
    step: string?,
    tail: string[],
    where: string?,
    why: string?,
    /// Its branch holds work that passed the gate: a parked bead can go to a PR.
    has_work: bool,
}

class FStageCfg {
    worker: string,
    reviewer: string,
    failures: int,
}

class FQueues {
    dev: FBead[],
    review: FBead[],
    merge: FBead[],
}

class FProvider {
    cost: string,
}

class FRepo {
    repo: string,
    slug: string,
    label: string,
    base: string,
    merge: string,
    on_exhaust: string,
    attach: bool,
    stages: FStageCfg[],
    research_model: string,
    precheck_model: string,
    conflict_worker: string,
    lanes: map<string, FBead>,
    lane_names: string[],
    queues: FQueues,
    ready_to_publish: FBead[],
    parked: FBead[],
    held: FBead[],
    decisions: FBead[],
    worktrees: FBead[],
    /// Each model server the stages name, and whether its rounds cost: Claude is metered.
    providers: map<string, FProvider>,
}

class FUnit {
    available: bool,
    active: string,
    since: string,
    result: string,
}

class FLog {
    t: int,
    msg: string,
}

class FMedian {
    median: float?,
    mean: float?,
}

class FModelLoss {
    total: int,
    by_reason: map<string, int>,
}

class FSendBacks {
    total: int,
    by_reason: map<string, int>,
    by_model: map<string, FModelLoss>,
}

class FModelTime {
    worker_usd: float,
    review_usd: float,
    worker_s: int,
    review_s: int,
    worker_rounds: int,
    review_rounds: int,
    empty_rounds: int,
}

class FPrecheck {
    sent_back: int,
    passed: int,
    skipped: int,
}

class FAvoided {
    input_tokens: int,
    output_tokens: int,
    cache_read_tokens: int,
    usd: float?,
}

class FRepoLanded {
    landed: int,
}

class FWindow {
    span_s: int,
    landed: int,
    landed_first_try: int,
    landed_local: int,
    rounds_per_landed: FMedian,
    time_to_land_s: FMedian,
    answers: int,
    escalations: int,
    holds: int,
    send_backs: FSendBacks,
    model_time: FModelTime,
    precheck: FPrecheck,
    rebases: int,
    interrupted: int,
    closed_by_hand: int,
    closed_unmerged: int,
    landed_by: map<string, int>,
    by_repo: map<string, FRepoLanded>,
    avoided: FAvoided,
}

class FFinished {
    id: string,
    slug: string,
    title: string,
    url: string?,
    how: string,
    closed: int,
    worker: string,
    rounds: int,
    time_to_land_s: int?,
    escalated: bool,
    answers: int,
}

class FStats {
    now: int,
    since: int,
    windows: map<string, FWindow>,
    finished: FFinished[],
    repos: string[],
}

class FStatus {
    now: int,
    repos: FRepo[],
    service: FUnit,
    timer: FUnit,
    log: FLog[],
    stats: FStats,
    doctor: string[],
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

function merge_word(m: root.machine.MergeMode) -> string throws never {
    match (m) {
        root.machine.MergeMode.Auto => "auto",
        root.machine.MergeMode.Pipeline => "pipeline",
        root.machine.MergeMode.Manual => "manual",
        root.machine.MergeMode.External => "external",
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
        tail: [],
        where: null,
        why: null,
        has_work: false,
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

/// What each round left, newest last: the send-backs and holds with their words, and
/// the bead's round logs under the last.
function history_of(
    timed: root.supervisor.TimedEvent[],
    p: root.machine.Policy,
    logs: string[],
) -> FRound[] throws never {
    let out: FRound[] = [];
    let b = root.machine.Bead.new("x");
    let round = 0;
    for (let t in timed) {
        let v = event_view(t);
        if (v.kind == "picked" || v.kind == "review_picked") {
            round = round + 1;
        }
        let worth = CHARGED.includes(v.kind)
            || v.kind == "infra"
            || v.kind == "answered"
            || v.kind == "research_blocked";
        if (worth) {
            let st = fstage(p, b.failures);
            let model = if (v.kind == "rejected" || v.kind == "reviewer_crashed") {
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

/// The lanes: one per model server, or NAME.K for each of its slots when it has more.
function lane_names_of(configs: root.supervisor.LoopConfig[]) -> string[] throws never {
    let out: string[] = [];
    for (let p in providers_of(configs)) {
        let n = configs.at(0)?.capacity.get(p) ?? (configs.at(0)?.lanes ?? 1);
        if (n <= 1) {
            out.push(p);
        } else {
            let k = 1;
            while (k <= n) {
                out.push(`${p}.${k}`);
                k = k + 1;
            }
        }
    }
    out
}

/// The first free slot of `model`'s server, or its name when every slot is taken.
function slot_for(names: string[], taken: string[], model: string) -> string throws never {
    let p = root.supervisor.provider_of(model);
    for (let n in names) {
        if ((n == p || n.starts_with(`${p}.`)) && !taken.includes(n)) {
            return n;
        }
    }
    p
}

// ---- one repo -----------------------------------------------------------------------

function frepo(
    c: root.supervisor.LoopConfig,
    titles: map<string, string>,
    rounds: RoundView[],
    names: string[],
    taken: string[],
    now: int,
) -> FRepo throws never {
    let p = c.policy;
    let log = root.supervisor.FileLog { state: c.state };
    let all_logs = shell_out(`ls -1t '${c.state}/logs' 2>/dev/null`).split("\n");
    let r = FRepo {
        repo: c.state,
        slug: name_of(c),
        label: c.label,
        base: c.base,
        merge: merge_word(p.merge),
        on_exhaust: if (p.on_exhaust == root.machine.OnExhaust.Park) {
            "park"
        } else {
            "repeat"
        },
        attach: true,
        stages: p.stages.map((s) -> {
            FStageCfg { worker: s.worker, reviewer: s.reviewer, failures: s.attempts }
        }),
        research_model: p.research,
        precheck_model: c.precheck,
        conflict_worker: p.conflict_worker,
        lanes: {},
        lane_names: names,
        queues: FQueues { dev: [], review: [], merge: [] },
        ready_to_publish: [],
        parked: [],
        held: [],
        decisions: [],
        worktrees: [],
        providers: {},
    };
    for (let s in p.stages) {
        for (let m in [s.worker, s.reviewer, p.research, c.precheck]) {
            if (m.length() > 0) {
                let prov = root.supervisor.provider_of(m);
                let cost = if (prov == "claude") {
                    "metered"
                } else {
                    "local"
                };
                let _ = r.providers.set(prov, FProvider { cost: cost });
            }
        }
    }
    for (let id in log.ids()) {
        let timed = root.supervisor.timed_events(c.state, id);
        let events = timed.map((t) -> {
            t.event
        });
        let b = root.machine.fold(id, events, p);
        if (b.place is root.machine.Closed) {
            continue;
        }
        // A bead waiting in a queue that bd no longer lists for the loop (its label off,
        // blocked, deferred, closed) is not the loop's to show there: it would not be picked.
        let waiting = b.place is root.machine.Ready || b.place is root.machine.InReview;
        if (waiting && titles.length() > 0 && titles.get(`listed:${id}`) == null) {
            continue;
        }
        let since = timed.at(timed.length() - 1)?.at ?? now;
        let x = fbead(id, titles.get(id) ?? "", b.failures, since);
        x.stage = fstage(p, b.failures);
        x.notes = b.last_note ?? "";
        x.has_work = b.kept;
        if (p.research.length() > 0) {
            x.research
                = if (b.brief == null) {
                    "pending"
                } else {
                    "done"
                };
        }
        let logs = all_logs.filter((f) -> {
            f.starts_with(`${id}.`) && f.ends_with(".jsonl")
        });
        x.history = history_of(timed, p, logs);
        if let h: root.machine.Hold = b.hold {
            x.held = FHeld { why: h.words };
        }
        let running: RoundView? = null;
        for (let rv in rounds) {
            if (rv.state == c.state && rv.id == id) {
                running = rv;
            }
        }
        if let rv: RoundView = running {
            x.step
                = if (rv.kind == "Research") {
                    "research"
                } else if (rv.kind == "Review") {
                    "review"
                } else {
                    "work"
                };
            x.since = now - rv.seconds;
            x.tail = rv.last;
            let slot = slot_for(names, taken, rv.model);
            taken.push(slot);
            let _ = r.lanes.set(slot, x);
            continue;
        }
        match (b.place) {
            let q: root.machine.InReview => r.queues.review.push(x),
            let q: root.machine.Reviewing => r.queues.review.push(x),
            let q: root.machine.Publishable => {
                let title = if (c.pr_style == "plain") {
                    x.title
                } else {
                    `${id}: ${x.title}`
                };
                x.proposal
                    = FProposal {
                        compare_url: q.compare_url,
                        title: title,
                        body: read_or_empty(`${c.state}/beads/${id}/report`),
                    };
                r.ready_to_publish.push(x);
            },
            let q: root.machine.Merging => {
                x.url = q.pr;
                x.merge_mode = merge_word(p.merge);
                x.adopted = q.adopted;
                let opened = since;
                for (let t in timed) {
                    if (event_view(t).kind == "pr_opened" || event_view(t).kind == "pr_adopted") {
                        opened = t.at;
                    }
                }
                x.awaiting_since = opened;
                r.queues.merge.push(x);
            },
            let q: root.machine.Parked => {
                let brief = read_or_empty(`${c.state}/beads/${id}/park.md`);
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
                x.open_cmd = `cd ${c.state}/wt/${id} && claude`;
                r.parked.push(x);
            },
            _ => r.queues.dev.push(x),
        }
        if (b.hold != null) {
            let h = fbead(id, x.title, b.failures, since);
            h.where
                = if (b.place is root.machine.Merging) {
                    "merge"
                } else if (b.place is root.machine.InReview || b.place is root.machine.Reviewing) {
                    "review"
                } else {
                    "dev"
                };
            h.why = b.hold?.words ?? "";
            r.held.push(h);
        }
    }
    r.queues.dev
        = r.queues.dev.sort_by_key((b) -> {
            b.failures
        });
    r
}

// ---- the scoreboard -----------------------------------------------------------------

/// One bead's life, as the scoreboard counts it.
class FTally {
    slug: string,
    id: string,
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
}

class FSend {
    at: int,
    kind: string,
    model: string,
}

function ftally(
    slug: string,
    id: string,
    timed: root.supervisor.TimedEvent[],
    p: root.machine.Policy,
) -> FTally throws never {
    let t = FTally {
        slug: slug,
        id: id,
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
    };
    let b = root.machine.Bead.new(id);
    for (let e in timed) {
        let v = event_view(e);
        let st = fstage(p, b.failures);
        if (t.first_at == 0 && (v.kind == "picked" || v.kind == "research_picked")) {
            t.first_at = e.at;
        }
        if (v.kind == "picked") {
            t.worker_rounds.push(e.at);
            t.worker = st?.worker ?? t.worker;
            if (
                !(st?.worker ?? "").starts_with("devbox/")
                    && !(st?.worker ?? "").starts_with("acbox/")
            ) {
                if ((st?.worker ?? "").starts_with("claude/")) {
                    t.local = false;
                }
            }
        }
        if (v.kind == "review_picked") {
            t.review_rounds.push(e.at);
        }
        if (v.kind == "answered") {
            t.answers.push(e.at);
        }
        if (v.kind == "escalated") {
            t.escalations.push(e.at);
        }
        if (v.kind == "infra") {
            t.holds.push(e.at);
        }
        if (v.kind == "conflicting") {
            t.rebases.push(e.at);
        }
        if (v.kind == "pr_closed") {
            t.closed_unmerged.push(e.at);
        }
        if (v.kind == "precheck_sent_back") {
            t.prechecks.push(e.at);
        }
        if (v.kind == "pr_opened" || v.kind == "pr_adopted") {
            t.url = v.text;
        }
        if (CHARGED.includes(v.kind)) {
            let model = if (v.kind == "rejected" || v.kind == "reviewer_crashed") {
                st?.reviewer ?? ""
            } else {
                st?.worker ?? ""
            };
            t.send_backs.push(FSend { at: e.at, kind: v.kind, model: model });
            if (t.landed_at == 0) {
                t.charged = true;
            }
        }
        b = root.machine.step(b, e.event, p).bead;
        if (
            b.place is root.machine.Closed
                && t.landed_at == 0
                && (v.kind == "pr_merged" || v.kind == "merged_outside")
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

function count_in(ats: int[], since: int) -> int throws never {
    ats
        .filter((a) -> {
            in_window(a, since)
        })
        .length()
}

function median_of(xs: float[]) -> FMedian throws never {
    if (xs.length() == 0) {
        return FMedian { median: null, mean: null };
    }
    let sorted = xs.sort_by_key((x) -> {
        x
    });
    let n = sorted.length();
    let mid = if (n % 2 == 1) {
        sorted.at(n / 2) ?? 0.0
    } else {
        ((sorted.at(n / 2 - 1) ?? 0.0) + (sorted.at(n / 2) ?? 0.0)) / 2.0
    };
    let sum = 0.0;
    for (let x in sorted) {
        sum = sum + x;
    }
    FMedian { median: mid, mean: sum / (n * 1.0) }
}

function fwindow(tallies: FTally[], since: int, span: int) -> FWindow throws never {
    let w = FWindow {
        span_s: span,
        landed: 0,
        landed_first_try: 0,
        landed_local: 0,
        rounds_per_landed: FMedian { median: null, mean: null },
        time_to_land_s: FMedian { median: null, mean: null },
        answers: 0,
        escalations: 0,
        holds: 0,
        send_backs: FSendBacks { total: 0, by_reason: {}, by_model: {} },
        model_time: FModelTime {
            worker_usd: 0.0,
            review_usd: 0.0,
            worker_s: 0,
            review_s: 0,
            worker_rounds: 0,
            review_rounds: 0,
            empty_rounds: 0,
        },
        precheck: FPrecheck { sent_back: 0, passed: 0, skipped: 0 },
        rebases: 0,
        interrupted: 0,
        closed_by_hand: 0,
        closed_unmerged: 0,
        landed_by: {},
        by_repo: {},
        avoided: FAvoided { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, usd: null },
    };
    let rounds: float[] = [];
    let times: float[] = [];
    for (let t in tallies) {
        if (t.landed_at > 0 && in_window(t.landed_at, since)) {
            w.landed = w.landed + 1;
            if (!t.charged) {
                w.landed_first_try = w.landed_first_try + 1;
            }
            if (t.local) {
                w.landed_local = w.landed_local + 1;
            }
            rounds.push(t.rounds * 1.0);
            if (t.first_at > 0) {
                times.push((t.landed_at - t.first_at) * 1.0);
            }
            let _ = w.landed_by.set(t.worker, (w.landed_by.get(t.worker) ?? 0) + 1);
            let had = w.by_repo.get(t.slug)?.landed ?? 0;
            let _ = w.by_repo.set(t.slug, FRepoLanded { landed: had + 1 });
        }
        w.answers = w.answers + count_in(t.answers, since);
        w.escalations = w.escalations + count_in(t.escalations, since);
        w.holds = w.holds + count_in(t.holds, since);
        w.rebases = w.rebases + count_in(t.rebases, since);
        w.closed_unmerged = w.closed_unmerged + count_in(t.closed_unmerged, since);
        w.precheck.sent_back = w.precheck.sent_back + count_in(t.prechecks, since);
        w.model_time.worker_rounds = w.model_time.worker_rounds + count_in(t.worker_rounds, since);
        w.model_time.review_rounds = w.model_time.review_rounds + count_in(t.review_rounds, since);
        for (let s in t.send_backs) {
            if (in_window(s.at, since)) {
                let sb = w.send_backs;
                sb.total = sb.total + 1;
                let _ = sb.by_reason.set(s.kind, (sb.by_reason.get(s.kind) ?? 0) + 1);
                let m = sb.by_model.get(s.model) ?? FModelLoss { total: 0, by_reason: {} };
                m.total = m.total + 1;
                let _ = m.by_reason.set(s.kind, (m.by_reason.get(s.kind) ?? 0) + 1);
                let _ = sb.by_model.set(s.model, m);
            }
        }
    }
    w.rounds_per_landed = median_of(rounds);
    w.time_to_land_s = median_of(times);
    w
}

function fstats(
    configs: root.supervisor.LoopConfig[],
    titles: map<string, string>,
    now: int,
) -> FStats throws never {
    let tallies: FTally[] = [];
    let first = now;
    for (let c in configs) {
        let log = root.supervisor.FileLog { state: c.state };
        for (let id in log.ids()) {
            let timed = root.supervisor.timed_events(c.state, id);
            let t = ftally(name_of(c), id, timed, c.policy);
            if (t.first_at > 0 && t.first_at < first) {
                first = t.first_at;
            }
            tallies.push(t);
        }
    }
    let windows: map<string, FWindow> = {};
    let _ = windows.set("24h", fwindow(tallies, now - 86400, 86400));
    let _ = windows.set("7d", fwindow(tallies, now - 7 * 86400, 7 * 86400));
    let _ = windows.set("30d", fwindow(tallies, now - 30 * 86400, 30 * 86400));
    let _ = windows.set("all", fwindow(tallies, 0, now - first));
    let finished: FFinished[] = [];
    for (let t in tallies) {
        if (t.landed_at > 0) {
            finished.push(
                FFinished {
                    id: t.id,
                    slug: t.slug,
                    title: titles.get(t.id) ?? "",
                    url: t.url,
                    how: "landed",
                    closed: t.landed_at,
                    worker: t.worker,
                    rounds: t.rounds,
                    time_to_land_s: if (t.first_at > 0) {
                        t.landed_at - t.first_at
                    } else {
                        null
                    },
                    escalated: t.escalations.length() > 0,
                    answers: t.answers.length(),
                },
            );
        }
    }
    finished
        = finished.sort_by_key((f) -> {
            0 - f.closed
        });
    FStats {
        now: now,
        since: first,
        windows: windows,
        finished: finished,
        repos: configs.map((c) -> {
            name_of(c)
        }),
    }
}

// ---- the units and the journal ------------------------------------------------------

function unit_of(name: string) -> FUnit throws never {
    let show = shell_out(`systemctl --user show -p ActiveState -p ActiveEnterTimestamp -p Result ${name} 2>/dev/null`);
    let active = "";
    let since = "";
    let result = "";
    for (let line in show.split("\n")) {
        if (line.starts_with("ActiveState=")) {
            active = line.slice(12, line.length());
        }
        if (line.starts_with("ActiveEnterTimestamp=")) {
            since = line.slice(21, line.length());
        }
        if (line.starts_with("Result=")) {
            result = line.slice(7, line.length());
        }
    }
    FUnit { available: active.length() > 0, active: active, since: since, result: result }
}

/// The loop's journal, one line each with its second: `short-unix` puts it first.
function journal_of() -> FLog[] throws never {
    let out: FLog[] = [];
    let text = shell_out("journalctl --user -u bead-supervisor.service -n 200 --no-pager -o short-unix 2>/dev/null");
    for (let line in text.split("\n")) {
        if (line.length() == 0 || line.includes("detect_shell") || line.starts_with("-- ")) {
            continue;
        }
        let stamp = line.split(" ").at(0) ?? "";
        let secs = (stamp.split(".").at(0) ?? "").trim();
        let t = baml.json.parse(secs) catch_all (e) {
            _ => null,
        };
        let at = baml.json.to<int>(t) catch_all (e) {
            _ => 0,
        };
        let rest = line.slice(stamp.length(), line.length());
        let colon = rest.index_of(": ") ?? -1;
        let msg = if (colon >= 0) {
            rest.slice(colon + 2, rest.length())
        } else {
            rest.trim()
        };
        out.push(FLog { t: at, msg: msg });
    }
    out
}

/// A bead as `bd list` gives it: enough for its title, and whether bd still lists it for
/// the loop.
class ListRow {
    id: string,
    title: string,
    status: string?,
    labels: string[]?,
}

class ListPage {
    issues: ListRow[],
}

/// `bd list --all` wraps its rows in {"issues": [...]}; without --all it is the array.
function list_rows(text: string) -> ListRow[] throws never {
    let page = baml.json.decode<ListPage>(text) catch_all (e) {
        _ => null,
    };
    if let p: ListPage = page {
        return p.issues;
    }
    baml.json.decode<ListRow[]>(text) catch_all (e) {
        _ => {
            let none: ListRow[] = [];
            none
        },
    }
}

/// Each bead's title by id, from `bd list` in each beads dir; and under "listed:ID" a "1"
/// for each bead bd lists for the loop now: its label on, open or in progress.
function titles_of(configs: root.supervisor.LoopConfig[]) -> map<string, string> throws never {
    let out: map<string, string> = {};
    let seen: string[] = [];
    for (let c in configs) {
        if (seen.includes(c.beads)) {
            continue;
        }
        seen.push(c.beads);
        let ran = baml.sys.run(
            "bd",
            args = ["list", "--all", "-n", "0", "--json"],
            cwd = c.beads,
            capture_output = true,
        ) catch_all (e) {
            _ => {
                continue;
            },
        };
        {
            for (let row in list_rows(ran.stdout.to_string())) {
                let _ = out.set(row.id, row.title);
                let st = row.status ?? "";
                if ((row.labels ?? []).includes(c.label) && (st == "open" || st == "in_progress")) {
                    let _ = out.set(`listed:${row.id}`, "1");
                }
            }
        }
    }
    out
}

function flow_status(
    configs: root.supervisor.LoopConfig[],
    titles: map<string, string>,
) -> FStatus throws never {
    let now = root.supervisor.unix_seconds();
    let names = lane_names_of(configs);
    let rounds: RoundView[] = [];
    let seen: string[] = [];
    for (let c in configs) {
        if (!seen.includes(c.state)) {
            seen.push(c.state);
            for (let r in rounds_of(name_of(c), c.state, now)) {
                rounds.push(r);
            }
        }
    }
    let taken: string[] = [];
    FStatus {
        now: now,
        repos: configs.map((c) -> {
            frepo(c, titles, rounds, names, taken, now)
        }),
        service: unit_of("bead-supervisor.service"),
        timer: unit_of("bead-supervisor.timer"),
        log: journal_of(),
        stats: fstats(configs, titles, now),
        doctor: [],
    }
}

test "a time reads as its civil date" {
    assert.equal(iso_of(0), "");
    assert.equal(iso_of(86400), "1970-01-02T00:00:00");
    assert.equal(iso_of(1794117081), "2026-11-08T05:51:21")
}

test "a lane per server, a name per slot, a round on the first free one" {
    let names = ["devbox", "acbox.1", "acbox.2", "claude"];
    assert.equal(slot_for(names, [], "acbox/reviewer"), "acbox.1");
    assert.equal(slot_for(names, ["acbox.1"], "acbox/utility"), "acbox.2");
    assert.equal(slot_for(names, [], "devbox/coder"), "devbox")
}

test "a park's reason is the page's word for it" {
    assert.equal(park_reason("BLOCKED: no such file"), "blocked");
    assert.equal(park_reason("PR closed unmerged: u"), "pr_closed");
    assert.equal(park_reason("the stages are exhausted"), "exhausted")
}
