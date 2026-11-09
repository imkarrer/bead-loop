# shellcheck shell=bash
# The last stage, and a stage without a reviewer. Ported from the Rust suite's cases of
# the same name (git show 8907dfa:test/run.sh), to what the BAML loop does with each.
#
# case_no_reviewer found that a stage with no reviewer started a review round on no model
# and never reached a PR (bl-lkb.11), though docs/config.md says "none: straight to PR".
# step.baml's on_working now takes a passed gate on such a stage straight to the PR.
#
# case_a_stage_with_no_worker_stops is not ported: the BAML loop does not check its
# stages, and the docs rewrite (1340e0b) took out the sentence that said a stage with no
# worker stops the run. Such a stage's rounds run on the default client
# (ns_agents/clients.baml); test/e2e/parity.md lists that as missing.

# last_stage_blocked TEXT: a worker's BLOCKED, with no commit (ns_rounds/round.baml's
# work_outcome).
last_stage_blocked() {
  printf '{"content":"{\\"outcome\\":\\"blocked\\",\\"summary\\":\\"%s\\"}"}' "$1"
}
last_stage_models() {
  jq -r .model "$E2E_CTRL"/requests/*.json 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ $//'
}

# A stage with no reviewer: the gate passes and the branch goes straight to a PR, with no
# review round and no reviewer model asked.
case_no_reviewer() {
  STAGES=$(stage local fake/coder "" 1) setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  until_event pr_merged 60 || bad "never merged: $(events)"
  assert_eq "$(events)" "picked committed gate_passed pr_opened checks_green pr_merged" "no review round"
  assert_eq "$(last_stage_models)" "coder" "only the worker was asked"
  assert_match "$(bd_field notes)" "no reviewer on this stage: straight to the PR" "the bead says why"
  assert_eq "$(bd_field status)" closed "bd status"
}

# BLOCKED on an earlier stage goes on to the next one: a stronger model may not be
# blocked. BLOCKED on the last stage parks, even under on_exhaust = "repeat".
case_blocked_at_last_stage_parks() {
  STAGES="$(stage fast fake/coder fake/reviewer 1)"$'\n'"$(stage slow fake/slow fake/reviewer 1)" setup
  sed -i 's/^on_exhaust = "park"$/on_exhaust = "repeat"/' "$HOME/.config/bead-loop/config.toml"
  reply coder "$(last_stage_blocked "README:1 says base, not the thing")"
  reply slow "$(last_stage_blocked "README:1 still says base")"
  until_event worker_blocked 60 || bad "the first stage never blocked: $(events)"
  assert_eq "$(view_bead .failures)" 1 "BLOCKED at the first stage: one failure"
  until_place parked 60 || bad "never parked: $(events)"
  assert_eq "$(events)" "picked worker_blocked picked worker_blocked" "one round on each stage, then parked"
  assert_eq "$(last_stage_models)" "coder slow" "the first stage's worker, then the last's"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_match "$(bd_field notes)" "README:1 still says base" "the last BLOCKED on the bead"
  tick 3
  assert_eq "$(events)" "picked worker_blocked picked worker_blocked" "repeat does not pick a parked bead again"
}

# A local round that fails sends the bead on to the Claude stage, whose prompt carries
# the note the local round left; Claude Code implements and reviews it to a PR.
case_claude_stage_after_local_ones() {
  STAGES="$(stage local fake/coder fake/reviewer 1)"$'\n'"$(stage frontier claude/sonnet claude/sonnet 1)" setup 'test -e work.txt'
  reply coder "$(done_report "nothing to change")"
  claude_reply 001 --arg b "$BEAD" '{sh:("echo done > work.txt && git add -A && git commit -qm \""+$b+": opus round\""), result:"{\"outcome\":\"done\",\"summary\":\"ok\"}"}'
  claude_reply 002 '{result:"{\"decision\":\"Approve\",\"reason\":\"ok\",\"work_order\":null}"}'
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_eq "$(events)" "picked no_commit picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" \
    "the local round, then Claude's work and review"
  assert_eq "$(last_stage_models)" "coder" "the local model asked once, before Claude"
  assert_match "$(cat "$E2E_CTRL/claude/prompt-001" "$E2E_CTRL/claude/argv-001" 2>/dev/null)" "no commit" \
    "Claude's prompt carries the local round's note"
  assert_eq "$(bd_field status)" closed "bd status"
}
