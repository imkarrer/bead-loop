// The supervisor: observe the world, turn what changed into events, fold them, and start
// whatever should be running. Nothing here waits on anything: a tick reads the world and
// returns, and the next tick reads it again. docs/design-baml-native.md has the shape.

class Supervisor {
    world: root.world.World,
    log: Log,
    policy: root.machine.Policy,
    beads: root.machine.Bead[],
    /// How many rounds may run at once on each lane.
    lanes: int,
    /// Ticks a hold lasts before the bead is tried again.
    hold_ticks: int,
    held_for: map<string, int>,

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
            hold_ticks: 5,
            held_for: {},
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
    let next = root.machine.step(current, event, s.policy);
    s.put(next.bead);
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
        let x: root.machine.SecondOpinion => none,
        let x: root.machine.WriteParkBrief => {
            s.world.write_park_brief(id, x.because);
            none
        },
        let x: root.machine.PushAndOpenPr => {
            let opened: root.machine.Event = s.world.push_and_open_pr(id);
            [opened]
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
    take_finished(s);
    watch_prs(s);
    admit_tickets(s);
    expire_holds(s);
    start_rounds(s);
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
            let none: root.world.Ticket[] = [];
            none
        },
    };
    for (let t in tickets) {
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
            if (n >= s.hold_ticks) {
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

function start_rounds(s: Supervisor) -> void throws never {
    let busy = s.world.running() catch (e) {
        root.machine.Infra => {
            return;
        },
    };
    let free = s.lanes - busy.length();
    for (
        let b in queue_of(s, (x) -> {
            x.place is root.machine.InReview
        })
    ) {
        if (free > 0) {
            free = free - start_review(s, b);
        }
    }
    for (
        let b in queue_of(s, (x) -> {
            x.place is root.machine.Ready
        })
    ) {
        if (free > 0) {
            free = free - start_work(s, b);
        }
    }
}

function start_work(s: Supervisor, b: root.machine.Bead) -> int throws never {
    apply(s, b.id, root.machine.Picked { kind: "picked" });
    let now = s.bead(b.id) ?? b;
    if (!(now.place is root.machine.Working) || now.hold != null) {
        return 0;
    }
    let model = root.machine.stage_for(s.policy, now.failures)?.worker ?? "";
    start(s, b.id, root.world.RoundKind.Work, model)
}

function start_review(s: Supervisor, b: root.machine.Bead) -> int throws never {
    apply(s, b.id, root.machine.ReviewPicked { kind: "review_picked" });
    let model = root.machine.stage_for(s.policy, b.failures)?.reviewer ?? "";
    start(s, b.id, root.world.RoundKind.Review, model)
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
        let on_a_round = b.place is root.machine.Working || b.place is root.machine.Reviewing;
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
