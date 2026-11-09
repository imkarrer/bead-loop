# shellcheck shell=bash
# Review feedback on the loop's own PR, ask mode (`open_pr = "ask"`) and the lever that
# publishes. Ported from the Rust suite's cases of the same name (git show
# 8907dfa:test/run.sh), to what the BAML loop does with each:
#
# - The Rust suite tested ask mode inside a target; it is a repo key here too
#   (config.baml), so these cases set it on the repo.
# - Rust's `sup publish ID --title` is `tell open_pr --title` here, and the proposal's
#   body is the bead's description (#234), not a plain-style body with a bead marker.
# - case_ask_counts_inflight found that a bead ready to publish did not count toward
#   max_inflight (bl-lkb.8); supervisor.baml's `inflight` counts it now.

# levers_to_publish: the first bead under open_pr = "ask" (and EXTRA, more repo keys),
# worked, approved and pushed, waiting for its PR.
levers_to_publish() {
  setup 'test -e work.txt'
  printf 'open_pr = "ask"\n%s\n' "${1:-}" >>"$REPO/.bead-loop.toml"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event branch_pushed 60 || bad "never pushed: $(events)"
}
levers_count() { events | tr ' ' '\n' | grep -cx "$1" || true; }
levers_events_of() { jq -r .kind "$(STATE)/beads/$1/events.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
levers_bd_of() { (cd "$REPO" && bd show "$1" --json | jq -r ".[0].$2"); }
levers_set_pr() {
  jq "$1" "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"
}

# A maintainer's CHANGES_REQUESTED review on the loop's own open PR sends the bead back on
# the same branch, uncharged, with the review in the next round's prompt; the push updates
# the PR it has, and the same review is never worked twice.
case_feedback_review_sends_back_to_same_pr() {
  setup 'test -e work.txt'
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "never opened: $(events)"
  tick 1   # the first look marks what the PR already has as seen
  levers_set_pr '.[0].reviews = [{state:"CHANGES_REQUESTED", body:"please add tests", author:{login:"maintainer"}, submittedAt:"2026-01-01T00:00:00Z"}]'
  reply coder '{"tool":"write_file","args":{"path":"tests.txt","content":"tested\n"}}' "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event feedback 30 || bad "the review was not seen: $(events)"
  assert_eq "$(view_bead .failures)" 0 "no failure charged"
  local start=$SECONDS
  until [ "$(levers_count pr_opened)" -ge 2 ] || [ $((SECONDS - start)) -ge 60 ]; do tick 1; done
  assert_eq "$(levers_count pr_opened)" 2 "back in the merge queue: $(events)"
  grep -rqs "please add tests" "$E2E_CTRL/requests" && ok || bad "the review's words never reached the worker"
  grep -rqs "maintainer" "$E2E_CTRL/requests" && ok || bad "nor who said them"
  git -C "$E2E_ORIGIN" show "refs/heads/bead/$BEAD:tests.txt" >/dev/null 2>&1 && ok || bad "the fix is not on the branch"
  assert_eq "$(grep -c '^pr create' "$E2E_CTRL/gh/calls")" 1 "no second PR: the push updated the first"
  assert_eq "$(view_bead .place)" merge "the same PR, in the merge queue"
  tick 2
  assert_eq "$(levers_count feedback)" 1 "the same review is not worked twice"
}

# open_pr = "ask": worked and reviewed as any round, the branch pushed, and no PR: the
# bead waits, in_progress, for you to open it.
case_ask_holds_the_pr() {
  levers_to_publish
  assert_eq "$(events)" "picked committed gate_passed review_picked approved branch_pushed" "worker then reviewer, then the push"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && ok || bad "the branch is not on origin"
  assert_eq "$(grep -c '^pr create' "$E2E_CTRL/gh/calls")" 0 "no PR opened"
  assert_eq "$(view_bead .place)" publish "ready to publish"
  assert_eq "$(bd_field status)" in_progress "in_progress, so bd ready does not list it again"
}

# The lever opens the PR the bead was waiting for, with your title over its own, and the
# merge closes the bead as any other round's PR does.
case_publish() {
  levers_to_publish
  tell open_pr --title "Better title"
  until_event pr_opened 30 || bad "no PR: $(events)"
  assert_eq "$(jq -r '.[0].title' "$E2E_CTRL/gh/prs.json")" "Better title" "your title"
  assert_eq "$(jq -r '.[0].body' "$E2E_CTRL/gh/prs.json")" "Write work.txt" "the bead's description as the body"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr create --head bead/$BEAD --base main" "opened from the pushed branch"
  until_event pr_merged 60 || bad "never merged: $(events)"
  assert_eq "$(bd_field status)" closed "the merge closes the bead"
}

# A bead ready to publish holds a max_inflight slot, as a PR waiting on CI does: with
# max_inflight = 1 the second bead is not taken while the first waits.
case_ask_counts_inflight() {
  levers_to_publish 'max_inflight = 1'
  local bead2
  bead2=$(cd "$REPO" && bd create "Second" -d "Write work.txt" --acceptance "test -e work.txt" -l delegate:local --json | jq -r .id)
  tick 3
  assert_eq "$(levers_events_of "$bead2")" "" "max_inflight = 1 with one ready to publish: the second bead is not taken"
  assert_eq "$(levers_bd_of "$bead2" status)" open "the second bead untouched"
}

# Every tick is a fresh process here, so each is a recovery: a bead ready to publish is
# left as its round left it, not reopened and worked again (pw-i7c, 24 Oct).
case_recover_leaves_a_proposed_bead() {
  levers_to_publish
  local before
  before=$(events)
  tick 3
  assert_eq "$(events)" "$before" "three restarts, and nothing done to it"
  assert_eq "$(view_bead .place)" publish "still waiting to be published"
  assert_eq "$(bd_field status)" in_progress "still in_progress"
}
