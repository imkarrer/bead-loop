// The real world: bd, git and gh, and rounds as detached processes. Layout under `state`:
// beads/ID/events.jsonl (ns_supervisor), rounds/ID.{spec,pid,result}.json, wt/ID, logs/.

class BdRow {
    id: string,
    title: string,
    description: string?,
    acceptance_criteria: string?,
}

class LiveWorld {
    repo: string,
    state: string,
    base: string,
    remote: string,
    label: string,
    gate: string,
    agent_bin: string,
    /// auto, pipeline, manual, or external. The watcher reads it.
    merge: string,

    function worktree(self, id: string) -> string throws never {
        `${self.state}/wt/${id}`
    }
    function branch(self, id: string) -> string throws never {
        `bead/${id}`
    }
    function rounds(self) -> string throws never {
        `${self.state}/rounds`
    }

    /// Runs a tool. A tool exiting non-zero is the world refusing, so it is Infra.
    function tool(
        self,
        what: root.machine.Trouble,
        program: string,
        args: string[],
        cwd: string,
    ) -> string throws root.machine.Infra {
        let out = baml.sys.run(program, args = args, cwd = cwd, capture_output = true) catch_all (e) {
            _ => {
                throw root.machine.Infra { kind: "infra", what: what, words: `${program} did not run: ${e}` }
            },
        };
        if (out.exit_code != 0) {
            let said = root.tools.tail(out.stderr.to_string() + out.stdout.to_string());
            throw root.machine.Infra { kind: "infra", what: what, words: `${program} ${args.at(0) ?? ""}: ${said}` }
        }
        out.stdout.to_string()
    }

    function refuse(
        self,
        what: root.machine.Trouble,
        words: string,
    ) -> never throws root.machine.Infra {
        throw root.machine.Infra { kind: "infra", what: what, words: words }
    }

    function bead_text(self, id: string) -> string throws root.machine.Infra {
        let shown = self.tool(root.machine.Trouble.Bd, "bd", ["show", id, "--json"], self.repo);
        let rows = baml.json.decode<BdRow[]>(shown) catch_all (e) {
            _ => {
                self.refuse(root.machine.Trouble.Bd, `bd show ${id}: ${e}`)
            },
        };
        let b = rows.at(0);
        if let row: BdRow = b {
            `<bead id="${id}">\nTITLE: ${row.title}\n\nDESCRIPTION:\n${row.description ?? ""}\n\nACCEPTANCE CRITERIA:\n${row.acceptance_criteria ?? ""}\n</bead>`
        } else {
            self.refuse(root.machine.Trouble.Bd, `bd show ${id} returned nothing`)
        }
    }

    implements World {
        function tickets(self) -> Ticket[] throws root.machine.Infra {
            let text = self.tool(
                root.machine.Trouble.Bd,
                "bd",
                ["ready", "-l", self.label, "--json", "-n", "0"],
                self.repo,
            );
            let rows = baml.json.decode<BdRow[]>(text) catch_all (e) {
                _ => {
                    self.refuse(root.machine.Trouble.Bd, `bd ready: ${e}`)
                },
            };
            rows.map((r) -> {
                Ticket {
                    id: r.id,
                    title: r.title,
                    description: r.description ?? "",
                    acceptance: r.acceptance_criteria ?? "",
                }
            })
        }

        function prepare_worktree(
            self,
            id: string,
            resume: bool,
        ) -> void throws root.machine.Infra {
            let dir = self.worktree(id);
            let there = baml.fs.exists(dir) catch_all (e) {
                _ => false,
            };
            if (resume && there) {
                return;
            }
            let _ = self.tool(
                root.machine.Trouble.Git,
                "git",
                ["fetch", "-q", self.remote, self.base],
                self.repo,
            );
            let args = if (resume) {
                ["worktree", "add", "-q", dir, self.branch(id)]
            } else {
                ["worktree", "add", "-q", "-B", self.branch(id), dir, `${self.remote}/${self.base}`]
            };
            let _ = self.tool(root.machine.Trouble.Git, "git", args, self.repo);
        }

        function remove_branch(self, id: string) -> void throws never {
            let dir = self.worktree(id);
            let _ = baml.sys.run(
                "git",
                args = ["worktree", "remove", "--force", dir],
                cwd = self.repo,
                capture_output = true,
            ) catch_all (e) {
                _ => null,
            };
            let _ = baml.sys.run(
                "git",
                args = ["branch", "-D", self.branch(id)],
                cwd = self.repo,
                capture_output = true,
            ) catch_all (e) {
                _ => null,
            };
        }

        function start_round(
            self,
            id: string,
            kind: RoundKind,
            model: string,
            note: string,
        ) -> void throws root.machine.Infra {
            let dir = self.rounds();
            let _ = self.tool(
                root.machine.Trouble.Harness,
                "mkdir",
                ["-p", dir, `${self.state}/logs`],
                self.repo,
            );
            let stamp = baml.sys.pid();
            let spec = root.rounds.RoundSpec {
                id: id,
                kind: kind,
                model: model,
                dir: self.worktree(id),
                base: `${self.remote}/${self.base}`,
                bead: self.bead_text(id),
                gate: self.gate,
                note: note,
                report: root.rounds.load_report(`${self.state}/beads/${id}/report`),
                report_file: `${self.state}/beads/${id}/report`,
                brief: root.rounds.load_report(`${self.state}/beads/${id}/brief`),
                brief_file: `${self.state}/beads/${id}/brief`,
                log_file: `${self.state}/logs/${id}.${stamp}.${kind}.jsonl`,
                result_file: `${dir}/${id}.result.json`,
            };
            let started = self.launch(id, spec) catch_all (e) {
                _ => {
                    self.refuse(root.machine.Trouble.Harness, `the round did not start: ${e}`)
                },
            };
        }

        function running(self) -> RoundRunning[] throws never {
            let out: RoundRunning[] = [];
            for (let name in self.names_in(self.rounds(), ".pid")) {
                let pid = baml.fs.read(`${self.rounds()}/${name}.pid`) catch_all (e) {
                    _ => "",
                };
                let alive = baml.fs.exists(`/proc/${pid.trim()}`) catch_all (e) {
                    _ => false,
                };
                if (alive && pid.trim().length() > 0) {
                    out.push(RoundRunning { id: name, kind: self.kind_of(name) });
                }
            }
            out
        }

        function take_finished(self) -> RoundDone[] throws root.machine.Infra {
            let out: RoundDone[] = [];
            for (let name in self.names_in(self.rounds(), ".result.json")) {
                let path = `${self.rounds()}/${name}.result.json`;
                let done = self.read_result(path) catch_all (e) {
                    _ => {
                        self.refuse(root.machine.Trouble.Harness, `cannot read ${path}: ${e}`)
                    },
                };
                out.push(done);
                let _ = baml.fs.remove(path) catch_all (e) {
                    _ => null,
                };
                let _ = baml.fs.remove(`${self.rounds()}/${name}.pid`) catch_all (e) {
                    _ => null,
                };
            }
            out
        }

        function observe_pr(
            self,
            id: string,
            pr: string,
        ) -> root.machine.Event[] throws root.machine.Infra {
            let text = self.tool(
                root.machine.Trouble.Gh,
                "gh",
                [
                    "pr",
                    "view",
                    pr,
                    "--json",
                    "url,state,mergeable,mergeStateStatus,headRefOid,statusCheckRollup",
                ],
                self.repo,
            );
            let view = view_of(text) catch_all (e) {
                _ => {
                    self.refuse(root.machine.Trouble.Gh, `gh pr view: ${e}`)
                },
            };
            let required = self.required(pr);
            let now = unix_now();
            let prev = self.load_watch(id);
            let situation = situation_of(view);
            let clock = root.world.PrClock {
                merge: self.merge,
                green_for: age(prev.green_since, situation == "green", now),
                quiet_for: age(prev.quiet_since, situation == "quiet", now),
                red_for: age(prev.red_since, situation == "red", now),
                required_failing: required.failing,
                required_known: required.known,
                rerun_head: prev.rerun_head,
            };
            let events = watch_pr(view, clock);
            self.save_watch(id, next_watch(prev, situation, now, view, events));
            events
        }

        function push_and_open_pr(
            self,
            id: string,
        ) -> root.machine.PrOpened throws root.machine.Infra {
            let dir = self.worktree(id);
            let branch = self.branch(id);
            let _ = self.tool(
                root.machine.Trouble.Push,
                "git",
                ["push", "-q", "--force-with-lease", "-u", self.remote, branch],
                dir,
            );
            let head = self.tool(root.machine.Trouble.Git, "git", ["rev-parse", "HEAD"], dir).trim();
            let existing = self
                .tool(
                    root.machine.Trouble.Gh,
                    "gh",
                    [
                        "pr",
                        "list",
                        "--head",
                        branch,
                        "--state",
                        "open",
                        "--json",
                        "url",
                        "--jq",
                        ".[0].url // \"\"",
                    ],
                    self.repo,
                )
                .trim();
            let url = if (existing.length() > 0) {
                existing
            } else {
                self
                    .tool(
                        root.machine.Trouble.Gh,
                        "gh",
                        [
                            "pr",
                            "create",
                            "--head",
                            branch,
                            "--base",
                            self.base,
                            "--title",
                            id,
                            "--body",
                            self.bead_text(id),
                        ],
                        self.repo,
                    )
                    .trim()
            };
            root.machine.PrOpened { kind: "pr_opened", url: url, head: head }
        }

        function merge_pr(self, id: string) -> void throws root.machine.Infra {
            let _ = self.tool(
                root.machine.Trouble.MergeRefused,
                "gh",
                ["pr", "merge", self.branch(id), "--squash", "--delete-branch"],
                self.repo,
            );
        }

        function update_branch(self, id: string) -> void throws root.machine.Infra {
            let _ = self.tool(
                root.machine.Trouble.Gh,
                "gh",
                ["pr", "update-branch", self.branch(id)],
                self.repo,
            );
        }

        function relabel(self, id: string) -> void throws root.machine.Infra {
            let pr = self.branch(id);
            let _ = baml.sys.run(
                "gh",
                args = ["pr", "edit", pr, "--remove-label", "automerge"],
                cwd = self.repo,
                capture_output = true,
            ) catch_all (e) {
                _ => null,
            };
            let _ = self.tool(
                root.machine.Trouble.Gh,
                "gh",
                ["pr", "edit", pr, "--add-label", "automerge"],
                self.repo,
            );
        }

        function delete_remote_branch(self, id: string) -> void throws never {
            let _ = baml.sys.run(
                "git",
                args = ["push", "-q", self.remote, "--delete", self.branch(id)],
                cwd = self.repo,
                capture_output = true,
            ) catch_all (e) {
                _ => null,
            };
        }

        function note(self, id: string, text: string) -> void throws root.machine.Infra {
            let _ = self.tool(root.machine.Trouble.Bd, "bd", ["note", id, `bead-loop: ${text}`], self.repo);
        }

        function close_bead(self, id: string, url: string?) -> void throws root.machine.Infra {
            let _ = self.tool(
                root.machine.Trouble.Bd,
                "bd",
                ["close", id, "--reason", url ?? "merged"],
                self.repo,
            );
        }

        function write_park_brief(
            self,
            id: string,
            because: string,
        ) -> void throws root.machine.Infra {
            let text = root.agents.park_brief_text(because, "");
            let dir = `${self.state}/beads/${id}`;
            let _ = baml.sys.run("mkdir", args = ["-p", dir]) catch_all (e) {
                _ => null,
            };
            let _ = baml.fs.write(`${dir}/park.md`, text) catch_all (e) {
                _ => null,
            };
            self.note(id, `parked: ${because}`);
        }
    }

    function launch(self, id: string, spec: root.rounds.RoundSpec) -> void {
        let spec_file = `${self.rounds()}/${id}.spec.json`;
        let _ = baml.fs.write(spec_file, baml.json.stringify(spec));
        let _ = baml.sys.run("mkdir", args = ["-p", `${self.repo}/.baml/btel`]) catch_all (e) {
            _ => null,
        };
        let argv = round_argv(bwrap_path(), self.agent_bin, spec_file, spec.dir, self.repo, self.state);
        let program = argv.at(0) ?? self.agent_bin;
        let args: string[] = [];
        let i = 1;
        while (i < argv.length()) {
            args.push(argv.at(i) ?? "");
            i = i + 1;
        }
        let child = baml.sys.subprocess(
            program,
            args = args,
            cwd = spec.dir,
            env = {
                "BAML_HOME": `${self.repo}/.baml`,
                "BAML_CONTEXT": trace_context(spec.id, kind_name(spec.kind), spec.log_file),
            },
            stdin = "ignore",
            stdout = "ignore",
            stderr = "ignore",
            detached = true,
        );
        let _ = baml.fs.write(`${self.rounds()}/${id}.pid`, `${child.pid}`);
    }

    function required(self, pr: string) -> root.world.Required throws never {
        let out = baml.sys.run(
            "gh",
            args = ["pr", "checks", pr, "--required", "--json", "name,state,description,bucket"],
            cwd = self.repo,
            capture_output = true,
        ) catch_all (e) {
            _ => {
                return root.world.Required { known: false, failing: [], killed: false };
            },
        };
        if (out.exit_code != 0) {
            return root.world.Required { known: false, failing: [], killed: false };
        }
        root.world.required_of(out.stdout.to_string())
    }

    function load_watch(self, id: string) -> Watch throws never {
        let text = baml.fs.read(self.watch_path(id)) catch_all (e) {
            _ => "",
        };
        if (text.length() == 0) {
            return Watch { green_since: 0, quiet_since: 0, red_since: 0, rerun_head: "" };
        }
        baml.json.decode<Watch>(text) catch_all (e) {
            _ => Watch { green_since: 0, quiet_since: 0, red_since: 0, rerun_head: "" },
        }
    }

    function save_watch(self, id: string, watch: Watch) -> void throws never {
        let _ = baml.sys.run("mkdir", args = ["-p", `${self.state}/beads/${id}`]) catch_all (e) {
            _ => null,
        };
        let _ = baml.fs.write(self.watch_path(id), baml.json.stringify(watch)) catch_all (e) {
            _ => null,
        };
    }

    function watch_path(self, id: string) -> string throws never {
        `${self.state}/beads/${id}/watch.json`
    }

    function read_result(self, path: string) -> RoundDone {
        baml.json.decode<RoundDone>(baml.fs.read(path))
    }

    function kind_of(self, id: string) -> RoundKind throws never {
        let spec = self.read_spec(id) catch_all (e) {
            _ => {
                return RoundKind.Work;
            },
        };
        spec.kind
    }

    function read_spec(self, id: string) -> root.rounds.RoundSpec {
        baml.json.decode<root.rounds.RoundSpec>(baml.fs.read(`${self.rounds()}/${id}.spec.json`))
    }

    /// The bead ids with a file of this suffix in `dir`.
    function names_in(self, dir: string, suffix: string) -> string[] throws never {
        let out = baml.sys.run("ls", args = [dir], capture_output = true) catch_all (e) {
            _ => {
                let none: string[] = [];
                return none;
            },
        };
        out.stdout.to_string()
            .split("\n")
            .filter((f) -> {
                f.ends_with(suffix)
            })
            .map((f) -> {
                f.slice(0, f.length() - suffix.length())
            })
    }
}

class Watch {
    green_since: int,
    quiet_since: int,
    red_since: int,
    rerun_head: string,
}

function unix_now() -> int throws never {
    let out = baml.sys.run("date", args = ["+%s"], capture_output = true) catch_all (e) {
        _ => {
            return 0;
        },
    };
    baml.json.decode<int>(out.stdout.to_string().trim()) catch_all (e) {
        _ => 0,
    }
}

/// Seconds since `since` while `active`, or 0. A situation that just started
/// counts as 0 until the next observation.
function age(since: int, active: bool, now: int) -> int throws never {
    if (!active || since <= 0 || now < since) {
        0
    } else {
        now - since
    }
}

function touch(since: int, active: bool, now: int) -> int throws never {
    if (!active) {
        0
    } else {
        if (since > 0) {
            since
        } else {
            now
        }
    }
}

function situation_of(view: PrView) -> string throws never {
    let first = pr_events(without_skipped(view)).at(0);
    if (first is root.machine.ChecksGreen) {
        "green"
    } else {
        if (first is root.machine.ChecksRed) {
            "red"
        } else {
            if (
                first is root.machine.PrMerged
                    || first is root.machine.PrClosed
                    || first is root.machine.Conflicting
                    || first is root.machine.Behind
            ) {
                "done"
            } else {
                "quiet"
            }
        }
    }
}

function saw_killed(events: root.machine.Event[]) -> bool throws never {
    events.some((e) -> {
        e is root.machine.RedKilled
    })
}

function next_watch(
    prev: Watch,
    situation: string,
    now: int,
    view: PrView,
    events: root.machine.Event[],
) -> Watch throws never {
    let rerun = if (saw_killed(events)) {
        view.headRefOid ?? prev.rerun_head
    } else {
        prev.rerun_head
    };
    Watch {
        green_since: touch(prev.green_since, situation == "green", now),
        quiet_since: touch(prev.quiet_since, situation == "quiet", now),
        red_since: touch(prev.red_since, situation == "red", now),
        rerun_head: rerun,
    }
}

function kind_name(kind: RoundKind) -> string throws never {
    match (kind) {
        RoundKind.Work => "work",
        RoundKind.Review => "review",
        RoundKind.Research => "research",
    }
}

function json_escape(s: string) -> string throws never {
    s.split("\\").join("\\\\").split("\"").join("\\\"")
}

/// What `baml query` reads as context_distinct_id and context_metadata. The
/// distinct id is the bead, so one bead's calls are one set.
function trace_context(id: string, kind: string, log: string) -> string throws never {
    let bead = json_escape(id);
    let k = json_escape(kind);
    let l = json_escape(log);
    `{"distinct_id":"${bead}","metadata":{"bead":"${bead}","kind":"${k}","log":"${l}"}}`
}

test "a round's trace names the bead" {
    let ctx = trace_context("bl-b1a.1", "work", "/state/beads/bl-b1a.1/log");
    assert.contains(ctx, "\"distinct_id\":\"bl-b1a.1\"");
    assert.contains(ctx, "\"kind\":\"work\"");
    assert.contains(ctx, "\"log\":\"/state/beads/bl-b1a.1/log\"")
}

function bwrap_path() -> string throws never {
    let out = baml.sys.run("which", args = ["bwrap"], capture_output = true) catch_all (e) {
        _ => {
            return "";
        },
    };
    if (out.exit_code != 0) {
        ""
    } else {
        out.stdout.to_string().trim()
    }
}

/// The round process. With bwrap the worktree, the git dir, the state dir and the
/// trace directory are writable and the rest of the filesystem is not, so a model
/// cannot write the checkout it was not given. The network stays, because the
/// model server is on it. Traces go to `<repo>/.baml/btel`, which is where
/// `baml query --local` reads them.
function round_argv(
    bwrap: string,
    bin: string,
    spec_file: string,
    worktree: string,
    repo: string,
    state: string,
) -> string[] throws never {
    if (bwrap.length() == 0) {
        return [bin, "round", "--spec_file", spec_file];
    }
    [
        bwrap,
        "--ro-bind",
        "/",
        "/",
        "--bind",
        worktree,
        worktree,
        "--bind",
        `${repo}/.git`,
        `${repo}/.git`,
        "--bind",
        `${repo}/.baml/btel`,
        `${repo}/.baml/btel`,
        "--bind",
        state,
        state,
        "--bind",
        "/tmp",
        "/tmp",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--chdir",
        worktree,
        "--",
        bin,
        "round",
        "--spec_file",
        spec_file,
    ]
}

test "a round is sandboxed when bwrap is there" {
    let args = round_argv("bwrap", "bead-loop", "/state/rounds/t-1.spec.json", "/state/wt/t-1", "/repo", "/state");
    assert.equal(args.at(0), "bwrap");
    assert.contains(args.join(" "), "--ro-bind");
    assert.contains(args.join(" "), "--bind /state/wt/t-1 /state/wt/t-1");
    assert.contains(args.join(" "), "--bind /repo/.git /repo/.git");
    assert.contains(args.join(" "), "--bind /repo/.baml/btel /repo/.baml/btel");
    assert.equal(args.at(args.length() - 1), "/state/rounds/t-1.spec.json")
}

test "without bwrap the round is the binary itself" {
    let args = round_argv("", "bead-loop", "spec.json", "/wt", "/repo", "/state");
    assert.equal(args, ["bead-loop", "round", "--spec_file", "spec.json"])
}

test "a green PR's clock starts when it is first seen green" {
    let prev = Watch { green_since: 0, quiet_since: 0, red_since: 0, rerun_head: "" };
    let view = view_of(
        `{"url":"u","state":"OPEN","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}`,
    );
    let next = next_watch(prev, "green", 1000, view, []);
    assert.equal(next.green_since, 1000);
    assert.equal(age(next.green_since, true, 2800), 1800)
}
