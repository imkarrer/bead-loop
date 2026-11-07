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
    let w = one_bead(
        [committed(), no_commit(), committed()],
        [rejected(), approved()],
        [green(), merged()],
    );
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
    [
        root.machine.BriefWritten {
            kind: "brief_written",
            overruled: false,
            text: "Files:\ncalc.js",
        },
    ]
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
