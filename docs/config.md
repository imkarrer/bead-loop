# Config

Two TOML files, every key optional but the stages: the global
`~/.config/bead-loop/config.toml` (`install.sh` seeds it) and each repo's `.bead-loop.toml`
(`bead-loop.example.toml` has every key annotated). A key in the repo file wins over the
same key in the global one; the global one wins over the default. `[[stages]]` come from
the repo file when it has any, else the global one.

The loop reads both when it starts (`baml_src/ns_supervisor/config.baml`), so an edit
takes effect at the next start: `systemctl --user restart bead-supervisor.service`, or
Restart on the page. Rounds in flight keep running through it.

A file that does not parse is never read as defaults: the loop leaves that repo, and its
targets, alone, and logs the file and the parse error in the repo's `STATE/loop.log`.

A model is named `PROVIDER/MODEL`. `claude/*` is one Claude Code turn with Claude's own
tools; any other runs `MODEL` on that provider's OpenAI-compatible server
(`[providers.NAME] url`), with the loop's own tools.

| Key | Default | What |
| --- | --- | --- |
| `repos` | `[]` | global only: the checkouts the loop works, `~` allowed. Each has `.beads/` and a `.bead-loop.toml` |
| `label` | `"delegate:local"` | `bd ready -l LABEL` is the queue. Only a bead `bd ready` lists now is picked |
| `base` | `"main"` | the branch to fork from and open PRs into |
| `remote` | `"origin"` | where the base is fetched from and `bead/*` branches are pushed |
| `setup` | none | runs in a fresh worktree before its first round (`npm ci`); not again on a branch sent back. Failing holds the bead, no failure |
| `gate` | none (CI is the gate) | runs after the worker in its worktree, whatever the worker reported; one fix round with its output on failure |
| `primer` | AGENTS.md at the repo root, for a local worker | a path from the repo root to a text file, read into every worker prompt (and the gate's fix prompt), cut at 4000 characters |
| `fixer` | none | a command run in the worktree after the worker and before each gate run: the repo's formatter. What it changes is committed for the worker; its exit code is not read |
| `precheck_model` | none | after the gate passes, reads the diff, the bead and the worker's report; SEND BACK is a failure, a pass or no answer goes on to review |
| `[[stages]]` | **required** | the workers and reviewers, in order (below) |
| `on_exhaust` | `"park"` | after the last stage: `park` for you, or `repeat` the stages |
| `research_model` | none (off) | reads the repo for a bead before its first work round and writes a brief (Files / Shape / Check / Pitfalls) that every worker prompt carries. Runs on its own server's slot, so the CPU box researches while the GPU works. A worker with a free slot and nothing briefed takes a bead without a brief rather than wait. Research never counts a failure |
| `research` | `"first"` | `off` turns research off; anything else runs it once per bead |
| `research_timeout` | `900` | seconds a research round may run; past it the worker goes without a brief |
| `brief_model` | the researcher | the **second opinion** on a researcher's BLOCKED: it researches the bead again with that reply in its prompt. Its brief goes to the worker; its own BLOCKED parks the bead before any edit |
| `conflict_worker` | the last stage's worker | who works a rebase round (a PR that conflicts with the base) and a feedback round (review comments on the PR): judgement, so the strong model by default |
| `worker_timeout` | `3600` | seconds a work or review round may run, the gate included |
| `merge` | `"auto"` | `auto`: the loop merges on green · `pipeline`: the loop labels, CI merges · `manual`: PR only, held for you once green · `external`: a maintainer merges; the loop watches and never holds on green |
| `merge_label` | `"automerge"` | the label `pipeline` puts on each PR |
| `update_behind` | `merge == "auto"` | when GitHub reports an open PR behind the base, bring its branch up (`gh pr update-branch`) |
| `feedback` | `true` | a review or comment on the loop's own PR from someone other than its gh account, newer than the last seen, sends the bead back on its branch with the comments as its note, no failure. The first look at a PR marks what is already there as seen. Bots are ignored |
| `adopt` | `true` | an open `bead/ID` PR the loop is not carrying joins the merge queue, from ready or parked; a parked bead, or a ready one `bd ready` lists, whose `bead/ID` PR has merged (among the last 30) is closed. One opened by the loop's own account (a PR left by a restart, or by the Rust loop) is the loop's own; one from anyone else is adopted: merged or labelled on green, held when red, never sent back, and not counted toward the caps |
| `max_inflight` | none | the dev lane pauses while this many of this repo's (or target's) own PRs are open; a bead ready to publish (`open_pr = "ask"`) counts as one |
| `max_open_prs` | none | global only: the dev lane pauses while this many own PRs are open across a repo and all its targets |
| `open_pr` | `"auto"` | `ask`: push the branch and stop at a compare link for you to open; the loop picks the PR up once it exists |
| `pr_style` | `plain` under `ask`, else `loop` | `loop`: the title is `ID: title` and the body the bead · `plain`: the bead's title and description |
| `sandbox` | `false` | run each round under bwrap. Writable: its worktree, the repo's git dir, its own `beads/ID`, the `logs` and `rounds` folders, `/tmp`, the build caches (`~/.cache`, `~/.npm`, `~/.local/share/flox`, flox's activations) and, for a Claude round, `~/.claude`. Read-only: everything else, so a round cannot forge another bead's log, its inbox or the page's view. Hidden: `~/.config/gh`, `~/.ssh`, the loop's config and the runtime dir (its `docker.sock`). The network is not cut |
| `sandbox_writable` | `[]` | more paths a sandboxed round may write, `~` allowed: another repo's `.flox` a gate activates with `flox activate -d` |
| `target_label` | `"work"` | the label prefix that names a target: `work:NAME` sends a bead to `[targets.NAME]` |
| `heartbeat_seconds` | `30` | global only: the pause between ticks |

## Providers

A provider is a model server, and a **lane**: each runs `parallel` rounds at once, shared
by every repo the loop works. So a review on acbox never waits behind a work round on the
GPU, and a round in one repo holds its server for all the others.

| Key | Default | What |
| --- | --- | --- |
| `url` | what `probe` implies | the OpenAI-compatible root the rounds call (`http://127.0.0.1:8100/v1`) |
| `probe` | none | a health URL; `http://host:8100/health` implies `url = "http://host:8100/v1"` |
| `parallel` | 1 | rounds on this server at once |

`claude` needs no table but `parallel`. A Claude usage limit met by any round holds every
claude round until it resets; the other servers go on.

## Stages

The failure count chooses the stage, the `[[stages]]` tables in order. Each has `worker`
(required), `reviewer` (none: straight to PR), `attempts` (how many failures it absorbs
before the next takes over; `failures` also reads) and `name`.

```toml
on_exhaust = "park"

[[stages]]
name = "local"
worker = "devbox/coder"
reviewer = "acbox/reviewer"
attempts = 2

[[stages]]
name = "frontier"
worker = "claude/sonnet"
reviewer = "claude/sonnet"
attempts = 1
```

A bead starts on the GPU worker, reviewed by gpt-oss-120b on acbox, and stays there for its
first two failures; the third sends it to Claude; then it parks. The same REJECT twice in a
row skips ahead to the next stage with a different worker.

## Targets

A target is another checkout a repo plans beads for, and the GitHub repo its PRs go to:
`[targets.NAME]` in the planning repo's `.bead-loop.toml`. A bead labelled `work:NAME` is
worked there: git in the target's checkout, bd in the planning repo, its state under the
planning repo's. The repo itself leaves `work:*` beads to its targets.

| Key | Default | What |
| --- | --- | --- |
| `path` | **required** | the checkout |
| `base` | `"main"` | the branch to fork from and PR into |
| `base_remote` | `"origin"` | where the base is fetched from |
| `push_remote` | `"origin"` | where `bead/*` branches are pushed: your fork |
| `pr_repo` | the checkout's own | `owner/name` the PR is opened against; the head is `FORK_OWNER:bead/ID` |
| `setup`, `gate`, `primer` | none | as above; the planning repo's are not inherited |
| `merge` | the repo's | as above |
| `open_pr` | `ask` when `pr_repo` is set, else `auto` | as above |
| `pr_style` | `plain` under `ask` | as above |
| `max_inflight` | none | as above, for this target alone |
| `adopt`, `feedback`, `update_behind`, `merge_label` | the repo's | as above |

## The merge, per repo

- `merge = "auto"`: the loop squash-merges once every reported check is green, and holds
  the bead for you while none is reported.
- `merge = "pipeline"`: the loop puts `merge_label` on each PR and merging is the
  pipeline's job; the watcher sees it merged and closes the bead. A green PR the pipeline
  has not merged in 30 minutes is held. ([pipeline.md](pipeline.md) is how this repo does it.)
- `merge = "manual"`: PR only; the bead is held for you once green.
- `merge = "external"`: the maintainer merges; the loop waits without holding, and still
  sends red, conflicts and review comments back.

## Not read

Keys from the Rust loop that the BAML loop ignores: `model` and `review_model` (name
`[[stages]]`), `[[lanes]]` (a lane is a provider), a stage's `timeout` and seat lists
(`approvals`), `diff_checks`, `research = "every"`, `research_aider`, `stall_compactions`,
`stall_steps`, `attach`, `[reference_rate]`, and the provider keys `harness`, `cost`,
`via`, `command` and `model_flag`. The label `harness:*` is ignored too. A `stage:NAME`
label is read: the bead starts on the `[[stages]]` table with that `name`.
