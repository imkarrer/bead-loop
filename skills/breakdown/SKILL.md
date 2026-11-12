---
name: breakdown
description: Breaking a spec, epic, plan or feature into beads the loop can land - settle the design, lay the skeleton, cut each bead to a few named files and a command that proves it, route it to the first stage or a later one, chain the blockers. Use when turning a project or task into beads for a repo the loop watches, in place of a generic ticket breakdown.
---

What one bead must look like is in `delegate`; `bd` syntax is in `beads`. This is the cut: the set of beads, their order, and which stage each starts on.

# Who works the beads

The loop exists to save Claude tokens: the cut is judged by how much work lands on the first stage. The stages are the `[[stages]]` of `~/.config/bead-loop/config.toml`: a worker, a reviewer and attempts each, then a park for the owner. The first stage, small and local, lands an **edit**: a known file, a command that goes green; it does not design. On a 30B model, first-try landings over a month named few files with a command; prose-criteria beads landed none.

# Steps

1. **Read the target.** The repo's `.bead-loop.toml` (`label`, `gate`), its `AGENTS.md`, `CONTEXT.md`, and `git ls-tree -r origin/<base> --name-only`. Done when you can name the gate command and the files each piece of the work lands in.
2. **Settle every decision.** A choice a bead would have to make is decided now: with the owner, or as a `bd create -t decision` bead that blocks what depends on it. Done when no bead's description holds an "either" or a "such as".
3. **Lay the skeleton first.** Greenfield work starts with one bead, on the last stage or done by hand, that creates the modules, tables, signatures and one passing test per area. Every later bead then edits a file that exists. Done when each remaining bead's Files exist on the base or are created by a bead that blocks it.
4. **Cut to edits.** One bead is one reviewable change: one to three source files plus their tests, each path named, one behaviour, a command that fails before and passes after. A layer at a time is fine when each bead lands green; a feature through every layer is several beads. A wide rename goes expand, migrate in batches, contract. Done when each bead passes the check below.
5. **Route.** The first stage is the default: every bead the loop can do starts there, unlabeled. Too wide or open for it, a bead is cut into a skeleton: failing tests for later, edits for first. Only what resists carries a later stage's `stage:NAME` and a note why: prose to write, a test suite to port. One needing a human gets no label.
6. **Chain.** `bd dep add <blocked> <blocker>`; children under the epic with `--parent`. Keep the graph wide: a bead that blocks more than three others is a hub, and a hub that parks stalls all of them, so cut it smaller or land it first by hand. Done when `bd ready -l <label>` shows the frontier you expect and `bd dep cycles` is empty.
7. **Show the owner.** Run `bead-supervisor lint --run true` over the ids. A numbered list: id, title, files, stage, blocked by. Label once approved.

# The check, per bead

Read it as the worker will (`bd show <id>`):

- **Files:** every path to change or create, from the repo root; each exists on `origin/<base>` or a blocker creates it.
- **The change**, as an edit: what is there now, what it becomes. A name the bead introduces is spelled out (the function, its arguments, the route).
- **Acceptance criteria** are commands: the gate, plus one test or grep that is red before this bead and green after. "The page works", "is refused", "is correct" are not criteria.
- **Fixers.** Where the gate checks formatting (`ruff format --check`, `cargo fmt --check`, prettier), the fixing command goes in the bead itself, as delegate says. Half of one repo's gate send-backs in a day were formatting.
- **Size.** Description under ~1500 characters.

A bead that fails the check is cut again or moved to a later stage.
