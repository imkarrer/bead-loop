---
name: delegate
description: Writing and labelling a bead for the loop - delegate:local hands it over, work:NAME sends it to a target, and the shape the worker needs from the description. Use when creating or labelling a bead the loop will work, or judging whether a bead is ready to delegate.
---

`bd` syntax is in the `beads` skill; what the worker does with a bead is in `bead-workflow`. This is what the planner decides before the loop takes one: whether, and where. Cutting a project into beads is `breakdown`.

# Handing a bead to the loop

`bd ready -l <label>` is the queue, `label` from the repo's `.bead-loop.toml` (`delegate:local` unless set). A bead the loop may work carries that label with its blockers closed, a DESCRIPTION that names the files and the change, and ACCEPTANCE CRITERIA that are a command in backticks. The stages are the `[[stages]]` of `~/.config/bead-loop/config.toml`, usually a local model first and Claude last. Every send-back (the gate failing twice, the pre-check's SEND BACK, a REJECT from review, CI red) is one failure, and moves the bead on toward the next stage. When you create a bead the loop will work, add the label `planned-in:$CLAUDE_CODE_SESSION_ID` (`bd create ... -l delegate:local,planned-in:$CLAUDE_CODE_SESSION_ID`; for a bead that exists, `bd label add ID planned-in:$CLAUDE_CODE_SESSION_ID`); skip it when the variable is unset.

A bead for another repo the planning repo names as `[targets.NAME]` also carries `work:NAME`; the loop works it in that checkout.

# What the worker is

The local stages' worker is a BAML agent with six tools: `read_file`, `write_file`, `edit_file`, `search`, `list_files` and `run` (a shell command in the worktree, bounded in time). It reads the bead, a research brief when `research_model` is set, and the last send-back's note; edits; runs the acceptance check; commits; and reports done or blocked. The last stage is one Claude Code turn with Claude's own tools. So the DESCRIPTION should:

- Name each file to change and each to read, from the repo root, as on disk. A path the model must hunt for costs steps; a 30B model on a long search runs out of them.
- State the change as an edit: what to find and what it becomes, anchored on one short, exact line.
- Name one acceptance command that fails on the base branch and passes once the change is in. The gate runs after the worker whatever it reports; the reviewer holds the diff to the bead.
- Leave out what a worker cannot do in a worktree: clone, download, sign in, touch another repo.

A bead with two possible shapes, or a decision in it, is not ready: settle it first, or the last stage parks it with your question.

# Before the label lands

`bd show <id>` and read it as the worker will: every path exists (`git ls-tree -r origin/<base> --name-only | grep`), every claim about the code is true, the acceptance check runs from a fresh worktree of the base branch. A false claim is a wasted round on every stage. Then run `bead-supervisor lint --config_file REPO/.bead-loop.toml --ids ID` and fix what it reports, adding `--run true` when the acceptance is a command.
