# shellcheck shell=bash
# Harness holds: a model's harness or its server failing before it has answered is the
# world's fault, not the bead's — held, no failure charged, and the round runs again once
# the hold clears. Ported from the Rust suite's cases of the same name (git show
# 8907dfa:test/run.sh), to what the BAML loop actually does with each.
#
# The BAML loop has no calendar backoff, by the owner's decision (11 Nov): the Rust
# loop's BEAD_LOOP_HOLD_BACKOFF and its doubling minutes are gone on purpose. A hold
# just keeps the bead off the pick list for a fixed run of ticks (hold_ticks, 5 —
# supervisor.baml), counted in-memory, so an e2e tick must be a single
# `tick N` call wide enough to hold that count; a restart (a fresh `tick` call, as every
# other case takes one) starts the count over, same as it would on a real restart. A bead
# held by the same broken harness five times running (HARNESS_STREAK, step.baml) is
# parked with its words — the BAML loop's stand-in for the Rust suite's "held over a day".
# The Rust suite's case_repeated_hold_restarts_backoff and
# case_hold_backs_off_exponentially_then_parks asserted that backoff; their places here,
# case_a_hold_is_retried_on_a_fixed_pace and case_five_harness_holds_in_a_row_park, assert
# this loop's own (test/e2e/parity.md rows 112 and 113).

# infra_count: how many "infra" (held) events the bead has logged so far.
infra_count() { events | tr ' ' '\n' | grep -c infra || true; }

# The model harness's server is unreachable: not the model's failure. The bead stays
# where it was (dev queue; review queue) with no failure, and the round runs once the
# hold clears.
case_harness_down_is_held() {
  setup 'test -e work.txt'
  echo '{"status":500,"error":"connection refused"}' >"$E2E_CTRL/replies/coder.last"
  until_event infra 60 || bad "no hold: $(events)"
  assert_eq "$(view_bead .failures)" 0 "no failure"
  assert_eq "$(bd_field status)" in_progress "still working the dev queue"
  assert_match "$(view_bead .held.why)" "connection refused" "held, with the server's words"
  rm -f "$E2E_CTRL/replies/coder.last"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tick 6
  until_event pr_merged 90 || bad "server back: never merged: $(events)"
  assert_eq "$(bd_field status)" closed "bd status"

  # The reviewer's server down: the bead stays in the review queue, no failure.
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  echo '{"status":500,"error":"connection refused"}' >"$E2E_CTRL/replies/reviewer.last"
  until_event infra 60 || bad "no hold in review: $(events)"
  assert_eq "$(view_bead .failures)" 0 "no failure"
  assert_eq "$(view_bead .place)" review "held, in the review queue"
  rm -f "$E2E_CTRL/replies/reviewer.last"
  reply reviewer "$(approve)"
  tick 6
  until_event pr_merged 90 || bad "reviewer back: never merged: $(events)"
}

# The harness answers with its own error before the model ever saw the bead (21 Sep 2026:
# a model added to a config without restarting its server, a 5xx underneath). No failure
# is charged, and the round that follows the hold is the same stage's, not the next one's
# (never charged, so the stage ladder never moves).
case_harness_error_is_held() {
  setup 'test -e work.txt'
  echo '{"status":502,"error":"UnknownError: Unexpected server error (err_502a8619)"}' >"$E2E_CTRL/replies/coder.last"
  until_event infra 60 || bad "no hold: $(events)"
  assert_eq "$(view_bead .failures)" 0 "no failure"
  assert_match "$(view_bead .held.why)" "err_502a8619" "held, with the harness's words"
  assert_nomatch "$(bd_field notes)" "round 1" "no round note: the round did not happen"
  rm -f "$E2E_CTRL/replies/coder.last"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tick 6
  until_event pr_merged 90 || bad "server back: never merged: $(events)"
  assert_eq "$(bd_field status)" closed "bd status"

  # The reviewer: the bead stays in the review queue, held with the same error, and the
  # same stage's reviewer reads it once the hold has cleared.
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  echo '{"status":502,"error":"UnknownError: Unexpected server error (err_502a8619)"}' >"$E2E_CTRL/replies/reviewer.last"
  until_event infra 60 || bad "no hold in review: $(events)"
  assert_eq "$(view_bead .failures)" 0 "no failure"
  assert_eq "$(view_bead .place)" review "held, in the review queue"
  rm -f "$E2E_CTRL/replies/reviewer.last"
  reply reviewer "$(approve)"
  tick 6
  until_event pr_merged 90 || bad "reviewer back: never merged: $(events)"
}

# A hold only keeps the bead off the pick list for hold_ticks — not a doubling wait, and
# not one that grows the more often the same reason holds it: every hold, even the same
# reason again and again, costs the same fixed run of ticks and charges nothing.
case_a_hold_is_retried_on_a_fixed_pace() {
  setup; echo '{"status":500,"error":"connection refused"}' >"$E2E_CTRL/replies/coder.last"
  tick 6
  assert_eq "$(infra_count)" 1 "one hold so far, still inside its own wait"
  setup; echo '{"status":500,"error":"connection refused"}' >"$E2E_CTRL/replies/coder.last"
  tick 13
  assert_eq "$(infra_count)" 3 "held, retried, and held again — three times at the same fixed pace"
  assert_eq "$(view_bead .failures)" 0 "nothing charged, however many times it holds"
  assert_eq "$(bd_field notes | grep -c 'held:')" 3 "every hold noted on its own, not silently piling up"
}

# The harness held five times in a row (the same broken CLI, or server) parks the bead
# with its words, not held forever — and nothing is charged for it.
case_five_harness_holds_in_a_row_park() {
  setup; echo '{"status":500,"error":"connection refused"}' >"$E2E_CTRL/replies/coder.last"
  tick 35
  assert_eq "$(infra_count)" 5 "five holds, the streak's limit"
  assert_eq "$(view_bead .place)" parked "parked, not held forever"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_eq "$(view_bead .failures)" 0 "no failure charged for any of it"
  assert_match "$(bd_field notes)" "parked: held 5 times in a row: .*connection refused" "the reason in the note"
}
