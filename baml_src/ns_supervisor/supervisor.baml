// The supervisor: observe the world, turn what changed into events, fold them, and start
// whatever should be running. Nothing here waits on anything: a tick reads the world and
// returns, and the next tick reads it again. docs/design-baml-native.md has the shape.

class Supervisor {
    world: root.world.World,
    log: Log,
    policy: root.machine.Policy,
    beads: root.machine.Bead[],
    /// How many rounds may run at once on a model server this map does not name.
    lanes: int,
    /// Rounds at once per model server, by provider (`devbox`, `acbox`, `claude`).
    capacity: map<string, int>,
    /// The models running in the other repos this process ticks. A model server is
    /// shared, so its lane counts every repo's rounds.
    elsewhere: string[],
    /// The repo this supervisor plans for; a target shares its parent's group.
    group: string,
    /// PRs in the merge queue in the rest of the group.
    group_inflight: int,
    /// The dev lane pauses at this many PRs in this merge queue; 0 is no cap.
    max_inflight: int,
    /// The dev lane pauses at this many PRs across the group; 0 is no cap.
    max_open_prs: int,
    /// Open `bead/*` PRs from anyone join the merge queue.
    adopt: bool,
    /// The beads `bd ready` listed on the last tick that could ask. Only these are picked:
    /// a bead closed, claimed or blocked since is left where it is.
    ready: string[],
    /// Ticks a hold lasts before the bead is tried again.
    hold_ticks: int,
    held_for: map<string, int>,
    /// Each bead's title, from the tickets or asked once; and the closed beads' tallies.
    known: map<string, root.world.Ticket>,
    tallies: map<string, FTally>,

    function new(
        world: root.world.World,
        log: Log,
        policy: root.machine.Policy,
    ) -> Supervisor throws never {
        Supervisor {
            world: world,
            log: log,
            policy: policy,
            beads: [],
            lanes: 1,
            capacity: {},
            elsewhere: [],
            group: "",
            group_inflight: 0,
            max_inflight: 0,
            max_open_prs: 0,
            adopt: true,
            ready: [],
            hold_ticks: 5,
            held_for: {},
            known: {},
            tallies: {},
        }
    }

    function bead(self, id: string) -> root.machine.Bead? throws never {
        self.beads.find((b) -> {
            b.id == id
        })
    }

    function put(self, bead: root.machine.Bead) -> void throws never {
        let i = 0;
        while (i < self.beads.length()) {
            if ((self.beads.at(i)?.id ?? "") == bead.id) {
                self.beads[i] = bead;
                return;
            }
            i = i + 1;
        }
        self.beads.push(bead);
    }
}

/// Records an event, folds it in, and carries out what it asks for. An effect that fails
/// becomes an Infra event on the same bead, so it is held and never charged.
function apply(s: Supervisor, id: string, event: root.machine.Event) -> void throws never {
    let current = s.bead(id) ?? root.machine.Bead.new(id);
    s.log.append(id, event);
    log.info(`${root.supervisor.repo_name(s.group)}: ${id}: ${event_line(event)}`);
    let next = root.machine.step(current, event, s.policy);
    s.put(next.bead);
    // The bead in bd says where it is: every move is written to it, its status and its
    // place as a loop:* label. A bd that refuses is said in the journal and the loop goes
    // on: the next move writes it again.
    let status = status_change(current.place, next.bead.place) ?? "";
    let was = place_label(current.place);
    let now = place_label(next.bead.place);
    if (status.length() > 0 || was != now) {
        let _ = s.world.mark(id, status, was, now) catch (e) {
            root.machine.Infra => {
                log.warn(`${id}: bd update: ${e.words}`);
            },
        };
    }
    for (let effect in next.effects) {
        let follow = perform(s, id, effect) catch (e) {
            root.machine.Infra => {
                let failed: root.machine.Event[] = [e];
                failed
            },
        };
        for (let f in follow) {
            apply(s, id, f);
        }
    }
}

/// A place as the label the bead carries in bd while it is there: `bd list -l loop:ready-for-pr`
/// is what waits for you to open a PR. Closed carries none.
function place_label(p: root.machine.Place) -> string throws never {
    match (p) {
        let x: root.machine.Ready => "loop:ready",
        let x: root.machine.Researching => "loop:research",
        let x: root.machine.Working => "loop:work",
        let x: root.machine.InReview => "loop:review-queue",
        let x: root.machine.Reviewing => "loop:review",
        let x: root.machine.Publishable => "loop:ready-for-pr",
        let x: root.machine.Merging => "loop:merging",
        let x: root.machine.Parked => "loop:parked",
        let x: root.machine.Closed => "",
    }
}

/// The bd status a transition writes, so the bead itself says where it is and a lost state
/// dir loses nothing that matters: `in_progress` once the loop picks it (and `bd ready` stops
/// listing it), `blocked` when it parks, `open` again when you answer, reopen or escalate.
/// Closing is the merge's own `bd close`. Anything else writes nothing, so a status you set
/// by hand stands until the bead next moves.
function status_change(
    before: root.machine.Place,
    after: root.machine.Place,
) -> string? throws never {
    if (after is root.machine.Parked) {
        return if (before is root.machine.Parked) {
            null
        } else {
            "blocked"
        };
    }
    if (before is root.machine.Parked) {
        return if (after is root.machine.Closed) {
            null
        } else if (after is root.machine.Ready) {
            "open"
        } else {
            "in_progress"
        };
    }
    if (
        before is root.machine.Ready
            && !(after is root.machine.Ready)
            && !(after is root.machine.Closed)
    ) {
        return "in_progress";
    }
    null
}

/// Does one effect. Each is safe to repeat, because a crash can land between doing it and
/// recording it. Returns the events the effect produced.
function perform(
    s: Supervisor,
    id: string,
    effect: root.machine.Effect,
) -> root.machine.Event[] throws root.machine.Infra {
    let none: root.machine.Event[] = [];
    match (effect) {
        let x: root.machine.Note => {
            s.world.note(id, x.text);
            none
        },
        let x: root.machine.PrepareWorktree => {
            s.world.prepare_worktree(id, x.resume);
            none
        },
        let x: root.machine.RemoveBranch => {
            s.world.remove_branch(id);
            none
        },
        let x: root.machine.DeleteRemoteBranch => {
            s.world.delete_remote_branch(id);
            none
        },
        let x: root.machine.SecondOpinion => {
            let started: root.machine.Event[] = [];
            let second = if (s.policy.brief_model.length() > 0) {
                s.policy.brief_model
            } else {
                s.policy.research
            };
            let _ = s.world.start_round(id, root.world.RoundKind.Research, second, x.first_reply) catch (e) {
                root.machine.Infra => {
                    started = [e];
                },
            };
            started
        },
        let x: root.machine.WriteParkBrief => {
            s.world.write_park_brief(id, x.because);
            none
        },
        let x: root.machine.PushAndOpenPr => {
            let opened: root.machine.Event = s.world.push_and_open_pr(id, x.title, x.body);
            [opened]
        },
        let x: root.machine.PushBranch => {
            let pushed: root.machine.Event = s.world.push_branch(id);
            [pushed]
        },
        let x: root.machine.MergePr => {
            s.world.merge_pr(id);
            none
        },
        let x: root.machine.UpdateBranch => {
            s.world.update_branch(id);
            none
        },
        let x: root.machine.Relabel => {
            s.world.relabel(id);
            none
        },
        let x: root.machine.CloseBead => {
            s.world.close_bead(id, x.url);
            none
        },
        let x: root.machine.Refuse => {
            s.world.note(id, x.why);
            none
        },
    }
}

/// One pass. Reads the world, then decides; everything it does is safe to do again.
function tick(s: Supervisor) -> void throws never {
    // What runs is asked before results are taken: a round that ends in between still
    // counts as running, and its result is there next tick.
    let alive = s.world.running() catch (e) {
        root.machine.Infra => {
            let none: root.world.RoundRunning[] = [];
            none
        },
    };
    take_finished(s);
    settle_lost(s, alive);
    take_inbox(s);
    adopt_prs(s);
    watch_prs(s);
    admit_tickets(s);
    expire_holds(s);
    start_rounds(s);
    write_view(s, alive);
}

/// A bead on a round whose process is gone and left no result: the round died (killed,
/// out of memory). Lost, not charged, and tried again.
function settle_lost(s: Supervisor, alive: root.world.RoundRunning[]) -> void throws never {
    for (let b in s.beads) {
        let on_a_round = b.place is root.machine.Working
            || b.place is root.machine.Reviewing
            || b.place is root.machine.Researching;
        if (
            on_a_round
                && !alive.some((r) -> {
                    r.id == b.id
                })
        ) {
            apply(s, b.id, root.machine.RoundLost { kind: "round_lost" });
        }
    }
}

function take_finished(s: Supervisor) -> void throws never {
    let done = s.world.take_finished() catch (e) {
        root.machine.Infra => {
            let none: root.world.RoundDone[] = [];
            none
        },
    };
    for (let d in done) {
        for (let event in d.events) {
            apply(s, d.id, event);
        }
    }
}

/// What you told the loop: an answer, a reopen or an escalation, each on its bead.
function take_inbox(s: Supervisor) -> void throws never {
    let mail = s.world.inbox() catch (e) {
        root.machine.Infra => {
            let none: root.world.Mail[] = [];
            none
        },
    };
    for (let m in mail) {
        if let e: root.machine.Event = m.event {
            apply(s, m.id, e);
        }
        if let o: root.world.Order = m.order {
            carry_out(s, m.id, o);
        }
    }
}

/// An order from the page or `tell`: the supervisor is the one that acts on a bead.
function carry_out(s: Supervisor, id: string, o: root.world.Order) -> void throws never {
    match (o) {
        let x: root.world.AbortOrder => s.world.abort(id),
        let x: root.world.NoteOrder => {
            let _ = s.world.note(id, `operator: ${x.text}`) catch (e) {
                root.machine.Infra => {
                    log.warn(`${id}: note: ${e.words}`);
                },
            };
        },
    }
}

/// An open `bead/ID` PR this loop is not already carrying joins the merge queue. The
/// step decides: only a ready bead with no PR of its own takes it.
function adopt_prs(s: Supervisor) -> void throws never {
    if (!s.adopt) {
        return;
    }
    let open = s.world.adoptable() catch (e) {
        root.machine.Infra => {
            let none: root.world.Adoptable[] = [];
            none
        },
    };
    for (let a in open) {
        let known = s.bead(a.id) ?? root.machine.Bead.new(a.id);
        // A branch pushed for you to open: the PR you opened is the one it waited for.
        if (known.place is root.machine.Publishable) {
            apply(s, a.id, root.machine.PrOpened { kind: "pr_opened", url: a.url, head: "" });
            continue;
        }
        if (known.pr == null && known.place is root.machine.Ready) {
            apply(s, a.id, root.machine.PrAdopted { kind: "pr_adopted", url: a.url, own: a.own });
        }
    }
}

function watch_prs(s: Supervisor) -> void throws never {
    for (let b in s.beads) {
        if let m: root.machine.Merging = b.place {
            let seen = s.world.observe_pr(b.id, m.pr) catch (e) {
                root.machine.Infra => {
                    let failed: root.machine.Event[] = [e];
                    failed
                },
            };
            for (let event in seen) {
                apply(s, b.id, event);
            }
        }
    }
}

function admit_tickets(s: Supervisor) -> void throws never {
    let tickets = s.world.tickets() catch (e) {
        root.machine.Infra => {
            return;
        },
    };
    s.ready
        = tickets.map((t) -> {
            t.id
        });
    for (let t in tickets) {
        let _ = s.known.set(t.id, t);
        if (s.bead(t.id) == null) {
            s.put(root.machine.Bead.new(t.id));
        }
    }
}

/// A hold ends by being tried again: the next attempt either works or holds it afresh.
function expire_holds(s: Supervisor) -> void throws never {
    for (let b in s.beads) {
        if (b.hold != null) {
            let n = (s.held_for.get(b.id) ?? 0) + 1;
            // A usage limit resets in hours, not ticks: try it again every half hour.
            let lasts = if ((b.hold?.words ?? "").starts_with("usage limit on ")) {
                s.hold_ticks * 12
            } else {
                s.hold_ticks
            };
            if (n >= lasts) {
                let _ = s.held_for.set(b.id, 0);
                apply(s, b.id, root.machine.HoldCleared { kind: "hold_cleared" });
            } else {
                let _ = s.held_for.set(b.id, n);
            }
        }
    }
}

/// Fewest failures first, so everything is tried once before anything is tried twice.
function queue_of(
    s: Supervisor,
    wanted: (root.machine.Bead) -> bool throws never,
) -> root.machine.Bead[] throws never {
    let waiting = s.beads.filter((b) -> {
        b.hold == null && wanted(b)
    });
    waiting.sort_by_key((b) -> {
        b.failures
    })
}

/// Ready here, and listed by `bd ready` now.
function pickable(s: Supervisor, b: root.machine.Bead) -> bool throws never {
    b.place is root.machine.Ready && s.ready.includes(b.id)
}

function needs_research(s: Supervisor, b: root.machine.Bead) -> bool throws never {
    s.policy.research.length() > 0 && b.brief == null
}

/// `devbox/coder` runs on `devbox`. A lane is a model server, so it is the provider.
function provider_of(model: string) -> string throws never {
    model.split("/").at(0) ?? model
}

/// Whether the server `model` runs on has a free slot, counting `busy` across every repo.
function lane_free(s: Supervisor, busy: string[], model: string) -> bool throws never {
    // No model: the stages are used up, and picking it is what parks it.
    if (model.length() == 0) {
        return true;
    }
    let p = provider_of(model);
    // A usage limit on the provider holds all of its rounds, not just the bead that met it.
    let limited = s.beads.some((b) -> {
        (b.hold?.words ?? "").starts_with(`usage limit on ${p}:`)
    });
    if (limited) {
        return false;
    }
    let used = busy
        .filter((m) -> {
            provider_of(m) == p
        })
        .length();
    used < (s.capacity.get(p) ?? s.lanes)
}

/// PRs this supervisor has in the merge queue. An adopted PR is someone else's and
/// does not count, as in the Rust loop.
function inflight(s: Supervisor) -> int throws never {
    s.beads
        .filter((b) -> {
            own_pr(b)
        })
        .length()
}

function own_pr(b: root.machine.Bead) -> bool throws never {
    if let m: root.machine.Merging = b.place {
        !m.adopted
    } else {
        false
    }
}

/// The dev lane waits while the merge queue is at a cap. Review and research go on: they
/// do not open a PR of their own until a bead already in review is approved.
function dev_paused(s: Supervisor) -> bool throws never {
    let here = inflight(s);
    (s.max_inflight > 0 && here >= s.max_inflight)
        || (s.max_open_prs > 0 && here + s.group_inflight >= s.max_open_prs)
}

/// A rebase round goes to the conflict worker, else the last stage's; any other round to
/// the stage its failures are at.
function worker_of(s: Supervisor, b: root.machine.Bead) -> string throws never {
    if (b.order == root.machine.Order.Rebase || b.order == root.machine.Order.Feedback) {
        let last = s.policy.stages.at(s.policy.stages.length() - 1)?.worker ?? "";
        return if (s.policy.conflict_worker.length() > 0) {
            s.policy.conflict_worker
        } else {
            last
        };
    }
    root.machine.stage_for(s.policy, b.failures)?.worker ?? ""
}

function reviewer_of(s: Supervisor, b: root.machine.Bead) -> string throws never {
    root.machine.stage_for(s.policy, b.failures)?.reviewer ?? ""
}

/// Reviews first, then research, then work, each on its own server's lane. A worker
/// lane with no briefed bead to take works one without a brief rather than sit idle.
function start_rounds(s: Supervisor) -> void throws never {
    let running = s.world.running() catch (e) {
        root.machine.Infra => {
            return;
        },
    };
    let busy: string[] = running.map((r) -> {
        r.model
    });
    for (let m in s.elsewhere) {
        busy.push(m);
    }
    for (
        let b in queue_of(s, (x) -> {
            // Only a bead bd still lists: one you took the label off, blocked or closed
            // waits where it is.
            x.place is root.machine.InReview && s.ready.includes(x.id)
        })
    ) {
        let model = reviewer_of(s, b);
        if (lane_free(s, busy, model) && start_review(s, b) > 0) {
            busy.push(model);
        }
    }
    for (
        let b in queue_of(s, (x) -> {
            pickable(s, x) && needs_research(s, x)
        })
    ) {
        if (lane_free(s, busy, s.policy.research) && start_research(s, b) > 0) {
            busy.push(s.policy.research);
        }
    }
    if (dev_paused(s)) {
        return;
    }
    for (
        let b in queue_of(s, (x) -> {
            pickable(s, x) && !needs_research(s, x)
        })
    ) {
        let model = worker_of(s, b);
        if (lane_free(s, busy, model) && start_work(s, b) > 0) {
            busy.push(model);
        }
    }
    for (
        let b in queue_of(s, (x) -> {
            pickable(s, x) && needs_research(s, x)
        })
    ) {
        let model = worker_of(s, b);
        if (lane_free(s, busy, model) && start_work(s, b) > 0) {
            busy.push(model);
        }
    }
}

function start_research(s: Supervisor, b: root.machine.Bead) -> int throws never {
    apply(s, b.id, root.machine.ResearchPicked { kind: "research_picked" });
    let now = s.bead(b.id) ?? b;
    if (!(now.place is root.machine.Researching) || now.hold != null) {
        return 0;
    }
    start(s, b.id, root.world.RoundKind.Research, s.policy.research)
}

function start_work(s: Supervisor, b: root.machine.Bead) -> int throws never {
    apply(s, b.id, root.machine.Picked { kind: "picked" });
    let now = s.bead(b.id) ?? b;
    if (!(now.place is root.machine.Working) || now.hold != null) {
        return 0;
    }
    start(s, b.id, root.world.RoundKind.Work, worker_of(s, now))
}

function start_review(s: Supervisor, b: root.machine.Bead) -> int throws never {
    apply(s, b.id, root.machine.ReviewPicked { kind: "review_picked" });
    start(s, b.id, root.world.RoundKind.Review, reviewer_of(s, b))
}

function start(
    s: Supervisor,
    id: string,
    kind: root.world.RoundKind,
    model: string,
) -> int throws never {
    let ok = true;
    let note = s.bead(id)?.last_note ?? "";
    let _ = s.world.start_round(id, kind, model, note) catch (e) {
        root.machine.Infra => {
            apply(s, id, e);
            ok = false;
        },
    };
    if (ok) {
        1
    } else {
        0
    }
}

/// Start is the only path: fold every log, then settle any round that has no process left.
/// A stop needs no handling of its own, because a stop is a restart.
function recover(
    world: root.world.World,
    log: Log,
    policy: root.machine.Policy,
) -> Supervisor throws never {
    let s = Supervisor.new(world, log, policy);
    for (let id in log.ids()) {
        s.put(root.machine.fold(id, log.load(id), policy));
    }
    // Results first: a round that ended while the loop was down is finished, not lost.
    take_finished(s);
    let alive = world.running() catch (e) {
        root.machine.Infra => {
            return s;
        },
    };
    for (let b in s.beads) {
        let on_a_round = b.place is root.machine.Working
            || b.place is root.machine.Reviewing
            || b.place is root.machine.Researching;
        if (
            on_a_round
                && !alive.some((r) -> {
                    r.id == b.id
                })
        ) {
            apply(s, b.id, root.machine.RoundLost { kind: "round_lost" });
        }
    }
    s
}

class KindOnly {
    kind: string,
    words: string?,
    line: string?,
    url: string?,
}

/// One line for the journal and the page: the event's kind and its words, short.
function event_line(event: root.machine.Event) -> string throws never {
    let json = baml.json.stringify(event) catch_all (e) {
        _ => {
            return "?";
        },
    };
    let k = baml.json.decode<KindOnly>(json) catch_all (e) {
        _ => {
            return "?";
        },
    };
    let said = (k.words ?? k.line ?? k.url ?? "").split("\n").at(0) ?? "";
    let short = if (said.length() > 160) {
        said.slice(0, 160)
    } else {
        said
    };
    if (short.length() > 0) {
        `${k.kind} ${short}`
    } else {
        k.kind
    }
}

test "an event's journal line is its kind and first words" {
    assert.equal(event_line(root.machine.Picked { kind: "picked" }), "picked");
    assert.equal(
        event_line(root.machine.Rejected { kind: "rejected", line: "REJECT: x", text: "t" }),
        "rejected REJECT: x",
    )
}
