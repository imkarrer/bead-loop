---
name: bead-workflow
description: The loop for one delegated bead in any repo - read, prove the claims, change only the named files, verify, commit early, report DONE or BLOCKED - and the stop conditions that turn a guess into a note. Use when asked to work a bead.
---

Command syntax for `bd` is in the `beads` skill; this is the order and the exits. It is written for a 32k-context model: about 40 tool calls, spent on the files the bead names.

# One bead, start to finish

The work happens on branch `bead/<id>` in its own worktree, never on the main checkout. The supervisor makes it; by hand, make it first and open the agent there: `git worktree add ../wt/<id> -b bead/<id> origin/<base>`. Every path is under that worktree (`pwd`); a path outside it is wrong.

1. The bead's text is in your prompt; if only an id was given, `bd show <id>`. DESCRIPTION names the files; ACCEPTANCE CRITERIA is the command or grep that proves the work. If it names a test file, run that test first: its failure is the spec.
2. Open each named file once, with a line range when it is long. Confirm every claim the description makes (the function exists, the flag exists, the file exists) before editing anything.
3. Change only those files, in the style around them. One edit per hunk with the exact old text; no scratch scripts, nothing under /tmp. A changed signature or export means grepping for every caller and test that uses it and fixing them in the same pass. The repo's own skills (`<repo>-layout`, `<repo>-vocabulary`) and `AGENTS.md` set the style when they exist.
4. Run the acceptance check verbatim, then the repo's verify commands: the `<repo>-verify` skill or `AGENTS.md` names them; otherwise the `test`, `typecheck` and `lint` scripts the repo defines. Typecheck before test; pipe long output through `tail -40`.
5. Commit as soon as the acceptance check passes: `component: what changed, as one plain sentence` (examples in `git log --oneline -20`), `.beads/` left out. Keep fixing and committing after that.
6. End your turn with one line, `DONE: <the command you ran and what it printed>`, and nothing after it.

Done means: the acceptance check passed, the verify commands pass, the commit exists, the last line is `DONE:` with the evidence. Closing the bead is the supervisor's job, after the pull request merges.

# A note from an earlier round

The prompt may carry the loop's note on a round that was sent back. Do what it says first and check it the way it says; a REJECT's "How to check" is this round's acceptance criterion, and its "Leave alone" is not yours to touch. A note that contradicts the bead is a stop condition, not a choice.

# Stop conditions

Stop, record, and end the turn when any of these appear. A precise note is a successful outcome; a guess is the failure.

- A claim in the description is false: the file, function, flag or route is not where it says, or has a different shape.
- The acceptance check cannot be run here (needs a box, a browser, a secret, a service that is not up).
- Two designs both satisfy the description, or two criteria cannot both hold. Choosing is the owner's job.
- The change needs a file the bead does not name.

End your turn with one line, `BLOCKED: <file:line and the claim that failed>`. Leave the working tree as it was: `git stash push -u -m "<id>"` if you had started.

# Scope

The bead is the whole scope. Adjacent improvements, refactors, and TODOs you notice go into the `DONE:` line as text, for the owner.
