# Design: a resident loop — the queues wake the lanes, no tick

Status: **built** — `bead-supervisor run` (PR #33, the Rust rewrite) is this design;
it runs as [config.md](config.md) and [operating.md](operating.md) say. Kept as the record of why. Written
2026-09-20 against the bash supervisor of the time, from one night of the journal and
`gh pr view` on the PRs it opened; "today" below means that supervisor. Of the questions
at the end: the bell is a one-second poll, not inotify; the watcher polls; Claude's
sign-in is re-probed on every wake; the config is re-read every round; and lanes per
server followed in #35.

## What the tick is for, and what it is not

The README gives three reasons for "a oneshot and a timer":

1. *State is on disk and in bd, so a crash or `systemctl stop` loses nothing.* True, and
   nothing about it needs a tick: a daemon with `Restart=on-failure` and the same state
   has the same property.
2. *It gives `gpu-mode` one unit to stop and start.* A service is one unit too.
3. *The only wait left is CI, and that is why a timer exists.* CI must be polled either
   way; the timer is one place to do it, and the worst one (below).

A tick already is a resident loop *while there is work*: each lane goes round its queue
until it looks empty. The tick's only real content is what happens then — the lane
exits, and nobody looks at anything until the timer fires.

## What it costs, measured

The tick of 2026-09-20 02:29 → 03:51, `inquire-platform`, `merge = "pipeline"`:

| when | what |
| --- | --- |
| 03:37:51 | review lane opens PR 70, labels it `automerge` |
| 03:39:58 | the pipeline merges PR 70 (`gh pr view 70 --json mergedAt`) |
| 03:45:44 | dev lane finishes `inq-85h.19` → review queue; then `1 in flight (max 1); waiting on CI` — with two beads in the dev queue and the GPU idle |
| 03:50:46 | review lane REJECTs `inq-85h.19` → dev queue; the dev lane is already leaving |
| 03:51:11 | tick ends; the closing `reconcile` sees PR 70 `MERGED`, closes the bead |
| 03:54:14 | the timer's next tick starts the next bead |

`reconcile` runs at the edges of a tick, so `inflight/inq-85h.15` stayed for 11 minutes
after the PR was gone, and `max_inflight` held the GPU for it. Then the tick had to end
(30 s of "is the other lane idle" checks) and the timer had to fire (3 min). **Fourteen
minutes of the 4080 idle with work queued**, from nothing but *when* the merge queue is
read. The rejected bead waited the same way. When nothing is queued, the shape is a
22-second tick every four minutes, all night, each one three `bd ready` calls and three
10-second sleeps.

## The proposal: `bead-supervisor run`

One resident process. Nothing about a round changes — `dev_one`, `review_one`,
`send_back`, `reconcile`'s per-PR logic, the stages, the failure count. What changes is
the waiting:

```
run
├── dev lane      pick → round → pick → … → nothing? block on the bell
├── review lane   pick → round → pick → … → nothing? block on the bell
└── merge watcher inflight/ empty? block on the bell. Else: gh every 30 s, reconcile
                  that PR, ring the bell when it closes a bead or sends one back
```

**The bell.** A lane with nothing to do does not sleep and does not exit: it blocks on
`inotifywait` over the queue directories (`$RS/review/`, `$RS/inflight/`) and one file,
`$STATE_DIR/wake`, with a 60-second timeout as the heartbeat. Every producer already
writes to those directories — the gate passing writes `review/ID`, APPROVE writes
`inflight/ID`, `send_back` reopens the bead and removes markers, the watcher removes
`inflight/ID`. Producers that only touch bd (`answer`, `escalate`, the UI's Reopen, a
`bd label add` by hand) `touch wake`. So a consumer wakes the moment its input exists,
and costs nothing while it does not. (`inotify-tools` is in the flox catalog. The
no-dependency form is a 5-second poll; the loop is the same either way, only the wait
differs, and `wait_for_work` is one function.)

**The merge queue is watched from inside.** The watcher loop is `reconcile` with a
sleep: while `inflight/` is non-empty, ask GitHub every 30 s (or `gh pr checks NUM
--watch`, which blocks until the checks conclude — one call per PR instead of a poll);
close, send back, or wait, per PR, exactly as today; ring the bell on any change. When
`inflight/` is empty it blocks on the bell like a lane. `close_merged` rings the bell
because closing a bead may unblock its dependents (below). On the night above, PR 70
merges at 03:39:58, the watcher sees it by 03:40:30, and the bead closes then, not at
03:51.

**The bookkeeping that disappears.** The three-checks-idle exit dance (`other_busy`,
`idle`, `LANE_WAIT`), `queued_work` and the "lanes done but work is queued; going round
again" retry, the timer unit, `OnUnitInactiveSec`, and the UI's `systemctl start
--no-block` after `answer`/`escalate`. `tick` stays as `run --until-idle` — the exact
semantics the test suite drives — so the tests, `--once`, `--serial`, `work`, and
`lane dev|review` do not change.

**Pause gets better.** A paused lane today exits the tick; the next tick after
`resume` picks it up. A paused resident lane blocks on the bell; `resume` touches
`wake` and it is on the next bead within a second.

**Stop and crash.** `systemctl stop` is today's `Stop tick`: the TERM handler aborts
each lane's model session and clears `lane.*`. `Restart=on-failure`, `RestartSec=10`.
At start, `run` removes stale `lane.*` files (it is the only process that writes them;
a `kill -9` leaves them, and today a stale `lane.dev` keeps the review lane polling
forever — an existing hole this closes). `gpu-mode game` stops the service, `work`
starts it; one unit each way, as now.

**Dogfood: the loop updating itself.** The timer re-reads `bin/bead-supervisor` every
tick, so a merged bead changed the running loop within minutes. A resident bash process
keeps the inode it started from (git writes a new file on merge, so the running script
is not corrupted), and re-execs itself — `exec "$0" run` — at the next moment all three
loops are blocked on the bell, when the file on disk differs from the one it started
with. Same effect, one check.

## Nothing holds the dev lane but dependencies

The dev queue is already a priority queue: `bd ready -l LABEL` lists only *unblocked*
beads — one with an open blocker is not in the queue at all — and `dev_queue` orders
them fewest failures first. A blocker closes at merge, so a dependent bead is handed
out only once the work it needs is on `origin/BASE`, which is what its fresh worktree
forks from. That is the whole ordering rule: **no dependencies, fewest tries, first.**

`max_inflight` is the one thing not in that spirit: it stops the dev lane when N PRs
are in CI, dependencies or not. Last night with `max_inflight = 1` the GPU stood still
behind one green PR while two independent beads waited. The queues exist to absorb
exactly that shock, so the limit goes: the default becomes no limit (the key stays as
an opt-in cap for a repo whose CI is the scarce thing), and the dev lane goes round
until `bd ready` is empty. The review and merge queues may then be several deep;
that is what they are for.

What several PRs in flight needs that one did not:

- **A conflicting PR is a send-back.** When two independent beads touch the same file,
  the second one's PR is green and `mergeStateStatus = DIRTY` once the first merges.
  Today `reconcile` logs "green but merge refused (DIRTY)" every pass and the bead sits
  in the merge queue for ever; under `pipeline` it says "waiting for the pipeline" for
  ever. Both become `send_back … keep "rebase onto BASE: conflicts in <files>"`: the next
  round's worker resolves them on the same branch and the push updates the PR. One more
  row in the outcome table. This is the first thing to build, before the cap is lifted
  on a repo with `merge = "pipeline"`.
- **`BEHIND` under `auto`** already updates the branch and reruns CI; with N PRs open, each
  merge can make the rest BEHIND. That is only true when branch protection requires
  strict status checks; otherwise GitHub merges a green PR that is behind. Nothing to
  build; noted so a burst of CI reruns is not a surprise.
- **Adopted PRs** never counted toward the cap and are unaffected.

## What the lanes look like

```bash
lane() {            # today's lane(), minus the exit logic
  while :; do
    [ -e "$STATE_DIR/pause.$name" ] && { wait_for_work; continue; }
    moved=0
    for r in "${REPOS[@]}"; do load_repo "$r"; one_round && moved=1; done
    [ "$moved" = 1 ] && continue
    [ "$UNTIL_IDLE" = 1 ] && all_idle && return 0      # tick: the old exit condition
    wait_for_work                                       # inotifywait -t 60 … || sleep 5
  done
}
```

`run` starts the two lanes and the watcher as subshells, as `tick` starts the lanes
today, and waits on them. The per-lane `flock`s stay, so a hand-run `work` still
refuses to collide with a busy lane.

## What does not change

- The rounds, the stages table, the failure counter, the outcome table in the README.
- The state files: `review/`, `inflight/`, `failures/`, `lane.*`, `wt/`. The bell adds one
  file, `wake`.
- `status`, `--json status`, `watch`, `log`, `open`, `answer`, `escalate`, `reconcile`
  as a command.
- The UI's page, except: the timer panel becomes the service's state (running, stopped,
  since when); *Tick now* goes (nothing waits long enough to need it; *Wake* is a
  `touch` if a lever is wanted); *Stop tick* becomes *Stop the loop*; *Pause / Resume
  timer* becomes stop/start of the service, or `pause dev` + `pause review`.
- flox: `[services.loop]` becomes `exec bead-supervisor run`; the `sleep 600` goes.

## Questions to grill

1. **inotify or a 5-second poll?** inotify is exact and free when idle, and is one more
   binary. A 5 s poll needs nothing and costs one `bd ready` per lane per 5 s forever.
   The proposal is inotify with the poll as the fallback when `inotifywait` is missing;
   the wait is one function either way.
2. **`gh pr checks --watch` or a 30-second poll?** `--watch` is one long call per PR
   and returns when the checks finish, but under `merge = "pipeline"` the merge comes
   *after* the checks, so a poll for `MERGED` follows anyway. Start with the poll (the
   UI already makes the same call once a minute; the watcher can feed it instead), keep
   `--watch` in reserve.
3. **`claude_ok` is asked once per process.** In a resident loop that is once per boot.
   It must be asked once per *wake* — a bead waiting on sign-in should start the moment
   the UI's Sign in completes (which can `touch wake`).
4. **Config reload.** `load_repo` re-reads both TOML files every round already, so a
   config edit takes effect on the next round, as it does today. The global `repos`
   list is read at start; adding a repo means a restart, or the re-exec check watches
   the global config file too. Cheap to include.
5. **Two lanes or one per server.** Independent of this note; the
   [lanes-per-server design](design-lanes-per-server.md) becomes a smaller change once a
   lane is "pick from my queues, run, block on the bell" — only the keying moves.

## Order of work

The state machine this loop must satisfy — every state, every exit, the hazards checked
— is [state-machine.md](state-machine.md); its build order puts the merge-queue exits
and "infrastructure is not failure" before the resident loop, so the loop never crunches
faster into a hole.

0. The conflicting-PR send-back and `max_inflight` defaulting to no limit. Small, and
   independent of the rest; the live config can drop `max_inflight = 1` the same day.
1. `run`: the bell, the watcher, `tick` as `run --until-idle`, the units and the flox
   service, the README's "What a tick is" rewritten as "How the loop waits". The test
   suite gets two cases: a lane blocked on the bell wakes on `review/ID` appearing; the
   dev lane at `max_inflight` wakes when the watcher removes `inflight/ID`. One PR.
2. The UI's levers and timer panel. One small PR.
3. Lanes per server, on top.
