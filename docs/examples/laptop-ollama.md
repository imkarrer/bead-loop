# Example: a laptop, Ollama and a paid reviewer

One local model through opencode's Ollama support, probed on `/api/tags`; one metered
provider as the second reviewer seat and as the stronger, last-resort stage. Two stages;
no `[[lanes]]` table, so the loop derives one lane per provider — `ollama` and
`anthropic` — from the models the stages name.

## The global config (`~/.config/bead-loop/config.toml`)

```toml
repos = ["~/src/my-project"]
model = "ollama/qwen2.5-coder"
worker_timeout = 3600
max_inflight = 100
on_exhaust = "park"

[providers.ollama]                      # the laptop's own Ollama, through opencode
probe = "http://127.0.0.1:11434/api/tags"

[providers.anthropic]                   # a paid API, through opencode's anthropic provider
cost = "metered"

# Escalation: the local model twice, its send-back reviewed by both seats; then the
# metered provider once, as its own worker and reviewer.
[[stages]]
name = "local"
worker = "ollama/qwen2.5-coder"
reviewer = ["ollama/qwen2.5-coder", "anthropic/claude-sonnet"]
approvals = "all"
attempts = 2

[[stages]]
name = "cloud"
worker = "anthropic/claude-sonnet"
reviewer = "anthropic/claude-sonnet"
attempts = 1
```

No `[[lanes]]`: the loop derives `ollama` (`parallel = 1`, the local server serves one
session) and `anthropic` (`parallel = 1`, the provider's default) from the stages above,
in the order they are first named.

## The repo config (`.bead-loop.toml`)

```toml
label = "delegate:local"
base = "main"
gate = "npm test"
merge = "pipeline"
```
