// What the page shows beyond the bead tables: the lanes and the rounds on them, one
// bead's history, the scoreboard, and the loop's own state. All read from the state
// dirs and systemd; nothing here asks bd, git or gh.

// ---- the lanes ---------------------------------------------------------------------

class RoundView {
    repo: string,
    state: string,
    id: string,
    kind: string,
    model: string,
    seconds: int,
    /// The round's last tool calls, newest last: `name argument`.
    last: string[],
}

class LaneView {
    provider: string,
    slots: int,
    rounds: RoundView[],
}

class ToolCall {
    name: string?,
    args: string?,
}

function shell_out(command: string) -> string throws never {
    let out = baml.sys.shell(command, capture_output = true) catch_all (e) {
        _ => {
            return "";
        },
    };
    out.stdout.to_string()
}

function seconds_since_modified(path: string, now: int) -> int throws never {
    let quoted = path.split("'").join("'\\''");
    let t = baml.json.decode<int>(shell_out(`stat -c %Y '${quoted}' 2>/dev/null`).trim()) catch_all (e) {
        _ => {
            return 0;
        },
    };
    if (now > t) {
        now - t
    } else {
        0
    }
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
        if (line.starts_with("{\"name\"") || line.includes("\"args\":")) {
            let c = baml.json.decode<ToolCall>(line) catch_all (e) {
                _ => ToolCall { name: null, args: null },
            };
            if (c.name != null) {
                calls.push(call_line(c));
            }
        } else {
            for (let c in claude_calls(line)) {
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

/// The rounds running under one state dir: a pid file whose process is alive.
function rounds_of(repo: string, state: string, now: int) -> RoundView[] throws never {
    let out: RoundView[] = [];
    let dir = `${state}/rounds`;
    for (let f in shell_out(`ls '${dir}' 2>/dev/null`).split("\n")) {
        if (f.ends_with(".pid")) {
            let id = f.slice(0, f.length() - 4);
            let pid = (
                baml.fs.read(`${dir}/${f}`) catch_all (e) {
                    _ => "",
                }
            )
                .trim();
            let alive = pid.length() > 0
                && (
                    baml.fs.exists(`/proc/${pid}`) catch_all (e) {
                        _ => false,
                    }
                );
            if (alive) {
                let spec = baml.json.decode<root.rounds.RoundSpec>(
                    baml.fs.read(`${dir}/${id}.spec.json`) catch_all (e) {
                        _ => "{}",
                    },
                ) catch_all (e) {
                    _ => null,
                };
                if let sp: root.rounds.RoundSpec = spec {
                    out.push(
                        RoundView {
                            repo: repo,
                            state: state,
                            id: id,
                            kind: root.world.kind_name(sp.kind),
                            model: sp.model,
                            seconds: seconds_since_modified(`${dir}/${f}`, now),
                            last: last_calls(sp.log_file, 6),
                        },
                    );
                }
            }
        }
    }
    out
}

/// Every provider a config names, in the order first named.
function providers_of(configs: root.supervisor.LoopConfig[]) -> string[] throws never {
    let out: string[] = [];
    for (let c in configs) {
        let models: string[] = [c.policy.research, c.precheck, c.policy.brief_model, c.policy.conflict_worker];
        for (let s in c.policy.stages) {
            models.push(s.worker);
            models.push(s.reviewer);
        }
        for (let m in models) {
            let p = root.world.provider_of(m);
            if (m.length() > 0 && !out.includes(p)) {
                out.push(p);
            }
        }
    }
    out
}

function lanes_of(
    configs: root.supervisor.LoopConfig[],
    names: string[],
    now: int,
) -> LaneView[] throws never {
    let all: RoundView[] = [];
    let i = 0;
    for (let c in configs) {
        for (let r in rounds_of(names.at(i) ?? "", c.state, now)) {
            all.push(r);
        }
        i = i + 1;
    }
    let capacity = configs.at(0)?.capacity ?? {};
    let providers = providers_of(configs);
    for (let r in all) {
        let p = root.world.provider_of(r.model);
        if (!providers.includes(p)) {
            providers.push(p);
        }
    }
    providers.map((p) -> {
        LaneView {
            provider: p,
            slots: capacity.get(p) ?? 1,
            rounds: all.filter((r) -> {
                root.world.provider_of(r.model) == p
            }),
        }
    })
}

// ---- one bead ----------------------------------------------------------------------

class EventView {
    at: int,
    kind: string,
    text: string,
}

class BeadDetail {
    id: string,
    events: EventView[],
    brief: string,
    report: string,
    park: string,
    logs: string[],
}

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

/// An event's whole text: the work order, the gate's output, the brief, the PR.
function event_view(t: root.supervisor.TimedEvent) -> EventView throws never {
    let json = baml.json.stringify(t.event) catch_all (e) {
        _ => "{}",
    };
    let w = baml.json.decode<EventWords>(json) catch_all (e) {
        _ => {
            EventWords {
                kind: "?",
                words: null,
                line: null,
                text: null,
                block: null,
                errors: null,
                url: null,
                compare_url: null,
                sha: null,
                checks: null,
                why: null,
                problems: null,
            }
        },
    };
    let text = w.text ?? w.errors ?? w.block ?? w.words ?? w.line ?? w.problems ?? w.checks ?? w.why ?? w.url
        ?? w.compare_url
        ?? w.sha
        ?? "";
    EventView { at: t.at, kind: w.kind, text: text }
}

function read_or_empty(path: string) -> string throws never {
    baml.fs.read(path) catch_all (e) {
        _ => "",
    }
}

function bead_detail(state: string, id: string) -> BeadDetail throws never {
    let dir = `${state}/beads/${id}`;
    let logs = shell_out(`ls -1t '${state}/logs' 2>/dev/null`).split("\n").filter((f) -> {
        f.starts_with(`${id}.`) && f.ends_with(".jsonl")
    });
    BeadDetail {
        id: id,
        events: root.supervisor.timed_events(state, id).map((t) -> {
            event_view(t)
        }),
        brief: read_or_empty(`${dir}/brief`),
        report: read_or_empty(`${dir}/report`),
        park: read_or_empty(`${dir}/park.md`),
        logs: logs,
    }
}

class LogLine {
    name: string?,
    args: string?,
    content: string?,
}

/// A round's log as the tool calls and what came back, each cut short: the page's view
/// of what the model did. `file` is a name under STATE/logs, nothing else.
function round_log(state: string, file: string) -> string[] throws never {
    let none: string[] = [];
    if (file.includes("/") || file.includes("..") || !file.ends_with(".jsonl")) {
        return none;
    }
    let text = baml.fs.read(`${state}/logs/${file}`) catch_all (e) {
        _ => {
            return none;
        },
    };
    let out: string[] = [];
    for (let line in text.split("\n")) {
        if (line.includes("\"args\":")) {
            let c = baml.json.decode<ToolCall>(line) catch_all (e) {
                _ => ToolCall { name: null, args: null },
            };
            let args = c.args ?? "";
            let short = if (args.length() > 400) {
                args.slice(0, 400) + " ..."
            } else {
                args
            };
            out.push(`> ${c.name ?? "?"} ${short}`);
        } else if (
            line.starts_with("{\"content\":")
                && line.includes("\"id\":")
                && !line.includes("requested_model")
        ) {
            let short = if (line.length() > 400) {
                line.slice(11, 400) + " ..."
            } else {
                line.slice(11, line.length())
            };
            out.push(`  ${short}`);
        } else {
            for (let c in claude_calls(line)) {
                let args = c.args ?? "";
                let short = if (args.length() > 400) {
                    args.slice(0, 400) + " ..."
                } else {
                    args
                };
                out.push(`> ${c.name ?? "?"} ${short}`);
            }
        }
    }
    out
}

// ---- the scoreboard ----------------------------------------------------------------

class Score {
    window: string,
    landed: int,
    first_try: int,
    without_claude: int,
    parked: int,
    send_backs: map<string, int>,
}

const CHARGED: string[] = [
    "worker_blocked",
    "no_commit",
    "round_timed_out",
    "worker_crashed",
    "gate_failed_twice",
    "diff_problems",
    "precheck_sent_back",
    "rejected",
    "reviewer_crashed",
    "checks_red",
];

/// One bead's history as what the scoreboard counts: when it landed (0: not), whether
/// it was ever charged before that, whether any round of it reached a claude stage,
/// when it parked, and when each send-back was.
class BeadTally {
    landed_at: int,
    charged: bool,
    claude: bool,
    parked_at: int[],
    send_backs: EventView[],
}

function tally(
    events: root.supervisor.TimedEvent[],
    policy: root.machine.Policy,
) -> BeadTally throws never {
    let b = root.machine.Bead.new("x");
    let t = BeadTally { landed_at: 0, charged: false, claude: false, parked_at: [], send_backs: [] };
    for (let e in events) {
        let v = event_view(e);
        if (CHARGED.includes(v.kind)) {
            t.send_backs.push(v);
            if (t.landed_at == 0) {
                t.charged = true;
            }
        }
        if (
            v.kind == "picked"
                && (root.machine.stage_for(policy, b.failures)?.worker ?? "").starts_with("claude/")
        ) {
            t.claude = true;
        }
        let was_parked = b.place is root.machine.Parked;
        b = root.machine.step(b, e.event, policy).bead;
        if (b.place is root.machine.Parked && !was_parked) {
            t.parked_at.push(e.at);
        }
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
        }
    }
    t
}

function in_window(at: int, since: int) -> bool throws never {
    since == 0 || at >= since
}

function score_of(window: string, since: int, tallies: BeadTally[]) -> Score throws never {
    let s = Score { window: window, landed: 0, first_try: 0, without_claude: 0, parked: 0, send_backs: {} };
    for (let t in tallies) {
        if (t.landed_at > 0 && in_window(t.landed_at, since)) {
            s.landed = s.landed + 1;
            if (!t.charged) {
                s.first_try = s.first_try + 1;
            }
            if (!t.claude) {
                s.without_claude = s.without_claude + 1;
            }
        }
        for (let p in t.parked_at) {
            if (in_window(p, since)) {
                s.parked = s.parked + 1;
            }
        }
        for (let sb in t.send_backs) {
            if (in_window(sb.at, since)) {
                let _ = s.send_backs.set(sb.kind, (s.send_backs.get(sb.kind) ?? 0) + 1);
            }
        }
    }
    s
}

function scoreboard(configs: root.supervisor.LoopConfig[], now: int) -> Score[] throws never {
    let tallies: BeadTally[] = [];
    for (let c in configs) {
        let log = root.supervisor.FileLog { state: c.state };
        for (let id in log.ids()) {
            tallies.push(tally(root.supervisor.timed_events(c.state, id), c.policy));
        }
    }
    [
        score_of("24h", now - 86400, tallies),
        score_of("7d", now - 7 * 86400, tallies),
        score_of("30d", now - 30 * 86400, tallies),
        score_of("all", 0, tallies),
    ]
}

// ---- the loop ----------------------------------------------------------------------

class LoopView {
    active: string,
    since: string,
    journal: string[],
}

/// The unit's state and its last lines. On a box without systemd, "unknown".
function loop_view() -> LoopView throws never {
    let active = shell_out("systemctl --user is-active bead-supervisor.service 2>/dev/null").trim();
    let since = shell_out("systemctl --user show -p ActiveEnterTimestamp --value bead-supervisor.service 2>/dev/null")
        .trim();
    let journal = shell_out("journalctl --user -u bead-supervisor.service -n 60 --no-pager -o short-iso 2>/dev/null")
        .split("\n")
        .filter((l) -> {
            l.length() > 0 && !l.includes("detect_shell") && !l.includes("Consumed ")
        });
    LoopView {
        active: if (active.length() > 0) {
            active
        } else {
            "unknown"
        },
        since: since,
        journal: journal,
    }
}

/// Start, stop or restart the loop: the keeper timer is what keeps it up, so a stop
/// stops both and a start starts the timer, which starts the service.
function loop_command(what: string) -> string? throws never {
    if (what == "stop") {
        "systemctl --user stop bead-supervisor.timer bead-supervisor.service"
    } else if (what == "start") {
        "systemctl --user start bead-supervisor.timer bead-supervisor.service"
    } else if (what == "restart") {
        "systemctl --user restart bead-supervisor.service"
    } else {
        null
    }
}

/// Abort a round: its process group, the round and everything it started. The loop
/// then finds the round gone with no result, and starts it again with no failure.
function abort_round(state: string, id: string) -> string throws never {
    if (id.includes("/") || id.includes("..")) {
        return "no such round";
    }
    let pid = read_or_empty(`${state}/rounds/${id}.pid`).trim();
    if (pid.length() == 0) {
        return "no such round";
    }
    let n = baml.json.decode<int>(pid) catch_all (e) {
        _ => {
            return "no such round";
        },
    };
    // The wrapper's group, then each child's: `timeout` makes a process group of its own,
    // so the wrapper's group alone leaves the round running.
    let _ = shell_out(
        `for c in $(pgrep -P ${n}); do kill -TERM -- -$c 2>/dev/null || kill -TERM $c; done; kill -TERM -- -${n} 2>/dev/null || kill -TERM ${n} 2>/dev/null`,
    );
    `aborted ${id}: the loop starts it again on its next tick`
}

test "a tool call reads as its name and first argument" {
    assert.equal(
        call_line(ToolCall { name: "read_file", args: "{\"path\":\"a/b.py\"}" }),
        "read_file a/b.py",
    );
    assert.equal(
        call_line(ToolCall { name: "run", args: "{\"command\":\"pytest -q\"}" }),
        "run pytest -q",
    )
}

test "a running round shows on its lane with its last calls" {
    let state = root.tools.scratch("lanes");
    let _ = baml.sys.run("rm", args = ["-rf", state]);
    let _ = baml.sys.run("mkdir", args = ["-p", `${state}/rounds`, `${state}/logs`]);
    let spec = root.rounds.spec_of("", "");
    spec.model = "devbox/coder";
    spec.log_file = `${state}/logs/t-1.1.Work.jsonl`;
    baml.fs.write(`${state}/rounds/t-1.spec.json`, baml.json.stringify(spec));
    baml.fs.write(`${state}/rounds/t-1.pid`, `${baml.sys.pid()}`);
    baml.fs.write(`${state}/rounds/t-2.spec.json`, baml.json.stringify(spec));
    baml.fs.write(`${state}/rounds/t-2.pid`, "999999999");
    baml.fs.write(
        spec.log_file,
        "{\"name\":\"read_file\",\"args\":\"{\\\"path\\\":\\\"a.py\\\"}\",\"id\":\"1\"}\n{\"content\":\"x\",\"id\":\"1\"}\n",
    );
    let rounds = rounds_of("r", state, 0);
    assert.equal(rounds.length(), 1);
    assert.equal(rounds.at(0)?.id, "t-1");
    assert.equal(rounds.at(0)?.last?.at(0), "read_file a.py");
    assert.equal(round_log(state, "t-1.1.Work.jsonl").length(), 2);
    assert.equal(round_log(state, "../t-1.spec.json").length(), 0)
}

test "the scoreboard counts landings, first tries, claude and send-backs by window" {
    let p = root.supervisor.policy();
    let now = 1800000000;
    let picked = root.machine.Picked { kind: "picked" };
    let committed = root.machine.Committed { kind: "committed", sha: "s" };
    let gate = root.machine.GatePassed { kind: "gate_passed" };
    let review = root.machine.ReviewPicked { kind: "review_picked" };
    let approved = root.machine.Approved { kind: "approved" };
    let opened = root.machine.PrOpened { kind: "pr_opened", url: "u", head: "h" };
    let merged = root.machine.PrMerged { kind: "pr_merged", url: "u" };
    let reject = root.machine.Rejected { kind: "rejected", line: "REJECT: x", text: "t" };
    let clean: root.supervisor.TimedEvent[] = [picked, committed, gate, review, approved, opened, merged].map((e) -> {
        root.supervisor.TimedEvent { at: now - 3600, event: e }
    });
    let sent: root.supervisor.TimedEvent[] = [
        picked,
        committed,
        gate,
        review,
        reject,
        picked,
        committed,
        gate,
        review,
        approved,
        opened,
        merged,
    ]
        .map((e) -> {
            root.supervisor.TimedEvent { at: now - 3 * 86400, event: e }
        });
    let tallies = [tally(clean, p), tally(sent, p)];
    let day = score_of("24h", now - 86400, tallies);
    assert.equal(day.landed, 1);
    assert.equal(day.first_try, 1);
    let week = score_of("7d", now - 7 * 86400, tallies);
    assert.equal(week.landed, 2);
    assert.equal(week.first_try, 1);
    assert.equal(week.without_claude, 2);
    assert.equal(week.send_backs.get("rejected") ?? 0, 1)
}

test "only start, stop and restart reach systemctl" {
    assert.contains(loop_command("stop") ?? "", "stop bead-supervisor.timer");
    assert.equal(loop_command("rm -rf") == null, true)
}

test "abort stops the round under timeout, not only its wrapper" {
    let state = root.tools.scratch("abort");
    let _ = baml.sys.run("rm", args = ["-rf", state]);
    let _ = baml.sys.run("mkdir", args = ["-p", `${state}/rounds`]);
    let mark = `${state}/rounds/t-1.timedout`;
    let child = baml.sys.subprocess(
        "/bin/sh",
        args = root.world.timed_argv(["sleep", "30"], 60, mark),
        stdin = "ignore",
        stdout = "ignore",
        stderr = "ignore",
        detached = true,
    );
    baml.fs.write(`${state}/rounds/t-1.pid`, `${child.pid}`);
    baml.sys.sleep(baml.time.Duration.from_seconds(1));
    let in_session = `ps -o pid= -s ${child.pid} | wc -l`;
    assert.equal(shell_out(in_session).trim() == "0", false);
    let said = abort_round(state, "t-1");
    assert.contains(said, "aborted t-1");
    baml.sys.sleep(baml.time.Duration.from_seconds(1));
    assert.equal(shell_out(in_session).trim(), "0")
}

test "a Claude round's tool calls come from Claude Code's own stream" {
    let line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\",\"input\":{\"file_path\":\"src/a.ts\"}}]}}";
    let calls = claude_calls(line);
    assert.equal(calls.length(), 1);
    assert.equal(call_line(calls.at(0) ?? ToolCall { name: null, args: null }), "Read src/a.ts");
    assert.equal(claude_calls("{\"type\":\"result\"}").length(), 0);
    let log = root.tools.scratch("cc-page.jsonl");
    let _ = baml.fs.write(log, `{"type":"system"}\n${line}\n`);
    assert.equal(last_calls(log, 6).join("|"), "Read src/a.ts");
    let _ = baml.fs.remove(log);
}
