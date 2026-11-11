# shellcheck shell=bash
# Send-backs: a round that ends without a commit, a leftover change the round settles
# for the worker, and a gate that stays red or comes clean on the one revision a round
# gives it. Ported from the Rust suite's cases of the same name (git show
# 8907dfa:test/run.sh), to what the BAML loop actually does with each
# (baml_src/ns_rounds/round.baml's work_round, commit_left; ns_machine/step.baml's
# charge).
#
# case_gate_fixed_on_revision names the fix a second commit, as the Rust case did; the
# BAML round folds both the commit and the fix into the same `committed` event
# (round.baml's `passed` reuses the first commit's event), so the two worker turns show
# up as a second commit on the branch, not a second event.

# A worker that never commits is charged "no commit" and parks once the only stage is
# spent (one attempt, lib.sh's default); nothing reaches origin.
case_no_commit() {
  setup
  reply coder "$(done_report)"
  until_place parked 90 || bad "never parked: $(events)"
  assert_eq "$(events)" "picked no_commit picked" "one round, no commit, then parked"
  assert_match "$(bd_field notes)" "worker made no commit" "noted"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && bad "a branch pushed" || ok
}

# A worker that reports done but leaves its change uncommitted has done the work; the
# round commits it for the worker, named from the report's own summary, and the gate and
# review carry on as if the worker had committed itself.
case_uncommitted_is_settled() {
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(done_report "settled the work")"
  reply reviewer "$(approve)"
  until_event pr_opened 90 || bad "no PR: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened checks_green" \
    "the round committed the leftovers, then review"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && ok || bad "no branch on origin"
  assert_match "$(git -C "$E2E_ORIGIN" log -1 --format=%s "bead/$BEAD")" "$BEAD: settled the work" \
    "commit named after the report's summary"
}

# A gate that never clears costs the round its one revision, then the bead is charged,
# sent back, and (its only stage spent) parked straight away; nothing is pushed.
case_gate_fails_twice() {
  setup 'echo nope >&2; false'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  done_report >"$E2E_CTRL/replies/coder.last"
  until_event gate_failed_twice 90 || bad "no gate failure: $(events)"
  assert_eq "$(events)" "picked committed gate_failed_twice picked" \
    "one revision round, then charged and sent back, then parked on its only stage"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "the gate failed. Fix it and commit" "gate output fed back"
  assert_match "$(bd_field notes)" "gate failed: nope" "noted"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && bad "a branch pushed" || ok
}

# A gate that fails once and passes on the round's one revision never sends the bead
# back: the fix is a second commit on the branch that goes on to review.
case_gate_fixed_on_revision() {
  setup '[ -e "$E2E_CTRL/gateok" ] || { touch "$E2E_CTRL/gateok"; false; }'
  reply coder "$(write_work)" "$(commit)" "$(done_report)" \
    '{"tool":"run","args":{"command":"echo more >> work.txt && git commit -qam more"}}' "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 90 || bad "no PR: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened checks_green" \
    "the gate's one revision, then review"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && ok || bad "no branch on origin"
  assert_eq "$(git -C "$E2E_ORIGIN" rev-list --count "main..bead/$BEAD")" 2 "the fix is a second commit"
}

# The revision session is a new session, not a continuation of the one the failed gate
# cut short: a file it reads again must come back whole, not "already read this session"
# for text the revision's own journal never held (bl-gc1.4).
case_gate_revision_reads_afresh() {
  setup '[ -e "$E2E_CTRL/gateok" ] || { touch "$E2E_CTRL/gateok"; false; }'
  reply coder '{"tool":"read_file","args":{"path":"README"}}' "$(write_work)" "$(commit)" "$(done_report)" \
    '{"tool":"read_file","args":{"path":"README"}}' \
    '{"tool":"run","args":{"command":"echo more >> work.txt && git commit -qam more"}}' "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 90 || bad "no PR: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened checks_green" \
    "the gate's one revision, then review"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && ok || bad "no branch on origin"
  assert_eq "$(git -C "$E2E_ORIGIN" rev-list --count "main..bead/$BEAD")" 2 "the fix is a second commit"
  assert_nomatch "$(cat "$E2E_CTRL"/requests/*.json)" "already read this session" \
    "the revision's read of README was not a stub"
}
