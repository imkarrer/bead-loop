# Operating the loop: the page, the terminal, the state on disk

The loop is one packed BAML binary, `~/.local/bin/bead-supervisor`
(`scripts/pack.sh`). `bead-supervisor.service` runs `bead-supervisor run --config_file
~/.config/bead-loop/config.toml`, which walks every repo the global file lists and every
`[targets.NAME]` those repos name. docs/state-machine.md is what happens to one bead.

## The page

**<http://127.0.0.1:4097>**: `bead-loop-ui.service`, which runs `bead-supervisor page`
(`bin/bead-loop-ui` is the two-line wrapper). It starts at boot and comes back after a
crash. It is the Rust loop's page, kept as it was: `ui/index.html`, which
`scripts/page-html.mjs` writes into the binary (`baml_src/ns_page/page_html.baml`; the gate
fails when they differ). It reads `/api/status` every five seconds. Top to bottom:

- **The header**: the loop up or down and since when, with **Stop** (the keeper brings it
  back in a minute), **Off** (the keeper too) and **Start**.
- **Flow**: the workflow as one graph. A band per stage, its worker and reviewer, local
  or metered; in each band Ready, Work (then the gate and the pre-check), Review queue
  and Review, left to right; CI · merge and Landed after every band; Research above;
  Parked below. The edges are the moves: gate ✓, PR, merge, the send-back rail (+1
  failure), down a band after a stage's failures, to parked when the last is spent. Each
  bead sits at its node; press one to open it under the graph: where it is, its rounds
  and their logs, a note to it, and on a lane its last tool calls and **Abort**.
- **Lanes**: one per model server slot, the round on it or why it is idle, and **Abort**.
- **Scoreboard**, over 24h, 7d, 30d and all: landed, first try, without metered models,
  rounds per landing, time to land, needed you; where rounds go back, by model, and what
  finished.
- **Each repo and target**, under **Needs you**: each parked bead with its question,
  **Answer & resume** (your text becomes the next round's note, one failure forgiven),
  **Work with Claude** (the last stage), **Reopen**, and, when its branch holds work that
  passed the gate, **Ready for PR** (the branch pushed, the bead ready for PR); each bead
  ready for PR with its compare link, the PR's title and body to edit, and **Open PR**;
  each held bead with its reason.
- **Supervisor log**: the loop's journal.

Each supervisor writes what the page shows to `STATE/view.json` every tick: its beads
from its own state (their places, holds, titles, rounds in flight and their last tool
calls) and the scoreboard's tallies. The page reads those files and adds only the
config, the lane slots, systemd and the journal: it folds no log and asks neither bd,
git nor gh, so what it shows is what the loop holds, as of its last tick. Its levers are
mail in the repo's inbox (answer, reopen, escalate, ready, publish; abort a round; note a
bead), and `systemctl --user` for the loop's own units. Mail wakes the loop within a
second, and a lever waits for the supervisor to carry it out and comes back with what
became of the bead, as its newest event: `pw-xl2: pr_opened: https://...`. Every POST carries a token the page is served with, made afresh
each run, and must come from the page's own origin, so another site open in the same
browser cannot pull a lever.

## The terminal

```bash
journalctl --user -u bead-supervisor.service -f -o cat     # the loop's own lines
bead-supervisor tell --config_file ~/src/repo/.bead-loop.toml --id ID --what answer --text "..."
bead-supervisor lint --config_file ~/src/repo/.bead-loop.toml --ids "ID ID" --run true
cat ~/.local/state/bead-loop/<repo>/baml/beads/<id>/events.jsonl   # one bead's history, each event with its time
```

`tell` is the page's levers: `--what` is `answer`, `reopen`, `escalate`, `publish` (a parked bead whose branch holds work: push it and wait for your PR) or `open_pr` (`--title` and `--text` the body). A bead
labelled `work:NAME` goes to that target's inbox.

`lint` checks a bead's claims before a label lands (the delegate skill runs it): every
path the DESCRIPTION names exists on the base branch, and the ACCEPTANCE CRITERIA has a
command in backticks. `--run true` also runs each acceptance command in a throwaway
worktree of the base: one of them must fail there, since a bead's check that already
passes proves nothing. It prints `ID: pass` or the problems and notes `bead-loop lint
DATE: ...` on the bead; no `--ids` lints every ready bead.

### Traces

Every model call a round makes is recorded by the BAML runtime under the repo's
`.baml/btel`, stamped with the bead (`BAML_CONTEXT`: distinct id the bead, metadata its
kind and log). `baml-cli query --local` reads them with SQL. A round's own tool calls are
in `logs/<id>.<pid>.<kind>.jsonl`.

A Claude round is one Claude Code turn, so it has no BAML tool calls of its own. It runs
the CLI through `logs/<id>.<pid>.<kind>.jsonl.sh`, a wrapper the round writes, which adds
what Claude may run without asking (the worker: Read, Edit and Write under its worktree,
Glob, Grep and Bash; a reviewer: Read under its worktree, Glob and Grep, and no shell,
since the diff is in its prompt) and tees Claude Code's own
`stream-json` into the same log, its stderr beside it in `.err`. The page shows those tool
calls like any other round's. When the CLI fails, the round reads what it said there: a
usage limit holds every claude round, anything else is held with the CLI's own words.

A local round's tools count reads and commands since its last edit: from 20 each answer says to finish, past 30 they are refused, so a model that is lost reports instead of spending its steps. A local round's file tools refuse a path outside its worktree (`BEAD_LOOP_WORKTREE`, which
the launch sets); its `run` tool is a shell, which only `sandbox` confines.

## Stop, restart, recover

A round is its own detached process, and the unit has `KillMode=process`, so `systemctl
stop` and a restart leave rounds running. Every start recovers: it folds each bead's log,
takes the result of any round that finished while the loop was down, and marks a bead
whose round has no process and no result as lost, which puts it back in its queue with
no failure charged. Each tick does the same for a round that dies under a running loop.

Each round runs under `timeout`: `worker_timeout` (3600 s) for work and review,
`research_timeout` (900 s) for research. A worker past it is a failure; a reviewer past
it is held; a researcher past it lets the worker go without a brief.

## State on disk

`~/.local/state/bead-loop/<repo>/baml/` (a target's is under it, `targets/<name>/`):

- `beads/<id>/events.jsonl` — the bead's log, the source of truth: its state is a fold
  of these events. Beside it `report` (the worker's last words, for the reviewer),
  `brief` (the researcher's), `park.md` (a parking's question) and `watch.json` (the PR
  watcher's clocks and the newest comment seen).
- `rounds/<id>.{spec.json,pid,result.json,timedout}` — a round in flight and what it
  left.
- `wt/<id>` — the bead's worktree, on branch `bead/<id>`.
- `logs/` — each round's tool calls; `inbox/` — mail from the page and `tell`.
- `view.json` — what the page shows, written each tick.
- `gh-login` — the account the loop acts as, asked once.

The Rust loop's state is beside it, in `~/.local/state/bead-loop/<repo>/`, and nothing
reads it. A PR the Rust loop left open is adopted as the loop's own: its author is the
same account.
