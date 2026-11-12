# shellcheck shell=bash
# The pre-check: a small model that reads the gate-passed diff and the worker's report
# before the senior reviewer does (docs/config.md's `precheck_model`, baml_src/ns_rounds/
# round.baml's `precheck`). Ported from the Rust suite (`git show 8907dfa:test/run.sh`),
# minus one case the BAML loop has no code path for:
#
#   case_diff_checks: the Rust loop's `diff_checks` scanned every round's diff itself for
#   a placeholder test, independent of any model. The BAML state machine still carries
#   the event it would raise (`DiffProblems`, baml_src/ns_machine/events.baml), but
#   nothing ever constructs one: no code reads `diff_checks` (docs/config.md lists it
#   under "Not read") and nothing scans a diff for a placeholder. Porting the case as
#   written would be asserting a feature with no implementation behind it.
#
# The Rust `case_precheck_unavailable` ran a server error and a crashed `bead-prechecker`
# subprocess: two ways its separate process could fail to answer. The BAML loop has no
# such subprocess — the pre-check is an agent call inside the worker's own round,
# `catch_all` at both the client and the call (round.baml's `precheck`) — so a server
# error and anything else that agent could throw are the same path, covered once below.

# A round that ends "no commit" gets a post-mortem from the pre-check model, folded into
# the note below the usual line (round.baml's `postmortem`, `charge_postmortem`).
case_postmortem() {
  GLOBAL_EXTRA='precheck_model = "fake/precheck"' setup
  reply coder "$(done_report)"
  reply precheck '{"content":"1. Tried to edit work.txt.\n2. Never committed it: no diff to the base.\n3. Write work.txt and commit it."}'
  until_place parked 90 || bad "never parked: $(events)"
  assert_eq "$(events)" "picked no_commit picked" "one round, no commit, then parked"
  assert_match "$(bd_field notes)" "Post-mortem (fake/precheck):" "the note carries the post-mortem"
  assert_match "$(bd_field notes)" "1. Tried to edit work.txt." "the stub's three lines"
}

# A pre-check model that errors writing the post-mortem (same catch_all as the pre-check
# itself) costs the note nothing but its usual line: no post-mortem, and the failure and
# park go on exactly as they do with no pre-check model at all.
case_postmortem_unavailable() {
  GLOBAL_EXTRA='precheck_model = "fake/precheck"' setup
  reply coder "$(done_report)"
  echo '{"status":500,"error":"down"}' >"$E2E_CTRL/replies/precheck.last"
  until_place parked 90 || bad "never parked: $(events)"
  assert_eq "$(events)" "picked no_commit picked" "one round, no commit, then parked"
  assert_match "$(bd_field notes)" "worker made no commit" "the tail alone"
  assert_nomatch "$(bd_field notes)" "Post-mortem" "no post-mortem line when it errored"
  assert_eq "$(view_bead .failures)" 1 "one failure, no hold"
}

# A PASS from the pre-check model falls through to the reviewer, same as no pre-check at
# all: the bead still lands.
case_precheck_pass() {
  GLOBAL_EXTRA='precheck_model = "fake/precheck"' setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply precheck '{"content":"{\"send_back\":false,\"block\":\"PASS: touches only work.txt\"}"}'
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" "events"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "\"model\":\"precheck\"" "the precheck model was asked"
}

# A SEND BACK from the pre-check model is a failure, charged before the reviewer ever
# sees the round, and the one-attempt stage is exhausted by it: the next pick parks.
case_precheck_sendback() {
  GLOBAL_EXTRA='precheck_model = "fake/precheck"' setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply precheck '{"content":"{\"send_back\":true,\"block\":\"lib/y.ts is not a file the bead names\"}"}'
  until_event precheck_sent_back 60 || bad "no send-back: $(events)"
  assert_nomatch "$(events)" "review_picked" "sent back before any review"
  assert_eq "$(view_bead .failures)" 1 "one failure"
  assert_match "$(bd_field notes)" "precheck sent back: lib/y.ts is not a file the bead names" "the precheck's words kept"
  until_place parked 60 || bad "not parked: $(events)"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_match "$(bd_field labels)" "loop:parked" "bd label"
}

# A pre-check model that errors (crashed harness or a 500 alike, both `catch_all` in the
# same place) is "nothing from the model", not a failure: the round goes on to review.
case_precheck_unavailable() {
  GLOBAL_EXTRA='precheck_model = "fake/precheck"' setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  echo '{"status":500,"error":"down"}' >"$E2E_CTRL/replies/precheck.last"
  reply reviewer "$(approve)"
  until_event review_picked 60 || bad "never fell through to review: $(events)"
  assert_eq "$(view_bead .failures)" 0 "no failure charged for an unavailable precheck"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" "events"
}
