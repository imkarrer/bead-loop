# Example: a review quorum

Three reviewer seats from three families, voting: the PR opens at two approvals, and
goes back only once two of the three have rejected it.

## The global config (`~/.config/bead-loop/config.toml`)

```toml
repos = ["~/src/my-project"]
model = "devbox/coder"
worker_timeout = 3600
max_inflight = 100
on_exhaust = "park"

[providers.devbox]
probe = "http://127.0.0.1:8100/health"

[providers.acbox]
probe = "http://192.168.1.50:8100/health"

[providers.openai]
cost = "metered"

[[stages]]
name = "local"
worker = "devbox/coder"
reviewer = ["acbox/reviewer", "openai/gpt-5", "devbox/reviewer"]
approvals = 2
attempts = 3
```

## The repo config (`.bead-loop.toml`)

```toml
label = "delegate:local"
base = "main"
gate = "npm test"
merge = "pipeline"
```

Each seat is its own round, on the lane that owns its model, and never sees another
seat's verdict — a blind vote, not a debate. It costs three review rounds instead of one,
but it is what a second and third family are for: a habit or a blind spot one seat shares
with the worker is exactly what the other two, from different families, do not share, and
`approvals = 2` means one dissent is not enough to send a bead back on a hunch.
