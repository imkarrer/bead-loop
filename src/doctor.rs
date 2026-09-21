//! Doctor command: every dependency probed, red or green, in one command.
use crate::config::Repo;

mod probe;

/// Run the doctor command: the repos are only needed for the opencode-provider and
/// attach-server probes (the stages and the attach URL come from them); the rest run the
/// same with none.
pub fn run(repos: &[Repo], json: bool) {
    let mut results = vec![probe::bd_probe(), probe::git_probe(), probe::gh_probe(), probe::claude_probe()];
    results.extend(probe::opencode_provider_probes(repos));
    results.push(probe::attach_probe(repos));
    results.push(probe::disk_free_probe());
    results.push(probe::systemctl_probe());

    let has_failures = results.iter().any(|r| !r.ok);

    if json {
        let json_array: Vec<serde_json::Value> =
            results.iter().map(|r| serde_json::json!({"name": r.name, "ok": r.ok, "detail": r.detail})).collect();
        println!("{}", serde_json::to_string(&json_array).unwrap());
    } else {
        for result in &results {
            println!("{}", result.to_line());
        }
    }

    if has_failures {
        std::process::exit(1);
    }
}
