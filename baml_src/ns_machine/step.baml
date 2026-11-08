// The state machine: one pure function from a bead and an event to a bead and its
// effects. docs/state-machine.md is the spec.
//
// `match (b.place)` is exhaustive, so a new Place does not build until it has its arms.

/// How many harness holds in a row park a bead. A usage limit is not one (it is SignedOut).
const HARNESS_STREAK: int = 5;

function step(b: Bead, e: Event, p: Policy) -> Step throws never {
    let s = step_at(b, e, p);
    // Anything but a hold, its end, a pick or a lost round is the harness working.
    let waiting = e is Infra
        || e is HoldCleared
        || e is Picked
        || e is ReviewPicked
        || e is ResearchPicked
        || e is RoundLost;
    if (!waiting && s.bead.harness_streak > 0) {
        let n = s.bead.copy();
        n.harness_streak = 0;
        return Step { bead: n, effects: s.effects };
    }
    s
}

function step_at(b: Bead, e: Event, p: Policy) -> Step throws never {
    match (b.place) {
        let x: Ready => on_ready(b, e, p),
        let x: Researching => on_researching(b, e, p),
        let x: Working => on_working(b, x, e, p),
        let x: InReview => on_in_review(b, e),
        let x: Reviewing => on_reviewing(b, e, p),
        let x: Publishable => on_publishable(b, e, p),
        let x: Merging => on_merging(b, x, e, p),
        let x: Parked => on_parked(b, e, p),
        let x: Closed => elsewhere(b, e),
    }
}

function stay(b: Bead) -> Step throws never {
    Step { bead: b, effects: [] }
}

/// What every place does with an event it has no arm for.
function elsewhere(b: Bead, e: Event) -> Step throws never {
    match (e) {
        let i: Infra => held(b, i),
        let c: HoldCleared => {
            let n = b.copy();
            n.hold = null;
            stay(n)
        },
        let a: Answered => Step { bead: b, effects: [Refuse { why: refusal(b) }] },
        let r: Reopened => Step { bead: b, effects: [Refuse { why: refusal(b) }] },
        let s: Escalated => Step { bead: b, effects: [Refuse { why: refusal(b) }] },
        _ => stay(b),
    }
}

function refusal(b: Bead) -> string throws never {
    if let m: Merging = b.place {
        `in the merge queue at ${m.pr}: close the PR or wait`
    } else {
        "only a parked bead takes an answer, a reopen or an escalation"
    }
}

/// Infrastructure: the bead stays where it is, nothing is charged, and it is said once.
function held(b: Bead, i: Infra) -> Step throws never {
    let same = b.hold?.words == i.words;
    let n = b.copy();
    n.hold = Hold { what: `${i.what}`, words: i.words };
    if (i.what == Trouble.Harness) {
        n.harness_streak = b.harness_streak + 1;
        if (n.harness_streak >= HARNESS_STREAK && !(b.place is Merging)) {
            n.hold = null;
            n.harness_streak = 0;
            return park(n, `held ${HARNESS_STREAK} times in a row: ${i.words}`);
        }
    }
    if (same) {
        stay(n)
    } else {
        Step { bead: n, effects: [Note { text: `held: ${i.words}` }] }
    }
}

function hold_for(b: Bead, what: string, words: string) -> Step throws never {
    let same = b.hold?.words == words;
    let n = b.copy();
    n.hold = Hold { what: what, words: words };
    if (same) {
        stay(n)
    } else {
        Step { bead: n, effects: [Note { text: `held: ${words}` }] }
    }
}

/// What a send-back says on the bead.
function note_of(o: ModelOutcome) -> string throws never {
    match (o) {
        let x: WorkerBlocked => x.line,
        let x: NoCommit => "worker made no commit",
        let x: RoundTimedOut => "worker timed out",
        let x: WorkerCrashed => `worker exited: ${x.words}`,
        let x: GateFailedTwice => `gate failed: ${x.errors}`,
        let x: DiffProblems => `diff checks: ${x.problems}`,
        let x: PrecheckSentBack => `precheck sent back: ${x.block}`,
        let x: Rejected => `review rejected: ${x.text}`,
        let x: ReviewerCrashed => `reviewer exited: ${x.words}`,
        let x: ChecksRed => `CI red: ${x.checks}`,
    }
}

/// Whether the branch outlives a send-back: work that passed the gate does.
function branch_survives(o: ModelOutcome) -> bool throws never {
    match (o) {
        let x: WorkerBlocked => false,
        let x: NoCommit => false,
        let x: RoundTimedOut => false,
        let x: WorkerCrashed => false,
        let x: GateFailedTwice => false,
        let x: DiffProblems => true,
        let x: PrecheckSentBack => true,
        let x: Rejected => true,
        let x: ReviewerCrashed => true,
        let x: ChecksRed => true,
    }
}

/// A failure: one more on the count, back to the dev queue with a note. Only a
/// ModelOutcome can reach this, so infrastructure cannot be charged.
function charge(b: Bead, o: ModelOutcome) -> Step throws never {
    // Work that already passed the gate stays: a later no-commit must not throw it away
    // (t-1 e2e, 7 Nov: the reviewer returned no verdict, the worker found the edit already
    // done, and NoCommit deleted the branch). An open PR lives on its branch too.
    let keep = branch_survives(o) || b.kept || b.pr != null;
    let n = b.at(Ready { kind: "ready" });
    n.failures = b.failures + 1;
    n.kept = keep;
    n.last_note = note_of(o);
    n.order
        = if (keep) {
            Order.FixInPlace
        } else {
            Order.Fresh
        };
    let effects: Effect[] = [Note { text: note_of(o) }];
    if (!keep) {
        effects.push(RemoveBranch {});
    }
    Step { bead: n, effects: effects }
}

function park(b: Bead, question: string) -> Step throws never {
    Step {
        bead: b.at(Parked { kind: "parked", question: question }),
        effects: [WriteParkBrief { because: question }],
    }
}

function on_ready(b: Bead, e: Event, p: Policy) -> Step throws never {
    match (e) {
        let x: Picked => {
            if (stage_for(p, b.failures) == null) {
                return park(b, "the stages are exhausted");
            }
            let n = b.at(Working { kind: "working", committed: false });
            n.rounds = b.rounds + 1;
            Step { bead: n, effects: [PrepareWorktree { resume: b.kept }] }
        },
        // The researcher reads the bead's worktree, so the pick makes one.
        let x: ResearchPicked => {
            Step {
                bead: b.at(Researching { kind: "researching" }),
                effects: [PrepareWorktree { resume: b.kept }],
            }
        },
        let x: PrAdopted => {
            if (b.pr != null) {
                return stay(b);
            }
            let n = b.at(Merging { kind: "merging", pr: x.url, adopted: !(x.own ?? false) });
            n.pr = x.url;
            let effects: Effect[] = if (p.merge == MergeMode.Pipeline) {
                [Relabel {}]
            } else {
                []
            };
            Step { bead: n, effects: effects }
        },
        let x: MergedOutside => closed(b, x.url),
        _ => elsewhere(b, e),
    }
}

function closed(b: Bead, url: string?) -> Step throws never {
    Step {
        bead: b.at(Closed { kind: "closed", url: url }),
        effects: [CloseBead { url: url }, DeleteRemoteBranch {}],
    }
}

function on_researching(b: Bead, e: Event, p: Policy) -> Step throws never {
    let back = b.at(Ready { kind: "ready" });
    match (e) {
        let x: BriefWritten => {
            let n = back.copy();
            n.brief = x.text;
            if (b.first_block != null) {
                n.first_block = null;
                n.last_note = null;
            }
            let text = if (x.overruled) {
                "brief written: the second opinion overruled the block"
            } else {
                "brief written"
            };
            Step { bead: n, effects: [Note { text: text }] }
        },
        let x: ResearchBlocked => {
            if (x.second_opinion || b.first_block != null || !p.second_opinion) {
                let parked = park(b, x.line);
                parked.effects.push(RemoveBranch {});
                parked
            } else {
                // Back to the research queue for a second opinion, which reads this line.
                let line = if (x.line.starts_with("BLOCKED")) {
                    x.line
                } else {
                    `BLOCKED: ${x.line}`
                };
                let n = back.copy();
                n.first_block = line;
                n.last_note = line;
                Step { bead: n, effects: [Note { text: line }] }
            }
        },
        let x: Infra => held(back, x),
        let x: RoundLost => stay(back),
        _ => elsewhere(b, e),
    }
}

function on_working(b: Bead, w: Working, e: Event, p: Policy) -> Step throws never {
    match (e) {
        let x: Committed => stay(b.at(Working { kind: "working", committed: true })),
        let x: GatePassed => {
            let n = b.at(InReview { kind: "in_review" });
            n.kept = true;
            stay(n)
        },
        let x: WorkerBlocked => {
            let sent = charge(b, x);
            if (on_last_stage(p, b.failures)) {
                let parked = park(sent.bead, x.line);
                // Work an earlier round committed and gated stays on its branch: you may
                // still want it (pw-xl2, 8 Nov, lost its passing commit to a false BLOCKED).
                parked.effects = [Note { text: x.line }, WriteParkBrief { because: x.line }];
                if (!sent.bead.kept) {
                    parked.effects.push(RemoveBranch {});
                }
                parked
            } else {
                sent
            }
        },
        let x: NoCommit => charge(b, x),
        let x: RoundTimedOut => charge(b, x),
        let x: WorkerCrashed => charge(b, x),
        let x: GateFailedTwice => charge(b, x),
        let x: DiffProblems => charge(b, x),
        let x: PrecheckSentBack => charge(b, x),
        let x: Infra => {
            let keep = w.committed || b.kept || b.pr != null;
            let n = b.at(Ready { kind: "ready" });
            n.kept = keep;
            let s = held(n, x);
            if (!keep && x.what != Trouble.Git) {
                s.effects.push(RemoveBranch {});
            }
            s
        },
        // The loop stopped: no failure, and the branch stays for the resume.
        let x: RoundLost => {
            let n = b.at(Ready { kind: "ready" });
            n.kept = true;
            stay(n)
        },
        _ => elsewhere(b, e),
    }
}

function on_in_review(b: Bead, e: Event) -> Step throws never {
    match (e) {
        let x: ReviewPicked => stay(b.at(Reviewing { kind: "reviewing" })),
        _ => elsewhere(b, e),
    }
}

/// Whitespace aside, as the same-REJECT rule compares them.
function squash(s: string) -> string throws never {
    s.split(" ")
        .filter((w) -> {
            w.length() > 0
        })
        .join(" ")
}

function rejected(b: Bead, r: Rejected, p: Policy) -> Step throws never {
    let twice = b.last_reject != null && squash(b.last_reject ?? "") == squash(r.line);
    let sent = charge(b, r);
    sent.bead.last_reject = r.line;
    if (!twice) {
        return sent;
    }
    let next = next_worker_at(p, b.failures);
    if let at: int = next {
        sent.bead.failures = at;
        let worker = stage_for(p, at)?.worker ?? "?";
        sent.effects.push(Note { text: `the same REJECT twice: escalated to ${worker}` });
        sent
    } else {
        park(sent.bead, "the same REJECT twice, and no other worker to try")
    }
}

function on_reviewing(b: Bead, e: Event, p: Policy) -> Step throws never {
    let back = b.at(InReview { kind: "in_review" });
    match (e) {
        let x: Rejected => rejected(b, x, p),
        let x: ReviewerCrashed => charge(b, x),
        let x: Approved => {
            let effects: Effect[] = if (p.ask_before_pr) {
                [PushBranch {}]
            } else {
                [PushAndOpenPr { title: null, body: null }]
            };
            Step { bead: b, effects: effects }
        },
        let x: PrOpened => opened(b, x, p),
        let x: BranchPushed => {
            stay(b.at(Publishable { kind: "publishable", compare_url: x.compare_url }))
        },
        let x: Infra => held(back, x),
        let x: RoundLost => stay(back),
        _ => elsewhere(b, e),
    }
}

function opened(b: Bead, o: PrOpened, p: Policy) -> Step throws never {
    let n = b.at(Merging { kind: "merging", pr: o.url, adopted: false });
    n.pr = o.url;
    let effects: Effect[] = [Note { text: o.url }];
    // Approved on the commit CI was red on: no new commit, so ask CI to run it again.
    if (p.merge == MergeMode.Pipeline && b.charged_head == o.head) {
        effects.push(Relabel {});
    }
    Step { bead: n, effects: effects }
}

function on_publishable(b: Bead, e: Event, p: Policy) -> Step throws never {
    match (e) {
        let x: PrOpened => opened(b, x, p),
        let x: PrRequested => {
            Step {
                bead: b,
                effects: [Note { text: "you opened the PR" }, PushAndOpenPr { title: x.title, body: x.body }],
            }
        },
        _ => elsewhere(b, e),
    }
}

function on_merging(b: Bead, m: Merging, e: Event, p: Policy) -> Step throws never {
    match (e) {
        let x: PrMerged => closed(b, x.url),
        let x: PrClosed => {
            let n = b.copy();
            n.pr = null;
            park(n, `PR closed unmerged: ${x.url}`)
        },
        let x: Conflicting => {
            if (m.adopted) {
                return stay(b);
            }
            let n = b.at(Ready { kind: "ready" });
            n.kept = true;
            n.order = Order.Rebase;
            n.last_note = REBASE_NOTE;
            Step { bead: n, effects: [Note { text: "PR conflicts with the base: a rebase round" }] }
        },
        let x: ChecksRed => red(b, m, x, p),
        let x: RedKilled => {
            if (!m.adopted && p.merge == MergeMode.Pipeline && b.rerun_head != x.head) {
                let n = b.copy();
                n.rerun_head = x.head;
                return Step {
                    bead: n,
                    effects: [Note { text: "CI killed: running it again" }, Relabel {}],
                };
            }
            red(b, m, ChecksRed { kind: "checks_red", checks: x.checks, head: x.head }, p)
        },
        let x: RedNotRequired => stay(b),
        let x: Feedback => {
            if (m.adopted) {
                return stay(b);
            }
            let n = b.at(Ready { kind: "ready" });
            n.kept = true;
            n.order = Order.Feedback;
            n.last_note
                = `The PR has review comments to act on. Change the branch to answer them, and commit:\n${x.text}`;
            Step {
                bead: n,
                effects: [Note { text: "review comments on the PR: a round to act on them" }],
            }
        },
        let x: Behind => {
            let effects: Effect[] = if (p.update_behind) {
                [UpdateBranch {}]
            } else {
                []
            };
            Step { bead: b, effects: effects }
        },
        let x: ChecksGreen => match (p.merge) {
            MergeMode.Auto => Step { bead: b, effects: [MergePr {}] },
            MergeMode.Pipeline => stay(b),
            MergeMode.Manual => hold_for(b, "manual", "yours to merge"),
            MergeMode.External => stay(b),
        },
        let x: WaitedTooLong => {
            if (p.merge == MergeMode.External) {
                stay(b)
            } else {
                hold_for(b, "waiting", x.why)
            }
        },
        _ => elsewhere(b, e),
    }
}

function red(b: Bead, m: Merging, r: ChecksRed, p: Policy) -> Step throws never {
    if (m.adopted) {
        return hold_for(b, "adopted", "CI red on a PR the loop did not open");
    }
    if (b.charged_head == r.head) {
        return if (p.merge == MergeMode.Pipeline) {
            Step { bead: b, effects: [Relabel {}] }
        } else {
            hold_for(b, "red", "CI still red on the commit already charged")
        };
    }
    let sent = charge(b, r);
    sent.bead.charged_head = r.head;
    sent
}

function on_parked(b: Bead, e: Event, p: Policy) -> Step throws never {
    let back = b.at(Ready { kind: "ready" });
    // Parked by research (both opinions said BLOCKED): you have overruled it, so the bead
    // goes to the worker without a brief instead of to research again, which never reads
    // your answer and can block a third time (web-2ad.3, 8 Nov: the researcher misread the
    // line twice; the block it said was missing is at sponsors.html:4-10, as quoted).
    if (b.first_block != null) {
        back.first_block = null;
        back.last_note = null;
        if (back.brief == null) {
            back.brief = "";
        }
    }
    match (e) {
        let x: Answered => {
            back.failures
                = if (b.failures > 0) {
                    b.failures - 1
                } else {
                    0
                };
            // Your answer is the next round's note: what it reads as "the last round was
            // sent back".
            back.last_note = x.text;
            Step { bead: back, effects: [Note { text: x.text }] }
        },
        let x: Reopened => stay(back),
        let x: Escalated => {
            back.failures = last_stage_start(p);
            stay(back)
        },
        let x: Published => {
            Step {
                bead: b,
                effects: [
                    Note { text: "ready for PR: pushing the branch" },
                    PrepareWorktree { resume: true },
                    PushBranch {},
                ],
            }
        },
        let x: BranchPushed => {
            let n = b.at(Publishable { kind: "publishable", compare_url: x.compare_url });
            n.kept = true;
            stay(n)
        },
        let x: MergedOutside => closed(b, x.url),
        _ => elsewhere(b, e),
    }
}

/// A bead's state: a fold over its log.
function fold(id: string, events: Event[], p: Policy) -> Bead throws never {
    events.reduce(
        (b, e) -> {
            step(b, e, p).bead
        },
        Bead.new(id),
    )
}

const REBASE_NOTE: string = "The PR conflicts with the base branch. Rebase this branch onto the base (git fetch, then git rebase onto it), resolve each conflict keeping what both sides meant, run the bead's check, and commit. Change nothing else.";
