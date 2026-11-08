# Example: API-only, no local model

> **Status:** written for the Rust loop. The BAML loop (since 8 Nov 2026) runs a local model on any OpenAI-compatible server (`[providers.NAME] url`, e.g. Ollama's `http://localhost:11434/v1`) and `claude/*` as Claude Code. It has one reviewer per stage (no seats or quorum), and no metered API provider other than Claude Code. See [config.md](../config.md).

No server to keep up: one provider, reached over the network, wide enough to run several
beads at once. One stage — there is nothing to escalate to.

## The global config (`~/.config/bead-loop/config.toml`)

```toml
repos = ["~/src/my-project"]
model = "anthropic/claude-sonnet"
worker_timeout = 3600
max_inflight = 100
on_exhaust = "park"

[providers.anthropic]
parallel = 4
cost = "metered"

[[stages]]
name = "cloud"
worker = "anthropic/claude-sonnet"
reviewer = "anthropic/claude-sonnet"
attempts = 3
```

No `[[lanes]]`: the loop derives one `anthropic` lane, `parallel = 4`, from the stage
above — four beads in flight on the one provider, none of them waiting on a GPU that
does not exist here.

## The repo config (`.bead-loop.toml`)

```toml
label = "delegate:local"
base = "main"
gate = "npm test"
merge = "pipeline"
```

Every bead here runs on a metered provider, so the page's scoreboard tile "Without
metered models" reads 0% — there is no local stage for a bead to land on without one.
