# Example: this setup — a GPU box, a big CPU box and a subscription

The config this repo is run with, copied from the live files and scrubbed of repo names.
Two machines on the home network, each served by [agent-hub](https://github.com/imkarrer/agent-hub)
on port 8100, which opencode reaches as a provider each:

- **devbox**: the dev machine, a WSL2 NixOS box with an RTX 4080 (16 GB). It runs
  Qwen3-Coder-30B (`devbox/coder`), the first stage's worker.
- **acbox**: `llm-box`, an HP Z840 with 256 GB of RAM and no GPU. Inference is CPU-bound
  and slow token for token, so it runs big models that do not sit in an edit loop:
  Qwen3-Coder-Next 80B as the researcher (`acbox/coder`), gpt-oss-120b as the reviewer
  (`acbox/reviewer`), and a 4B model (`acbox/utility`) for cheap calls.
- **claude**: Claude Code on a subscription, the last stage, for a bead the local stage
  could not land.

Three lanes, one per provider: `gpu`, `cpu`, `claude`. The loop watches several repos at
once; each has its own `.bead-loop.toml` (below), and they share this global file.

## The global config (`~/.config/bead-loop/config.toml`)

```toml
repos = [
  "~/src/web-app",            # merge = "pipeline"
  "~/src/python-tool",        # merge = "auto"
  "~/src/bead-loop",          # this repo, worked by the loop it implements
  "~/src/notes-site",         # beads here, the work in another repo: [targets.NAME]
]
model = "devbox/coder"           # worker, when no [[stages]] table applies
worker_timeout = 3600            # seconds per model session
max_open_prs = 1                 # one open PR at a time across every repo and target
max_inflight = 100               # no cap: bd's dependencies are the only gate
attach = "http://127.0.0.1:4096" # sessions run inside opencode-web.service; watch them live in the browser
on_exhaust = "park"              # after the last stage: park for you, rather than repeat

# A ready bead goes to the 80B first, which reads the repo and writes a brief — Files /
# Shape / Check / Pitfalls — that every worker prompt then carries; "first" runs it once,
# before round 1. A brief whose Files all exist puts the worker under aider;
# `harness:opencode` on a bead opts out.
research_model = "acbox/coder"
research = "first"
research_aider = true

# precheck_model = "acbox/utility"  # off: the 4B model's look before review needs a slot on
#                                   # acbox beside the reviewer's, so acbox gets parallel = 2 first

[reference_rate]          # USD per million tokens: what the scoreboard prices the local tokens at
input = 2.00              # tokens the model reads fresh
output = 10.00            # tokens it writes (reasoning included)
cache_read = 0.20         # tokens the server already held

[providers.devbox]               # Qwen3-Coder-30B on the RTX 4080, through opencode
probe = "http://127.0.0.1:8100/health"

[providers.acbox]                # the HP Z840's CPU: the 80B, gpt-oss-120b, the 4B utility model
probe = "http://192.168.1.51:8100/health"

[providers.claude]               # the Claude Code subscription: the last stage
harness = "claude-code"
parallel = 2
cost = "metered"

# Escalation, in order: two attempts on the local stage, then Sonnet once; after that the
# bead parks for you. There is no CPU stage between them (acbox/coder as a worker landed
# one bead in 24 rounds), and repeat is off, so a Sonnet send-back does not cycle back to
# the GPU. `name` is what a bead's `stage:NAME` label points at.
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

# One lane per model server: a round on the CPU box never holds the GPU's queue, and a
# bead escalated to Claude runs at once. Anthropic takes two rounds at the same time.
[[lanes]]
name = "gpu"
models = ["devbox/*"]

[[lanes]]
name = "cpu"
models = ["acbox/*"]

[[lanes]]
name = "claude"
models = ["claude/*"]
parallel = 2
```

## The repo configs (`.bead-loop.toml`)

Every key here wins over the same key in the global file. The three shapes in use:

A repo whose CI is a Buildkite pipeline. The loop labels each green PR and the pipeline's
automerge step merges it. This repo's own [.bead-loop.toml](../../.bead-loop.toml) is the
same shape, with a cargo gate.

```toml
label = "delegate:local"
base = "master"
setup = "npm ci"                                   # the fresh worktree has no node_modules
gate = "npm run typecheck && npm run lint && npm test"
merge = "pipeline"                                 # the loop labels the PR "automerge"; the pipeline merges it
```

A repo with no pipeline of its own: the loop's merge watcher squash-merges once CI is
green. The gate runs inside the repo's flox environment, so the toolchain is the repo's,
not the login shell's.

```toml
label = "delegate:local"
base = "main"
gate = "flox activate -- bash scripts/check.sh"
merge = "auto"                                     # the watcher squash-merges on green
```

A repo that holds the beads for work done in someone else's repository. A bead's
`work:NAME` label sends the round to `[targets.NAME]`: a worktree of that checkout, the PR
opened against the upstream from a fork, and nothing merged by the loop
([design-targets.md](../design-targets.md)).

```toml
label = "delegate:local"
target_label = "work"
merge = "manual"

[targets.upstream-project]
path = "~/src/upstream-project"
base = "main"
base_remote = "upstream"              # the project's own repository
push_remote = "origin"                # our fork
pr_repo = "owner/upstream-project"
setup = "npm ci"
gate = "flox activate -d ~/src/notes-site -- npm test"
merge = "external"                    # the maintainer merges; the loop watches
open_pr = "ask"                       # never surprise them with a PR: the operator publishes it
pr_style = "plain"                    # a contribution: the bead's title and text, no loop line
max_inflight = 1                      # one open PR at a time on their repo
```

## Why each choice

Two servers, so a lane each: the GPU implements the next bead while the CPU reviews the
last, and neither queue idles behind the other. The reviewer, gpt-oss-120b, is a
different model family from every worker, so it catches what the Qwen models share — a
habit, a blind spot — that a same-family review would miss. The 80B does the research
round rather than the reviewer's job because it is too slow to sit in an edit loop but
good enough to spend once, up front, turning a bead that names no files into one that
does; it picks up work only when the CPU lane has no review waiting, so the GPU never
waits on it. The 4B pre-check is written down but off until acbox has the second slot.
Claude Code is the last stage because it never exhausts and never needs a local server up;
a bead two local attempts could not land is worth the metered cost rather than a park.
`[reference_rate]` prices the local tokens as if a metered model had billed them, so the
scoreboard can say what the GPU saved. `max_open_prs = 1` keeps one PR open across every repo
and target, so a queue of PRs on someone else's repository never becomes a queue of review
for them.

`merge = "pipeline"` where CI is Buildkite, not GitHub's own checks: its automerge step is
the thing that actually watches for green. `merge = "auto"` where the repo's checks are
GitHub's own and the loop's watcher can squash-merge on them. `merge = "external"` on a
target, because the loop is a guest in someone else's repository: it opens the PR when the
operator says so, then only watches.
