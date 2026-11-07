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

function pick(repo: baml.toml.Table, global: baml.toml.Table, key: string, fallback: string) -> string throws never {
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
            out = if (out.length() == 0) {
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

test "the parent of a config file is the repo" {
    assert.equal(parent_dir("/src/bead-loop/.bead-loop.toml"), "/src/bead-loop")
}

test "a repo toml keeps its merge mode and takes the global stages" {
    let repo = baml.fs.read(".bead-loop.toml");
    let c = config_from_toml(repo, GLOBAL_SAMPLE, "/src/bead-loop", "/state", "bead-loop");
    assert.equal(c.base, "main");
    assert.equal(c.label, "delegate:local");
    assert.equal(c.policy.merge, root.machine.MergeMode.Pipeline);
    assert.contains(c.gate, "cargo test");
    assert.equal(c.policy.stages.length(), 2);
    assert.equal(c.policy.stages.at(0)?.worker, "devbox/coder");
    assert.equal(c.policy.stages.at(1)?.worker, "claude/sonnet");
    assert.equal(c.policy.research, "acbox/coder");
    assert.equal(c.policy.on_exhaust, root.machine.OnExhaust.Park)
}
