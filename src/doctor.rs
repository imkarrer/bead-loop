//! Doctor command: probe all dependencies

use crate::util::log;
use crate::doctor::probe::{Probe, ProbeResult, Version, Git, GhAuth, ClaudeAuth, OpencodeProvider, AttachServer, DiskFree, SystemctlUnits};

mod probe;

/// Run the doctor command
pub fn run(json: bool) {
    let probes: Vec<Box<dyn Probe>> = vec![
        Box::new(Version),
        Box::new(Git),
        Box::new(GhAuth),
        Box::new(ClaudeAuth),
        Box::new(OpencodeProvider),
        Box::new(AttachServer),
        Box::new(DiskFree),
        Box::new(SystemctlUnits),
    ];

    let results: Vec<ProbeResult> = probes.iter().map(|p| p.check()).collect();
    
    let has_failures = results.iter().any(|r| !r.ok);

    if json {
        // Output as JSON array
        let json_array: Vec<serde_json::Value> = results.iter().map(|r| {
            serde_json::json!({
                "name": r.name,
                "ok": r.ok,
                "detail": r.detail
            })
        }).collect();
        log(&serde_json::to_string_pretty(&json_array).unwrap());
    } else {
        // Output one line per probe
        for result in results {
            log(&result.to_line());
        }
    }

    if has_failures {
        std::process::exit(1);
    }
}
