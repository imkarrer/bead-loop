# Design: the bead state machine, and lanes per model server

Status: **built**, as `[[lanes]]` in the global config (PR #35, on the Rust supervisor;
docs/config.md). Lanes derive from the providers since PR #102; see
[design-providers.md](design-providers.md). Kept as the record of why. Written
2026-09-19, after
the three-queue / two-lane change (#17) and the human queue (#23), against the bash
supervisor of the time. What differs from the proposal: lanes are keyed by model globs
(`models = ["acbox/*"]`) rather than discovered from the stages; `state/ID` was not
built — a bead's state is still the marker files, listed in
[state-machine.md](state-machine.md); the reviewer on ac-box is now `acbox/reviewer`
(gpt-oss-120b), not the 80B; the last stage is `claude/sonnet`.

## What is wrong now

Two things, one of them the reason for this note.

1. **The Claude stage waits behind the GPU.** The last stage — `claude/opus` worker and
   reviewer — runs on the dev and review lanes like every other stage. A Claude round
   costs this box nothing (it runs at Anthropic), yet it queues behind a 30B round on the
   4080 in the dev lane, or a 80B round on ac-box in the review lane. When a bead is
   escalated to Claude by hand, that is the moment the operator most wants it to start
   *now*.
2. **Two stages on one server fight.** Stage 2's worker is `acbox/coder`; stage 1's
   reviewer is `acbox/coder`. When the dev lane is on a stage-2 bead and the review lane
   on a stage-1 bead, both hit the 80B and llama-swap serialises them: both lanes run at
   half speed and neither knows why.

Both come from lanes being keyed by **role** (dev, review) when the scarce thing is the
**server**. A lane per server fixes both: Claude gets a lane of its own that never waits
for local hardware, and two rounds that need ac-box queue on ac-box's lane in order,
instead of colliding.

## The state machine, explicit

Today a bead's state is implicit: `open` / `in_progress` / `closed` in bd, plus marker
files (`review/ID`, `inflight/ID`, `lane.*`). It works, but "where is this bead" is a
query over four places. The proposal makes it one file, `state/ID`, holding one word:

```
ready ──► dev ──► gate ──► review ──► merge ──► closed
           │        │         │          │
           └────────┴─────────┴──────────┴──► human
                                                │
ready ◄──── answer · reopen · escalate ─────────┘
```

| state    | means                                            | who moves it on                   |
| -------- | ------------------------------------------------ | --------------------------------- |
| `ready`  | in the dev queue (bd `open`, the label)          | a lane whose server has its stage's worker |
| `dev`    | a worker round is running                        | the lane                          |
| `gate`   | the gate is running (part of the same round)     | the lane                          |
| `review` | in the review queue, or a reviewer round running | a lane whose server has its stage's reviewer |
| `merge`  | PR in CI                                         | reconcile                         |
| `closed` | merged; bd `closed`                              | —                                 |
| `human`  | waiting on you                                   | you: answer, reopen, escalate     |

Send-backs (+1 failure, `→ ready`): the gate failing twice, BLOCKED or no commit,
REJECT, CI red. Into `human`: stages exhausted, BLOCKED at the last stage, PR closed
unmerged. `closed` is terminal.

`state/ID` is written by whoever moves the bead, atomically (write to a temp file,
rename). bd's own status stays what it is — `open` for `ready`, `in_progress` for
everything else, `closed` at the end — because the workers and skills read bd, and bd
is the audit trail; `state/ID` is the loop's index over it.

## Lanes per server

A **server** is a model endpoint that runs one thing at a time: `devbox` (the 4080),
`acbox` (the 80B on CPU), `claude` (Anthropic — effectively unlimited, but one lane keeps
the accounting simple and the page readable). The config already names models as
`provider/model`; the provider is the server.

```toml
[[stages]]
worker = "devbox/coder"     # server: devbox
reviewer = "acbox/coder"    # server: acbox
failures = 3
```

A tick starts **one lane per server named anywhere in the stages**. Each lane's loop:

1. Look at every queued round — `ready` beads (a worker round, model = the bead's
   stage's worker) and `review` beads not yet being reviewed (a reviewer round, model =
   the stage's reviewer) — and keep the ones whose model's server is mine.
2. Take the first by the same order as today: **review rounds before dev rounds**
   (finishing work beats starting work), then fewest failures, then bd's order.
3. Run it: a worker round is claim → worktree → worker → gate → `review`; a reviewer
   round is reviewer → push → `merge`. Exactly the code in `dev_one` and `review_one`
   today, with the lane no longer deciding which of the two it is.
4. Go round while there is work for me, or any other lane is busy (it may hand me
   something); leave after the others have looked idle three checks running.

`max_inflight` gates worker rounds only, as now. `pause` is per server: `pause acbox`.
`lane.NAME` becomes `lane.<server>` with the bead and the role.

What the operator sees: the page's lane panels become one per server — **devbox**,
**acbox**, **claude** — each saying which bead and which role (worker or reviewer) it is
on. The five queues are: **dev**, **review**, **merge**, **needs you**, and **Claude** —
the last one a view, not a state: every bead whose current stage names a `claude/*`
model, with where it sits (ready, review, on the claude lane). That is the honest
version of "the Claude queue": Claude is a server that has a lane, and beads are on his
stage or not.

## What does not change

- The stages table and the failure counter. A send-back is a failure wherever it comes
  from; the count alone picks the stage.
- `dev_one` and `review_one` — the rounds themselves. The change is who calls them.
- Reconcile, the merge queue, adoption, the timer, `--once`, `--serial`, `work`, `open`,
  `answer`, `escalate`.
- The UI's levers. Abort per lane still works; there are just more lanes.

## What it costs

- Three processes per tick instead of two, on a box that already runs the model. Nothing.
- The tests: the lane cases (`lanes_run_side_by_side`, `review_lane_waits_for_dev_to_claim`,
  `pause_one_lane`) are rewritten for `stub` as a server name; the round cases are untouched.
- One real question, below.

## The question to grill

**A worker round and its reviewer round on the same server.** With stage 2 (`acbox/coder`
worker, `acbox/instruct` reviewer), the acbox lane does the worker round, puts the bead
in `review`, and then — being the only lane for acbox — takes the reviewer round next,
before any other acbox worker round. Is that the right order? It is the "finish before
start" rule applied, and it keeps a bead's rounds together. The alternative, strict
fewest-failures-first across roles, would let a fresh bead's worker round jump ahead of
a review that is one step from a PR. I think finishing wins, but it is a choice.

**Claude as one lane.** Anthropic can run many sessions at once; one lane means one
Claude round at a time. That is fine while Claude is the last stage and rare. If Claude
became a first-stage worker, the lane would want a `parallel = N`. Not now.

## Order of work

1. `state/ID` written alongside today's markers, read by `status`. No behaviour change;
   the page's five queues come from it. One PR.
2. Lanes per server, replacing `lane dev|review`; the tests rewritten. One PR.
3. Remove the old markers once nothing reads them.
