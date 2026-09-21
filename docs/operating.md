# Operating the loop: the page, the terminal, the state on disk

## The page

**<http://127.0.0.1:4097>** — `bead-loop-ui.service`, one page, pushed on every change
(an event stream; nobody presses refresh). Top to bottom:

- **The header**: the loop — up since when and what it is on, or down — with **Wake**,
  **Stop** (the keeper timer brings it back in a minute: a breather) and **Off** (timer
  too: down until you start it); **Sign in** when `claude` is signed out (it runs `claude
  auth login`: open the link, sign in, paste the code back into the page; the bell rings
  when it is done); and, where the box has a `gpu-mode` command, a **Work / Game** switch
  (`game` stops the loop and the local model server to free the GPU, `work` starts them
  again; run as `sudo -n gpu-mode`, so sudoers must allow it without a password).
- **The lanes**, one panel each: the bead it is on, its repo, title, failure count and
  stage, the live session's model, when it last produced output, a link into it, **Abort**
  — or why it is idle (nothing queued for it; N queued and starting; Claude signed out) —
  and **Pause / Resume** (the round it is on finishes and it starts no new one; resume is
  instant).
- **The scoreboard**, over 24h, 7d, 30d or all of it: **Landed**, **First try** (no
  send-back), **Without Claude** (landed by a local model: the point of the local stack),
  **Rounds per landing**, **Time to land** (first claim to merge), **Needed you**; under
  them where rounds go back (by reason: no commit, gate, review, CI red, blocked, timed
  out, crashed), by model, model hours by role with the **empty rounds** (a session the
  server never answered), and the beads finished, newest first. Read from what the beads
  and the session logs already carry, once a minute (`bead-supervisor --json stats`).
- **Per repo**, with **★ make priority** on its heading: the three queues in their order
  — **dev** (#1 is next; each bead's failures and the stage that puts it on), **review**
  (how long each has waited), **merge** (each PR with GitHub's word on it: CI running
  m/n, red with the failing check, green, merged, conflicting). Every dev and review row
  has **✎ note**: a word to the bead before its next round — context it lacked, a claim
  that changed — put on the bead as an operator note, which that round reads; nothing
  else moves.
- **Needs you**, per repo: first each **decision** — a bead of type `decision` (or
  labelled `needs-human`) is a question for you, asked by the loop, by an agent planning
  work, or by yourself (`bd create -t decision "the question" -d "the context"`); its
  text in full and an answer box. **Answer & close** puts the answer on the bead as its
  close reason, where whoever asked reads it, and rings the bell: beads that depended on
  the decision are ready. Then each bead **parked**, with **the question** first — the
  brief's, or the loop's own — and, folded under it, the brief in full, **the rounds**
  (each with its worker, stage, when, the whole note it left and its **logs**: the
  worker's session, the gate, the reviewer, the brief, each opening in place) and the
  bead's notes; then the ways out: **Answer & resume** (your reply goes on the bead, the
  bead returns to the dev queue at the stage it stopped on with that round forgiven),
  **Work with Claude** (the last stage, now), **Reopen** (as is), or the one-line
  `bead-supervisor open` command. Then each bead **held** — still in its queue, waiting
  on something outside the loop, with the reason and where it sits; nothing to press, it
  clears itself when the world changes. Last, only when there is one, a session the
  server is still running that is on no lane (an orphan of a killed round, a hand-run
  `work`), with Abort.
- **The supervisor's log**, live.

The server binds to loopback and refuses cross-site requests; it needs `node`, and
`systemctl`/`journalctl` for the units and log (without them, those parts say so and the
rest works).

## The brief

Before the loop parks a bead for you it writes the **brief**: one call to `brief_model`
(the last stage's worker unless set) that reads every round's note and the end of every
round's log and answers *what happened*, *why* (the bead is wrong about X; the bead is
underspecified; the environment; the model) and *the question*, with the options and
what each would mean. Without a brief (no model, Claude signed out, the call failing) the
loop's own question stands: the `BLOCKED:` line and what you can do about it, or the
count of rounds and the last send-back. So what reaches you is a question, not a stack
of notes. `bead-supervisor answer` and `open` are the page's Answer and the one-line
command from a terminal.

## The terminal

```bash
bead-supervisor watch                                     # the screen below, every 5 s (BEAD_LOOP_WATCH=N)
bead-supervisor status                                    # the same, once
bead-supervisor --json status                             # one JSON object per repo: what the UI reads
bead-supervisor stats                                     # the scoreboard, one line per window (--json for the page's)
journalctl --user -u bead-supervisor.service -f -o cat    # stage transitions, one line each, live
bead-supervisor log ~/src/repo [bead-id]                  # the newest session's log, one line per tool call
```

```
05:41:12   bead-supervisor watch (every 5s, ctrl-c to stop)

05:39:22 inquire-platform: dev: bead inq-ufz.13 — grading.dlq: 30-day retention (0 failures, worker devbox/coder, reviewer acbox/reviewer)
05:39:32 inquire-platform: review: inq-85h.5 by acbox/reviewer (1 failures)
05:40:01 inquire-platform: inq-85h.5: review approved
05:40:03 inquire-platform: opened https://github.com/imkarrer/inquire-platform/pull/44

inquire-platform  label=delegate:local base=master merge=pipeline stages=devbox/coder⇢acbox/reviewer×3 → acbox/coder⇢acbox/reviewer×1 → claude/sonnet⇢claude/sonnet×1  [priority]
  gpu lane:    inq-ufz.13 grading.dlq: 30-day retention as a per-topic config (2m)
  cpu lane:    idle
  claude lane: idle
  dev queue (4):
    1   inq-5rm.11     0× devbox/coder   scripts/*.mjs: replace the never-firing process.on('exit') pg cleanup
    2   inq-8gg.10     1× devbox/coder   packages/domain bands: BAND_CUTS keyed by (rubricVersion, graderModel)
    3   inq-h2i.8      1× devbox/coder   Gate a Claimed Session to its owner
    4   inq-c0t.23     4× acbox/coder    scripts/lib/gate.mjs: Composite spread ratio, tail rank correlation
  review queue (1):
    1   inq-c0t.28     0× devbox/coder   ladderVersion: blind ratings are evidence for the ladder text
  merge queue (1):
    inq-85h.5      https://github.com/imkarrer/inquire-platform/pull/44
  parked: inq-8gg.8
  held (waiting on you or the world; still in its queue):
    inq-h2i.7      [merge] https://github.com/imkarrer/inquire-platform/pull/41 reports no CI checks; merge it yourself or set merge = "manual"
```

The last log lines, then per repo: what each lane is on, the queues in the order the
lanes take them (position, id, failures, the stage's worker, title), the merge queue's
PRs, the parked and held beads — and any session the attached opencode server is still
running that is on no lane, with its state, agent, model, when it last produced anything,
and the url that opens it. `busy` with a stale "ago" is the CPU box thinking: a cold
20k-token prompt is minutes of prefill before its first token.

A session the server calls busy with no `opencode run` client left on this box shows as
one of two states, and they call for opposite responses:

- **`REJOIN`** is a session a restart found still running under a bead's worktree
  (`recover`, `lanes.rs`): the bead went back in its queue with a `rejoin/ID` marker, and
  the lane that takes it waits on the session instead of starting one (no client is ever
  spawned for a rejoin — the loop polls it directly, `harness.rs` `rejoin_session`) — so
  seeing it with no client is expected, not a fault. Leave it; the line under it says so.
  Aborting it does the wrong thing twice: it throws away a round that may already be
  finished, and the lane still rejoins by the marker, reads no text from the now-dead
  session, and charges the bead a failure. To actually stop it, abort the session *and*
  remove its `rejoin/ID` marker together, so the lane starts a fresh round instead.
- **`ORPHAN`** is the real thing: no `rejoin/ID` marker names this session, so nothing is
  coming back for it. With `attach`, killing the client does not stop the server-side
  session, and on a one-model box it starves the next round. The loop aborts its own
  sessions on the server whenever their client dies — on `worker_timeout`, on
  `systemctl stop`, at start (recover), before it recreates a worktree — so an orphan
  means something else killed the client (`kill -9`, a crash); the line under it is the
  command that stops it.

**<http://127.0.0.1:4096>** is the opencode server itself (`opencode-web.service`): with
`attach = "http://127.0.0.1:4096"` in the global config every worker and reviewer session
runs inside it and streams there live, titled by bead, with the diff. The unit runs
`opencode serve`, not `opencode web`: the same server and UI, but `web` opens a browser
tab every time it starts, and a deploy is a start.

## Stop, restart, recover

`systemctl stop` aborts the model sessions the lanes are on; a worker, gate or reviewer
that comes back under the stop is cut short, never judged: no failure, no note, the
branch kept. A **restart** — the deploy's, which drops `$STATE_DIR/restart` first —
aborts nothing: the sessions go on inside `opencode-web.service`, and the next process
**rejoins** them (`recover` finds a session still running under a bead's worktree, puts
the bead back in its queue first with a `rejoin/ID` marker, and the lane that takes it
waits on that session instead of starting one). Every start **recovers** first: stale
lane markers go, orphan sessions are aborted (or rejoined), and a dev round a stop cut
short is back in the dev queue with no failure charged. The binary also watches its own
path, and re-execs itself at the next moment every lane is idle when the file there has
changed.

## State on disk

`~/.local/state/bead-loop/<repo>/`: `inflight/<id>` (the PR url, with
`.<id>.red|nocheck|adopted|fixing|conflict` markers beside it), `logs/<id>.<stamp>.*`
(setup, worker, gate, reviewer, brief output per round), `wt/<id>` (the worktree while a
bead is on a lane or waiting for review), `review/<id>` (the review queue: the worker's
last words), `failures/<id>` (the count; `.rounds.jsonl` the history, one record per
send-back with the whole note and the round's log files), `parked/<id>` (the loop's
record of a parking: the reason, the stage it stopped on, the question, the brief),
`held/<id>` (the reason a bead waits), `rejoin/<id>` (a session to wait on after a
restart), `lane.<name>` (the bead that lane is on). Under the state dir itself: `wake`
(the bell), `priority`, `pause.<lane>`, `restart`, `lock` and `lock.<lane>`, and
`deploy/` (the deploy's clone and what is deployed).

Environment: `BEAD_LOOP_CONFIG` (the global config's directory), `BEAD_LOOP_STATE` (the
state dir), `BEAD_LOOP_HOME` (the checkout, for `agents/` and `ui/`),
`BEAD_LOOP_HOLD_BACKOFF` (seconds before a held bead is tried again, 300), `BEADS_ACTOR`
(who the loop's `bd` changes are by; the label otherwise).
