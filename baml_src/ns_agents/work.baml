// A worker session: the Work function under a runner, with every event in the session log.

function work(bead_file: string, log_file: string, max_steps: int = 80) -> Report {
    let bead = baml.fs.read(bead_file);
    let log_out = baml.fs.open(log_file, "a");
    let agent = ai.Agent.new(client = Devbox, max_steps = max_steps, on_event = (e) -> {
        let line = baml.json.stringify(e) catch_all (x) {
            _ => "{}",
        };
        let _ = log_out.write(line + "\n") catch_all (x) {
            _ => 0,
        };
    });
    agent.run(Work@spec(bead)).value
}
