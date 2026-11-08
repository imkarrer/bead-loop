# Operating the loop: the page, the terminal, the state on disk

The loop is one packed BAML binary, `~/.local/bin/bead-supervisor`
(`scripts/pack.sh`). `bead-supervisor.service` runs `bead-supervisor run --config_file
~/.config/bead-loop/config.toml`, which walks every repo the global file lists and every
`[targets.NAME]` those repos name. docs/state-machine.md is what happens to one bead.

## The page

**<http://127.0.0.1:4097>**: `bead-loop-ui.service`, which runs `bead-supervisor page`
(`bin/bead-loop-ui` is the two-line wrapper). It starts at boot and comes back after a
crash. Top to bottom, refreshed every five seconds:

- **The header**: the loop up or down and since when, with **Start**, **Stop** (the
  keeper timer too, so it stays down) and **Restart** (a config edit takes effect).
- **Flow**: the stages as rows (each with its worker, reviewer and how many failures it
  absorbs) against the queues as columns: Ready, Research, Working, Review queue,
  Reviewing, Merge, and a row for parked beads. Every bead is a chip where it sits, its
  failure count beside it, amber when held; click one for its panel. Under it, what
  landed in the last day.
- **Lanes**: one card per model server (devbox, acbox, claude), with how many of its
  slots are busy, and for each round on it the bead, its repo, research, work or review,
  the model, how long, and its last six tool calls. **Abort** stops the round and all it
  started; the loop starts it again with no failure.
- **Needs you**: each parked bead with its question and **Answer** (your text becomes
  the next round's note, one failure forgiven), **Reopen** and **Escalate** (straight to
  the last stage); each pushed branch waiting for you to open its PR; each held bead with
  its reason.
- **Scoreboard**, over 24h, 7d, 30d and all: landed, first try (no send-back), without
  Claude (no round on a `claude/*` stage), parked, and the send-backs by kind.
- **Each repo and target**: every bead that is not closed, its place, failures and
  rounds, its PR, its hold. **Click a bead** for its panel: every event with its whole
  text (the work order, the gate's output, the pre-check's block, CI's checks), the
  brief, the last report, the park question, and each round's tool calls.
- **Supervisor log**: the loop's journal, one line per event.

The page folds each repo's event log afresh on every refresh and never asks bd, git or
gh, so it cannot take a round's result or start anything. Its levers leave mail in the
repo's inbox (taken on the next tick), signal a round's process group, or call
`systemctl --user` for the loop's units.

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
what Claude may run without asking (the worker: Read, Edit, Write, Glob, Grep and Bash; a
reviewer: reading tools and git's reading commands) and tees Claude Code's own
`stream-json` into the same log, its stderr beside it in `.err`. The page shows those tool
calls like any other round's. When the CLI fails, the round reads what it said there: a
usage limit holds every claude round, anything else is held with the CLI's own words.

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
- `gh-login` — the account the loop acts as, asked once.

The Rust loop's state is beside it, in `~/.local/state/bead-loop/<repo>/`, and nothing
reads it. A PR the Rust loop left open is adopted as the loop's own: its author is the
same account.
