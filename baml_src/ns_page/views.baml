// Small helpers the page shares: a shell's output, a file or nothing, a window test, and
// the model servers the configs name.

function shell_out(command: string) -> string throws never {
    let out = baml.sys.shell(command, capture_output = true) catch_all (e) {
        _ => {
            return "";
        },
    };
    out.stdout.to_string()
}

function read_or_empty(path: string) -> string throws never {
    baml.fs.read(path) catch_all (e) {
        _ => "",
    }
}

function in_window(at: int, since: int) -> bool throws never {
    since == 0 || at >= since
}

/// Every model server the configs name, once each, in the order they first appear.
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
