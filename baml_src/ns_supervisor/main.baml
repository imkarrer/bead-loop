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
    s
}

/// Tick each supervisor and keep the result. An index write on a local array does not
/// stick, so the ticked value is pushed onto a new array.
function tick_all(worlds: Supervisor[]) -> Supervisor[] {
    let out: Supervisor[] = [];
    let i = 0;
    while (i < worlds.length()) {
        if let s: Supervisor = worlds.at(i) {
            tick(s);
            out.push(s);
        }
        i = i + 1;
    }
    out
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
