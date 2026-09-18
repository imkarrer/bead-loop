---
name: bead-workflow
description: The loop for one delegated bead in any repo - read, prove the claims, change only the named files, verify, commit, report DONE or BLOCKED - and the stop conditions that turn a guess into a note. Use when asked to work a bead.
---

Command syntax for `bd` is in the `beads` skill; this is the order and the exits.

# One bead, start to finish

The work happens on branch `bead/<id>` in its own worktree, never on the main checkout. The supervisor makes it; started by hand, make it first and open opencode there: `git worktree add ../wt/<id> -b bead/<id> origin/<base>`.

1. The bead's text is in your prompt; if only an id was given, `bd show <id>`.
2. Read its DESCRIPTION and ACCEPTANCE CRITERIA twice. The description names the files; the acceptance criterion is the command or grep that proves the work.
3. Open every file the bead names before editing any of them. Confirm each claim the description makes (the function exists, the flag exists, the file exists).
4. Make the change in those files only, in the style of the surrounding code. The repo's own skills (`<repo>-layout`, `<repo>-vocabulary`) and `AGENTS.md` set that style when they exist.
5. Run the acceptance check verbatim, then the repo's verify commands: the `<repo>-verify` skill or `AGENTS.md` names them; otherwise the `test`, `typecheck` and `lint` scripts the repo defines.
6. Commit on the current branch: `component: what changed, as one plain sentence` (examples in `git log --oneline -20`). Leave `.beads/` out of the commit.
7. End your turn with one line, `DONE: <the command you ran and what it printed>`.

Done means: the acceptance check passed, the verify commands pass, the commit exists, the last line is `DONE:` with the evidence. Closing the bead is the supervisor's job, after the pull request merges.

# Stop conditions

Stop, record, and end the turn when any of these appear. A precise note is a successful outcome; a guess is the failure.

- A claim in the description is false: the file, function, flag or route is not where it says, or has a different shape.
- The acceptance check cannot be run here (needs a box, a browser, a secret, a service that is not up).
- Two designs both satisfy the description. Choosing is the owner's job.
- The change needs a file the bead does not name.

End your turn with one line, `BLOCKED: <file:line and the claim that failed>`. Leave the working tree as it was: `git stash push -u -m "<id>"` if you had started.

# Scope

The bead is the whole scope. Adjacent improvements, refactors, and TODOs you notice go into the `DONE:` line as text, for the owner.
