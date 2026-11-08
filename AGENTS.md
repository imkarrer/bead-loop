# bead-loop

The supervisor is one packed BAML binary, `bead-supervisor` (`baml_src/`), plus the page
(`bead-supervisor page`; `bin/bead-loop-ui` wraps it), the skills a planner uses to write beads (`skills/`), and
`install.sh`. What it does is the [README](README.md); one bead from start to finish is
[docs/state-machine.md](docs/state-machine.md).

## The toolchain

`flox activate` gives `bd`, `gh`, node and shellcheck. `baml-cli` is not in
that env: `scripts/ensure-baml.sh` downloads the pinned static binary and prints its
directory. To work on the repo with the engineering skills loaded, run the dev stack
inside it: `flox activate -- nix run .#dev`.

## The gate

The gate is `gate` in [.bead-loop.toml](.bead-loop.toml), and CI runs the same checks
(`scripts/ci.sh`). Before you commit:

```bash
export PATH="$(scripts/ensure-baml.sh):$PATH"
baml-cli --agent-skill-check off fmt
bash -c "$(sed -n 's/^gate = "\(.*\)"$/\1/p' .bead-loop.toml)"   # the whole gate
```

Run the parts on their own while iterating:
- `baml-cli --agent-skill-check off test` for the loop;
- `test/lint-skills.sh` for `skills/` and `agents/` (frontmatter, under 700 words);
- `scripts/pack.sh target/bead-supervisor` for the binary the unit execs.
- `node scripts/page-html.mjs` after editing `ui/index.html`: the binary serves the page from
  the BAML constant it writes; `node test/ui-onclicks.js test/ui-state.json` checks its levers.

## Where a test goes

- **A test in `baml_src/`:** the shape of a prompt, a note, a queue order, a transition
  the state machine makes. Every row of the outcome table in `docs/state-machine.md`
  has one.

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

## Agent skills

### Issue tracker

Issues are beads in `.beads/`, worked with the `bd` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, applied as bd labels. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the root, with `docs/design-*.md` as the existing decision notes. See `docs/agents/domain.md`.
