# Examples

The owner's live configuration, copied 2026-10-22. A snapshot, not a template:
`bead-loop.example.toml` at the root is the annotated per-repo template (a test checks
every key is in it), and `install.sh` seeds the global file.

- `config.toml` — `~/.config/bead-loop/config.toml`: the repos, providers, stages and lanes.
- `repos/<name>.bead-loop.toml` — each watched repo's `.bead-loop.toml`: label, base, gate, merge mode.

The comments are tidied to match what the loop does today; the keys are the live ones.
