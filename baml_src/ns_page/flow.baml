// The page's state, in the shape ui/index.html reads. Each supervisor writes its own
// beads to STATE/view.json every tick (ns_supervisor/view.baml); this adds what is the
// page's: each repo's config, the lane slots across repos, the scoreboard's windows,
// systemd and the journal. It folds no log and asks neither bd nor git nor gh.

class FStageCfg {
    worker: string,
    reviewer: string,
    failures: int,
}

class FQueues {
    dev: root.supervisor.FBead[],
    review: root.supervisor.FBead[],
    merge: root.supervisor.FBead[],
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
    lanes: map<string, root.supervisor.FBead>,
    lane_names: string[],
    queues: FQueues,
    ready_to_publish: root.supervisor.FBead[],
    parked: root.supervisor.FBead[],
    held: root.supervisor.FBead[],
    decisions: root.supervisor.FBead[],
    worktrees: root.supervisor.FBead[],
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

/// A supervisor's view, or an empty one when it has not written one yet.
function view_at(state: string) -> root.supervisor.View throws never {
    let text = read_or_empty(`${state}/view.json`);
    baml.json.decode<root.supervisor.View>(text) catch_all (e) {
        _ => root.supervisor.View { at: 0, beads: [], tallies: [] },
    }
}

function frepo(
    c: root.supervisor.LoopConfig,
    view: root.supervisor.View,
    names: string[],
    taken: string[],
) -> FRepo throws never {
    let p = c.policy;
    let r = FRepo {
        repo: c.state,
        slug: name_of(c),
        label: c.label,
        base: c.base,
        merge: root.machine.merge_name(p.merge),
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
    for (let b in view.beads) {
        if (b.place == "running") {
            let slot = slot_for(names, taken, b.model ?? "");
            taken.push(slot);
            let _ = r.lanes.set(slot, b);
            continue;
        }
        if (b.place == "parked") {
            b.open_cmd = `cd ${c.state}/wt/${b.id} && claude`;
            r.parked.push(b);
        } else if (b.place == "review") {
            r.queues.review.push(b);
        } else if (b.place == "publish") {
            if let pr: root.supervisor.FProposal = b.proposal {
                if (c.pr_style != "plain") {
                    pr.title = `${b.id}: ${b.title}`;
                }
            }
            r.ready_to_publish.push(b);
        } else if (b.place == "merge") {
            r.queues.merge.push(b);
        } else {
            r.queues.dev.push(b);
        }
        if (b.held != null) {
            r.held.push(b);
        }
    }
    r.queues.dev
        = r.queues.dev.sort_by_key((b) -> {
            b.failures
        });
    r
}

// ---- the scoreboard -----------------------------------------------------------------

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

function fwindow(tallies: root.supervisor.FTally[], since: int, span: int) -> FWindow throws never {
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
    tallies: root.supervisor.FTally[],
    now: int,
) -> FStats throws never {
    let first = now;
    for (let t in tallies) {
        if (t.first_at > 0 && t.first_at < first) {
            first = t.first_at;
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
                    title: t.title,
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

function flow_status(configs: root.supervisor.LoopConfig[]) -> FStatus throws never {
    let now = root.supervisor.unix_seconds();
    let names = lane_names_of(configs);
    let taken: string[] = [];
    let tallies: root.supervisor.FTally[] = [];
    let repos: FRepo[] = [];
    for (let c in configs) {
        let v = view_at(c.state);
        for (let t in v.tallies) {
            tallies.push(t);
        }
        repos.push(frepo(c, v, names, taken));
    }
    FStatus {
        now: now,
        repos: repos,
        service: unit_of("bead-supervisor.service"),
        timer: unit_of("bead-supervisor.timer"),
        log: journal_of(),
        stats: fstats(configs, tallies, now),
        doctor: [],
    }
}

test "a lane per server, a name per slot, a round on the first free one" {
    let names = ["devbox", "acbox.1", "acbox.2", "claude"];
    assert.equal(slot_for(names, [], "acbox/reviewer"), "acbox.1");
    assert.equal(slot_for(names, ["acbox.1"], "acbox/utility"), "acbox.2");
    assert.equal(slot_for(names, [], "devbox/coder"), "devbox")
}

test "a repo is its config and its supervisor's view, each bead in its node" {
    let c = root.supervisor.load_config(root.tools.scratch("frepo-none.toml"));
    let run = root.supervisor.fbead("t-run", "running", 0, 1);
    run.place = "running";
    run.model = "devbox/coder";
    let parked = root.supervisor.fbead("t-park", "parked", 2, 1);
    parked.place = "parked";
    let pub = root.supervisor.fbead("t-pub", "it", 0, 1);
    pub.place = "publish";
    pub.proposal = root.supervisor.FProposal { compare_url: "u", title: "it", body: "b" };
    let v = root.supervisor.View { at: 1, beads: [run, parked, pub], tallies: [] };
    let r = frepo(c, v, ["devbox", "acbox"], []);
    assert.equal(r.lanes.get("devbox")?.id, "t-run");
    assert.equal(r.parked.at(0)?.id, "t-park");
    assert.equal(r.ready_to_publish.at(0)?.id, "t-pub")
}
