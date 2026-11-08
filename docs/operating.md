# Operating the loop: the page, the terminal, the state on disk

The loop is one packed BAML binary, `~/.local/bin/bead-supervisor`
(`scripts/pack.sh`). `bead-supervisor.service` runs `bead-supervisor run --config_file
~/.config/bead-loop/config.toml`, which walks every repo the global file lists and every
`[targets.NAME]` those repos name. docs/state-machine.md is what happens to one bead.

## The page

**<http://127.0.0.1:4097>** — `bead-loop-ui.service`, which runs `bead-supervisor page`
(`bin/bead-loop-ui` is the two-line wrapper). One section per repo and target: every bead
that is not closed, where it is (ready, researching, working, in review, reviewing,
publishable, merging, parked), its failures and rounds, its PR, and why it is held when
it is. A **parked** bead shows its question and takes **Answer** (your text becomes its
next round's note and one failure is forgiven), **Reopen** (back to its queue as it was)
or **Escalate** (straight to the last stage). A **publishable** bead (`open_pr = "ask"`)
shows the compare link to open its PR; the loop picks the PR up once it exists.

The page refreshes every five seconds, folding each repo's event log afresh. It never
asks bd, git or gh and never starts anything: the levers leave mail in the repo's inbox,
which the loop takes on its next tick.

## The terminal

```bash
journalctl --user -u bead-supervisor.service -f -o cat     # the loop's own lines
bead-supervisor tell --config_file ~/src/repo/.bead-loop.toml --id ID --what answer --text "..."
bead-supervisor lint --config_file ~/src/repo/.bead-loop.toml --ids "ID ID" --run true
cat ~/.local/state/bead-loop/<repo>/baml/beads/<id>/events.jsonl   # one bead's history
```

`tell` is the page's levers: `--what` is `answer`, `reopen` or `escalate`. A bead
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
