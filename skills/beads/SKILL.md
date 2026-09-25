---
name: beads
description: The bd commands for a repo's beads backlog in .beads/ - find ready work, claim, read, note, close - in the syntax this bd version accepts. Use when a task names a bead id, asks what is ready, or needs a note or close recorded.
---

The backlog lives in `.beads/` at the repo root; ids are `<prefix>-<hash>` and children `<prefix>-<hash>.<n>` (`bd show <parent>` is the epic). Quote ids exactly; `bd show` on a wrong id prints nothing useful.

# Commands

```bash
bd ready -l <label>                     # unblocked tasks carrying the label, top first
bd ready -l <label> --json -n 1         # the same, for scripts
bd update <id> --claim                  # assignee you, status in_progress; idempotent
bd show <id>                            # DESCRIPTION, ACCEPTANCE CRITERIA, notes, deps
bd show <id> --json                     # fields: title, description, acceptance_criteria, notes, labels
bd update <id> --append-notes "..."     # progress or a BLOCKED note; keeps status
bd comment <id> "..."                   # a dated comment, for the owner
bd close <id> --reason "..."            # the only way to finish: evidence in the reason
bd search "text"                        # title and id; open issues only
```

# Status

`open`, `in_progress`, `blocked`, `deferred`, `closed`. `done` is rejected. Finishing is `bd close`, never `--status closed`, so the reason is recorded.

# Notes

A note is text for the owner. Give it a file and line when one exists: `BLOCKED: lib/api.ts:8 has no /api fallback; the task assumes one`. On a bead the loop works, open the note with who and when (`planner 2026-09-25: ...`): a note without one belongs to the entry above it, and when that entry is the loop's own, the loop's prompts leave the note out.

# Git

`.beads/issues.jsonl` is tracked and the owner commits it. Leave `.beads/` out of task commits.
