// The supervisor end to end, on a FakeWorld with scripted rounds: no model, no git, no gh.

function ticket(id: string) -> root.world.Ticket throws never {
    root.world.Ticket { id: id, title: "t", description: "d", acceptance: "a" }
}

function committed() -> root.machine.Event[] throws never {
    [
        root.machine.Committed { kind: "committed", sha: "s" },
        root.machine.GatePassed { kind: "gate_passed" },
    ]
}

function approved() -> root.machine.Event[] throws never {
    [root.machine.Approved { kind: "approved" }]
}

function rejected() -> root.machine.Event[] throws never {
    [root.machine.Rejected { kind: "rejected", line: "REJECT: a", text: "REJECT: a" }]
}

function no_commit() -> root.machine.Event[] throws never {
    [root.machine.NoCommit { kind: "no_commit" }]
}

function no_verdict() -> root.machine.Event[] throws never {
    [
        root.machine.Infra {
            kind: "infra",
            what: root.machine.Trouble.Harness,
            words: "the reviewer returned no verdict: out of steps",
        },
    ]
}

function green() -> root.machine.Event[] throws never {
    [root.machine.ChecksGreen { kind: "checks_green" }]
}

function merged() -> root.machine.Event[] throws never {
    [root.machine.PrMerged { kind: "pr_merged", url: "pr/t-1" }]
}

function policy() -> root.machine.Policy throws never {
    root.machine.Policy {
        stages: [
            root.machine.Stage {
                name: "local",
                worker: "devbox/coder",
                reviewer: "acbox/reviewer",
                attempts: 2,
            },
            root.machine.Stage {
                name: "frontier",
                worker: "claude/sonnet",
                reviewer: "claude/sonnet",
                attempts: 1,
            },
        ],
        on_exhaust: root.machine.OnExhaust.Park,
        merge: root.machine.MergeMode.Auto,
        second_opinion: true,
        ask_before_pr: false,
        research: "",
        conflict_worker: "",
        update_behind: false,
        brief_model: "",
    }
}

/// A tick, then every running round ends.
function turn(s: Supervisor, w: root.world.FakeWorld) -> void throws never {
    tick(s);
    w.finish();
}

function turns(s: Supervisor, w: root.world.FakeWorld, n: int) -> void throws never {
    let i = 0;
    while (i < n) {
        turn(s, w);
        i = i + 1;
    }
}

function one_bead(
    work: root.machine.Event[][],
    review: root.machine.Event[][],
    pr: root.machine.Event[][],
    research: root.machine.Event[][] = [],
) -> root.world.FakeWorld throws never {
    root.world.FakeWorld.new(
        [ticket("t-1")],
        [root.world.Script { id: "t-1", work: work, review: review, pr: pr, research: research }],
    )
}

function place_of(s: Supervisor) -> root.machine.Place? throws never {
    s.bead("t-1")?.place
}

test "a bead goes from ready to closed" {
    let w = one_bead([committed()], [approved()], [green(), merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 6);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.equal(s.bead("t-1")?.failures, 0);
    assert.is_true(w.calls.includes("merge_pr"));
    assert.is_true(w.calls.includes("close_bead"))
}

test "a rejected bead is fixed and lands, and the worker is the stage's" {
    let w = one_bead([committed(), committed()], [rejected(), approved()], [merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 8);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.equal(s.bead("t-1")?.failures, 1);
    assert.is_true(w.calls.includes("start_round Work devbox/coder"));
    assert.is_true(w.calls.includes("start_round Review acbox/reviewer"))
}

test "the next round is told why the last was sent back" {
    let w = one_bead([committed(), committed()], [rejected(), approved()], [merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 8);
    assert.contains(w.notes_given.at(2) ?? "", "REJECT: a")
}

test "failures walk the stages, then the bead parks with a brief" {
    let w = one_bead([no_commit(), no_commit(), no_commit()], [], []);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 6);
    assert.is_type<root.machine.Parked>(place_of(s));
    assert.is_true(w.calls.includes("start_round Work claude/sonnet"));
    assert.is_true(w.calls.includes("write_park_brief"))
}

test "a world that refuses to start a round holds the bead and charges nothing" {
    let w = one_bead([committed()], [approved()], [merged()]);
    w.failing = ["prepare_worktree"];
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    tick(s);
    assert.not_null(s.bead("t-1")?.hold);
    assert.equal(s.bead("t-1")?.failures, 0)
}

test "a held bead is tried again and lands" {
    let w = one_bead([committed()], [approved()], [merged()]);
    w.failing = ["prepare_worktree"];
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    s.hold_ticks = 2;
    turns(s, w, 9);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.equal(s.bead("t-1")?.failures, 0)
}

test "a no-commit after a reject keeps the branch the worker already landed" {
    let w = one_bead([committed(), no_commit(), committed()], [rejected(), approved()], [green(), merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 12);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.equal(s.bead("t-1")?.failures, 2);
    assert.is_true(!w.calls.includes("remove_branch"))
}

test "a reviewer with no verdict is held and tried again, and nothing is charged" {
    let w = one_bead([committed()], [no_verdict(), approved()], [green(), merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    s.hold_ticks = 1;
    turns(s, w, 8);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.equal(s.bead("t-1")?.failures, 0);
    assert.equal(
        w.calls
            .filter((c) -> {
                c.starts_with("start_round Review")
            })
            .length(),
        2,
    )
}

test "a refused push holds in review and charges nothing" {
    let w = one_bead([committed()], [approved()], [merged()]);
    w.failing = ["push_and_open_pr"];
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 3);
    assert.is_type<root.machine.InReview>(place_of(s));
    assert.equal(s.bead("t-1")?.failures, 0)
}

test "gh failing while watching holds the bead, then the merge is seen" {
    let w = one_bead([committed()], [approved()], [merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    s.hold_ticks = 1;
    turns(s, w, 3);
    w.failing = ["observe_pr"];
    turns(s, w, 3);
    assert.is_type<root.machine.Closed>(place_of(s));
}

test "one lane runs one round, fewest failures first" {
    let w = root.world.FakeWorld.new(
        [ticket("a"), ticket("b")],
        [
            root.world.Script {
                id: "a",
                work: [no_commit(), committed()],
                review: [approved()],
                pr: [],
                research: [],
            },
            root.world.Script {
                id: "b",
                work: [committed()],
                review: [approved()],
                pr: [],
                research: [],
            },
        ],
    );
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    tick(s);
    assert.equal(w.running_now.length(), 1);
    w.finish();
    tick(s);
    assert.equal(w.running_now.at(0)?.id, "b")
}

function briefed() -> root.machine.Event[] throws never {
    [root.machine.BriefWritten { kind: "brief_written", overruled: false, text: "Files:\ncalc.js" }]
}

test "research runs before work when the policy names a researcher" {
    let p = policy();
    p.research = "devbox/coder";
    let w = one_bead([committed()], [approved()], [green(), merged()], research = [briefed()]);
    let s = Supervisor.new(w, MemoryLog.new(), p);
    turns(s, w, 8);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.is_true(w.calls.includes("start_round Research devbox/coder"));
    assert.equal(s.bead("t-1")?.brief, "Files:\ncalc.js")
}

test "a restart folds the log and keeps a running round" {
    let w = one_bead([committed()], [approved()], [merged()]);
    let log = MemoryLog.new();
    let s = Supervisor.new(w, log, policy());
    tick(s);
    let again = recover(w, log, policy());
    assert.is_type<root.machine.Working>(again.bead("t-1")?.place);
    w.finish();
    turns(again, w, 5);
    assert.is_type<root.machine.Closed>(again.bead("t-1")?.place);
    assert.equal(again.bead("t-1")?.failures, 0)
}

test "a round that ended while the loop was down is taken, not lost" {
    let w = one_bead([committed()], [approved()], [merged()]);
    let log = MemoryLog.new();
    let s = Supervisor.new(w, log, policy());
    tick(s);
    w.finish();
    let again = recover(w, log, policy());
    assert.is_type<root.machine.InReview>(again.bead("t-1")?.place);
    assert.is_true(again.bead("t-1")?.kept ?? false)
}

test "a round with no process and no result is lost, and charged to nobody" {
    let w = one_bead([committed()], [approved()], [merged()]);
    let log = MemoryLog.new();
    let s = Supervisor.new(w, log, policy());
    tick(s);
    w.running_now = [];
    let again = recover(w, log, policy());
    assert.is_type<root.machine.Ready>(again.bead("t-1")?.place);
    assert.equal(again.bead("t-1")?.failures, 0)
}

test "a restart loses nothing a bead has been charged" {
    let w = one_bead([no_commit(), committed()], [approved()], [merged()]);
    let log = MemoryLog.new();
    let s = Supervisor.new(w, log, policy());
    turns(s, w, 2);
    let again = recover(w, log, policy());
    assert.equal(again.bead("t-1")?.failures, 1)
}

// Lanes and caps: a lane is a model server, shared by every repo the process ticks.

function two_beads() -> root.world.FakeWorld throws never {
    root.world.FakeWorld.new(
        [ticket("t-1"), ticket("t-2")],
        [
            root.world.Script {
                id: "t-1",
                work: [committed()],
                review: [approved()],
                pr: [],
                research: [],
            },
            root.world.Script {
                id: "t-2",
                work: [committed()],
                review: [approved()],
                pr: [],
                research: [],
            },
        ],
    )
}

function starts(w: root.world.FakeWorld, call: string) -> int throws never {
    w.calls
        .filter((c) -> {
            c == call
        })
        .length()
}

test "one devbox slot takes one bead and the other waits" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    tick(s);
    assert.equal(starts(w, "start_round Work devbox/coder"), 1)
}

test "a server with two slots takes two beads" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    let _ = s.capacity.set("devbox", 2);
    tick(s);
    assert.equal(starts(w, "start_round Work devbox/coder"), 2)
}

test "research on acbox and work on devbox run at once" {
    let w = two_beads();
    let p = policy();
    p.research = "acbox/coder";
    let s = Supervisor.new(w, MemoryLog.new(), p);
    tick(s);
    assert.equal(starts(w, "start_round Research acbox/coder"), 1);
    assert.equal(starts(w, "start_round Work devbox/coder"), 1)
}

test "a round in another repo holds its server's slot" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    s.elsewhere = ["devbox/coder"];
    tick(s);
    assert.equal(starts(w, "start_round Work devbox/coder"), 0)
}

test "max_inflight pauses the dev lane while a PR is in the queue" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    let _ = s.capacity.set("devbox", 2);
    s.max_inflight = 1;
    turns(s, w, 3);
    // t-1 and t-2 both worked at once, both reviewed; then both opened PRs. Nothing new
    // is ready, so the check is the next bead: none is picked while one is in the queue.
    assert.is_true(inflight(s) >= 1);
    assert.is_true(dev_paused(s))
}

test "max_open_prs counts the PRs elsewhere in the group" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    s.max_open_prs = 1;
    s.group_inflight = 1;
    tick(s);
    assert.equal(starts(w, "start_round Work devbox/coder"), 0)
}

test "an adopted PR does not count toward the caps" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    s.max_inflight = 1;
    apply(s, "t-1", root.machine.PrAdopted { kind: "pr_adopted", url: "pr/t-1" });
    assert.equal(inflight(s), 0);
    tick(s);
    assert.equal(starts(w, "start_round Work devbox/coder"), 1)
}

test "a round in one repo holds the server for the next repo in the same pass" {
    let a = two_beads();
    let b = two_beads();
    let sa = Supervisor.new(a, MemoryLog.new(), policy());
    let sb = Supervisor.new(b, MemoryLog.new(), policy());
    sa.group = "a";
    sb.group = "b";
    let _ = tick_all([sa, sb]);
    assert.equal(
        starts(a, "start_round Work devbox/coder") + starts(b, "start_round Work devbox/coder"),
        1,
    )
}

test "an open bead PR the loop did not open is adopted, merged and closed" {
    let w = one_bead([], [], [green(), merged()]);
    w.tickets_now = [];
    w.adoptable_now = [root.world.Adoptable { id: "t-1", url: "pr/t-1", own: false }];
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 3);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.is_true(w.calls.includes("merge_pr"));
    assert.equal(starts(w, "start_round Work devbox/coder"), 0)
}

test "the loop's own PR is not adopted a second time" {
    let w = one_bead([committed()], [approved()], [[], []]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 3);
    let url = s.bead("t-1")?.pr ?? "";
    assert.equal(url, "pr/t-1");
    w.adoptable_now = [root.world.Adoptable { id: "t-1", url: url, own: true }];
    tick(s);
    let m = s.bead("t-1")?.place;
    assert.is_type<root.machine.Merging>(m);
    if let merging: root.machine.Merging = m {
        assert.equal(merging.adopted, false);
    }
}

test "an answer in the inbox takes a parked bead back to ready" {
    let w = one_bead([no_commit(), no_commit(), no_commit()], [], []);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 6);
    assert.is_type<root.machine.Parked>(place_of(s));
    w.inbox_now
        = [
            root.world.Mail {
                id: "t-1",
                event: root.machine.Answered { kind: "answered", text: "use the other file" },
            },
        ];
    tick(s);
    // Back to ready, one failure forgiven, and picked again in the same tick.
    assert.is_type<root.machine.Working>(place_of(s));
    assert.is_true(w.calls.includes("note use the other file"))
}

test "open_pr ask pushes, waits for you to open the PR, then watches it" {
    let w = one_bead([committed()], [approved()], [green(), merged()]);
    let p = policy();
    p.ask_before_pr = true;
    p.merge = root.machine.MergeMode.External;
    let s = Supervisor.new(w, MemoryLog.new(), p);
    turns(s, w, 3);
    assert.is_type<root.machine.Publishable>(place_of(s));
    assert.is_true(w.calls.includes("push_branch"));
    assert.equal(w.calls.includes("push_and_open_pr"), false);
    w.adoptable_now = [root.world.Adoptable { id: "t-1", url: "pr/t-1", own: false }];
    turns(s, w, 2);
    assert.is_type<root.machine.Closed>(place_of(s));
    assert.equal(w.calls.includes("merge_pr"), false)
}

test "a usage limit on claude holds every claude round, and nothing else" {
    let w = two_beads();
    let p = policy();
    p.stages
        = [
            root.machine.Stage {
                name: "frontier",
                worker: "claude/sonnet",
                reviewer: "claude/sonnet",
                attempts: 1,
            },
        ];
    let s = Supervisor.new(w, MemoryLog.new(), p);
    let _ = s.capacity.set("claude", 2);
    admit_tickets(s);
    apply(
        s,
        "t-1",
        root.machine.Infra {
            kind: "infra",
            what: root.machine.Trouble.SignedOut,
            words: "usage limit on claude: resets 7:40am",
        },
    );
    start_rounds(s);
    assert.equal(starts(w, "start_round Work claude/sonnet"), 0);
    assert.equal(lane_free(s, [], "devbox/coder"), true)
}

test "a ready bead that left bd ready is not picked" {
    let w = one_bead([no_commit(), committed()], [approved()], [green(), merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turn(s, w);
    // Sent back by the no-commit, then closed or blocked by hand.
    w.tickets_now = [];
    turn(s, w);
    assert.is_type<root.machine.Ready>(place_of(s));
    assert.equal(starts(w, "start_round Work devbox/coder"), 1)
}

test "a world that cannot list its beads keeps the last list" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    w.failing = ["tickets"];
    s.ready = ["t-1"];
    admit_tickets(s);
    assert.equal(s.ready.join(","), "t-1")
}

test "a folder with no log is not a bead of this loop's" {
    let state = root.tools.scratch("filelog-test");
    let _ = baml.sys.run("rm", args = ["-rf", state]);
    let _ = baml.sys.run("mkdir", args = ["-p", `${state}/beads/rust-only`]);
    let log = FileLog { state: state };
    log.append("t-1", root.machine.Picked { kind: "picked" });
    assert.equal(log.ids().join(","), "t-1")
}

test "a rebase round goes to the last stage's worker, or the conflict worker" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    let b = root.machine.Bead.new("t-1");
    b.order = root.machine.Order.Rebase;
    assert.equal(worker_of(s, b), "claude/sonnet");
    s.policy.conflict_worker = "acbox/coder";
    assert.equal(worker_of(s, b), "acbox/coder");
    b.order = root.machine.Order.Fresh;
    assert.equal(worker_of(s, b), "devbox/coder")
}

test "update_behind is on under auto unless the files say otherwise" {
    let auto = config_from_toml("merge = \"auto\"\n", "", "/r", "/s", "b");
    assert.equal(auto.policy.update_behind, true);
    let pipe = config_from_toml("merge = \"pipeline\"\n", "", "/r", "/s", "b");
    assert.equal(pipe.policy.update_behind, false);
    let ext = config_from_toml("merge = \"external\"\nupdate_behind = true\n", "", "/r", "/s", "b");
    assert.equal(ext.policy.update_behind, true)
}

test "a PR the loop's own account opened before a cutover counts as its own" {
    let w = two_beads();
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    s.max_open_prs = 1;
    w.adoptable_now = [root.world.Adoptable { id: "t-1", url: "pr/t-1", own: true }];
    tick(s);
    assert.equal(inflight(s), 1);
    assert.equal(starts(w, "start_round Work devbox/coder"), 0)
}

test "a round that died with no result is lost and started again, uncharged" {
    let w = one_bead([committed()], [approved()], [green(), merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    tick(s);
    assert.is_type<root.machine.Working>(place_of(s));
    // The process is gone, and it wrote nothing.
    w.running_now = [];
    tick(s);
    assert.equal(s.bead("t-1")?.failures, 0);
    assert.equal(starts(w, "start_round Work devbox/coder"), 2)
}

test "the bead in bd says what the loop is doing: in_progress, blocked, open again" {
    let w = one_bead([no_commit(), no_commit(), no_commit()], [], []);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 6);
    assert.is_type<root.machine.Parked>(place_of(s));
    assert.is_true(w.calls.includes("status t-1 in_progress"));
    assert.is_true(w.calls.includes("status t-1 blocked"));
    w.inbox_now = [root.world.Mail { id: "t-1", event: root.machine.Reopened { kind: "reopened" } }];
    tick(s);
    assert.is_true(w.calls.includes("status t-1 open"))
}

test "a status is written on a move, not on every event" {
    let ready = root.machine.Ready { kind: "ready" };
    let working = root.machine.Working { kind: "working", committed: false };
    let parked = root.machine.Parked { kind: "parked", question: "q" };
    assert.equal(status_change(ready, working), "in_progress");
    assert.equal(status_change(working, ready) == null, true);
    assert.equal(status_change(working, parked), "blocked");
    assert.equal(status_change(parked, parked) == null, true);
    assert.equal(status_change(parked, ready), "open");
    assert.equal(status_change(working, root.machine.Closed { kind: "closed" }) == null, true)
}

test "a bead waiting for review that left bd waits where it is" {
    let w = one_bead([committed()], [approved()], [green(), merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    w.calls = [];
    tick(s);
    w.tickets_now = [];
    w.finish();
    turn(s, w);
    assert.is_type<root.machine.InReview>(place_of(s));
    assert.equal(starts(w, "start_round Review acbox/reviewer"), 0)
}

test "every move is on the bead in bd as its loop label" {
    let w = one_bead([committed()], [approved()], [green(), merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 6);
    assert.is_type<root.machine.Closed>(place_of(s));
    for (let l in ["loop:work", "loop:review-queue", "loop:review", "loop:merging"]) {
        assert.is_true(w.calls.includes(`label t-1 ${l}`));
    }
    assert.equal(
        place_label(root.machine.Publishable { kind: "publishable", compare_url: "u" }),
        "loop:ready-for-pr",
    )
}

test "a parked bead with its work done is pushed, then opened as the PR you asked for" {
    let w = one_bead([no_commit(), no_commit(), no_commit()], [], []);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    turns(s, w, 6);
    assert.is_type<root.machine.Parked>(place_of(s));
    w.inbox_now
        = [root.world.Mail { id: "t-1", event: root.machine.Published { kind: "published" } }];
    tick(s);
    assert.is_type<root.machine.Publishable>(place_of(s));
    assert.is_true(w.calls.includes("label t-1 loop:ready-for-pr"));
    assert.equal(
        status_change(
            root.machine.Parked { kind: "parked", question: "q" },
            root.machine.Publishable { kind: "publishable", compare_url: "u" },
        ),
        "in_progress",
    );
    w.inbox_now
        = [
            root.world.Mail {
                id: "t-1",
                event: root.machine.PrRequested { kind: "pr_requested", title: "T", body: "B" },
            },
        ];
    tick(s);
    assert.is_type<root.machine.Merging>(place_of(s));
    assert.is_true(w.calls.includes("push_and_open_pr"))
}

test "each tick the supervisor writes what the page shows: its beads, from its own state" {
    let w = one_bead([no_commit(), no_commit(), no_commit()], [], []);
    let log = MemoryLog.new();
    let s = Supervisor.new(w, log, policy());
    tick(s);
    let running = baml.json.decode<View>(log.view);
    assert.equal(running.beads.at(0)?.place, "running");
    assert.equal(running.beads.at(0)?.step, "work");
    assert.equal(running.beads.at(0)?.title, "t");
    w.finish();
    turns(s, w, 6);
    let parked = baml.json.decode<View>(log.view);
    assert.equal(parked.beads.at(0)?.place, "parked");
    assert.equal(parked.tallies.length(), 1)
}

test "a bead that left bd ready is not shown waiting in a queue" {
    let w = one_bead([no_commit(), committed()], [approved()], [green(), merged()]);
    let log = MemoryLog.new();
    let s = Supervisor.new(w, log, policy());
    turn(s, w);
    w.tickets_now = [];
    tick(s);
    assert.equal(baml.json.decode<View>(log.view).beads.length(), 0)
}

test "an abort or a note in the inbox is the supervisor's to carry out" {
    let w = one_bead([committed()], [approved()], [merged()]);
    let s = Supervisor.new(w, MemoryLog.new(), policy());
    w.inbox_now
        = [
            root.world.Mail {
                id: "t-1",
                event: null,
                order: root.world.AbortOrder { kind: "abort" },
            },
            root.world.Mail {
                id: "t-1",
                event: null,
                order: root.world.NoteOrder { kind: "note", text: "use b.ts" },
            },
        ];
    tick(s);
    assert.is_true(w.calls.includes("abort t-1"));
    assert.is_true(w.calls.includes("note operator: use b.ts"))
}
