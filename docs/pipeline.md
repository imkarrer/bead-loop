# Checks, the pipeline, the deploy

## Dogfood

This repo is one of the loop's repos: `.beads/` holds its backlog (`bd ready -l
delegate:local` lists what the loop may take), `.bead-loop.toml` says how a worktree is
proven (the same checks CI runs, inside the flox env), and `~/src/bead-loop` is in the
global `repos`. So an improvement to the loop is a bead, and the loop works it: worker,
gate, reviewer, PR, CI, automerge, release, deploy. Within two minutes of the release the
deploy timer installs it on this box; the running loop is restarted and rejoins the
sessions it was on. A bead that touches `src/` should say so in its acceptance criteria.

## Checks

`cargo test` covers everything with a shape and no tool behind it: config layering and
parsing, the stage table, the queue order and the one-place invariant, the merge
verdicts, the prompts, the rejection that travels, the PR body, the status JSON.
`test/run.sh` drives the binary through every row of the outcome table in
[state-machine.md](state-machine.md) with stub `bd`, `opencode`, `claude`, `aider`, `gh`
and `curl` (`test/bin/`) and a real git origin: no model, no network, the cases side by
side (`JOBS=1` for one at a time), seconds. `test/lint-skills.sh` checks the frontmatter
opencode needs. `scripts/ci.sh rust|scripts|suite` are the three steps.

## Buildkite

Buildkite runs them, merges, and releases (`.buildkite/pipeline.yml`). Every push and PR
builds on queue `self` (ac-box): `rust` (fmt, clippy `-D warnings`, build, unit tests)
and `scripts` side by side, then the `suite`; then, on a PR carrying the `automerge`
label — which the loop puts on every PR it opens under `merge = "pipeline"` —
`scripts/ci-merge.sh` squash-merges the commit the build tested (the label is read from
the live PR, a moved head is refused, a removed label is a withdrawn request); and on
main, `release`: the release binary as the GitHub release `main-<sha7>` at that commit
(the last ten are kept).

`main`'s protection requires the three step statuses (`buildkite/bead-loop/rust`,
`/scripts`, `/suite`) — never the build-level one, which would still be pending while
the automerge step runs.

**The label is a trigger, not only a flag.** The pipeline object also builds on the
`pull_request` `labeled` event, filtered to the `automerge` label (homelab's
`hub/pipelines/bead-loop.json`: `build_pull_request_labels_changed`, a
`filter_condition`, and `skip_pull_request_builds_for_existing_commits` off — on, it
drops the label's build because the commit already built). So a label added after the
build finished starts a build of its own that tests the same head and merges it; one
added mid-build cancels that build for one that will merge; nothing depends on GitHub's
own auto-merge, which private repos on the free plan do not have.

Buildkite posts statuses only once its GitHub App has been given the repo. The cargo
registry and target directory live beside the agent's checkouts (`scripts/ci.sh`), so a
build recompiles only what changed and a docs-only push costs a no-op build. Two more
pipeline settings make the rest add up: "Build pull requests" and "cancel intermediate
builds".

## The deploy

**A pull, and a download, not a build.** The box the loop runs on is behind WSL's NAT,
where the agent on ac-box cannot reach it, so `bead-loop-deploy.timer` on that box runs
`scripts/deploy.sh` every two minutes: one `git fetch` in the deploy's own clone
(`~/.local/state/bead-loop/deploy/src`), and nothing more unless `origin/main` has moved
past what is deployed — then download the release `main-<sha7>` the pipeline published
for exactly that commit (the tested binary, byte for byte; no compiler on the box), put
the clone at the commit, `install.sh` with that binary, and restart what changed: the loop
always (it rejoins its sessions); the opencode server, where the sessions live, only when
`agents/`, `skills/` or its unit moved; the UI only when `bin/`, `ui/` or its unit did. When
the opencode server does restart, the loop is stopped first (a plain stop, not a restart),
the server restarted, and the loop started again, so the rounds in flight are reopened
with no failure charged.

The clone is the deploy's alone — nothing else writes there, so a reset is always safe —
and `~/src/bead-loop`, the project the loop works, is not read by the deploy at all:
development never blocks it. The binary links the flox env's glibc by store path; the box
runs it inside the same pinned env (`manifest.lock`), which the deploy activates at the
commit before installing. `scripts/deploy.sh --force` installs origin/main's release
again; `--dry-run` fetches, downloads and checks, and installs nothing.
