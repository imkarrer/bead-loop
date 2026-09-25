# Config

Two TOML files, every key optional: the global `~/.config/bead-loop/config.toml`
(`install.sh` seeds it) and the repo's `.bead-loop.toml` (`bead-loop.example.toml` has
every key annotated). A key in the repo file wins over the same key in the global one;
the global one wins over the default. A file that does not parse stops the run with its
name. Both are read afresh on every round, so an edit takes effect on the next round.

| Key | Default | What |
| --- | --- | --- |
| `repos` | `[]` | global only: the repos the lanes walk, `~` allowed |
| `[[lanes]]` | `dev` + `review` (+ `claude`) | global only: the lanes, one per model server — `name`, `models` (globs: `devbox/*`, `acbox/*`, `claude/*`, `*`), `roles` (`worker`, `reviewer`; both by default), `exclude`, `parallel` (rounds at once, default 1). Each takes the rounds whose model it matches. Unset: the pair by role, plus a `claude` lane when a stage names `claude/*` |
| `label` | `"delegate:local"` | `bd ready -l LABEL` picks the work; the loop claims, notes and closes beads as this actor, not as you (`BEADS_ACTOR` in its environment overrides) |
| `base` | origin's HEAD | branch to fork from and PR into |
| `setup` | none | runs in a fresh worktree before the worker (`npm ci`); not again on a branch sent back. It failing holds the bead, no failure: setup runs on the base, so it cannot be the bead's fault |
| `gate` | none (CI is the gate) | runs after the worker, before the review queue; one fix round on failure |
| `model` | none | the worker when no `[[stages]]` table applies. The name picks the harness: `provider/model` runs in opencode, `claude/<alias>` in Claude Code, `aider:provider/model` in aider on that opencode provider's server ([design.md](design.md#harnesses)) |
| `review_model` | none (no review) | the reviewer when no `[[stages]]` table applies; none: straight to PR |
| `[[stages]]` | one stage of `model`/`review_model`, `failures = 3` | `worker`, `reviewer`, `failures` (how many send-backs this stage absorbs before the next takes over; `attempts` still reads), `timeout` (`worker_timeout`), in order |
| `on_exhaust` | `"park"` | after the last stage: `park` for you, or `repeat` the stages |
| `conflict_worker` | the last stage's worker | who rebases a PR that conflicts with the base; a rebase is judgement, so the strong model by default |
| `brief_model` | the last stage's worker | who writes the **brief** when a bead is parked for you — what each round tried, why it was sent back, the question you have to answer; `none` for no brief, the loop's own question then |
| `merge` | `"auto"` | `auto`: the watcher merges on green · `pipeline`: the loop labels, CI merges · `manual`: PR only, the bead held for you once green |
| `merge_label` | `"automerge"` | the label `pipeline` puts on each PR |
| `adopt` | `true` | open `bead/*` PRs from anyone join the loop: merged on green under `auto`, labelled under `pipeline`, the bead the branch names closed; red or conflicting, held with a note for whoever opened them. They do not count toward `max_inflight` |
| `max_inflight` | none | a cap on PRs in the merge queue before the dev lane pauses. Unset, there is no cap: bd's dependencies are the only gate on the dev lane, and the queues absorb the rest. Set it for a repo whose CI is the scarce thing |
| `worker_timeout` | `3600` | seconds per model session |
| `stall_compactions` | `10` | opencode sessions only: past this many compactions in one session, the watchdog aborts it as stalled — a read/compaction loop, not the model at work. `0` disables the check |
| `stall_steps` | `60` | opencode sessions only: past this many tool calls since the last edit/write/patch call, the watchdog aborts the session as stalled. `0` disables the check |
| `attach` | none | an opencode server url; sessions run there and stream in its web UI |

## Lanes per model server

The default lanes are split by role: **dev** (claim, worker, gate → the review queue)
and **review** (reviewer, then push and PR → the merge queue). The scarce thing is the
*server*, and a round on the CPU box should never hold the GPU's queue, so `[[lanes]]`
in the global config replaces the defaults with lanes keyed by model:

```toml
[[lanes]]
name = "gpu"
models = ["devbox/*"]
[[lanes]]
name = "cpu"
models = ["acbox/*"]
[[lanes]]
name = "claude"
models = ["claude/*"]
```

Each lane takes every round — worker or reviewer, and a rebase round when
`conflict_worker` is its — whose model matches one of its globs. So a stage-2 worker
round on acbox runs in the `cpu` lane while the `gpu` lane goes on with stage-1 beads,
and a bead escalated to Claude runs at once, on Anthropic, never behind either. A lane
keeps a bead's rounds together (worker, then its reviewer round when that is the same
lane's, or straight to PR with no reviewer), pauses on its own (`pause cpu`), and is its
own panel on the page. The first lane also parks beads whose stages are exhausted; the
first reviewing lane also takes rounds with no reviewer. Without `[[lanes]]`, a stage
naming `claude/*` still gets its own `claude` lane beside `dev` and `review`. With Claude
signed out its lane waits, saying so, and takes the beads the moment Sign in completes.

`parallel = N` on a lane runs N rounds of its models at once, one bead each, in slots
named `NAME`, `NAME.2` … `NAME.N`: a marker (`lane.NAME.K`) and a lock each, a row
each in `status` and a panel each on the page, one `pause NAME` for all of them. Every
bead has its own worktree, so the slots never share a checkout. It is for a server that
takes several sessions at once — `claude/*`, say — not for a GPU that serves one.

## Stages

The failure count chooses the stage, the `[[stages]]` tables in order:

```toml
on_exhaust = "repeat"

[[stages]]
worker = "devbox/coder"
reviewer = "acbox/reviewer"
failures = 3

[[stages]]
worker = "acbox/coder"
reviewer = "acbox/reviewer"
failures = 1
timeout = 14400

[[stages]]
worker = "claude/sonnet"
reviewer = "claude/sonnet"
failures = 1
```

Read: a bead starts on the fast GPU worker, reviewed by gpt-oss-120b, and stays there for
its first three failures; the fourth sends it to the 80B implementing, the same reviewer
(four-hour timeout); the fifth to Claude; then, with `repeat`, around again until it
lands. So "when does something get evicted to Claude" is one number: the sum of
`failures` above the Claude stage. A stage may name `claude/<alias>` (`claude/sonnet`,
`claude/opus`): that round runs in Claude Code instead of opencode — the frontier model
gets only what the local ones could not land.

## The merge, per repo

- `merge = "auto"` (the default): the watcher squash-merges once every reported check
  is green, and holds the bead for you while none is reported. Branch protection, where
  the plan allows it, is a second lock. GitHub's own auto-merge is not used: private
  repos need a paid plan for it.
- `merge = "pipeline"`: the loop puts `merge_label` on each PR it opens or adopts and
  merging is the pipeline's job — it merges the moment its own run is green, and the
  loop never calls `gh pr merge`. The watcher sees `MERGED` and closes the bead. The
  label must exist in the repo; if GitHub refuses it, that is noted on the bead and the
  bead is held for you. ([pipeline.md](pipeline.md) is how this repo's pipeline does it.)
- `merge = "manual"`: PR only; the bead is held for you once green.
