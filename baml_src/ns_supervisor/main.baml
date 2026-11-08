// The loop's entry: `bead-agent run --config_file PATH`.

class LoopConfig {
    repo: string,
    state: string,
    base: string,
    remote: string,
    label: string,
    gate: string,
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

function start_of(config_file: string) -> Supervisor {
    let c = load_config(config_file);
    let world = root.world.LiveWorld {
        repo: c.repo,
        state: c.state,
        base: c.base,
        remote: c.remote,
        label: c.label,
        gate: c.gate,
        agent_bin: c.agent_bin,
        merge: root.machine.merge_name(c.policy.merge),
    };
    let s = recover(world, FileLog { state: c.state }, c.policy);
    s.lanes = c.lanes;
    s.capacity = c.capacity;
    s.max_inflight = c.max_inflight;
    s.max_open_prs = c.max_open_prs;
    s.adopt = c.adopt;
    s.group = c.repo;
    s
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
    let s = start_of(config_file);
    let n = 0;
    while (ticks == 0 || n < ticks) {
        tick(s);
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
        worlds.push(start_of(`${repo}/.bead-loop.toml`));
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
        let dir = `${c.state}/inbox`;
        let _ = baml.sys.run("mkdir", args = ["-p", dir]);
        let path = `${dir}/${id}.${baml.sys.pid()}.json`;
        baml.fs.write(path, baml.json.stringify(root.world.Mail { id: id, event: e }));
        path
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
