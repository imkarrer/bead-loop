# shellcheck shell=bash
# Stages escalate: a bead moves to a slower stage when its faster one runs out of
# attempts, or straight away when the same REJECT lands twice. Ported from the Rust
# suite's cases of the same name (git show 8907dfa:test/run.sh), to what the BAML loop
# actually does with each (baml_src/ns_machine/stages.baml, step.baml's `rejected`).
#
# case_repeat_cycles and case_blocked_at_last_stage_parks are not ported: both need
# `on_exhaust = "repeat"`, which cycles the stages forever instead of parking. The BAML
# loop has the config key (ns_machine/stages.baml's OnExhaust.Repeat) but no e2e case
# anywhere exercises it yet; this bead's files are this one alone, so it stays unported.
#
# case_claude_stage_after_local_ones is not ported: it is already covered, on the BAML
# loop, by core.sh's case_stage_label_starts_there and case_usage_limit_ends_at_its_reset.

# A REJECT with its own reason: the same-REJECT rule (step.baml's `rejected`) compares
# the reviewer's reason alone, so two rejects with the same reason escalate even with a
# different work order, and two with different reasons do not.
reject_work_order() {
  local reason=$1 how=$2
  printf '{"content":"{\\"decision\\":\\"Reject\\",\\"reason\\":\\"%s\\",\\"work_order\\":{\\"what_is_wrong\\":\\"work.txt is thin\\",\\"why_it_fails\\":\\"criterion\\",\\"what_to_do\\":\\"fix it\\",\\"how_to_check\\":\\"%s\\",\\"leave_alone\\":\\"the rest\\"}}"}' \
    "$reason" "$how"
}

# Append, commit, and report done: a worker's second (or third) turn on a bead whose
# first round already committed.
more_work() {
  printf '{"tool":"run","args":{"command":"echo %s >> work.txt && git commit -qam %s"}}' "$1" "$1"
}

# A bead with no worker left on its own stage moves to the next one down the ladder;
# with none left at all, it parks (docs/state-machine.md's `stages exhausted`).
case_escalation_stages() {
  STAGES="$(stage local fake/fast fake/rev 2)"$'\n'"$(stage frontier fake/slow fake/senior 1)" setup
  reply fast "$(done_report)" "$(done_report)"
  reply slow "$(done_report)"
  until_place parked 90 || bad "never parked: $(events)"
  assert_eq "$(events)" "picked no_commit picked no_commit picked no_commit picked" \
    "two attempts on the fast stage, one on the slow, then exhausted"
  assert_eq "$(jq -rs '[.[].model] | join(" ")' "$E2E_CTRL"/requests/*.json)" "fast fast slow" \
    "the ladder: the fast stage twice, then the slow one"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_match "$(bd_field labels)" "loop:parked" "bd label"
  assert_eq "$(view_bead .parked.question)" "the stages are exhausted" "the brief's reason"
}

# A REJECT whose squashed text matches the one before it skips the rest of its own
# stage's attempts and lands on the next one straight away (step.baml's `rejected`).
case_same_reject_twice_escalates() {
  STAGES="$(stage local fake/fast fake/rev 3)"$'\n'"$(stage frontier fake/slow fake/rev 1)" setup 'test -e work.txt'
  reply fast "$(write_work)" "$(commit)" "$(done_report)" "$(more_work more)" "$(done_report)"
  reply slow "$(write_work)" "$(commit)" "$(done_report)"
  local reject
  reject=$(reject_work_order thin "grep XYZZY work.txt")
  reply rev "$reject" "$reject" "$(approve)"
  until_event pr_merged 120 || bad "never merged: $(events)"
  assert_eq "$(grep -l '"model":"fast"' "$E2E_CTRL"/requests/*.json | wc -l)" 5 "the fast stage's two rounds, 3 then 2 calls"
  assert_eq "$(grep -l '"model":"slow"' "$E2E_CTRL"/requests/*.json | wc -l)" 3 "escalated straight to the slow stage's round"
  assert_match "$(bd_field notes)" "the same REJECT twice: escalated to fake/slow" "the note says why"
}

# Two REJECTs whose texts differ are two ordinary failures, not an escalation: the next
# round stays on the stage it was on.
case_different_rejects_do_not_escalate() {
  STAGES="$(stage local fake/fast fake/rev 3)"$'\n'"$(stage frontier fake/slow fake/rev 1)" setup 'test -e work.txt'
  reply fast "$(write_work)" "$(commit)" "$(done_report)" "$(more_work more)" "$(done_report)" \
    "$(more_work evenmore)" "$(done_report)"
  reply rev "$(reject_work_order thin "grep XYZZY work.txt")" \
    "$(reject_work_order "still thin" "grep PLUGH work.txt")" "$(approve)"
  until_event pr_merged 120 || bad "never merged: $(events)"
  assert_eq "$(grep -l '"model":"fast"' "$E2E_CTRL"/requests/*.json | wc -l)" 7 "all three rounds stay on the fast stage"
  assert_eq "$(grep -l '"model":"slow"' "$E2E_CTRL"/requests/*.json | wc -l)" 0 "the slow stage is never reached"
  assert_nomatch "$(bd_field notes)" "escalated" "no escalation from two different REJECTs"
}

# A stage with no attempts left and nowhere else to escalate to parks the bead, even
# though every send-back was an ordinary REJECT, not a repeat.
case_reject_until_parked() {
  STAGES="$(stage local fake/coder fake/rev 3)" setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)" "$(more_work more)" "$(done_report)" \
    "$(more_work evenmore)" "$(done_report)"
  reply rev "$(reject_work_order thin "grep XYZZY work.txt")" \
    "$(reject_work_order "still thin" "grep PLUGH work.txt")" \
    "$(reject_work_order "still too thin" "grep YYZ work.txt")"
  until_place parked 90 || bad "never parked: $(events)"
  assert_eq "$(events)" \
    "picked committed gate_passed review_picked rejected picked committed gate_passed review_picked rejected picked committed gate_passed review_picked rejected picked" \
    "three ordinary rejections, then the stage ladder is exhausted"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_match "$(bd_field labels)" "loop:parked" "bd label"
  assert_match "$(bd_field notes)" "review rejected" "the last send-back noted"
  assert_eq "$(view_bead .parked.question)" "the stages are exhausted" "the brief's reason"
}
