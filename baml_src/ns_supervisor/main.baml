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

/// Runs until stopped, or for `ticks` passes when that is above zero. Start is a recovery
/// every time: nothing distinguishes a first start from a restart.
function run(config_file: string, ticks: int = 0) -> int {
    let c = baml.json.decode<LoopConfig>(baml.fs.read(config_file));
    let world = root.world.LiveWorld {
        repo: c.repo,
        state: c.state,
        base: c.base,
        remote: c.remote,
        label: c.label,
        gate: c.gate,
        agent_bin: c.agent_bin,
    };
    let s = recover(world, FileLog { state: c.state }, c.policy);
    s.lanes = c.lanes;
    let n = 0;
    while (ticks == 0 || n < ticks) {
        tick(s);
        baml.sys.sleep(baml.time.Duration.from_seconds(c.heartbeat_seconds));
        n = n + 1;
    }
    n
}
