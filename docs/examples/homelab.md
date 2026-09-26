# Example: this box — two local servers and a subscription

The setup this repo runs on. Two servers on the home network: **devbox**, this machine,
an RTX 4080 running Qwen3-Coder-30B through `llama-server`; **acbox**, a CPU box running
three models at once — Qwen3-Coder-Next 80B as the researcher, gpt-oss-120b as the
reviewer, a 4B model as the pre-check and post-mortem utility. Claude Code is the last
stage, for a bead the first two exhaust. Three lanes, one per provider: `gpu`, `cpu`,
`claude`. `merge = "pipeline"`: Buildkite reports the checks and its automerge step
merges a labelled, green PR.

## The global config (`~/.config/bead-loop/config.toml`)

```toml
repos = ["~/src/my-project"]
model = "devbox/coder"           # worker, when no [[stages]] table applies
worker_timeout = 3600            # seconds per model session
max_inflight = 100                # no cap: bd's dependencies are the only gate
attach = "http://127.0.0.1:4096" # sessions run inside opencode-web.service
on_exhaust = "park"              # after the last stage: park for you, rather than repeat

# A ready bead goes to the 80B first, which reads and writes a brief — Files / Shape /
# Check / Pitfalls — every worker prompt then carries; "first" runs it once, before round 1.
research_model = "acbox/coder"
research = "first"
research_aider = true

[providers.devbox]               # Qwen3-Coder-30B on the RTX 4080, through opencode
probe = "http://127.0.0.1:8100/health"

[providers.acbox]                # ac-box's CPU: the 80B, gpt-oss-120b, the 4B utility model
probe = "http://192.168.1.50:8100/health"

[providers.claude]               # the Claude Code subscription: the last stage
harness = "claude-code"
parallel = 2
cost = "metered"

precheck_model = "acbox/utility" # the 4B model: a cheap second look before review spends a round

# Escalation, in order: two attempts on the local stage, then Sonnet once; after that the
# bead parks for you.
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
# bead escalated to Claude runs at once.
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

## The repo config (`.bead-loop.toml`)

```toml
label = "delegate:local"
base = "main"
gate = "npm test"
merge = "pipeline"                   # Buildkite reports, and its automerge step merges a labelled PR on green
```

## Why each choice

Two servers, so a lane each: the GPU implements the next bead while the CPU reviews the
last, and neither queue idles behind the other. The reviewer, gpt-oss-120b, is a
different model family from every worker, so it catches what the Qwen models share — a
habit, a blind spot — that a same-family review would miss. The 80B does the research
round rather than the reviewer's job because it is too slow to sit in an edit loop but
good enough to spend once, up front, turning a bead that names no files into one that
does. The 4B model is the pre-check: cheap enough to run on every gate pass, catching what
would otherwise cost a full review round. Claude Code is the last stage because it never
exhausts and never needs a local server up; a bead two local attempts could not land is
worth the metered cost rather than a park. `merge = "pipeline"` rather than the loop
pushing to `main` directly, because CI here is Buildkite, not GitHub's own checks, and its
automerge step is the thing that actually watches for green.
