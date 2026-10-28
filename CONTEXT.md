# bead-loop

A supervisor that works beads with local and metered models, and the means to tell
whether a change to it, or to a config, made it better.

## Language

### The loop

**Round**:
One attempt by a model at one job on a bead: a worker round, a review round, a research round.
_Avoid_: run, attempt, iteration

**Session**:
One model call within a round, with its own model and agent; a round has one or more (a worker and its gate fix, each review seat).
_Avoid_: round (a round is the job, the session one call in it)

**Send-back**:
A round that returns the bead to the dev queue, with a note saying why.
_Avoid_: retry, bounce

**Failure**:
A send-back the bead is charged for; the failure count picks the stage.
_Avoid_: error (infrastructure trouble is never a failure)

**Stage**:
The worker and reviewers a bead gets at its current failure count; the last is usually metered.
_Avoid_: tier, level

**Held**:
A bead waiting in its queue on something outside the loop, with no failure charged.
_Avoid_: stuck, blocked

**Parked**:
A bead the models could not land, handed to its owner with a question.
_Avoid_: held, abandoned

**Landed**:
A bead the loop merged and closed.
_Avoid_: done, finished, shipped

**Human touch**:
One act by a person that a bead needed to move: an answer, an unpark, an escalation, an operator note. (An operator's commit on the bead's branch is one too, not yet counted.)
_Avoid_: intervention, human minutes

### Measurement

**Stamp**:
What produced a session: the loop's commit, the prompts and skills it was handed, the target commit it started from, and the resolved stage and config.
_Avoid_: version, metadata

**Row**:
One bead's features as they stood when the loop first claimed it, and its outcome: the unit every metric is computed over.
_Avoid_: record, entry

**Headline metric**:
Metered USD per landed bead, always read beside landing rate and human touches per landed bead.
_Avoid_: cost per bead (it hides parks), score

**Guardrail**:
A metric a change must not worsen even when the headline improves; today, defects after merge.

**Defect after merge**:
Within 14 days of a bead landing, a revert of its commit or a later bead linked to it by a `caused-by` dependency (a mention in the text is not one).
_Avoid_: regression, bug

**Diagnostic**:
A number read to explain a movement, never optimised: send-backs by reason, empty rounds, pre-check catches.

**Hypothesis**:
A proposed change stated as the metric it should move and the beads it should move it on.
_Avoid_: improvement, idea

**Case**:
A closed bead frozen for replay: its base commit, its text as the worker saw it, and its hidden check.
_Avoid_: fixture, sample

**Hidden check**:
The tests that landed with a case's merge, run after a replay and never shown to the worker.
_Avoid_: oracle, answer key

**Bench**:
Replaying the same cases under two configs, offline, to compare them under control.
_Avoid_: eval, benchmark suite

**Arm**:
One config a bench run compares; the frontier-only arm is the baseline for whether delegation pays.
_Avoid_: variant, branch
