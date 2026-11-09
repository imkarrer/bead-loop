# shellcheck shell=bash
# Research refreshed, and your answers to a park. Ported from the Rust suite (`git show
# 8907dfa:test/run.sh`, search `NAME() {`), to what the BAML loop actually does with
# each.
#
# case_research_every_refreshes is not ported: it needs `research = "every"`, which the
# BAML loop parses but never reads (docs/config.md's "Not read" list says so in words;
# the loop researches a bead once, `research_model`, and that is all `research`'s value
# ever chooses between — on or off). There is no send-back-then-refine path to port.
#
# case_brief_falls_back_to_the_loops_question is not ported: the Rust loop wrote a
# parked bead's brief with a model (`brief_model`, with the loop's own question as the
# fallback when that model had nothing). The BAML loop's `brief_model` is a different
# knob entirely — the second opinion on a researcher's BLOCKED
# (baml_src/ns_supervisor/supervisor.baml's `researcher_of`) — and a park's brief is
# never written by a model: `write_park_brief` always calls the deterministic
# `park_brief_text` (baml_src/ns_agents/park.baml), whether a round sent the bead back
# with a BLOCKED or the stages ran out. `ParkBriefAgent` in that same file is defined
# and never called. There is no fallback to port: the loop's own question is the only
# brief there ever is.
#
# case_human_queue_answer_and_open ports only its first half, the answer: `tell answer`
# (baml_src/ns_supervisor/main.baml's `told`) takes a parked bead off the failure count
# by one, carries the text as the next round's note, and sends it back to the same
# stage. Its second half, `sup open`, started an interactive Claude Code session in the
# bead's worktree; the BAML loop's `tell` knows five words (answer, reopen, escalate,
# publish, open_pr) and none of them opens a session, so that half has nothing to port.
#
# case_escalate_to_the_last_stage is ported as two cases, one per scenario the Rust
# function ran in sequence: escalating a bead parked by its stages running out
# (case_escalate_to_the_last_stage below), and escalating a bead parked some other way,
# to show the reopening alone (case_escalate_reopens_a_parked_bead).

# The worker's report, parsed as a BLOCKED send-back (ns_rounds/round.baml's
# `work_outcome`): no commit of its own, so nothing survives for `tell answer` to build
# on but the question and the note.
blocked_report() {
  printf '{"content":"{\\"outcome\\":\\"blocked\\",\\"summary\\":\\"%s\\"}"}' "$1"
}

# BLOCKED on a one-attempt stage parks at once (it is already the last stage): the
# question is the BLOCKED line, and the brief is the loop's own, not a model's.
# `tell answer` takes the bead off the count by one and sends it back with the answer as
# the next round's note; the next round runs on the same stage.
case_human_queue_answer_and_open() {
  setup
  reply coder "$(blocked_report "lib/x.ts:3 has no such flag")"
  until_place parked 90 || bad "not parked: $(events)"
  assert_eq "$(bd_field status)" blocked "bd status while parked"
  assert_eq "$(view_bead .parked.question)" "BLOCKED: lib/x.ts:3 has no such flag" "the question"
  assert_match "$(view_bead .parked.brief)" "^WHAT HAPPENED:" "and its brief"
  assert_match "$(bd_field notes)" "BLOCKED: lib/x.ts:3 has no such flag" "the bead's notes"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tell answer --text "the flag is called --dry-run, see lib/x.ts:9"
  until_event pr_merged 90 || bad "never merged after the answer: $(events)"
  assert_match "$(bd_field notes)" "the flag is called --dry-run" "the answer on the bead"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "the flag is called --dry-run" \
    "the next round reads the answer as the last round's note"
}

# A bead parked by its stages running out: escalate (baml_src/ns_machine/step.baml's
# `on_parked`) sets its failure count to the last stage's first value and sends it back
# to the dev queue, which runs it there next, not on the stage it parked on.
case_escalate_to_the_last_stage() {
  STAGES="$(stage local fake/fast fake/rev 2)"$'\n'"$(stage frontier fake/slow fake/senior 1)" setup
  reply fast "$(done_report)" "$(done_report)"
  reply slow "$(done_report)"
  until_place parked 90 || bad "never parked: $(events)"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_eq "$(view_bead .parked.question)" "the stages are exhausted" "parked by the ladder"
  reply slow "$(write_work)" "$(commit)" "$(done_report)"
  reply senior "$(approve)"
  tell escalate
  until_event pr_merged 90 || bad "never merged after escalate: $(events)"
  assert_match "$(events)" "escalated" "the escalation"
  assert_eq "$(grep -lc '"model":"fast"' "$E2E_CTRL"/requests/*.json | wc -l)" 2 \
    "no further rounds on the stage it parked on"
  assert_eq "$(grep -lc '"model":"slow"' "$E2E_CTRL"/requests/*.json | wc -l)" 4 \
    "escalate landed the next round on the last stage's worker"
}

# A bead parked some other way: escalate still reopens it, even with nowhere further to
# escalate to (one stage, already its own last).
case_escalate_reopens_a_parked_bead() {
  setup 'false'
  reply coder "$(write_work)" "$(commit)"
  done_report >"$E2E_CTRL/replies/coder.last"
  until_event gate_failed_twice 90 || bad "no gate failure: $(events)"
  tick 2
  assert_eq "$(bd_field status)" blocked "parked once the only stage is spent"
  reply coder "$(write_work)" "$(commit)"
  tell escalate
  local start=$SECONDS
  while [ $((SECONDS - start)) -lt 90 ] \
    && [ "$(events | tr ' ' '\n' | grep -cw gate_failed_twice)" -lt 2 ]; do
    tick 1
  done
  assert_eq "$(events | tr ' ' '\n' | grep -cw gate_failed_twice)" 2 \
    "escalate reopened it for one more round, which failed the gate again"
  assert_match "$(events)" "escalated" "the escalation itself"
}
