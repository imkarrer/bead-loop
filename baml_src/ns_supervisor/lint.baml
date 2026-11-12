// `lint`: whether a bead's claims hold before a round ever starts. A path the DESCRIPTION
// names that is not on the base branch, an ACCEPTANCE CRITERIA with no command in it, and
// with `run`, an acceptance that is already green on the base, before the bead's change
// (docs/design-measurement.md hypothesis 1, decisions 8, 17, 18, 21). Run by hand or from
// the planner, never inside a round; it changes no label, only notes its verdict.

const ACCEPTANCE_PREFIXES: string[] = [
    "cargo",
    "bash",
    "sh",
    "test",
    "grep",
    "rg",
    "git",
    "node",
    "npm",
    "make",
    "flox",
    "shellcheck",
    "./",
    "test/",
    "baml-cli",
    "python3",
    "pytest",
    "npx",
];

/// The tokens a DESCRIPTION names a path by: every whitespace-separated token with a slash
/// or a dot, trimmed of punctuation at either end. No existence check.
function path_tokens(desc: string) -> string[] throws never {
    let space = baml.regex.new("\\s+") catch_all (e) {
        _ => {
            let none: string[] = [];
            return none;
        },
    };
    let lead = baml.regex.new("^[^A-Za-z0-9_./]+") catch_all (e) {
        _ => {
            let none: string[] = [];
            return none;
        },
    };
    let tail = baml.regex.new("[^A-Za-z0-9_/-]+$") catch_all (e) {
        _ => {
            let none: string[] = [];
            return none;
        },
    };
    let out: string[] = [];
    for (let raw in space.split(desc)) {
        let t = raw.replace(lead, "").replace(tail, "");
        if (t.length() > 0 && (t.includes("/") || t.includes("."))) {
            out.push(t);
        }
    }
    out
}

/// The backtick spans of an acceptance that start like a command, trimmed, in order.
function acceptance_commands(s: string) -> string[] throws never {
    let out: string[] = [];
    let i = 0;
    for (let span in s.split("`")) {
        let t = span.trim();
        if (
            i % 2 == 1
                && ACCEPTANCE_PREFIXES.some((p) -> {
                    t.starts_with(p)
                })
        ) {
            out.push(t);
        }
        i = i + 1;
    }
    out
}

function acceptance_problem(s: string) -> string? throws never {
    let quiet_grep = baml.regex.new("\\|\\s*grep\\s+-[A-Za-z]*q") catch_all (e) {
        _ => null,
    };
    if (s.trim().length() == 0) {
        "no acceptance criteria"
    } else if (acceptance_commands(s).length() == 0) {
        "acceptance has no command"
    } else if (
        acceptance_commands(s).some((c) -> {
            quiet_grep?.has_match(c) ?? false
        })
    ) {
        "acceptance hides its output: a quiet grep after a pipe shows the worker an exit code alone; drop the q"
    } else {
        null
    }
}

function on_base(c: LoopConfig, path: string) -> bool throws never {
    let out = baml.sys.run(
        "git",
        args = ["cat-file", "-e", `${c.remote}/${c.base}:${path}`],
        cwd = c.repo,
        capture_output = true,
    ) catch_all (e) {
        _ => {
            return false;
        },
    };
    out.exit_code == 0
}

function static_problems(c: LoopConfig, row: root.world.BdRow) -> string[] throws never {
    let problems: string[] = [];
    for (let t in path_tokens(row.description ?? "")) {
        if (!on_base(c, t)) {
            problems.push(`path not on base: ${t}`);
        }
    }
    let a = acceptance_problem(row.acceptance_criteria ?? "");
    if let p: string = a {
        problems.push(p);
    }
    problems
}

/// `run`'s own check: a throwaway detached worktree of the base, setup there, each
/// acceptance command under bash with ten minutes each, the worktree removed again. A
/// command that fails there is what a bead's check is for; none failing is the problem.
function run_problems(c: LoopConfig, id: string, acceptance: string) -> string[] throws never {
    let commands = acceptance_commands(acceptance);
    let none: string[] = [];
    if (commands.length() == 0) {
        return none;
    }
    let wt = `${c.state}/wt/lint-${id}`;
    let _ = baml.sys.run(
        "git",
        args = ["worktree", "remove", "--force", wt],
        cwd = c.repo,
        capture_output = true,
    ) catch_all (e) {
        _ => null,
    };
    let _ = baml.sys.run(
        "git",
        args = ["fetch", "-q", c.remote, c.base],
        cwd = c.repo,
        capture_output = true,
    ) catch_all (e) {
        _ => null,
    };
    let added = baml.sys.run(
        "git",
        args = ["worktree", "add", "-q", "--detach", wt, `${c.remote}/${c.base}`],
        cwd = c.repo,
        capture_output = true,
    ) catch_all (e) {
        _ => {
            return none;
        },
    };
    if (added.exit_code != 0) {
        return none;
    }
    if (c.setup.length() > 0) {
        let _ = baml.sys.shell(c.setup, cwd = wt, capture_output = true) catch_all (e) {
            _ => null,
        };
    }
    let red = false;
    for (let command in commands) {
        let out = baml.sys.shell(
            root.tools.bounded(command, 600),
            cwd = wt,
            capture_output = true,
            timeout = baml.time.Duration.from_seconds(630),
        ) catch_all (e) {
            _ => null,
        };
        if ((out?.exit_code ?? 1) != 0) {
            red = true;
        }
    }
    let _ = baml.sys.run(
        "git",
        args = ["worktree", "remove", "--force", wt],
        cwd = c.repo,
        capture_output = true,
    ) catch_all (e) {
        _ => null,
    };
    if (red) {
        none
    } else {
        ["acceptance is green on base: a bead's check must fail before its change"]
    }
}

/// The config a bead's own labels pick: its `work:NAME` target, else the repo.
function config_for(configs: LoopConfig[], labels: string[]) -> LoopConfig? throws never {
    let target = configs.find((c) -> {
        c.only.length() > 0 && labels.includes(c.only)
    });
    target ?? configs.at(0)
}

function lint_date() -> string throws never {
    let out = baml.sys.run("date", args = ["+%Y-%m-%dT%H:%M%:z"], capture_output = true) catch_all (e) {
        _ => {
            return "";
        },
    };
    out.stdout.to_string().trim()
}

/// `bead-supervisor lint --config_file REPO/.bead-loop.toml [--ids "ID ID"] [--run true]`:
/// prints `ID: pass` or the problems, and notes `bead-loop lint DATE: ...` on each bead.
/// No ids lints every ready bead with the loop's label.
function lint(config_file: string, ids: string = "", run: bool = false) -> string {
    let c = load_config(config_file);
    let configs: LoopConfig[] = [c];
    for (let t in targets_of(read_or_empty(config_file), c, home_dir())) {
        configs.push(t);
    }
    let wanted = ids.split(" ").filter((i) -> {
        i.trim().length() > 0
    });
    if (wanted.length() == 0) {
        let ready = baml.sys.run(
            "bd",
            args = ["ready", "-l", c.label, "--json", "-n", "0"],
            cwd = c.repo,
            capture_output = true,
        );
        let rows = baml.json.decode<root.world.BdRow[]>(ready.stdout.to_string());
        wanted
            = rows.map((r) -> {
                r.id
            });
    }
    let report: string[] = [];
    for (let id in wanted) {
        let shown = baml.sys.run("bd", args = ["show", id, "--json"], cwd = c.repo, capture_output = true);
        let rows = baml.json.decode<root.world.BdRow[]>(shown.stdout.to_string()) catch_all (e) {
            _ => {
                let none: root.world.BdRow[] = [];
                none
            },
        };
        if let row: root.world.BdRow = rows.at(0) {
            let here = config_for(configs, row.labels ?? []) ?? c;
            let problems = static_problems(here, row);
            if (run) {
                for (let p in run_problems(here, id, row.acceptance_criteria ?? "")) {
                    problems.push(p);
                }
            }
            let verdict = if (problems.length() == 0) {
                "pass"
            } else {
                problems.join("; ")
            };
            report.push(`${id}: ${verdict}`);
            let _ = baml.sys.run(
                "bd",
                args = ["note", id, `bead-loop lint ${lint_date()}: ${verdict}`],
                cwd = c.repo,
                capture_output = true,
            );
        } else {
            report.push(`${id}: not found`);
        }
    }
    report.join("\n")
}

test "a description's paths are its slashed or dotted words, trimmed" {
    let t = path_tokens("Edit `src/a.rs` and (docs/b.md), then run it. See README.md: done");
    assert.equal(t.join(","), "src/a.rs,docs/b.md,README.md")
}

test "an acceptance is a command, prose or nothing" {
    assert.equal(
        acceptance_commands("Run `cargo test foo` then ` bash -c \"echo hi\" ` and `foo bar`.")
            .join("|"),
        "cargo test foo|bash -c \"echo hi\"",
    );
    assert.equal(acceptance_problem("") ?? "", "no acceptance criteria");
    assert.equal(acceptance_problem("work.txt exists") ?? "", "acceptance has no command");
    assert.equal(acceptance_problem("Run `cargo test`") == null, true)
}

test "an acceptance piped into a quiet grep is flagged" {
    assert.equal(
        acceptance_problem("Run `bash -c 'cargo test 2>&1 | grep -q PASS'`")?.starts_with(
            "acceptance hides its output",
        )
            ?? false,
        true,
    );
    assert.equal(
        acceptance_problem("Run `cargo test | grep -qE ok`")?.starts_with(
            "acceptance hides its output",
        )
            ?? false,
        true,
    );
    assert.equal(acceptance_problem("Run `test -f a && grep -q x a`") == null, true)
}

test "a bead labelled for a target is linted against the target" {
    let parent = config_from_toml(TARGETS_SAMPLE, GLOBAL_SAMPLE, "/src/pw", "/state/pw", "bead-loop");
    let configs: LoopConfig[] = [parent];
    for (let t in targets_of(TARGETS_SAMPLE, parent, "/home/me")) {
        configs.push(t);
    }
    assert.equal(
        config_for(configs, ["delegate:local", "work:euclid"])?.repo,
        "/home/me/src/euclid",
    );
    assert.equal(config_for(configs, ["delegate:local"])?.repo, "/src/pw")
}
