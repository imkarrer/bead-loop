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
            pr_events(view)
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
            self.note(id, `parked: ${because}`);
        }
    }

    function launch(self, id: string, spec: root.rounds.RoundSpec) -> void {
        let spec_file = `${self.rounds()}/${id}.spec.json`;
        let _ = baml.fs.write(spec_file, baml.json.stringify(spec));
        let child = baml.sys.subprocess(
            self.agent_bin,
            args = ["round", "--spec_file", spec_file],
            cwd = spec.dir,
            stdin = "ignore",
            stdout = "ignore",
            stderr = "ignore",
            detached = true,
        );
        let _ = baml.fs.write(`${self.rounds()}/${id}.pid`, `${child.pid}`);
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
