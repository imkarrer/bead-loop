// .bead-loop.toml, with the global file filling in what the repo leaves out.
// A key in the repo wins. Stages come from whichever file has them.

function text_at(t: baml.toml.Table, key: string) -> string throws never {
    let v = t.get(key);
    if let s: string = v {
        s
    } else {
        ""
    }
}

function int_at(t: baml.toml.Table, key: string, fallback: int) -> int throws never {
    let v = t.get(key);
    if let n: int = v {
        n
    } else {
        fallback
    }
}

function bool_at(t: baml.toml.Table, key: string, fallback: bool) -> bool throws never {
    let v = t.get(key);
    if let b: bool = v {
        b
    } else {
        fallback
    }
}

function pick(
    repo: baml.toml.Table,
    global: baml.toml.Table,
    key: string,
    fallback: string,
) -> string throws never {
    let here = text_at(repo, key);
    if (here.length() > 0) {
        here
    } else {
        let there = text_at(global, key);
        if (there.length() > 0) {
            there
        } else {
            fallback
        }
    }
}

function merge_of(name: string) -> root.machine.MergeMode throws never {
    if (name == "auto") {
        root.machine.MergeMode.Auto
    } else {
        if (name == "manual") {
            root.machine.MergeMode.Manual
        } else {
            if (name == "external") {
                root.machine.MergeMode.External
            } else {
                root.machine.MergeMode.Pipeline
            }
        }
    }
}

function exhaust_of(name: string) -> root.machine.OnExhaust throws never {
    if (name == "repeat") {
        root.machine.OnExhaust.Repeat
    } else {
        root.machine.OnExhaust.Park
    }
}

function stage_of(item: baml.toml.Item) -> root.machine.Stage? throws never {
    if let t: baml.toml.Table = item {
        root.machine.Stage {
            name: text_at(t, "name"),
            worker: text_at(t, "worker"),
            reviewer: text_at(t, "reviewer"),
            attempts: int_at(t, "attempts", 1),
        }
    } else {
        null
    }
}

function stages_of(t: baml.toml.Table) -> root.machine.Stage[] throws never {
    let v = t.get("stages");
    if let rows: baml.toml.Item[] = v {
        let out: root.machine.Stage[] = [];
        for (let item in rows) {
            if let s: root.machine.Stage = stage_of(item) {
                out.push(s);
            }
        }
        out
    } else {
        []
    }
}

function research_model(global: baml.toml.Table) -> string throws never {
    let mode = text_at(global, "research");
    if (mode == "off" || mode.length() == 0) {
        ""
    } else {
        text_at(global, "research_model")
    }
}

/// The directory a config file lives in.
function parent_dir(path: string) -> string throws never {
    let parts = path.split("/");
    let keep = parts.length() - 1;
    let out = "";
    let i = 0;
    while (i < keep) {
        let p = parts.at(i) ?? "";
        if (p.length() > 0) {
            out
                = if (out.length() == 0) {
                    p
                } else {
                    `${out}/${p}`
                };
        }
        i = i + 1;
    }
    if (path.starts_with("/")) {
        `/${out}`
    } else {
        out
    }
}

/// `~/src/a` with home `/home/me` is `/home/me/src/a`. Anything else is left as written.
function expand_home(path: string, home: string) -> string throws never {
    if (path.starts_with("~/") && home.length() > 0) {
        let rest = path.split("~/").at(1) ?? path;
        `${home}/${rest}`
    } else {
        path
    }
}

/// `repos` in the global file, `~` expanded. Empty when the file is a repo toml.
function repos_in(global_text: string, home: string) -> string[] throws never {
    let global = baml.toml.Table.parse(global_text) catch_all (e) {
        _ => {
            let none: string[] = [];
            return none;
        },
    };
    let v = global.get("repos");
    let out: string[] = [];
    if let rows: baml.toml.Item[] = v {
        for (let item in rows) {
            if let s: string = item {
                out.push(expand_home(s, home));
            }
        }
    }
    out
}

function repo_name(path: string) -> string throws never {
    let parts = path.split("/");
    let last = "";
    for (let p in parts) {
        if (p.length() > 0) {
            last = p;
        }
    }
    last
}

/// Repo text wins over the global text. `repo` is the checkout the loop works.
function config_from_toml(
    repo_text: string,
    global_text: string,
    repo: string,
    state: string,
    agent_bin: string,
) -> LoopConfig throws never {
    let repo_table = baml.toml.Table.parse(repo_text) catch_all (e) {
        _ => baml.toml.Table.new(),
    };
    let global = baml.toml.Table.parse(global_text) catch_all (e) {
        _ => baml.toml.Table.new(),
    };
    let own = stages_of(repo_table);
    let stages = if (own.length() > 0) {
        own
    } else {
        stages_of(global)
    };
    let merge = merge_of(pick(repo_table, global, "merge", "pipeline"));
    LoopConfig {
        repo: repo,
        state: state,
        base: pick(repo_table, global, "base", "main"),
        remote: pick(repo_table, global, "remote", "origin"),
        label: pick(repo_table, global, "label", "delegate:local"),
        gate: pick(repo_table, global, "gate", ""),
        agent_bin: agent_bin,
        policy: root.machine.Policy {
            stages: stages,
            on_exhaust: exhaust_of(pick(repo_table, global, "on_exhaust", "park")),
            merge: merge,
            second_opinion: false,
            ask_before_pr: pick(repo_table, global, "open_pr", "") == "ask",
            research: research_model(global),
        },
        lanes: 1,
        capacity: capacity_of(global),
        max_inflight: int_at(repo_table, "max_inflight", int_at(global, "max_inflight", 0)),
        max_open_prs: int_at(global, "max_open_prs", 0),
        adopt: bool_at(repo_table, "adopt", bool_at(global, "adopt", true)),
        heartbeat_seconds: int_at(global, "heartbeat_seconds", 30),
    }
}

function home_dir() -> string throws never {
    let out = baml.sys.shell(`printf %s "$HOME"`, capture_output = true) catch_all (e) {
        _ => {
            return "";
        },
    };
    out.stdout.to_string().trim()
}

function read_or_empty(path: string) -> string throws never {
    baml.fs.read(path) catch_all (e) {
        _ => "",
    }
}

/// `bead-loop run --config_file REPO/.bead-loop.toml`. The global file, when it
/// is there, supplies the stages. State lands beside the Rust loop's state.
function config_from_toml_file(path: string) -> LoopConfig throws never {
    let repo = parent_dir(path);
    let home = home_dir();
    let state = if (home.length() > 0) {
        `${home}/.local/state/bead-loop/${repo_name(repo)}`
    } else {
        `${repo}/.bead-loop-state`
    };
    let bin = baml.sys.run("readlink", args = ["-f", "/proc/self/exe"], capture_output = true) catch_all (e) {
        _ => {
            return config_from_toml(read_or_empty(path), "", repo, state, "bead-loop");
        },
    };
    config_from_toml(
        read_or_empty(path),
        read_or_empty(`${home}/.config/bead-loop/config.toml`),
        repo,
        state,
        bin.stdout.to_string().trim(),
    )
}

function load_config(path: string) -> LoopConfig {
    if (path.ends_with(".toml")) {
        config_from_toml_file(path)
    } else {
        baml.json.decode<LoopConfig>(baml.fs.read(path))
    }
}

const GLOBAL_SAMPLE: string = `
    on_exhaust = "park"
    research = "first"
    research_model = "acbox/coder"

    [[stages]]
    name = "local"
    worker = "devbox/coder"
    reviewer = "acbox/reviewer"
    attempts = 2

    [[stages]]
    name = "frontier"
    worker = "claude/sonnet"
    reviewer = "claude/sonnet"
    attempts = 1
`;

test "a global file lists its repos, with home expanded" {
    let listed = repos_in("repos = [\"~/src/a\", \"~/src/b\"]\n", "/home/me");
    assert.equal(listed.length(), 2);
    assert.equal(listed.at(0) ?? "", "/home/me/src/a");
    assert.equal(listed.at(1) ?? "", "/home/me/src/b");
    assert.equal(repos_in("label = \"delegate:local\"\n", "/home/me").length(), 0)
}

test "the parent of a config file is the repo" {
    assert.equal(parent_dir("/src/bead-loop/.bead-loop.toml"), "/src/bead-loop")
}

test "a repo toml keeps its merge mode and takes the global stages" {
    let repo = baml.fs.read(".bead-loop.toml");
    let c = config_from_toml(repo, GLOBAL_SAMPLE, "/src/bead-loop", "/state", "bead-loop");
    assert.equal(c.base, "main");
    assert.equal(c.label, "delegate:local");
    assert.equal(c.policy.merge, root.machine.MergeMode.Pipeline);
    assert.contains(c.gate, "baml-cli");
    assert.equal(c.policy.stages.length(), 2);
    assert.equal(c.policy.stages.at(0)?.worker, "devbox/coder");
    assert.equal(c.policy.stages.at(1)?.worker, "claude/sonnet");
    assert.equal(c.policy.research, "acbox/coder");
    assert.equal(c.policy.on_exhaust, root.machine.OnExhaust.Park)
}

/// `[providers.NAME] parallel` for each provider that sets it. A provider that does not
/// runs one round at a time, the Rust loop's default.
function capacity_of(global: baml.toml.Table) -> map<string, int> throws never {
    let out: map<string, int> = {};
    let v = global.get("providers");
    if let t: baml.toml.Table = v {
        for (let name in t.items.keys()) {
            let row = t.get(name);
            if let p: baml.toml.Table = row {
                let _ = out.set(name, int_at(p, "parallel", 1));
            }
        }
    }
    out
}

test "providers set their lanes and the caps come from the files" {
    let global = `
        max_open_prs = 1
        max_inflight = 100

        [providers.devbox]
        probe = "http://127.0.0.1:8100/health"

        [providers.claude]
        parallel = 2
    `;
    let c = config_from_toml("max_inflight = 3\n", global, "/src/r", "/state", "bead-loop");
    assert.equal(c.capacity.get("claude") ?? 0, 2);
    assert.equal(c.capacity.get("devbox") ?? 0, 1);
    assert.equal(c.max_inflight, 3);
    assert.equal(c.max_open_prs, 1)
}
