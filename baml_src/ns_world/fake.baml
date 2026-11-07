// A World for tests: rounds and PRs follow a script, and every call is recorded. Each
// entry of a script is one round's or one observation's events.

class Script {
    id: string,
    work: root.machine.Event[][],
    review: root.machine.Event[][],
    pr: root.machine.Event[][],
}

class FakeWorld {
    tickets_now: Ticket[],
    scripts: Script[],
    running_now: RoundRunning[],
    finished_now: RoundDone[],
    calls: string[],
    /// Calls that throw, by name, each used up once.
    failing: string[],

    function new(tickets: Ticket[], scripts: Script[]) -> FakeWorld throws never {
        FakeWorld {
            tickets_now: tickets,
            scripts: scripts,
            running_now: [],
            finished_now: [],
            calls: [],
            failing: [],
        }
    }

    function record(self, call: string) -> void throws root.machine.Infra {
        self.calls.push(call);
        let at = self.failing.index_of(call);
        if (at != null) {
            let rest: string[] = [];
            let i = 0;
            while (i < self.failing.length()) {
                if (i != at) {
                    rest.push(self.failing.at(i) ?? "");
                }
                i = i + 1;
            }
            self.failing = rest;
            throw root.machine.Infra { kind: "infra", what: root.machine.Trouble.Gh, words: `${call} refused` }
        }
    }

    function script_of(self, id: string) -> Script? throws never {
        self.scripts.find((s) -> { s.id == id })
    }

    /// Ends a running round now, for tests that run a round across ticks.
    function finish(self) -> void throws never {
        for (let r in self.running_now) {
            let s = self.script_of(r.id);
            let queue = if (r.kind == RoundKind.Work) { s?.work } else { s?.review };
            let events = queue?.shift() ?? [];
            self.finished_now.push(RoundDone { id: r.id, kind: r.kind, events: events });
        }
        self.running_now = [];
    }

    implements World {
        function tickets(self) -> Ticket[] throws root.machine.Infra {
            self.record("tickets");
            self.tickets_now
        }
        function prepare_worktree(self, id: string, resume: bool) -> void throws root.machine.Infra {
            self.record("prepare_worktree");
        }
        function remove_branch(self, id: string) -> void throws root.machine.Infra {
            self.record("remove_branch");
        }
        function start_round(self, id: string, kind: RoundKind, model: string) -> void throws root.machine.Infra {
            self.record(`start_round ${kind} ${model}`);
            self.running_now.push(RoundRunning { id: id, kind: kind });
        }
        function running(self) -> RoundRunning[] throws never {
            self.running_now
        }
        function take_finished(self) -> RoundDone[] throws never {
            let done = self.finished_now;
            self.finished_now = [];
            done
        }
        function observe_pr(self, id: string, pr: string) -> root.machine.Event[] throws root.machine.Infra {
            self.record("observe_pr");
            self.script_of(id)?.pr?.shift() ?? []
        }
        function push_and_open_pr(self, id: string) -> root.machine.PrOpened throws root.machine.Infra {
            self.record("push_and_open_pr");
            root.machine.PrOpened { kind: "pr_opened", url: `pr/${id}`, head: "head" }
        }
        function merge_pr(self, id: string) -> void throws root.machine.Infra {
            self.record("merge_pr");
        }
        function update_branch(self, id: string) -> void throws root.machine.Infra {
            self.record("update_branch");
        }
        function relabel(self, id: string) -> void throws root.machine.Infra {
            self.record("relabel");
        }
        function delete_remote_branch(self, id: string) -> void throws root.machine.Infra {
            self.record("delete_remote_branch");
        }
        function note(self, id: string, text: string) -> void throws never {
            self.calls.push(`note ${text}`);
        }
        function close_bead(self, id: string, url: string?) -> void throws root.machine.Infra {
            self.record("close_bead");
        }
        function write_park_brief(self, id: string, because: string) -> void throws root.machine.Infra {
            self.record("write_park_brief");
        }
    }
}
