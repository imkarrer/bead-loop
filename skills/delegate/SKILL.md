---
name: delegate
description: Writing and labelling a bead for the loop - delegate:local hands it over, harness:aider when the files to edit are known, and the shape each harness needs from the description. Use when creating or labelling a bead the loop will work, or judging whether a bead is ready to delegate.
---

`bd` syntax is in the `beads` skill; what the worker does with a bead is in `bead-workflow`. This is what the planner decides before the loop takes one: whether, and under which harness.

# Handing a bead to the loop

`bd ready -l delegate:local` is the queue. A bead the loop may work carries that label with its blockers closed, a DESCRIPTION that names the files and the change, and ACCEPTANCE CRITERIA that are a command or a grep. The stages are in `~/.config/bead-loop/config.toml`: the small local model first, the larger local model after its failures, Claude last. Every send-back (the gate failing twice, a REJECT from review, CI red) is one failure, and moves the bead one stage on.

# Picking the harness

A stage's worker runs in opencode: the model reads the repo with tools, finds its files, runs the acceptance check, commits, ends `DONE:` or `BLOCKED:`. One label puts the same model under aider instead:

```bash
bd label add <id> harness:aider
```

Aider is handed the files and edits them; it explores nothing. The loop's logs say where opencode rounds die on the small model: a path outside the worktree, the 32k context spent before the first edit. Both are exploration, and an aider round has none. So:

- **harness:aider** when the DESCRIPTION can name every file to touch, each exists on the base branch, and the repo's gate proves the change (the gate runs as aider's lint after every edit). A one-file fix; a rename across callers you have listed; a test and the code it covers.
- **no label** (opencode) when the model must find its files, create one, run a test the bead names, or might need to stop with `BLOCKED:` and a reason. Anything with two possible shapes.
- The Claude stage ignores the label. `harness:opencode` on a bead takes it out of a stage whose worker is `aider:...`.

# An aider bead's description

Aider gets every token of the DESCRIPTION with a `/` or a `.` in it that is a file in the worktree, and nothing else:

- Each path from the repo root, as on disk: `src/round.rs`, `test/run.sh`. A bare `round.rs` or `harness_for` is not a file. Name the files to change and the files to read; both go to aider.
- State the change as an edit: what to find and what it becomes, in which file. Aider runs only the gate; the reviewer proves the acceptance criteria afterwards, so an aider bead's gate should cover them (a test the gate runs, a grep the reviewer can run).
- A zero exit with a diff is done; there is no `DONE:` line and no `BLOCKED:`. A bead aider cannot do burns a round and moves on, so a doubtful bead stays in opencode.

# Before the label lands

`bd show <id>` and read it as the worker will: every path exists (`git ls-tree -r origin/<base> --name-only | grep`), every claim about the code is true, the acceptance check runs from a fresh worktree of the base branch. A false claim is a wasted round on every stage.
