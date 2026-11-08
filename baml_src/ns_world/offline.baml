// The bench world: the same round code, no bd and no gh. A case is a ticket; a
// green merge is recorded locally so the supervisor can close the bead.

class Case {
    id: string,
    title: string,
    description: string,
    acceptance: string,
    repo: string,
    base: string,
    gate: string,
}

class OfflineWorld {
    repo: string,
    state: string,
    base: string,
    remote: string,
    gate: string,
    agent_bin: string,
    tickets_now: Ticket[],
    merged: string[],

    function new(c: Case, state: string, agent_bin: string) -> OfflineWorld throws never {
        OfflineWorld {
            repo: c.repo,
            state: state,
            base: c.base,
            remote: "origin",
            gate: c.gate,
            agent_bin: agent_bin,
            tickets_now: [
                Ticket {
                    id: c.id,
                    title: c.title,
                    description: c.description,
                    acceptance: c.acceptance,
                },
            ],
            merged: [],
        }
    }

    function worktree(self, id: string) -> string throws never {
        `${self.state}/wt/${id}`
    }

    function rounds(self) -> string throws never {
        `${self.state}/rounds`
    }

    function bead_text(self, id: string) -> string throws never {
        let t = self.tickets_now.find((x) -> {
            x.id == id
        });
        if let row: Ticket = t {
            `<bead id="${id}">\nTITLE: ${row.title}\n\nDESCRIPTION:\n${row.description}\n\nACCEPTANCE CRITERIA:\n${row.acceptance}\n</bead>`
        } else {
            `<bead id="${id}"></bead>`
        }
    }

    function run_git(self, args: string[], cwd: string) -> string throws never {
        let out = baml.sys.run("git", args = args, cwd = cwd, capture_output = true) catch_all (e) {
            _ => {
                return "";
            },
        };
        out.stdout.to_string()
    }

    implements World {
        function tickets(self) -> Ticket[] throws root.machine.Infra {
            self.tickets_now
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
            let args = if (resume) {
                ["worktree", "add", "-q", dir, `bead/${id}`]
            } else {
                ["worktree", "add", "-q", "-B", `bead/${id}`, dir, self.base]
            };
            let out = baml.sys.run("git", args = args, cwd = self.repo, capture_output = true) catch_all (e) {
                _ => {
                    throw root.machine.Infra {
                        kind: "infra",
                        what: root.machine.Trouble.Git,
                        words: `git worktree: ${e}`,
                    }
                },
            };
            if (out.exit_code != 0) {
                throw root.machine.Infra {
                    kind: "infra",
                    what: root.machine.Trouble.Git,
                    words: out.stderr.to_string(),
                }
            }
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
                args = ["branch", "-D", `bead/${id}`],
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
            let _ = self.launch(id, kind, model, note) catch_all (e) {
                _ => {
                    throw root.machine.Infra {
                        kind: "infra",
                        what: root.machine.Trouble.Harness,
                        words: `the round did not start: ${e}`,
                    }
                },
            };
        }

        function running(self) -> RoundRunning[] throws never {
            let out: RoundRunning[] = [];
            let listing = baml.sys.run("ls", args = [self.rounds()], capture_output = true) catch_all (e) {
                _ => {
                    return out;
                },
            };
            for (let f in listing.stdout.to_string().split("\n")) {
                if (f.ends_with(".pid")) {
                    let name = f.slice(0, f.length() - 4);
                    let pid = baml.fs.read(`${self.rounds()}/${name}.pid`) catch_all (e) {
                        _ => "",
                    };
                    let alive = baml.fs.exists(`/proc/${pid.trim()}`) catch_all (e) {
                        _ => false,
                    };
                    if (alive && pid.trim().length() > 0) {
                        out.push(RoundRunning { id: name, kind: RoundKind.Work, model: "" });
                    }
                }
            }
            out
        }

        function take_finished(self) -> RoundDone[] throws root.machine.Infra {
            let out: RoundDone[] = [];
            let listing = baml.sys.run("ls", args = [self.rounds()], capture_output = true) catch_all (e) {
                _ => {
                    return out;
                },
            };
            for (let f in listing.stdout.to_string().split("\n")) {
                if (f.ends_with(".result.json")) {
                    let name = f.slice(0, f.length() - 12);
                    let path = `${self.rounds()}/${name}.result.json`;
                    let done = baml.json.decode<RoundDone>(baml.fs.read(path)) catch_all (e) {
                        _ => {
                            throw root.machine.Infra {
                                kind: "infra",
                                what: root.machine.Trouble.Harness,
                                words: `cannot read ${path}: ${e}`,
                            }
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
            }
            out
        }

        function observe_pr(
            self,
            id: string,
            pr: string,
        ) -> root.machine.Event[] throws root.machine.Infra {
            if (self.merged.includes(id)) {
                [root.machine.PrMerged { kind: "pr_merged", url: pr }]
            } else {
                [root.machine.ChecksGreen { kind: "checks_green" }]
            }
        }

        function push_and_open_pr(
            self,
            id: string,
        ) -> root.machine.PrOpened throws root.machine.Infra {
            let head = self.run_git(["rev-parse", "HEAD"], self.worktree(id)).trim();
            root.machine.PrOpened { kind: "pr_opened", url: `bench://${id}`, head: head }
        }

        function merge_pr(self, id: string) -> void throws root.machine.Infra {
            self.merged.push(id);
        }

        function update_branch(self, id: string) -> void throws root.machine.Infra {}

        function relabel(self, id: string) -> void throws root.machine.Infra {}

        function delete_remote_branch(self, id: string) -> void throws never {}

        function note(self, id: string, text: string) -> void throws root.machine.Infra {
            self.write_note(id, text) catch_all (e) {
                _ => {
                    throw root.machine.Infra {
                        kind: "infra",
                        what: root.machine.Trouble.Harness,
                        words: `note: ${e}`,
                    }
                },
            }
        }

        function close_bead(self, id: string, url: string?) -> void throws root.machine.Infra {
            let _ = baml.fs.write(`${self.state}/beads/${id}/closed`, url ?? "bench") catch_all (e) {
                _ => {
                    throw root.machine.Infra {
                        kind: "infra",
                        what: root.machine.Trouble.Harness,
                        words: `close: ${e}`,
                    }
                },
            };
        }

        function write_park_brief(
            self,
            id: string,
            because: string,
        ) -> void throws root.machine.Infra {
            let text = root.agents.park_brief_text(because, "");
            let _ = baml.sys.run("mkdir", args = ["-p", `${self.state}/beads/${id}`]) catch_all (e) {
                _ => null,
            };
            let _ = baml.fs.write(`${self.state}/beads/${id}/park.md`, text) catch_all (e) {
                _ => {
                    throw root.machine.Infra {
                        kind: "infra",
                        what: root.machine.Trouble.Harness,
                        words: `park brief: ${e}`,
                    }
                },
            };
            self.note(id, `parked: ${because}`);
        }
    }

    function launch(self, id: string, kind: RoundKind, model: string, note: string) -> void {
        let dir = self.rounds();
        let _ = baml.sys.run("mkdir", args = ["-p", dir, `${self.state}/logs`, `${self.state}/beads/${id}`]);
        let stamp = baml.sys.pid();
        let spec = root.rounds.RoundSpec {
            id: id,
            kind: kind,
            model: model,
            dir: self.worktree(id),
            base: self.base,
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
        let spec_file = `${dir}/${id}.spec.json`;
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
        let _ = baml.fs.write(`${dir}/${id}.pid`, `${child.pid}`);
    }

    function write_note(self, id: string, text: string) -> void {
        let path = `${self.state}/beads/${id}/notes`;
        let _ = baml.sys.run("mkdir", args = ["-p", `${self.state}/beads/${id}`]);
        let out = baml.fs.open(path, "a");
        let _ = out.write(text + "\n");
        out.close();
    }
}

function case_of(text: string) -> Case {
    baml.json.decode<Case>(text)
}

/// `bead-loop bench --config_file PATH --case_file PATH --ticks N`. Recovers onto
/// an OfflineWorld for that case and ticks until the bead closes, parks, or the
/// budget runs out. The reviewer is still in the policy; turn it off in the case's
/// config if the hidden check is the judge.
function bench(config_file: string, case_file: string, ticks: int = 40) -> string {
    let cfg = baml.json.decode<root.supervisor.LoopConfig>(baml.fs.read(config_file));
    let c = case_of(baml.fs.read(case_file));
    let world = OfflineWorld.new(c, cfg.state, cfg.agent_bin);
    let s = root.supervisor.recover(world, root.supervisor.FileLog { state: cfg.state }, cfg.policy);
    s.lanes = 1;
    let n = 0;
    while (n < ticks) {
        root.supervisor.tick(s);
        let b = s.bead(c.id);
        if (b?.place is root.machine.Closed || b?.place is root.machine.Parked) {
            break;
        }
        baml.sys.sleep(baml.time.Duration.from_seconds(cfg.heartbeat_seconds));
        n = n + 1;
    }
    root.page.snapshot_json(s)
}

test "a case is a ticket" {
    let c = case_of(
        `{"id":"t-1","title":"t","description":"d","acceptance":"a","repo":"/tmp/x","base":"HEAD","gate":"true"}`,
    );
    let w = OfflineWorld.new(c, "/tmp/bead-loop-offline", "/bin/false");
    assert.equal(w.tickets().at(0)?.id, "t-1");
    assert.contains(w.bead_text("t-1"), "TITLE: t")
}

test "a bench PR is local, not github" {
    let c = case_of(
        `{"id":"t-1","title":"t","description":"d","acceptance":"a","repo":"/tmp/x","base":"HEAD","gate":"true"}`,
    );
    let w = OfflineWorld.new(c, "/tmp/bead-loop-offline", "/bin/false");
    let opened = w.push_and_open_pr("t-1");
    assert.equal(opened.url, "bench://t-1");
    assert.is_type<root.machine.ChecksGreen>(w.observe_pr("t-1", opened.url).at(0));
}
