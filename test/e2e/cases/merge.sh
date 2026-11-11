# shellcheck shell=bash
# The merge queue: CI's checks, a required check, a killed job, a behind or conflicting
# PR, and the pipeline's own label. Ported from the Rust suite's cases of the same name
# (git show 8907dfa:test/run.sh), to what the BAML loop actually does with each
# (docs/state-machine.md's merge rows; baml_src/ns_world/github.baml's watch_pr).
#
# case_mergeable_unknown_is_pending_not_nocheck is not ported: the Rust loop reads a PR's
# `mergeable: UNKNOWN` as "GitHub has not computed it yet, ask again quietly", distinct
# from an empty check rollup that is held as `nocheck` once past its grace period. The
# BAML watcher (ns_world/github.baml: pr_events, watch_pr) has no such case for `UNKNOWN`:
# it falls through to the same empty-rollup path as `MERGEABLE`, so it would be held same
# as a true nocheck. That is a gap, not this file's to fix (its own bead).
#
# case_merge_pipeline_label_missing is not ported: it needs `gh pr edit --add-label` to
# fail, and the gh stub (test/e2e/bin/gh) has no control for that — a helper for it would
# have to live in the stub, not here, and this bead's files are this one alone.

# set_checks JSON: the PR's statusCheckRollup, as `gh pr view --json ...` would answer.
set_checks() {
  jq --argjson c "$1" '.[0].statusCheckRollup = $c' "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" \
    && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"
}

# set_required JSON: what `gh pr checks --required --json name,state,description,bucket` answers.
set_required() { printf '%s\n' "$1" >"$E2E_CTRL/gh/required.json"; }

# set_pr FILTER: any other field of the one PR (.[0]), by a jq filter.
set_pr() {
  jq "$1" "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"
}

# land_pr: the first round, worker then reviewer, to an open PR (lib.sh's case_lands, as
# a fixture every case here starts from).
land_pr() {
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "never opened: $(events)"
}

# until_count KIND N [SECONDS]: tick until the bead's log has KIND at least N times (for
# an event, like pr_opened or checks_red, a later round can log again).
until_count() {
  local want=$1 n=$2 limit=${3:-60} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    tick 1
    [ "$(events | tr ' ' '\n' | grep -cx -- "$want")" -ge "$n" ] && return 0
  done
  return 1
}

# CI's checks: nothing while any is pending, the merge once every one is green.
case_ci_pending_then_green() {
  setup 'test -e work.txt'
  echo '[{"context":"a","state":"SUCCESS"},{"context":"b","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  land_pr
  assert_nomatch "$(events)" "pr_merged" "one pending check holds the merge"
  assert_eq "$(bd_field status)" in_progress "pending: bead waits"
  set_checks '[{"context":"ci","state":"SUCCESS"},{"context":"gate","state":"SUCCESS"}]'
  until_event pr_merged 30 || bad "never merged: $(events)"
  assert_eq "$(bd_field status)" closed "green: bead closed"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr merge bead/$BEAD --squash --delete-branch" "squash, branch deleted"
}

# CI red sends the bead back to the dev queue on the same branch; the next push updates
# the same PR, not a second one.
case_ci_red() {
  STAGES=$(stage local fake/coder fake/reviewer 2) setup 'test -e work.txt'
  echo '[{"context":"ci","state":"FAILURE"}]' >"$E2E_CTRL/gh/checks.json"
  set_required '[{"name":"ci","state":"FAILURE","bucket":"fail"}]'
  # Both rounds' replies are queued before the first tick: the second round can start as
  # soon as the first tick sees the red (same tick as the pick, a background process
  # away from this shell), before this script would otherwise get to queue it.
  reply coder "$(write_work)" "$(commit)" "$(done_report)" \
    '{"tool":"run","args":{"command":"echo more >> work.txt && git commit -qam more"}}' "$(done_report)"
  reply reviewer "$(approve)" "$(approve)"
  until_event pr_opened 60 || bad "never opened: $(events)"
  until_event checks_red 30 || bad "no red: $(events)"
  assert_eq "$(view_bead .failures)" 1 "one failure"
  assert_match "$(bd_field notes)" "CI red: ci" "the failing check named"
  until_place merge 60 || bad "never repushed: $(events)"
  assert_eq "$(grep -c '^pr create' "$E2E_CTRL/gh/calls")" 1 "no second PR: the push updated the first"
}

# A red in no required check is not charged, and waits rather than parking.
case_ci_red_unrequired_waits() {
  MERGE=pipeline setup 'test -e work.txt'
  land_pr
  set_required '[{"name":"ci/suite","state":"SUCCESS","bucket":"pass"}]'
  set_checks '[{"context":"ci/suite","state":"SUCCESS"},{"context":"ci/automerge","state":"FAILURE"}]'
  until_event red_not_required 30 || bad "no red_not_required: $(events)"
  assert_eq "$(view_bead .failures)" 0 "a red in no required check is not charged"
  assert_eq "$(view_bead .place)" merge "stays in the merge queue"
  set_required '[{"name":"ci/suite","state":"FAILURE","bucket":"fail"}]'
  set_checks '[{"context":"ci/suite","state":"FAILURE"}]'
  until_event checks_red 30 || bad "no red: $(events)"
  assert_eq "$(view_bead .failures)" 1 "a required check's red is charged"
}

# A Buildkite job killed at its timeout is re-run once before it is charged; a build
# that skipped is not a result at all.
case_ci_skipped_build_is_not_red() {
  MERGE=pipeline setup 'test -e work.txt'
  land_pr
  set_checks '[{"context":"ci","state":"ERROR","description":"Build #285 skipped"}]'
  tick 1
  assert_eq "$(view_bead .failures)" 0 "a skipped build is not charged"
  assert_eq "$(view_bead .place)" merge "it waits in the merge queue, pending"
  set_checks '[{"context":"ci","state":"ERROR","description":"Build #287 skipped"},{"context":"ci/suite","state":"SUCCESS"}]'
  tick 1
  assert_eq "$(view_bead .failures)" 0 "a skip after a green build does not turn it red"
  set_required '[{"name":"ci","state":"FAILURE","bucket":"fail"}]'
  set_checks '[{"context":"ci","state":"FAILURE"}]'
  until_event checks_red 30 || bad "no red: $(events)"
  assert_eq "$(view_bead .failures)" 1 "a red from a build that ran is charged"
}

# A Buildkite step killed at its timeout re-runs once (the label off, then back on, asks
# CI again): not charged while that rerun is pending, charged once it has a real result.
case_ci_killed_job_reruns_once() {
  MERGE=pipeline setup 'test -e work.txt'
  land_pr
  set_required '[{"name":"ci/suite","state":"FAILURE","description":"timed out (exit status -1)","bucket":"fail"}]'
  set_checks '[{"context":"ci/suite","state":"FAILURE"}]'
  until_event red_killed 30 || bad "not seen as killed: $(events)"
  assert_eq "$(view_bead .failures)" 0 "a killed job is not charged"
  assert_eq "$(view_bead .place)" merge "the bead stays in the merge queue"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr checks https://github.com/owner/repo/pull/1 --required" "asked for the required checks"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "remove-label automerge" "re-run by relabelling"
  set_checks '[{"context":"ci/suite","state":"PENDING"}]'
  tick 1
  assert_eq "$(view_bead .failures)" 0 "the rerun, still pending, is not charged"
  set_required '[{"name":"ci/suite","state":"FAILURE","description":"Failed (exit status 1)","bucket":"fail"}]'
  set_checks '[{"context":"ci/suite","state":"FAILURE"}]'
  until_event checks_red 30 || bad "no red on the rerun: $(events)"
  assert_eq "$(view_bead .failures)" 1 "the rerun's own red is charged"
}

# bl-iej.8.1, 25 Sep: a fix round that found nothing new to commit still asks CI again
# (the label off, then back on), and the old build's red, still in the rollup, is not
# charged a second time.
case_ci_red_unchanged_head_reruns() {
  MERGE=pipeline STAGES=$(stage local fake/coder fake/reviewer 2) setup 'test -e work.txt'
  land_pr
  set_required '[{"name":"ci","state":"FAILURE","bucket":"fail"}]'
  set_checks '[{"context":"ci","state":"FAILURE"}]'
  reply coder "$(done_report)"
  reply reviewer "$(approve)"
  until_count checks_red 1 30 || bad "no red: $(events)"
  assert_eq "$(view_bead .failures)" 1 "build 1's red charged once"
  : >"$E2E_CTRL/gh/calls"
  until_count rebutted 1 60 || bad "no rebuttal: $(events)"
  until_count approved 2 30 || bad "not re-approved: $(events)"
  assert_eq "$(view_bead .failures)" 1 "no new commit: not charged again"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "remove-label automerge" "the label comes off"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "add-label automerge" "and back on, to ask CI again"
  assert_eq "$(grep -c '^pr create' "$E2E_CTRL/gh/calls")" 0 "no second PR"
}

# The same no-commit fix round under merge = "auto": no label to re-run CI with, so the
# old red is not charged twice and the bead is held for you instead.
case_ci_red_unchanged_head_holds() {
  STAGES=$(stage local fake/coder fake/reviewer 2) setup 'test -e work.txt'
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  land_pr
  set_required '[{"name":"ci","state":"FAILURE","bucket":"fail"}]'
  set_checks '[{"context":"ci","state":"FAILURE"}]'
  reply coder "$(done_report)"
  reply reviewer "$(approve)"
  until_count checks_red 1 30 || bad "no red: $(events)"
  assert_eq "$(view_bead .failures)" 1 "the first red charged"
  until_count rebutted 1 60 || bad "no rebuttal: $(events)"
  until_count approved 2 30 || bad "not re-approved: $(events)"
  : >"$E2E_CTRL/gh/calls"
  until_count checks_red 2 30 || bad "no second look at the same red: $(events)"
  tick 1
  assert_eq "$(view_bead .failures)" 1 "the same red is not charged twice"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "remove-label" "no label to take off under auto"
  assert_match "$(view_bead .why)" "already charged" "held, saying why"
}

# Under pipeline the loop labels the PR it opens, CI's own merge step merges it, and a
# green PR waiting on that is not an event a tick logs.
case_merge_pipeline() {
  MERGE=pipeline setup 'test -e work.txt'
  land_pr
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr edit bead/$BEAD --add-label automerge" "labelled as soon as the PR opens"
  assert_eq "$(jq -r '[.[0].labels[].name] | join(",")' "$E2E_CTRL/gh/prs.json")" automerge "the PR's labels"
  set_checks '[{"context":"ci","state":"SUCCESS"}]'
  tick 3
  assert_eq "$(bd_field status)" in_progress "green: the tick does not merge, the pipeline does"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pr merge" "no merge call from the loop"
  jq '.[0].state = "MERGED"' "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"
  until_event pr_merged 30 || bad "the merge was not seen: $(events)"
  assert_eq "$(bd_field status)" closed "the next tick sees MERGED and closes the bead"
}

# A PR behind the base is updated, not merged; CI reruns on the update. Closed instead of
# merged parks the bead, out of the merge queue.
case_behind_then_closed_unmerged() {
  setup 'test -e work.txt'
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  land_pr
  set_pr '.[0].mergeStateStatus = "BEHIND"'
  set_checks '[{"context":"ci","state":"SUCCESS"}]'
  until_event behind 30 || bad "not seen as behind: $(events)"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr update-branch bead/$BEAD" "behind: branch updated, not merged"
  assert_eq "$(view_bead .place)" merge "behind: waits for CI to rerun"
  set_pr '.[0].state = "CLOSED"'
  until_place parked 30 || bad "not parked: $(events)"
  assert_eq "$(bd_field status)" blocked "closed unmerged: parked"
  assert_match "$(view_bead .parked.question)" "closed unmerged" "the question names it"
}

# GitHub says our PR conflicts with the base: no failure, back to the dev queue on its
# branch, and that round's worker is the last stage's, told to rebase. The push updates
# the same PR and the merge queue has it again.
case_conflicting_pr_rebased_by_the_last_stage() {
  STAGES=$(stage local fake/coder fake/reviewer 2)$'\n'"$(stage frontier claude/sonnet claude/sonnet 1)" setup 'test -e work.txt'
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  land_pr
  set_pr '.[0].mergeable = "CONFLICTING"'
  # The rebase order picks the last stage's worker (worker_of), but the reviewer is
  # still the stage its failures are at (reviewer_of only overrides for a rebuttal): the
  # local fake/reviewer, not claude.
  claude_reply 001 --arg b "$BEAD" '{sh:("git fetch >/dev/null 2>&1; echo rebased >> work.txt && git add -A && git commit -qm \""+$b+": rebase\""), result:"{\"outcome\":\"done\",\"summary\":\"rebased\"}"}'
  reply reviewer "$(approve)"
  until_event conflicting 30 || bad "not seen as conflicting: $(events)"
  assert_eq "$(view_bead .failures)" 0 "no failure charged"
  assert_eq "$(view_bead .place)" dev "back in the dev queue"
  assert_match "$(bd_field notes)" "conflicts with the base" "noted"
  set_pr '.[0].mergeable = "MERGEABLE"'
  until_place merge 60 || bad "never repushed: $(events)"
  local worker
  worker=$(cat "$E2E_CTRL/claude/argv-001" 2>/dev/null)
  assert_match "$worker" "sonnet" "the rebase round runs on the last stage's worker"
  assert_match "$(cat "$E2E_CTRL/claude/prompt-001")" "Rebase this branch onto the base" "with the rebase order"
  assert_eq "$(view_bead .place)" merge "back in the merge queue"
  assert_eq "$(grep -c '^pr create' "$E2E_CTRL/gh/calls")" 1 "the same PR, updated"
}

# A conflict's rebase round is approved after the PR it is for has been closed: the push
# checks that PR first, finds it closed, and parks instead of opening a second one.
case_conflict_pr_closed_parks() {
  setup 'test -e work.txt'
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  land_pr
  set_pr '.[0].mergeable = "CONFLICTING"'
  reply coder '{"tool":"run","args":{"command":"echo rebased >> work.txt && git add -A && git commit -qm rebase"}}' "$(done_report)"
  reply reviewer "$(approve)"
  until_event conflicting 30 || bad "not seen as conflicting: $(events)"
  local url
  url=$(jq -r '.[0].url' "$E2E_CTRL/gh/prs.json")
  set_pr '.[0].state = "CLOSED"'
  until_place parked 60 || bad "never parked: $(events)"
  assert_eq "$(grep -c '^pr create' "$E2E_CTRL/gh/calls")" 1 "no second PR for the closed one"
  assert_eq "$(bd_field status)" blocked "bd says blocked"
  assert_match "$(bd_field notes)" "$url" "the closed PR's url is named"
}
