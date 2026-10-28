# bead-loop

The supervisor is one Rust binary, `bead-supervisor` (`src/`), plus the page
(`bin/bead-loop-ui`, `ui/`), the opencode agents the loop runs (`agents/*.md`), the skills a
planner uses to write beads (`skills/`), and `install.sh`. What it does is the
[README](README.md); one bead from start to finish is
[docs/state-machine.md](docs/state-machine.md).

## The toolchain

Everything comes from the flox env in this checkout: `flox activate` gives cargo, `bd`,
`gh`, `opencode`, node and shellcheck. To work on the repo with the engineering skills
loaded, run the dev stack inside it: `flox activate -- nix run .#dev`.

## The gate

The gate is `gate` in [.bead-loop.toml](.bead-loop.toml), and CI runs the same checks
(`scripts/ci.sh`). Before you commit:

```bash
cargo fmt                 # the fixer: the gate runs cargo fmt --check
bash -c "$(sed -n 's/^gate = "\(.*\)"$/\1/p' .bead-loop.toml)"   # the whole gate
```

Run the parts on their own while iterating:
- `cargo clippy -- -D warnings` and `cargo test` for the Rust;
- `test/lint-skills.sh` for `skills/` and `agents/` (frontmatter, under 700 words);
- `test/run.sh [case-name...]` for the integration suite (it needs `cargo build` first).

## Where a test goes

- **A unit test in `src/` (`cargo test`):** the shape of a prompt, a note, a queue
  order or the status JSON.
- **A case in `test/run.sh`:** a transition the state machine makes through its tools
  (a round, a queue, a PR, a session) and what it leaves on the bead and on disk. It
  runs against the stubs in `test/bin`. Every row of the outcome table in
  `docs/state-machine.md` has a case.

Every change ships with its test.

## Docs

- [docs/config.md](docs/config.md): every key. A new key lands here and in
  `bead-loop.example.toml` in the same change.
- [docs/state-machine.md](docs/state-machine.md): the states, outcomes and exits.
- [docs/operating.md](docs/operating.md): the page, the terminal, and the state on disk.
- [docs/design.md](docs/design.md) and `docs/design-*.md`: why things are the way they
  are, one note per decision. Each opens with a `Status:` line (proposed, or built with
  its PRs).
- [docs/design-measurement.md](docs/design-measurement.md): the plan for measuring
  changes. It is under discussion, so read it before proposing an improvement to the
  loop.

## Commits and PRs

The subject is `<bead-id>: <what changed>`, or `<area>: <what changed>` without a bead.
The body is prose: what was wrong, what the change does now, and how it was verified.
PRs go to `main` and squash-merge.
