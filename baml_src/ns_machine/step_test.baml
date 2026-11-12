// The outcome table of docs/state-machine.md, a test per row, each named for its row.
// Rows about reading the world (a skipped build, a check's required-ness) belong to the
// observation layer and are listed at the bottom.

function policy() -> Policy throws never {
    Policy {
        stages: [
            Stage { name: "local", worker: "devbox/coder", reviewer: "acbox/reviewer", attempts: 2 },
            Stage {
                name: "frontier",
                worker: "claude/sonnet",
                reviewer: "claude/sonnet",
                attempts: 1,
            },
        ],
        on_exhaust: OnExhaust.Park,
        merge: MergeMode.Pipeline,
        second_opinion: true,
        ask_before_pr: false,
        research: "",
        conflict_worker: "",
        update_behind: false,
        brief_model: "",
    }
}

function with_merge(mode: MergeMode) -> Policy throws never {
    let p = policy();
    p.merge = mode;
    p
}

function bead(place: Place, failures: int = 0) -> Bead throws never {
    let b = Bead.new("t-1").at(place);
    b.failures = failures;
    b
}

function ready() -> Place throws never {
    Ready { kind: "ready" }
}

function working() -> Place throws never {
    Working { kind: "working", committed: false }
}

function committed_work() -> Place throws never {
    Working { kind: "working", committed: true }
}

function reviewing() -> Place throws never {
    Reviewing { kind: "reviewing" }
}

function in_review() -> Place throws never {
    InReview { kind: "in_review" }
}

function researching() -> Place throws never {
    Researching { kind: "researching" }
}

function merging() -> Place throws never {
    Merging { kind: "merging", pr: "pr/1", adopted: false }
}

function adopted() -> Place throws never {
    Merging { kind: "merging", pr: "pr/1", adopted: true }
}

function parked() -> Place throws never {
    Parked { kind: "parked", question: "q" }
}

function infra(what: Trouble) -> Event throws never {
    Infra { kind: "infra", what: what, words: "the words" }
}

function removes(s: Step) -> bool throws never {
    s.effects.some((e) -> {
        e is RemoveBranch
    })
}

function briefs(s: Step) -> bool throws never {
    s.effects.some((e) -> {
        e is WriteParkBrief
    })
}

function refuses(s: Step) -> bool throws never {
    s.effects.some((e) -> {
        e is Refuse
    })
}

function relabels(s: Step) -> bool throws never {
    s.effects.some((e) -> {
        e is Relabel
    })
}

function merges(s: Step) -> bool throws never {
    s.effects.some((e) -> {
        e is MergePr
    })
}

function notes(s: Step) -> int throws never {
    s.effects
        .filter((e) -> {
            e is Note
        })
        .length()
}

function is_held(s: Step) -> bool throws never {
    s.bead.hold != null
}

// --- research ---

test "Researcher writes a brief" {
    let s = step(
        bead(researching()),
        BriefWritten { kind: "brief_written", overruled: false, text: "Files:\ncalc.js" },
        policy(),
    );
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 0);
    assert.equal(s.bead.brief, "Files:\ncalc.js")
}

test "Researcher BLOCKED goes back to the research queue for a second opinion" {
    let s = step(
        bead(researching()),
        ResearchBlocked {
            kind: "research_blocked",
            line: "layouts/a.html:3",
            second_opinion: false,
        },
        policy(),
    );
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.first_block, "BLOCKED: layouts/a.html:3");
    assert.equal(s.bead.last_note, "BLOCKED: layouts/a.html:3");
    assert.equal(s.bead.brief == null, true)
}

test "a second BLOCKED parks, however the round marked it" {
    let first = step(
        bead(researching()),
        ResearchBlocked { kind: "research_blocked", line: "BLOCKED: x", second_opinion: false },
        policy(),
    ).bead;
    let again = step(
        first.at(Researching { kind: "researching" }),
        ResearchBlocked { kind: "research_blocked", line: "BLOCKED: x", second_opinion: false },
        policy(),
    );
    assert.is_type<Parked>(again.bead.place);
}

test "a second opinion's brief clears the block" {
    let first = step(
        bead(researching()),
        ResearchBlocked { kind: "research_blocked", line: "BLOCKED: x", second_opinion: false },
        policy(),
    ).bead;
    let s = step(
        first.at(Researching { kind: "researching" }),
        BriefWritten { kind: "brief_written", overruled: true, text: "Files:\nok" },
        policy(),
    );
    assert.equal(s.bead.first_block == null, true);
    assert.equal(s.bead.last_note == null, true);
    assert.equal(s.bead.brief, "Files:\nok")
}

test "the second opinion writes a brief" {
    let s = step(
        bead(researching()),
        BriefWritten { kind: "brief_written", overruled: true, text: "Files:\nok" },
        policy(),
    );
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 0)
}

test "the second opinion says BLOCKED too" {
    let s = step(
        bead(researching()),
        ResearchBlocked { kind: "research_blocked", line: "BLOCKED: x", second_opinion: true },
        policy(),
    );
    assert.is_type<Parked>(s.bead.place);
    assert.equal(s.bead.failures, 0);
    assert.is_true(briefs(s))
}

test "no second opinion to ask parks at once" {
    let p = policy();
    p.second_opinion = false;
    let s = step(
        bead(researching()),
        ResearchBlocked { kind: "research_blocked", line: "BLOCKED: x", second_opinion: false },
        p,
    );
    assert.is_type<Parked>(s.bead.place);
}

// --- the dev lane ---

test "a lane picks a ready bead" {
    let s = step(bead(ready()), Picked { kind: "picked" }, policy());
    assert.is_type<Working>(s.bead.place);
    assert.equal(s.bead.rounds, 1)
}

test "Worker BLOCKED" {
    let s = step(bead(working()), WorkerBlocked { kind: "worker_blocked", line: "BLOCKED: x" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 1);
    assert.is_true(removes(s))
}

test "Worker BLOCKED at the last stage parks with the brief" {
    let s = step(
        bead(working(), failures = 2),
        WorkerBlocked { kind: "worker_blocked", line: "BLOCKED: x" },
        policy(),
    );
    assert.is_type<Parked>(s.bead.place);
    assert.equal(s.bead.failures, 3);
    assert.is_true(briefs(s));
    assert.is_true(removes(s))
}

test "No commit" {
    let s = step(bead(working()), NoCommit { kind: "no_commit" }, policy());
    assert.equal(s.bead.failures, 1);
    assert.is_true(removes(s))
}

test "No commit on a kept branch leaves it" {
    let b = bead(working());
    b.kept = true;
    let s = step(b, NoCommit { kind: "no_commit" }, policy());
    assert.equal(s.bead.failures, 1);
    assert.is_true(!removes(s));
    assert.is_true(s.bead.kept)
}

test "the session timed out" {
    let s = step(bead(working()), RoundTimedOut { kind: "round_timed_out" }, policy());
    assert.equal(s.bead.failures, 1);
    assert.is_true(removes(s))
}

test "the worker exits non-zero after real work" {
    let s = step(bead(working()), WorkerCrashed { kind: "worker_crashed", words: "rc 1" }, policy());
    assert.equal(s.bead.failures, 1)
}

test "Setup fails" {
    let s = step(bead(working()), infra(Trouble.Setup), policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 0);
    assert.is_true(is_held(s));
    assert.is_true(removes(s))
}

test "Git refuses the worktree" {
    let s = step(bead(working()), infra(Trouble.Git), policy());
    assert.equal(s.bead.failures, 0);
    assert.is_true(is_held(s));
    assert.is_true(!removes(s))
}

test "Harness exits with nothing from the model" {
    let s = step(bead(working()), infra(Trouble.Harness), policy());
    assert.equal(s.bead.failures, 0);
    assert.is_true(is_held(s));
    assert.is_true(removes(s))
}

test "Harness exits with nothing, once a round had committed" {
    let s = step(bead(committed_work()), infra(Trouble.Harness), policy());
    assert.equal(s.bead.failures, 0);
    assert.is_true(!removes(s));
    assert.is_true(s.bead.kept)
}

test "Gate fails twice" {
    let s = step(bead(working()), GateFailedTwice { kind: "gate_failed_twice", errors: "e" }, policy());
    assert.equal(s.bead.failures, 1);
    assert.is_true(removes(s))
}

test "the note of a failed round carries its post-mortem" {
    let postmortem = "Post-mortem (m):\n1. Tried x";

    let no_commit = step(bead(working()), NoCommit { kind: "no_commit", postmortem: postmortem }, policy());
    assert.equal(no_commit.bead.last_note, "worker made no commit\n\nPost-mortem (m):\n1. Tried x");
    let no_commit_bare = step(bead(working()), NoCommit { kind: "no_commit", postmortem: null }, policy());
    assert.equal(no_commit_bare.bead.last_note, "worker made no commit");

    let worker_crashed = step(
        bead(working()),
        WorkerCrashed { kind: "worker_crashed", words: "rc 1", postmortem: postmortem },
        policy(),
    );
    assert.equal(
        worker_crashed.bead.last_note,
        "worker exited: rc 1\n\nPost-mortem (m):\n1. Tried x",
    );
    let worker_crashed_bare = step(
        bead(working()),
        WorkerCrashed { kind: "worker_crashed", words: "rc 1", postmortem: null },
        policy(),
    );
    assert.equal(worker_crashed_bare.bead.last_note, "worker exited: rc 1");

    let gate_failed_twice = step(
        bead(working()),
        GateFailedTwice { kind: "gate_failed_twice", errors: "e", postmortem: postmortem },
        policy(),
    );
    assert.equal(gate_failed_twice.bead.last_note, "gate failed: e\n\nPost-mortem (m):\n1. Tried x");
    let gate_failed_twice_bare = step(
        bead(working()),
        GateFailedTwice { kind: "gate_failed_twice", errors: "e", postmortem: null },
        policy(),
    );
    assert.equal(gate_failed_twice_bare.bead.last_note, "gate failed: e")
}

test "Gate passes" {
    let s = step(bead(committed_work()), GatePassed { kind: "gate_passed" }, policy());
    assert.is_type<InReview>(s.bead.place);
    assert.is_true(s.bead.kept)
}

test "Gate passes on a stage with no reviewer: straight to the PR" {
    let p = policy();
    p.stages = [Stage { name: "local", worker: "devbox/coder", reviewer: "", attempts: 1 }];
    let s = step(bead(committed_work()), GatePassed { kind: "gate_passed" }, p);
    assert.is_type<Reviewing>(s.bead.place);
    assert.is_true(s.bead.kept);
    assert.is_true(
        s.effects.some((e) -> {
            e is PushAndOpenPr
        }),
    );
    let o = step(s.bead, PrOpened { kind: "pr_opened", url: "pr/1", head: "h" }, p);
    assert.is_type<Merging>(o.bead.place);
    p.ask_before_pr = true;
    let a = step(bead(committed_work()), GatePassed { kind: "gate_passed" }, p);
    assert.is_true(
        a.effects.some((e) -> {
            e is PushBranch
        }),
    );
}

test "Gate passes, diff checks find a problem" {
    let s = step(bead(committed_work()), DiffProblems { kind: "diff_problems", problems: "p" }, policy());
    assert.equal(s.bead.failures, 1);
    assert.is_true(!removes(s));
    assert.equal(s.bead.order, Order.FixInPlace)
}

test "Pre-check SEND BACK" {
    let s = step(bead(committed_work()), PrecheckSentBack { kind: "precheck_sent_back", block: "b" }, policy());
    assert.equal(s.bead.failures, 1);
    assert.is_true(!removes(s))
}

// --- the review lane ---

test "a lane picks a bead in review" {
    let s = step(bead(in_review()), ReviewPicked { kind: "review_picked" }, policy());
    assert.is_type<Reviewing>(s.bead.place);
}

test "Reviewer REJECT" {
    let s = step(
        bead(reviewing()),
        Rejected { kind: "rejected", line: "REJECT: a", text: "REJECT: a" },
        policy(),
    );
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 1);
    assert.is_true(!removes(s));
    assert.equal(s.bead.order, Order.FixInPlace)
}

test "The same REJECT twice escalates to a different worker" {
    let b = bead(reviewing(), failures = 0);
    b.last_reject = "REJECT:   same  thing";
    let s = step(b, Rejected { kind: "rejected", line: "REJECT: same thing", text: "t" }, policy());
    assert.equal(s.bead.failures, 2);
    assert.equal(stage_for(policy(), s.bead.failures)?.worker, "claude/sonnet")
}

test "The same REJECT twice with no other worker parks" {
    let b = bead(reviewing(), failures = 2);
    b.last_reject = "REJECT: same";
    let s = step(b, Rejected { kind: "rejected", line: "REJECT: same", text: "t" }, policy());
    assert.is_type<Parked>(s.bead.place);
}

test "the reviewer exits non-zero after work" {
    let s = step(bead(reviewing()), ReviewerCrashed { kind: "reviewer_crashed", words: "rc 1" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 1);
    assert.is_true(!removes(s))
}

test "the reviewer comes back with nothing from the model" {
    let s = step(bead(reviewing()), infra(Trouble.Harness), policy());
    assert.is_type<InReview>(s.bead.place);
    assert.equal(s.bead.failures, 0);
    assert.is_true(is_held(s))
}

test "Reviewer APPROVE pushes, then the PR moves it to merge" {
    let a = step(bead(reviewing()), Approved { kind: "approved" }, policy());
    assert.is_true(
        a.effects.some((e) -> {
            e is PushAndOpenPr
        }),
    );
    let s = step(a.bead, PrOpened { kind: "pr_opened", url: "pr/1", head: "h" }, policy());
    assert.is_type<Merging>(s.bead.place);
}

test "an approved round carries the PR it had" {
    let b = bead(reviewing());
    b.pr = "pr-1";
    let s = step(b, Approved { kind: "approved" }, policy());
    assert.is_true(
        s.effects.some((e) -> {
            if let p: PushAndOpenPr = e {
                p.was == "pr-1"
            } else {
                false
            }
        }),
    )
}

test "a PR closed while its round ran parks the bead" {
    let b = bead(reviewing());
    b.pr = "pr-1";
    let s = step(b, PrClosed { kind: "pr_closed", url: "pr-1" }, policy());
    assert.is_type<Parked>(s.bead.place);
    assert.equal(s.bead.pr, null)
}

test "Reviewer APPROVE under ask is ready to publish" {
    let s = step(bead(reviewing()), BranchPushed { kind: "branch_pushed", compare_url: "c" }, policy());
    assert.is_type<Publishable>(s.bead.place);
    let o = step(s.bead, PrOpened { kind: "pr_opened", url: "pr/1", head: "h" }, policy());
    assert.is_type<Merging>(o.bead.place);
}

test "Push or gh pr create refused" {
    let s = step(bead(reviewing()), infra(Trouble.Push), policy());
    assert.is_type<InReview>(s.bead.place);
    assert.is_true(is_held(s));
    assert.equal(s.bead.failures, 0)
}

test "a PR opened under pipeline gets its merge label, and under auto does not" {
    let s = step(bead(reviewing()), PrOpened { kind: "pr_opened", url: "pr/1", head: "h" }, policy());
    assert.is_true(relabels(s));
    let auto = policy();
    auto.merge = MergeMode.Auto;
    let a = step(bead(reviewing()), PrOpened { kind: "pr_opened", url: "pr/1", head: "h" }, auto);
    assert.is_true(!relabels(a))
}

test "APPROVE on the commit CI was red on asks CI again" {
    let b = bead(reviewing());
    b.charged_head = "h";
    let s = step(b, PrOpened { kind: "pr_opened", url: "pr/1", head: "h" }, policy());
    assert.is_true(relabels(s))
}

// --- the merge queue ---

test "CI green, auto" {
    assert.is_true(
        merges(step(bead(merging()), ChecksGreen { kind: "checks_green" }, with_merge(MergeMode.Auto))),
    )
}

test "CI green, pipeline waits for the pipeline" {
    let s = step(bead(merging()), ChecksGreen { kind: "checks_green" }, policy());
    assert.is_true(!merges(s));
    assert.is_true(!is_held(s))
}

test "CI green, pipeline, not merged in time is held" {
    assert.is_true(
        is_held(step(bead(merging()), WaitedTooLong { kind: "waited_too_long", why: "30 min" }, policy())),
    )
}

test "CI green, manual" {
    assert.is_true(
        is_held(step(bead(merging()), ChecksGreen { kind: "checks_green" }, with_merge(MergeMode.Manual))),
    )
}

test "CI green, external" {
    let s = step(bead(merging()), ChecksGreen { kind: "checks_green" }, with_merge(MergeMode.External));
    assert.is_true(!is_held(s));
    assert.equal(notes(s), 0)
}

test "no hold for external however long it waits" {
    assert.is_true(
        !is_held(
            step(
                bead(merging()),
                WaitedTooLong { kind: "waited_too_long", why: "w" },
                with_merge(MergeMode.External),
            ),
        ),
    )
}

test "CI green, GitHub refuses the merge" {
    assert.is_true(
        is_held(step(bead(merging()), infra(Trouble.MergeRefused), with_merge(MergeMode.Auto))),
    )
}

test "BEHIND with update_behind updates the branch, whatever the merge mode" {
    let p = with_merge(MergeMode.External);
    p.update_behind = true;
    let s = step(bead(merging()), Behind { kind: "behind" }, p);
    assert.is_true(
        s.effects.some((e) -> {
            e is UpdateBranch
        }),
    )
}

test "CI red" {
    let s = step(bead(merging()), ChecksRed { kind: "checks_red", checks: "c", head: "h" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 1);
    assert.equal(s.bead.charged_head, "h");
    assert.equal(s.bead.pr, null);
}

test "CI red again on the commit already charged, pipeline" {
    let b = bead(merging(), failures = 1);
    b.charged_head = "h";
    let s = step(b, ChecksRed { kind: "checks_red", checks: "c", head: "h" }, policy());
    assert.equal(s.bead.failures, 1);
    assert.is_true(relabels(s));
    assert.is_type<Merging>(s.bead.place);
    assert.equal(s.bead.rerun_head, "h");
}

test "CI red on a charged head that was re-run is charged" {
    let b = bead(merging(), failures = 1);
    b.charged_head = "h";
    b.rerun_head = "h";
    let s = step(b, ChecksRed { kind: "checks_red", checks: "c", head: "h" }, policy());
    assert.equal(s.bead.failures, 2);
    assert.is_type<Ready>(s.bead.place);
    assert.is_true(!relabels(s));
}

test "CI red again on the commit already charged, otherwise held" {
    let b = bead(merging(), failures = 1);
    b.charged_head = "h";
    let s = step(b, ChecksRed { kind: "checks_red", checks: "c", head: "h" }, with_merge(MergeMode.Auto));
    assert.equal(s.bead.failures, 1);
    assert.is_true(is_held(s))
}

test "a waiting hold is noted once, however its words change" {
    let a = step(bead(merging()), WaitedTooLong { kind: "waited_too_long", why: "green for 30 min" }, policy());
    assert.equal(notes(a), 1);
    let b = step(a.bead, WaitedTooLong { kind: "waited_too_long", why: "green for 31 min" }, policy());
    assert.equal(notes(b), 0);
    assert.equal(b.bead.hold?.words, "green for 31 min");
    let c = step(b.bead, HoldCleared { kind: "hold_cleared" }, policy());
    let d = step(c.bead, WaitedTooLong { kind: "waited_too_long", why: "green for 33 min" }, policy());
    assert.equal(notes(d), 0);
    assert.is_true(is_held(d))
}

test "a different hold in the merge queue is noted" {
    let a = step(
        bead(merging()),
        WaitedTooLong { kind: "waited_too_long", why: "no checks for 5 min" },
        with_merge(MergeMode.Manual),
    );
    let b = step(a.bead, ChecksGreen { kind: "checks_green" }, with_merge(MergeMode.Manual));
    assert.equal(notes(b), 1);
    assert.equal(b.bead.hold?.words, "yours to merge")
}

test "CI red, every failing required check killed, runs once more" {
    let s = step(bead(merging()), RedKilled { kind: "red_killed", checks: "c", head: "h" }, policy());
    assert.equal(s.bead.failures, 0);
    assert.is_true(relabels(s));
    assert.equal(s.bead.rerun_head, "h")
}

test "killed again is charged like any red" {
    let b = bead(merging());
    b.rerun_head = "h";
    let s = step(b, RedKilled { kind: "red_killed", checks: "c", head: "h" }, policy());
    assert.equal(s.bead.failures, 1)
}

test "CI red only in checks the base does not require" {
    let s = step(bead(merging()), RedNotRequired { kind: "red_not_required" }, policy());
    assert.equal(s.bead.failures, 0);
    assert.is_type<Merging>(s.bead.place);
}

test "CI red on an adopted PR" {
    let s = step(bead(adopted()), ChecksRed { kind: "checks_red", checks: "c", head: "h" }, policy());
    assert.equal(s.bead.failures, 0);
    assert.is_true(is_held(s))
}

test "CI pending for over two hours" {
    assert.is_true(
        is_held(
            step(
                bead(merging()),
                WaitedTooLong { kind: "waited_too_long", why: "is the agent up?" },
                policy(),
            ),
        ),
    )
}

test "gh cannot read the PR" {
    let s = step(bead(merging()), infra(Trouble.Gh), policy());
    assert.is_true(is_held(s));
    assert.is_type<Merging>(s.bead.place);
}

test "PR conflicts with the base" {
    let s = step(bead(merging()), Conflicting { kind: "conflicting" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 0);
    assert.equal(s.bead.order, Order.Rebase);
    assert.is_true(s.bead.kept)
}

test "Adopted PR conflicts" {
    assert.is_type<Merging>(
        step(bead(adopted()), Conflicting { kind: "conflicting" }, policy()).bead.place,
    );
}

test "merged" {
    assert.is_type<Closed>(
        step(bead(merging()), PrMerged { kind: "pr_merged", url: "pr/1" }, policy()).bead.place,
    );
}

test "a merged bead loses its worktree and local branch" {
    let a = step(bead(merging()), PrMerged { kind: "pr_merged", url: "u" }, policy());
    assert.is_true(removes(a));
    let b = step(bead(parked()), MergedOutside { kind: "merged_outside", url: "u" }, policy());
    assert.is_true(removes(b))
}

test "Merged, but bd close fails" {
    let s = step(bead(merging()), PrMerged { kind: "pr_merged", url: "pr/1" }, policy());
    assert.is_true(is_held(step(s.bead, infra(Trouble.Bd), policy())))
}

test "PR closed unmerged" {
    let s = step(bead(merging()), PrClosed { kind: "pr_closed", url: "pr/1" }, policy());
    assert.is_type<Parked>(s.bead.place);
    assert.is_true(briefs(s))
}

test "A dev-queue bead's PR merged outside the loop" {
    assert.is_type<Closed>(
        step(bead(ready()), MergedOutside { kind: "merged_outside", url: "u" }, policy()).bead.place,
    );
}

test "A parked bead's PR merged outside the loop" {
    assert.is_type<Closed>(
        step(bead(parked()), MergedOutside { kind: "merged_outside", url: "u" }, policy()).bead.place,
    );
}

test "an open PR the loop did not open is adopted" {
    let s = step(bead(ready()), PrAdopted { kind: "pr_adopted", url: "u" }, policy());
    assert.is_type<Merging>(s.bead.place);
    assert.is_true(relabels(s))
}

test "a PR the loop sent back is not adopted" {
    let b = bead(ready());
    b.pr = "pr/1";
    assert.is_type<Ready>(
        step(b, PrAdopted { kind: "pr_adopted", url: "pr/1" }, policy()).bead.place,
    );
}

test "a PR opened by hand from a parked bead's branch is adopted" {
    let s = step(bead(parked()), PrAdopted { kind: "pr_adopted", url: "u", own: true }, policy());
    assert.is_type<Merging>(s.bead.place);
    assert.equal(s.bead.pr, "u");
    if let m: Merging = s.bead.place {
        assert.equal(m.adopted, false);
    }
}

test "a parked bead merged outside the loop is closed" {
    let s = step(bead(parked()), MergedOutside { kind: "merged_outside", url: "u" }, policy());
    assert.is_type<Closed>(s.bead.place);
}

// --- exhaustion and you ---

test "Failures exhausted" {
    let s = step(bead(ready(), failures = 3), Picked { kind: "picked" }, policy());
    assert.is_type<Parked>(s.bead.place);
    assert.is_true(briefs(s))
}

test "repeat cycles the stages" {
    let p = policy();
    p.on_exhaust = OnExhaust.Repeat;
    assert.equal(stage_for(p, 4)?.worker, "devbox/coder");
    assert.is_type<Working>(
        step(bead(ready(), failures = 3), Picked { kind: "picked" }, p).bead.place,
    );
}

test "an answer takes one off the count" {
    let s = step(bead(parked(), failures = 3), Answered { kind: "answered", text: "use x" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 2)
}

test "reopen keeps the count" {
    assert.equal(
        step(bead(parked(), failures = 3), Reopened { kind: "reopened" }, policy()).bead.failures,
        3,
    )
}

test "escalate lands on the last stage" {
    let s = step(bead(parked(), failures = 0), Escalated { kind: "escalated" }, policy());
    assert.equal(stage_for(policy(), s.bead.failures)?.worker, "claude/sonnet")
}

test "the merge queue refuses an answer, reopen and escalate" {
    assert.is_true(
        refuses(step(bead(merging()), Answered { kind: "answered", text: "x" }, policy())),
    );
    assert.is_true(refuses(step(bead(merging()), Reopened { kind: "reopened" }, policy())));
    assert.is_true(refuses(step(bead(merging()), Escalated { kind: "escalated" }, policy())))
}

// --- the loop ---

test "The loop stopped mid dev round" {
    let s = step(bead(working()), RoundLost { kind: "round_lost" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 0);
    assert.is_true(s.bead.kept)
}

test "the loop stopped mid review" {
    let s = step(bead(reviewing()), RoundLost { kind: "round_lost" }, policy());
    assert.is_type<InReview>(s.bead.place);
    assert.equal(s.bead.failures, 0)
}

test "a hold is said once and cleared by the world" {
    let a = step(bead(merging()), infra(Trouble.Gh), policy());
    assert.equal(notes(a), 1);
    let b = step(a.bead, infra(Trouble.Gh), policy());
    assert.equal(notes(b), 0);
    let c = step(b.bead, HoldCleared { kind: "hold_cleared" }, policy());
    assert.is_true(!is_held(c))
}

// --- properties ---

test "infrastructure never charges a failure, in any place" {
    let places = [
        ready(),
        researching(),
        working(),
        committed_work(),
        in_review(),
        reviewing(),
        merging(),
        adopted(),
        parked(),
    ];
    let troubles = [
        Trouble.Setup,
        Trouble.Git,
        Trouble.Harness,
        Trouble.Push,
        Trouble.Gh,
        Trouble.Bd,
        Trouble.SignedOut,
        Trouble.NoSuchTarget,
        Trouble.MergeRefused,
    ];
    for (let place in places) {
        for (let t in troubles) {
            assert.equal(step(bead(place, failures = 1), infra(t), policy()).bead.failures, 1);
        }
    }
}

function exits() -> Event[] throws never {
    [
        Picked { kind: "picked" },
        BriefWritten { kind: "brief_written", overruled: false, text: "" },
        GatePassed { kind: "gate_passed" },
        ReviewPicked { kind: "review_picked" },
        PrOpened { kind: "pr_opened", url: "u", head: "h" },
        PrMerged { kind: "pr_merged", url: "u" },
        Reopened { kind: "reopened" },
    ]
}

test "every place but Closed has an exit" {
    let places: Place[] = [
        ready(),
        researching(),
        working(),
        in_review(),
        reviewing(),
        Publishable { kind: "publishable", compare_url: "c" },
        merging(),
        parked(),
    ];
    for (let place in places) {
        let moved = exits().some((e) -> {
            step(bead(place), e, policy()).bead.place != place
        });
        assert.is_true(moved);
    }
}

test "a bead folds from its log" {
    let log: Event[] = [
        Picked { kind: "picked" },
        Committed { kind: "committed", sha: "a" },
        GatePassed { kind: "gate_passed" },
        ReviewPicked { kind: "review_picked" },
        Rejected { kind: "rejected", line: "REJECT: x", text: "t" },
        Picked { kind: "picked" },
        Committed { kind: "committed", sha: "b" },
        GatePassed { kind: "gate_passed" },
        ReviewPicked { kind: "review_picked" },
        Approved { kind: "approved" },
        PrOpened { kind: "pr_opened", url: "u", head: "h" },
        PrMerged { kind: "pr_merged", url: "u" },
    ];
    let b = fold("t-1", log, policy());
    assert.is_type<Closed>(b.place);
    assert.equal(b.failures, 1);
    assert.equal(b.rounds, 2)
}

function all_events() -> Event[] throws never {
    [
        WorkerBlocked { kind: "worker_blocked", line: "l" },
        NoCommit { kind: "no_commit" },
        RoundTimedOut { kind: "round_timed_out" },
        WorkerCrashed { kind: "worker_crashed", words: "w" },
        GateFailedTwice { kind: "gate_failed_twice", errors: "e" },
        DiffProblems { kind: "diff_problems", problems: "p" },
        PrecheckSentBack { kind: "precheck_sent_back", block: "b" },
        Rejected { kind: "rejected", line: "l", text: "t" },
        ReviewerCrashed { kind: "reviewer_crashed", words: "w" },
        ChecksRed { kind: "checks_red", checks: "c", head: "h" },
        Infra { kind: "infra", what: Trouble.Gh, words: "w" },
        ResearchPicked { kind: "research_picked" },
        BriefWritten { kind: "brief_written", overruled: true, text: "t" },
        ResearchBlocked { kind: "research_blocked", line: "l", second_opinion: true },
        Picked { kind: "picked" },
        Committed { kind: "committed", sha: "s" },
        GatePassed { kind: "gate_passed" },
        ReviewPicked { kind: "review_picked" },
        Approved { kind: "approved" },
        PrOpened { kind: "pr_opened", url: "u", head: "h" },
        BranchPushed { kind: "branch_pushed", compare_url: "c" },
        PrMerged { kind: "pr_merged", url: "u" },
        PrClosed { kind: "pr_closed", url: "u" },
        Conflicting { kind: "conflicting" },
        RedKilled { kind: "red_killed", checks: "c", head: "h" },
        RedNotRequired { kind: "red_not_required" },
        ChecksGreen { kind: "checks_green" },
        Behind { kind: "behind" },
        WaitedTooLong { kind: "waited_too_long", why: "w" },
        PrAdopted { kind: "pr_adopted", url: "u" },
        MergedOutside { kind: "merged_outside", url: "u" },
        Answered { kind: "answered", text: "t" },
        Reopened { kind: "reopened" },
        Escalated { kind: "escalated" },
        RoundLost { kind: "round_lost" },
        HoldCleared { kind: "hold_cleared" },
    ]
}

test "every event survives the log's JSON" {
    for (let e in all_events()) {
        let text = baml.json.stringify(e);
        let back = baml.json.decode<Event>(text);
        assert.equal(back, e);
    }
}

// Rows for the observation layer, not this function: a build CI skipped, no checks five
// minutes on, a check the base does not require, a label that cannot be added, no brief
// yet and nothing else to take.

test "BEHIND without update_behind leaves the branch alone" {
    let s = step(bead(merging()), Behind { kind: "behind" }, with_merge(MergeMode.Auto));
    assert.equal(s.effects.length(), 0)
}

test "a conflict sends the bead back told to rebase" {
    let s = step(bead(merging()), Conflicting { kind: "conflicting" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.order, Order.Rebase);
    assert.contains(s.bead.last_note ?? "", "Rebase this branch")
}

test "review comments send the loop's own PR back to act on them, uncharged" {
    let s = step(bead(merging()), Feedback { kind: "feedback", text: "rename x", at: "t" }, policy());
    assert.is_type<Ready>(s.bead.place);
    assert.equal(s.bead.failures, 0);
    assert.equal(s.bead.kept, true);
    assert.equal(s.bead.order, Order.Feedback);
    assert.contains(s.bead.last_note ?? "", "rename x")
}

test "a research pick prepares the worktree the researcher reads" {
    let s = step(bead(ready()), ResearchPicked { kind: "research_picked" }, policy());
    assert.is_type<Researching>(s.bead.place);
    assert.is_true(
        s.effects.some((e) -> {
            e is PrepareWorktree
        }),
    )
}

/// One pick and its harness failure, as the supervisor applies them.
function picked_and_held(b: Bead, what: Trouble) -> Bead throws never {
    let p = policy();
    let held = step(step(b, Picked { kind: "picked" }, p).bead, infra(what), p).bead;
    step(held, HoldCleared { kind: "hold_cleared" }, p).bead
}

test "five harness holds in a row park the bead, with the words" {
    let b = bead(ready(), failures = 2);
    for (let i in [1, 2, 3, 4]) {
        b = picked_and_held(b, Trouble.Harness);
    }
    assert.is_true(b.place is Ready);
    let p = policy();
    let s = step(step(b, Picked { kind: "picked" }, p).bead, infra(Trouble.Harness), p);
    if let x: Parked = s.bead.place {
        assert.equal(x.question, "held 5 times in a row: the words");
    } else {
        assert.is_true(false);
    }
    assert.equal(s.bead.failures, 2)
}

test "a usage limit is waited out however long, and work between holds resets the count" {
    let b = bead(ready());
    for (let i in [1, 2, 3, 4, 5, 6]) {
        b = picked_and_held(b, Trouble.SignedOut);
    }
    assert.is_true(b.place is Ready);
    let c = bead(ready());
    for (let i in [1, 2, 3, 4]) {
        c = picked_and_held(c, Trouble.Harness);
    }
    let p = policy();
    let worked = step(step(c, Picked { kind: "picked" }, p).bead, Committed { kind: "committed", sha: "s" }, p).bead;
    assert.equal(worked.harness_streak, 0)
}

test "a BLOCKED on the last stage parks, keeping a branch that holds gated work" {
    let b = bead(working(), failures = 2);
    b.kept = true;
    let s = step(b, WorkerBlocked { kind: "worker_blocked", line: "BLOCKED: x" }, policy());
    assert.is_true(s.bead.place is Parked);
    assert.is_true(!removes(s));
    let fresh = step(
        bead(working(), failures = 2),
        WorkerBlocked { kind: "worker_blocked", line: "BLOCKED: x" },
        policy(),
    );
    assert.is_true(removes(fresh))
}

/// Two BLOCKEDs from research: parked with the first block still on the bead.
function research_parked() -> Bead throws never {
    let first = step(
        bead(researching()),
        ResearchBlocked { kind: "research_blocked", line: "BLOCKED: x", second_opinion: false },
        policy(),
    ).bead;
    step(
        first.at(Researching { kind: "researching" }),
        ResearchBlocked { kind: "research_blocked", line: "BLOCKED: x", second_opinion: true },
        policy(),
    ).bead
}

test "an answer is the next round's note" {
    let s = step(
        bead(Parked { kind: "parked", question: "q" }, failures = 2),
        Answered { kind: "answered", text: "use b.ts" },
        policy(),
    );
    assert.equal(s.bead.last_note, "use b.ts");
    assert.equal(s.bead.failures, 1)
}

test "a bead research parked goes to the worker once you overrule it, not to research again" {
    let p = research_parked();
    assert.is_type<Parked>(p.place);
    let answered = step(p, Answered { kind: "answered", text: "the block is at lines 4-10" }, policy()).bead;
    assert.equal(answered.brief, "");
    assert.equal(answered.first_block == null, true);
    assert.equal(answered.last_note, "the block is at lines 4-10");
    let reopened = step(p, Reopened { kind: "reopened" }, policy()).bead;
    assert.equal(reopened.brief, "");
    assert.equal(reopened.last_note == null, true);
    let other = step(bead(Parked { kind: "parked", question: "q" }), Reopened { kind: "reopened" }, policy()).bead;
    assert.equal(other.brief == null, true)
}

test "a worker's rebuttal goes back to review, uncharged, and a REJECT ends it" {
    let b = bead(working(), failures = 1);
    b.kept = true;
    let s = step(
        b,
        Rebutted { kind: "rebutted", text: "the commit already does it; the gate passes" },
        policy(),
    );
    assert.is_type<InReview>(s.bead.place);
    assert.equal(s.bead.failures, 1);
    assert.equal(s.bead.rebutted, true);
    let r = step(
        s.bead.at(Reviewing { kind: "reviewing" }),
        Rejected { kind: "rejected", line: "REJECT: x", text: "REJECT: x" },
        policy(),
    );
    assert.equal(r.bead.rebutted, false);
    assert.equal(r.bead.failures, 2)
}

test "a lever with no work behind it is refused" {
    let parked = step(
        bead(working(), failures = 2),
        WorkerBlocked { kind: "worker_blocked", line: "BLOCKED: x" },
        policy(),
    ).bead;
    assert.is_type<Parked>(parked.place);
    assert.is_true(!parked.kept);
    let published = step(parked, Published { kind: "published" }, policy());
    assert.is_true(refuses(published));
    assert.equal(published.effects.length(), 1);
    assert.is_type<Parked>(published.bead.place);
    let requested = step(parked, PrRequested { kind: "pr_requested", title: "t", body: "b" }, policy());
    assert.is_true(refuses(requested));
    assert.equal(requested.effects.length(), 1);
    assert.is_type<Parked>(requested.bead.place);
}

test "a stage label moves a ready bead to that stage, never back" {
    let s = step(bead(ready()), StageLabelled { kind: "stage_labelled", stage: "frontier" }, policy());
    assert.equal(s.bead.failures, 2);
    assert.is_type<Ready>(s.bead.place);
    let past = step(
        bead(ready(), failures = 3),
        StageLabelled { kind: "stage_labelled", stage: "local" },
        policy(),
    );
    assert.equal(past.bead.failures, 3);
    let unknown = step(bead(ready()), StageLabelled { kind: "stage_labelled", stage: "nowhere" }, policy());
    assert.equal(unknown.bead.failures, 0)
}
