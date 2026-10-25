---
name: breakdown
description: Breaking a spec, epic, plan or feature into beads the loop can land - settle the design, lay the skeleton, cut each bead to a few named files and a command that proves it, route it local or Sonnet, chain the blockers. Use when turning a project or task into beads for a repo the loop watches, in place of a generic ticket breakdown.
---

What one bead must look like is in `delegate`; `bd` syntax is in `beads`. This is the cut: the set of beads, their order, and which stage each starts on.

# Who works the beads

The first stage is a 30B local model with a 64k context (`[[stages]]` in `~/.config/bead-loop/config.toml`): two attempts, then Sonnet once, then a park for the owner. The local model lands an **edit**: a known file, a stated change, a command that goes green. It does not design. In October every first-try local landing named one to five files and stated its acceptance as a command; library-ai-lab's greenfield beads, written as behaviour with prose criteria, landed none of eight locally.

# Steps

1. **Read the target.** The repo's `.bead-loop.toml` (`label`, `gate`), its `AGENTS.md`, `CONTEXT.md`, and `git ls-tree -r origin/<base> --name-only`. Done when you can name the gate command and the files each piece of the work lands in.
2. **Settle every decision.** A choice a bead would have to make is decided now: with the owner, or as a `bd create -t decision` bead that blocks what depends on it. Done when no bead's description holds an "either" or a "such as".
3. **Lay the skeleton first.** Greenfield work starts with one bead, on `stage:frontier` or by hand, that creates the modules, tables, signatures and one passing test per area. Every later bead then edits a file that exists. Done when each remaining bead's Files exist on the base or are created by a bead that blocks it.
4. **Cut to edits.** One bead is one reviewable change: one to three source files plus their tests, each path named, one behaviour, a command that fails before and passes after. A layer at a time is a fine cut when each bead lands green with its own test; a feature through every layer is several beads. A wide rename goes expand, migrate in batches, contract. Done when each bead passes the check below.
5. **Route.** `delegate:local` on every bead the loop can do; add `stage:frontier` to one that needs judgement, breadth (more than five files), page JavaScript, or prose to write. Sonnet gets one attempt: write a frontier bead as carefully. One that needs a human (credentials, a browser, a purchase) gets none.
6. **Chain.** `bd dep add <blocked> <blocker>`; children under the epic with `--parent`. Keep the graph wide: a bead that blocks more than three others is a hub, and a hub that parks stalls all of them, so cut it smaller or land it first by hand. Done when `bd ready -l delegate:local` shows the frontier you expect and `bd dep cycles` is empty.
7. **Show the owner.** A numbered list: id, title, files, stage, blocked by. Label once approved.

# The check, per bead

Read it as the worker will (`bd show <id>`):

- **Files:** every path to change or create, from the repo root; each exists on `origin/<base>` or a blocker creates it.
- **The change**, as an edit: what is there now, what it becomes. A name the bead introduces is spelled out (the function, its arguments, the route).
- **Acceptance criteria** are commands: the gate, plus one test or grep that is red before this bead and green after. "The page works", "is refused", "is correct" are not criteria.
- **Fixers.** Where the gate checks formatting (`ruff format --check`, `cargo fmt --check`, prettier), the repo's `AGENTS.md` names the command that fixes it, so the worker runs it before committing: on 24-25 Oct, five of library-ai-lab's eleven gate send-backs were format and import order that `ruff format` and `ruff check --fix` fix.
- **Size.** Description under ~1500 characters, the files under ~8k tokens each for an aider bead (`delegate`).

A bead that fails the check is cut again or moved to `stage:frontier`.
