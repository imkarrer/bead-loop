# shellcheck shell=bash
# The queue: the label filter, a stale assignee, and the one-place invariant. Ported from
# the Rust suite's cases of the same name (git show 8907dfa:test/run.sh), to what the BAML
# loop actually does with each.
#
# case_priority_repo is not ported: it exercised `sup priority <repo>` / `sup priority
# none`, a CLI command that wrote `$BEAD_LOOP_STATE/priority` to steer one repo's beads
# ahead of a group's others. The BAML loop's CLI (baml_src/ns_supervisor/main.baml) has
# only `run` and `tell`, and `tell` knows five words (answer, reopen, escalate, publish,
# open_pr) and none of them is a priority marker. There is no feature here to port.

# A bead with no label the loop's queue is reading for is never admitted: `bd ready -l
# LABEL` (ns_world/live.baml's `tickets`) does not list it, so no round starts.
case_nothing_ready() {
  setup
  (cd "$REPO" && bd label remove "$BEAD" delegate:local >/dev/null)
  tick 1
  assert_eq "$(events)" "" "label filter respected"
  assert_eq "$(bd_field status)" open "left open: never picked"
}

# An assignee from a stale claim does not block the pick: `tickets` (ns_world/live.baml)
# reads `bd ready` by label alone, and `mark` (the same file) sets the bead's status with
# a plain `bd update`, never `--claim`. An open bead's assignee, whoever it names, is
# stale by definition and nothing the loop ever reads.
case_stale_assignee_does_not_block() {
  setup 'test -e work.txt'
  (cd "$REPO" && bd update "$BEAD" --assignee "Somebody Else" >/dev/null)
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "never worked: $(events)"
  assert_eq "$(bd_field status)" in_progress "claimed despite the stale assignee"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && ok || bad "no branch on origin"
}

# A bead in the merge queue is not reopened under its PR: answer and escalate refuse
# (ns_machine/step.baml's `elsewhere` and `refusal`), noted on the bead, left where it is.
# A bead reopened by hand while there is not handed to the dev lane either: the loop's own
# bead, not bd's status, says where a known bead is (ns_supervisor/supervisor.baml's
# `admit_tickets` only seeds a bead it has never seen).
case_one_place_invariant() {
  setup 'test -e work.txt'
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "never opened: $(events)"
  assert_eq "$(view_bead .place)" merge "in the merge queue"
  tell answer --text "x"
  tick 1
  assert_match "$(bd_field notes)" "in the merge queue at https://github.com/owner/repo/pull/1: close the PR or wait" \
    "answer refused, and says why"
  assert_eq "$(view_bead .place)" merge "left where it is"
  tell escalate
  tick 1
  assert_match "$(bd_field notes)" "in the merge queue at https://github.com/owner/repo/pull/1: close the PR or wait" \
    "escalate refused too"
  (cd "$REPO" && bd update "$BEAD" --status open >/dev/null)
  local before
  before=$(find "$E2E_CTRL/requests" -name '*.json' 2>/dev/null | wc -l)
  tick 1
  assert_eq "$(find "$E2E_CTRL/requests" -name '*.json' 2>/dev/null | wc -l)" "$before" \
    "in the merge queue: not handed to dev whatever bd says"
  assert_eq "$(view_bead .place)" merge "still in the merge queue"
}

# A bead someone claimed by hand, in_progress with no `loop:` label and no record in the
# loop's log, is never picked: admit_tickets (ns_supervisor/supervisor.baml) admits a
# ticket `bd ready` has stopped listing only when the loop marked it or already has a
# bead for it.
case_in_progress_by_hand_is_not_picked() {
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  (cd "$REPO" && bd update "$BEAD" --status in_progress >/dev/null)
  local before
  before=$(find "$E2E_CTRL/requests" -name '*.json' 2>/dev/null | wc -l)
  tick 3
  assert_eq "$(events)" "" "never picked"
  assert_eq "$(find "$E2E_CTRL/requests" -name '*.json' 2>/dev/null | wc -l)" "$before" \
    "no model request"
  assert_eq "$(bd_field status)" in_progress "left in_progress"
  assert_eq "$(view_bead .place)" "" "no place for the bead"
}
