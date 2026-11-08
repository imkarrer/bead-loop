// The loop's entry: `bead-agent run --config_file PATH`.

class LoopConfig {
    /// The checkout git works in.
    repo: string,
    /// Where bd runs: the repo, or for a target the repo that plans it.
    beads: string,
    state: string,
    base: string,
    remote: string,
    push_remote: string,
    pr_repo: string,
    label: string,
    only: string,
    skip: string,
    gate: string,
    setup: string,
    pr_style: string,
    merge_label: string,
    feedback: bool,
    work_seconds: int,
    research_seconds: int,
    /// Each provider's server: `url`, or its `probe` with `/health` made `/v1`.
    urls: map<string, string>,
    precheck: string,
    agent_bin: string,
    policy: root.machine.Policy,
    lanes: int,
    /// `[providers.NAME] parallel`, by provider.
    capacity: map<string, int>,
    max_inflight: int,
    max_open_prs: int,
    adopt: bool,
    heartbeat_seconds: int,
}

function world_of(c: LoopConfig) -> root.world.LiveWorld throws never {
    root.world.LiveWorld {
        repo: c.repo,
        beads: c.beads,
        state: c.state,
        base: c.base,
        remote: c.remote,
        push_remote: c.push_remote,
        pr_repo: c.pr_repo,
        label: c.label,
        only: c.only,
        skip: c.skip,
        gate: c.gate,
        setup: c.setup,
        agent_bin: c.agent_bin,
        merge: root.machine.merge_name(c.policy.merge),
        pr_style: c.pr_style,
        merge_label: c.merge_label,
        feedback: c.feedback,
        work_seconds: c.work_seconds,
        research_seconds: c.research_seconds,
        urls: c.urls,
        precheck: c.precheck,
    }
}

function start_config(c: LoopConfig, group: string) -> Supervisor throws never {
    let s = recover(world_of(c), FileLog { state: c.state }, c.policy);
    s.lanes = c.lanes;
    s.capacity = c.capacity;
    s.max_inflight = c.max_inflight;
    s.max_open_prs = c.max_open_prs;
    s.adopt = c.adopt;
    s.group = group;
    s
}

/// A repo's supervisor and one for each of its targets, all in the repo's group.
function start_all(config_file: string) -> Supervisor[] {
    let c = load_config(config_file);
    let out: Supervisor[] = [start_config(c, c.repo)];
    if (config_file.ends_with(".toml")) {
        for (let t in targets_of(read_or_empty(config_file), c, home_dir())) {
            out.push(start_config(t, c.repo));
        }
    }
    out
}

/// Tick each supervisor and keep the result. An index write on a local array does not
/// stick, so the ticked value is pushed onto a new array. Before each tick it is told
/// what the others are running, so a model server's slots are shared by every repo, and
/// how many PRs the rest of its group has open, for `max_open_prs`.
function tick_all(worlds: Supervisor[]) -> Supervisor[] {
    let out: Supervisor[] = [];
    let i = 0;
    while (i < worlds.length()) {
        if let s: Supervisor = worlds.at(i) {
            let others: Supervisor[] = [];
            let j = 0;
            while (j < worlds.length()) {
                let o = if (j < i) {
                    out.at(j)
                } else {
                    worlds.at(j)
                };
                if let other: Supervisor = o {
                    if (j != i) {
                        others.push(other);
                    }
                }
                j = j + 1;
            }
            share(s, others);
            tick(s);
            out.push(s);
        }
        i = i + 1;
    }
    out
}

/// What `s` needs to know about the other supervisors in this process.
function share(s: Supervisor, others: Supervisor[]) -> void throws never {
    let busy: string[] = [];
    let group = 0;
    for (let o in others) {
        let running = o.world.running() catch (e) {
            root.machine.Infra => {
                let none: root.world.RoundRunning[] = [];
                none
            },
        };
        for (let r in running) {
            busy.push(r.model);
        }
        if (o.group == s.group) {
            group = group + inflight(o);
        }
    }
    s.elsewhere = busy;
    s.group_inflight = group;
}

function run_one(config_file: string, ticks: int) -> int {
    let c = load_config(config_file);
    let worlds = start_all(config_file);
    let n = 0;
    while (ticks == 0 || n < ticks) {
        worlds = tick_all(worlds);
        baml.sys.sleep(baml.time.Duration.from_seconds(c.heartbeat_seconds));
        n = n + 1;
    }
    n
}

/// One pass over every repo the global file names, then one sleep. Each repo is its
/// own `.bead-loop.toml`. The supervisors stay across passes so a hold keeps counting.
function run_listed(repos: string[], wait: int, ticks: int) -> int {
    let worlds: Supervisor[] = [];
    for (let repo in repos) {
        for (let s in start_all(`${repo}/.bead-loop.toml`)) {
            worlds.push(s);
        }
    }
    let n = 0;
    while (ticks == 0 || n < ticks) {
        worlds = tick_all(worlds);
        baml.sys.sleep(baml.time.Duration.from_seconds(wait));
        n = n + 1;
    }
    n
}

/// Runs until stopped, or for `ticks` passes when that is above zero. A global file
/// (`repos = [...]`) is every checkout it names; a repo file is that checkout alone.
/// Start is a recovery every time: nothing distinguishes a first start from a restart.
function run(config_file: string, ticks: int = 0) -> int {
    let text = read_or_empty(config_file);
    let listed = repos_in(text, home_dir());
    if (listed.length() > 0) {
        let table = baml.toml.Table.parse(text) catch_all (e) {
            _ => baml.toml.Table.new(),
        };
        run_listed(listed, int_at(table, "heartbeat_seconds", 30), ticks)
    } else {
        run_one(config_file, ticks)
    }
}

/// What `tell` turns into an event: `answer` (with the text), `reopen`, or `escalate`.
function told(what: string, text: string) -> root.machine.Event? throws never {
    if (what == "answer") {
        root.machine.Answered { kind: "answered", text: text }
    } else {
        if (what == "reopen") {
            root.machine.Reopened { kind: "reopened" }
        } else {
            if (what == "escalate") {
                root.machine.Escalated { kind: "escalated" }
            } else {
                null
            }
        }
    }
}

/// `bead-supervisor tell --config_file REPO/.bead-loop.toml --id ID --what answer --text T`:
/// leaves the event in the repo's inbox, which the running loop takes on its next tick.
/// A parked bead takes all three; anything else is refused there, with a note.
function tell(config_file: string, id: string, what: string, text: string = "") -> string {
    let event = told(what, text);
    if let e: root.machine.Event = event {
        let c = load_config(config_file);
        let configs: LoopConfig[] = [c];
        for (let t in targets_of(read_or_empty(config_file), c, home_dir())) {
            configs.push(t);
        }
        let shown = baml.sys.run("bd", args = ["show", id, "--json"], cwd = c.repo, capture_output = true);
        let rows = baml.json.decode<root.world.BdRow[]>(shown.stdout.to_string()) catch_all (x) {
            _ => {
                let none: root.world.BdRow[] = [];
                none
            },
        };
        let here = config_for(configs, rows.at(0)?.labels ?? []) ?? c;
        mail_to(here.state, id, e)
    } else {
        `unknown: ${what} (answer, reopen or escalate)`
    }
}

test "tell knows its three words and nothing else" {
    assert.is_type<root.machine.Answered>(told("answer", "x"));
    assert.is_type<root.machine.Reopened>(told("reopen", ""));
    assert.is_type<root.machine.Escalated>(told("escalate", ""));
    assert.equal(told("merge", "") == null, true)
}

test "a mail written by tell reads back as its event" {
    let state = "/tmp/bead-loop-tell-test";
    let _ = baml.sys.run("rm", args = ["-rf", state]);
    let _ = baml.sys.run("mkdir", args = ["-p", `${state}/inbox`]);
    let e = told("answer", "use the \"other\" file") ?? root.machine.Reopened { kind: "reopened" };
    baml.fs.write(
        `${state}/inbox/t-1.1.json`,
        baml.json.stringify(root.world.Mail { id: "t-1", event: e }),
    );
    let mail = root.world.read_inbox(state);
    assert.equal(mail.length(), 1);
    assert.is_type<root.machine.Answered>(mail.at(0)?.event);
    assert.equal(root.world.read_inbox(state).length(), 0)
}

/// Leaves one event for one bead in a state's inbox; returns the file.
function mail_to(state: string, id: string, event: root.machine.Event) -> string {
    let dir = `${state}/inbox`;
    let _ = baml.sys.run("mkdir", args = ["-p", dir]);
    let path = `${dir}/${id}.${baml.sys.pid()}.${unix_seconds()}.json`;
    baml.fs.write(path, baml.json.stringify(root.world.Mail { id: id, event: event }));
    path
}

function unix_seconds() -> int throws never {
    let out = baml.sys.run("date", args = ["+%s"], capture_output = true) catch_all (e) {
        _ => {
            return 0;
        },
    };
    baml.json.decode<int>(out.stdout.to_string().trim()) catch_all (e) {
        _ => 0,
    }
}
