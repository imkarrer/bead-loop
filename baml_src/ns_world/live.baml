// The real world: bd, git and gh, and rounds as detached processes. Layout under `state`:
// beads/ID/events.jsonl (ns_supervisor), rounds/ID.{spec,pid,result}.json, wt/ID, logs/.

class BdRow {
    id: string,
    title: string,
    description: string?,
    acceptance_criteria: string?,
    labels: string[]?,
}

class LiveWorld {
    /// The checkout git works in: the repo, or a target's path.
    repo: string,
    /// Where bd runs. A target's beads live in the repo that plans them.
    beads: string,
    state: string,
    base: string,
    /// The remote the base is fetched from.
    remote: string,
    /// The remote `bead/*` branches are pushed to: a fork, for someone else's repo.
    push_remote: string,
    /// `owner/name` the PR is opened against; empty is the checkout's own.
    pr_repo: string,
    label: string,
    /// A target takes only the beads with this label (`work:NAME`); empty takes any.
    only: string,
    /// The repo itself leaves the beads with a label of this prefix (`work:`) to its targets.
    skip: string,
    gate: string,
    /// Runs in a fresh worktree before the first round (`npm ci`).
    setup: string,
    agent_bin: string,
    /// auto, pipeline, manual, or external. The watcher reads it.
    merge: string,
    /// `loop`: the title is `ID: TITLE`. `plain`: the bead's title and description alone.
    pr_style: string,
    merge_label: string,
    /// Review comments from others on the loop's own PR send it back to act on them.
    feedback: bool,
    /// Seconds a work or review round may run (worker_timeout), and a research round.
    work_seconds: int,
    research_seconds: int,
    /// Run rounds under bwrap (when it is on PATH): only the worktree, the git dir, the
    /// state and /tmp writable. Off by default: a gate that writes a cache (flox, npm,
    /// pip) fails read-only, and the network is not cut yet.
    sandbox: bool,
    /// Each provider's server, from `[providers.NAME]`.
    urls: map<string, string>,
    /// The pre-check model; empty is none.
    precheck: string,

    /// gh, pointed at the PR's repo when that is not the checkout's own.
    function gh_args(self, args: string[]) -> string[] throws never {
        if (self.pr_repo.length() == 0) {
            return args;
        }
        let out = args;
        out.push("-R");
        out.push(self.pr_repo);
        out
    }

    /// The PR's head: `owner:bead/ID` when the branch lives on a fork.
    function head_ref(self, id: string) -> string throws never {
        if (self.pr_repo.length() == 0) {
            return self.branch(id);
        }
        let url = baml.sys.run(
            "git",
            args = ["remote", "get-url", self.push_remote],
            cwd = self.repo,
            capture_output = true,
        ) catch_all (e) {
            _ => {
                return self.branch(id);
            },
        };
        let owner = github_owner(url.stdout.to_string().trim());
        if (owner.length() == 0) {
            self.branch(id)
        } else {
            `${owner}:${self.branch(id)}`
        }
    }

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

    function bead_row(self, id: string) -> BdRow throws root.machine.Infra {
        let shown = self.tool(root.machine.Trouble.Bd, "bd", ["show", id, "--json"], self.beads);
        let rows = baml.json.decode<BdRow[]>(shown) catch_all (e) {
            _ => {
                self.refuse(root.machine.Trouble.Bd, `bd show ${id}: ${e}`)
            },
        };
        let b = rows.at(0);
        if let row: BdRow = b {
            row
        } else {
            self.refuse(root.machine.Trouble.Bd, `bd show ${id} returned nothing`)
        }
    }

    function bead_text(self, id: string) -> string throws root.machine.Infra {
        let row = self.bead_row(id);
        `<bead id="${id}">\nTITLE: ${row.title}\n\nDESCRIPTION:\n${row.description ?? ""}\n\nACCEPTANCE CRITERIA:\n${row.acceptance_criteria ?? ""}\n</bead>`
    }

    /// Push the bead's branch to the push remote; returns the head pushed.
    function push(self, id: string) -> string throws root.machine.Infra {
        let dir = self.worktree(id);
        let _ = self.tool(
            root.machine.Trouble.Push,
            "git",
            ["push", "-q", "--force-with-lease", "-u", self.push_remote, self.branch(id)],
            dir,
        );
        self.tool(root.machine.Trouble.Git, "git", ["rev-parse", "HEAD"], dir).trim()
    }

    /// The open PR from this bead's branch, or "".
    function open_pr_url(self, id: string) -> string throws root.machine.Infra {
        self
            .tool(
                root.machine.Trouble.Gh,
                "gh",
                self.gh_args(
                    [
                        "pr",
                        "list",
                        "--head",
                        self.branch(id),
                        "--state",
                        "open",
                        "--json",
                        "url",
                        "--jq",
                        ".[0].url // \"\"",
                    ],
                ),
                self.repo,
            )
            .trim()
    }

    /// `owner/name` of the checkout's own GitHub repo.
    function own_repo(self) -> string throws root.machine.Infra {
        self
            .tool(
                root.machine.Trouble.Gh,
                "gh",
                ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                self.repo,
            )
            .trim()
    }

    function bd_rows(self, args: string[]) -> BdRow[] throws root.machine.Infra {
        let text = self.tool(root.machine.Trouble.Bd, "bd", args, self.beads);
        baml.json.decode<BdRow[]>(text) catch_all (e) {
            _ => {
                self.refuse(root.machine.Trouble.Bd, `bd ${args.at(0) ?? ""}: ${e}`)
            },
        }
    }

    implements World {
        function tickets(self) -> Ticket[] throws root.machine.Infra {
            let ready = self.bd_rows(["ready", "-l", self.label, "--json", "-n", "0"]);
            // What the loop already carries: it set them in_progress when it picked them,
            // so `bd ready` no longer lists them (docs/state-machine.md, The bead in bd).
            let carried = self.bd_rows(["list", "-l", self.label, "--status", "in_progress", "--json", "-n", "0"]);
            ticket_rows(ready, carried)
                .filter((r) -> {
                    takes(r.labels ?? [], self.only, self.skip)
                })
                .map((r) -> {
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
            // A fresh round starts from the base: a worktree left by research goes first.
            if (!resume && there) {
                let _ = baml.sys.run(
                    "git",
                    args = ["worktree", "remove", "--force", dir],
                    cwd = self.repo,
                    capture_output = true,
                ) catch_all (e) {
                    _ => null,
                };
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
            if (!resume && self.setup.length() > 0) {
                let out = baml.sys.shell(
                    self.setup,
                    cwd = dir,
                    capture_output = true,
                    timeout = baml.time.Duration.from_seconds(1800),
                ) catch_all (e) {
                    _ => {
                        self.refuse(root.machine.Trouble.Setup, `setup did not finish: ${e}`)
                    },
                };
                if (out.exit_code != 0) {
                    let said = root.tools.tail(out.stderr.to_string() + out.stdout.to_string());
                    self.refuse(root.machine.Trouble.Setup, `setup failed: ${said}`);
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
                base_url: self.urls.get(provider_of(model)) ?? "",
                precheck: self.precheck,
                precheck_url: self.urls.get(provider_of(self.precheck)) ?? "",
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
                    out.push(
                        RoundRunning {
                            id: name,
                            kind: self.kind_of(name),
                            model: self.model_of(name),
                        },
                    );
                }
            }
            out
        }

        function take_finished(self) -> RoundDone[] throws root.machine.Infra {
            let out: RoundDone[] = [];
            for (let name in self.names_in(self.rounds(), ".timedout")) {
                let kind = self.kind_of(name);
                out.push(
                    RoundDone {
                        id: name,
                        kind: kind,
                        events: [timed_out(kind, self.limit_of(kind))],
                    },
                );
                let _ = baml.fs.remove(`${self.rounds()}/${name}.timedout`) catch_all (e) {
                    _ => null,
                };
                let _ = baml.fs.remove(`${self.rounds()}/${name}.pid`) catch_all (e) {
                    _ => null,
                };
            }
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
            let next = next_watch(prev, situation, now, view, events);
            next.feedback_at = prev.feedback_at;
            if (self.feedback) {
                let said = self.comments(pr);
                let fresh = feedback_of(said, self.login(), prev.feedback_at);
                next.feedback_at = newest_comment(said, prev.feedback_at ?? "");
                if let f: root.machine.Feedback = fresh {
                    events.push(f);
                }
            }
            self.save_watch(id, next);
            events
        }

        function push_and_open_pr(
            self,
            id: string,
        ) -> root.machine.PrOpened throws root.machine.Infra {
            let head = self.push(id);
            let existing = self.open_pr_url(id);
            let url = if (existing.length() > 0) {
                existing
            } else {
                let row = self.bead_row(id);
                let title = if (self.pr_style == "plain") {
                    row.title
                } else {
                    `${id}: ${row.title}`
                };
                let body = if (self.pr_style == "plain") {
                    row.description ?? ""
                } else {
                    `${self.bead_text(id)}\n\nOpened by bead-loop.`
                };
                self
                    .tool(
                        root.machine.Trouble.Gh,
                        "gh",
                        self.gh_args(
                            [
                                "pr",
                                "create",
                                "--head",
                                self.head_ref(id),
                                "--base",
                                self.base,
                                "--title",
                                title,
                                "--body",
                                body,
                            ],
                        ),
                        self.repo,
                    )
                    .trim()
            };
            root.machine.PrOpened { kind: "pr_opened", url: url, head: head }
        }

        function push_branch(
            self,
            id: string,
        ) -> root.machine.BranchPushed throws root.machine.Infra {
            let _ = self.push(id);
            let existing = self.open_pr_url(id);
            if (existing.length() > 0) {
                return root.machine.BranchPushed { kind: "branch_pushed", compare_url: existing };
            }
            let repo = if (self.pr_repo.length() > 0) {
                self.pr_repo
            } else {
                self.own_repo()
            };
            root.machine.BranchPushed {
                kind: "branch_pushed",
                compare_url: `https://github.com/${repo}/compare/${self.base}...${self.head_ref(id)}?expand=1`,
            }
        }

        function merge_pr(self, id: string) -> void throws root.machine.Infra {
            let _ = self.tool(
                root.machine.Trouble.MergeRefused,
                "gh",
                self.gh_args(["pr", "merge", self.branch(id), "--squash", "--delete-branch"]),
                self.repo,
            );
        }

        function update_branch(self, id: string) -> void throws root.machine.Infra {
            let _ = self.tool(
                root.machine.Trouble.Gh,
                "gh",
                self.gh_args(["pr", "update-branch", self.branch(id)]),
                self.repo,
            );
        }

        function relabel(self, id: string) -> void throws root.machine.Infra {
            let pr = self.branch(id);
            let _ = baml.sys.run(
                "gh",
                args = self.gh_args(["pr", "edit", pr, "--remove-label", self.merge_label]),
                cwd = self.repo,
                capture_output = true,
            ) catch_all (e) {
                _ => null,
            };
            let _ = self.tool(
                root.machine.Trouble.Gh,
                "gh",
                self.gh_args(["pr", "edit", pr, "--add-label", self.merge_label]),
                self.repo,
            );
        }

        function delete_remote_branch(self, id: string) -> void throws never {
            let _ = baml.sys.run(
                "git",
                args = ["push", "-q", self.push_remote, "--delete", self.branch(id)],
                cwd = self.repo,
                capture_output = true,
            ) catch_all (e) {
                _ => null,
            };
        }

        function note(self, id: string, text: string) -> void throws root.machine.Infra {
            let _ = self.tool(root.machine.Trouble.Bd, "bd", ["note", id, `bead-loop: ${text}`], self.beads);
        }

        function set_status(self, id: string, status: string) -> void throws root.machine.Infra {
            let _ = self.tool(root.machine.Trouble.Bd, "bd", ["update", id, "--status", status], self.beads);
        }

        function close_bead(self, id: string, url: string?) -> void throws root.machine.Infra {
            let _ = self.tool(
                root.machine.Trouble.Bd,
                "bd",
                ["close", id, "--reason", url ?? "merged"],
                self.beads,
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

        function adoptable(self) -> Adoptable[] throws root.machine.Infra {
            let text = self.tool(
                root.machine.Trouble.Gh,
                "gh",
                self.gh_args(
                    [
                        "pr",
                        "list",
                        "--state",
                        "open",
                        "--limit",
                        "200",
                        "--json",
                        "headRefName,url,author",
                    ],
                ),
                self.repo,
            );
            let rows = baml.json.decode<PrRow[]>(text) catch_all (e) {
                _ => {
                    self.refuse(root.machine.Trouble.Gh, `gh pr list: ${e}`)
                },
            };
            adoptable_of(rows, self.login())
        }

        function inbox(self) -> Mail[] throws never {
            read_inbox(self.state)
        }
    }

    function launch(self, id: string, spec: root.rounds.RoundSpec) -> void {
        let spec_file = `${self.rounds()}/${id}.spec.json`;
        let _ = baml.fs.write(spec_file, baml.json.stringify(spec));
        let _ = baml.sys.run("mkdir", args = ["-p", `${self.repo}/.baml/btel`]) catch_all (e) {
            _ => null,
        };
        let bwrap = if (self.sandbox) {
            bwrap_path()
        } else {
            ""
        };
        let argv = round_argv(bwrap, self.agent_bin, spec_file, spec.dir, self.repo, self.state);
        let seconds = if (spec.kind == RoundKind.Research) {
            self.research_seconds
        } else {
            self.work_seconds
        };
        // subprocess does not search PATH, so the shell is named by its path.
        let child = baml.sys.subprocess(
            "/bin/sh",
            args = timed_argv(argv, seconds, `${self.rounds()}/${id}.timedout`),
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
            return Watch {
                green_since: 0,
                quiet_since: 0,
                red_since: 0,
                rerun_head: "",
                feedback_at: null,
            };
        }
        baml.json.decode<Watch>(text) catch_all (e) {
            _ => {
                Watch {
                    green_since: 0,
                    quiet_since: 0,
                    red_since: 0,
                    rerun_head: "",
                    feedback_at: null,
                }
            },
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

    /// The PR's reviews and comments, as gh gives them; "" when gh cannot say.
    function comments(self, pr: string) -> string throws never {
        let out = baml.sys.run(
            "gh",
            args = ["pr", "view", pr, "--json", "reviews,comments"],
            cwd = self.repo,
            capture_output = true,
        ) catch_all (e) {
            _ => {
                return "";
            },
        };
        if (out.exit_code == 0) {
            out.stdout.to_string()
        } else {
            ""
        }
    }

    /// The account the loop acts as: its own comments are not feedback. Asked once.
    function login(self) -> string throws never {
        let path = `${self.state}/gh-login`;
        let known = baml.fs.read(path) catch_all (e) {
            _ => "",
        };
        if (known.trim().length() > 0) {
            return known.trim();
        }
        let out = baml.sys.run("gh", args = ["api", "user", "--jq", ".login"], capture_output = true) catch_all (e) {
            _ => {
                return "";
            },
        };
        let me = out.stdout.to_string().trim();
        if (out.exit_code == 0 && me.length() > 0) {
            let _ = baml.fs.write(path, me) catch_all (e) {
                _ => null,
            };
        }
        me
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

    function limit_of(self, kind: RoundKind) -> int throws never {
        if (kind == RoundKind.Research) {
            self.research_seconds
        } else {
            self.work_seconds
        }
    }

    function model_of(self, id: string) -> string throws never {
        let spec = self.read_spec(id) catch_all (e) {
            _ => {
                return "";
            },
        };
        spec.model
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
    /// The newest review comment already seen; null until the PR is first read.
    feedback_at: string?,
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
        feedback_at: prev.feedback_at,
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
    let prev = Watch { green_since: 0, quiet_since: 0, red_since: 0, rerun_head: "", feedback_at: null };
    let view = view_of(
        `{"url":"u","state":"OPEN","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}`,
    );
    let next = next_watch(prev, "green", 1000, view, []);
    assert.equal(next.green_since, 1000);
    assert.equal(age(next.green_since, true, 2800), 1800)
}

class PrRow {
    headRefName: string,
    url: string,
    author: Login?,
}

/// The open PRs whose branch is `bead/ID`, as the bead they deliver.
function adoptable_of(rows: PrRow[], me: string) -> Adoptable[] throws never {
    let out: Adoptable[] = [];
    for (let r in rows) {
        if (r.headRefName.starts_with("bead/")) {
            let own = me.length() > 0 && (r.author?.login ?? "") == me;
            out.push(
                Adoptable {
                    id: r.headRefName.slice(5, r.headRefName.length()),
                    url: r.url,
                    own: own,
                },
            );
        }
    }
    out
}

test "only bead branches are adoptable" {
    let rows = baml.json.decode<PrRow[]>(
        `[{"headRefName":"bead/bl-1.2","url":"u1","author":{"login":"me"}},{"headRefName":"claude/x","url":"u2"},{"headRefName":"bead/bl-9","url":"u3","author":{"login":"you"}}]`,
    );
    let a = adoptable_of(rows, "me");
    assert.equal(a.length(), 2);
    assert.equal(a.at(0)?.id, "bl-1.2");
    assert.equal(a.at(0)?.own, true);
    assert.equal(a.at(1)?.own, false)
}

/// `STATE/inbox/*.json`, each one Mail, removed once read. `bead-supervisor tell`
/// writes them; a file that does not parse is left for you to look at.
function read_inbox(state: string) -> Mail[] throws never {
    let dir = `${state}/inbox`;
    let out: Mail[] = [];
    let listing = baml.sys.run("ls", args = [dir], capture_output = true) catch_all (e) {
        _ => {
            return out;
        },
    };
    for (let f in listing.stdout.to_string().split("\n")) {
        if (f.ends_with(".json")) {
            let path = `${dir}/${f}`;
            let text = baml.fs.read(path) catch_all (e) {
                _ => "",
            };
            let mail = baml.json.decode<Mail>(text) catch_all (e) {
                _ => null,
            };
            if let m: Mail = mail {
                out.push(m);
                let _ = baml.fs.remove(path) catch_all (e) {
                    _ => null,
                };
            }
        }
    }
    out
}

/// Whether a world takes a bead with these labels: a target only its `work:NAME`, the
/// repo itself none that a target takes.
function takes(labels: string[], only: string, skip: string) -> bool throws never {
    let wanted = only.length() == 0 || labels.includes(only);
    let left = skip.length() > 0
        && labels.some((l) -> {
            l.starts_with(skip)
        });
    wanted && !left
}

/// `imkarrer` from `git@github.com:imkarrer/euclid.git` or `https://github.com/imkarrer/euclid`.
function github_owner(url: string) -> string throws never {
    let rest = if (url.includes("github.com:")) {
        url.split("github.com:").at(1) ?? ""
    } else {
        url.split("github.com/").at(1) ?? ""
    };
    rest.split("/").at(0) ?? ""
}

test "a target takes its own beads and the repo leaves them alone" {
    assert.equal(takes(["delegate:local", "work:lektor"], "work:lektor", ""), true);
    assert.equal(takes(["delegate:local"], "work:lektor", ""), false);
    assert.equal(takes(["delegate:local", "work:lektor"], "", "work:"), false);
    assert.equal(takes(["delegate:local", "phase:P0"], "", "work:"), true)
}

test "a fork's owner comes from its remote" {
    assert.equal(github_owner("git@github.com:imkarrer/euclid.git"), "imkarrer");
    assert.equal(github_owner("https://github.com/imkarrer/euclid"), "imkarrer")
}

/// The server a model runs on: `devbox/coder` is `devbox`.
function provider_of(model: string) -> string throws never {
    model.split("/").at(0) ?? model
}

class Login {
    login: string,
}

class ReviewRow {
    author: Login?,
    body: string?,
    state: string?,
    submittedAt: string?,
}

class CommentRow {
    author: Login?,
    body: string?,
    createdAt: string?,
}

class PrComments {
    reviews: ReviewRow[]?,
    comments: CommentRow[]?,
}

class Said {
    who: string,
    body: string,
    at: string,
}

/// Every review and comment with a body, as who said what when.
function said_of(text: string) -> Said[] throws never {
    let none: Said[] = [];
    let c = baml.json.decode<PrComments>(text) catch_all (e) {
        _ => {
            return none;
        },
    };
    let out: Said[] = [];
    for (let r in c.reviews ?? []) {
        let body = (r.body ?? "").trim();
        if (body.length() > 0 || r.state == "CHANGES_REQUESTED") {
            out.push(Said { who: r.author?.login ?? "", body: body, at: r.submittedAt ?? "" });
        }
    }
    for (let m in c.comments ?? []) {
        let body = (m.body ?? "").trim();
        if (body.length() > 0) {
            out.push(Said { who: m.author?.login ?? "", body: body, at: m.createdAt ?? "" });
        }
    }
    out
}

/// The newest time among the comments, or `since` when none is newer.
function newest_comment(text: string, since: string) -> string throws never {
    let newest = since;
    for (let s in said_of(text)) {
        if (s.at > newest) {
            newest = s.at;
        }
    }
    newest
}

/// What others said after `since`, as one Feedback. The first look at a PR (`since`
/// null) only marks the comments already there as seen: they were answered, or not
/// meant for the loop, before it watched.
function feedback_of(
    text: string,
    me: string,
    since: string?,
) -> root.machine.Feedback? throws never {
    if let after: string = since {
        let fresh = said_of(text).filter((s) -> {
            s.at > after && s.who != me && s.who.length() > 0 && !s.who.ends_with("[bot]")
        });
        if (fresh.length() == 0) {
            return null;
        }
        let text_of = fresh
            .map((s) -> {
                `${s.who}: ${s.body}`
            })
            .join("\n\n");
        root.machine.Feedback { kind: "feedback", text: text_of, at: newest_comment(text, after) }
    } else {
        null
    }
}

const COMMENTS_SAMPLE: string = `{"reviews":[{"author":{"login":"brownnrl"},"body":"","state":"CHANGES_REQUESTED","submittedAt":"2026-11-01T10:00:00Z"},{"author":{"login":"imkarrer"},"body":"thanks","state":"COMMENTED","submittedAt":"2026-11-01T11:00:00Z"}],"comments":[{"author":{"login":"brownnrl"},"body":"please keep the caption under twenty words","createdAt":"2026-11-02T09:00:00Z"},{"author":{"login":"buildkite[bot]"},"body":"build passed","createdAt":"2026-11-02T09:30:00Z"}]}`;

test "the first look at a PR marks its comments seen and acts on none" {
    assert.equal(feedback_of(COMMENTS_SAMPLE, "imkarrer", null) == null, true);
    assert.equal(newest_comment(COMMENTS_SAMPLE, ""), "2026-11-02T09:30:00Z")
}

test "comments from others after the mark are feedback; the loop's own and bots' are not" {
    let f = feedback_of(COMMENTS_SAMPLE, "imkarrer", "2026-11-01T10:30:00Z");
    assert.is_type<root.machine.Feedback>(f);
    assert.contains(f?.text ?? "", "brownnrl: please keep the caption");
    assert.equal((f?.text ?? "").includes("thanks"), false);
    assert.equal((f?.text ?? "").includes("build passed"), false);
    assert.equal(feedback_of(COMMENTS_SAMPLE, "imkarrer", "2026-11-02T09:30:00Z") == null, true)
}

/// The round under `timeout`: past `seconds` it and everything it started are stopped
/// (TERM, then KILL thirty seconds on), and `marker` says it was the clock, not a crash.
function timed_argv(argv: string[], seconds: int, marker: string) -> string[] throws never {
    let out = [
        "-c",
        "m=$1; s=$2; shift 2; timeout -k 30 \"$s\" \"$@\"; rc=$?; if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then : >\"$m\"; fi; exit $rc",
        "round",
        marker,
        `${seconds}`,
    ];
    for (let a in argv) {
        out.push(a);
    }
    out
}

/// What a round that ran out of time comes to. A worker's is the model's failure, as in
/// the Rust loop; a reviewer's is held, since no verdict is nothing from the model; a
/// researcher's lets the worker go without a brief.
function timed_out(kind: RoundKind, seconds: int) -> root.machine.Event throws never {
    match (kind) {
        RoundKind.Work => root.machine.RoundTimedOut { kind: "round_timed_out" },
        RoundKind.Review => {
            root.machine.Infra {
                kind: "infra",
                what: root.machine.Trouble.Harness,
                words: `the reviewer returned no verdict in ${seconds}s`,
            }
        },
        RoundKind.Research => {
            root.machine.BriefWritten { kind: "brief_written", overruled: false, text: "" }
        },
    }
}

test "a timed-out round marks itself, and only on the clock" {
    let argv = timed_argv(["bin", "round", "--spec_file", "s"], 5, "/r/t-1.timedout");
    assert.equal(argv.at(2), "round");
    assert.equal(argv.at(3), "/r/t-1.timedout");
    assert.equal(argv.at(4), "5");
    assert.equal(argv.at(5), "bin");
    let dir = root.tools.scratch("timed-test");
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
    let _ = baml.sys.run("mkdir", args = ["-p", dir]);
    let slow = baml.sys.run("sh", args = timed_argv(["sleep", "5"], 1, `${dir}/slow.timedout`));
    assert.equal(baml.fs.exists(`${dir}/slow.timedout`), true);
    let quick = baml.sys.run("sh", args = timed_argv(["false"], 5, `${dir}/quick.timedout`));
    assert.equal(baml.fs.exists(`${dir}/quick.timedout`), false)
}

test "a timeout charges a worker, holds a reviewer, and frees a researcher" {
    assert.is_type<root.machine.RoundTimedOut>(timed_out(RoundKind.Work, 1));
    assert.is_type<root.machine.Infra>(timed_out(RoundKind.Review, 1));
    assert.is_type<root.machine.BriefWritten>(timed_out(RoundKind.Research, 1));
}

/// The beads the loop may work: what `bd ready` lists, then what it already carries.
function ticket_rows(ready: BdRow[], carried: BdRow[]) -> BdRow[] throws never {
    let out = ready;
    let ids = ready.map((r) -> {
        r.id
    });
    for (let r in carried) {
        if (!ids.includes(r.id)) {
            out.push(r);
        }
    }
    out
}

test "the queue is the ready beads and the ones the loop carries, each once" {
    let a = BdRow { id: "t-1", title: "a", description: null, acceptance_criteria: null, labels: null };
    let b = BdRow { id: "t-2", title: "b", description: null, acceptance_criteria: null, labels: null };
    let rows = ticket_rows([a], [a, b]);
    assert.equal(
        rows
            .map((r) -> {
                r.id
            })
            .join(","),
        "t-1,t-2",
    )
}
