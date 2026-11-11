# shellcheck shell=bash
# merge = "external", and the PRs this loop did not open itself: a `bead/ID` branch
# anyone pushes joins the merge queue (adopt, docs/config.md), green or not its own.
# Ported from the Rust suite (`git show 8907dfa:test/run.sh`).
#
# Also: a foreign PR's branch is always exactly `bead/ID` here (ns_world/live.baml's
# `branch`); the Rust suite's `bead/t-9-some-slug` case of a slug suffix has nothing to
# port, since this loop never looks for one (adoptable_of slices off `bead/` and takes
# the rest as the id, whole).

# merge = "external": someone else merges. Green sits in the queue, polled, never held
# and never merged by the loop — the maintainer's call, on their own time.
case_external_green() {
  MERGE=external setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "no PR: $(events)"
  # checks_green itself is never logged under external (idle_green, supervisor.baml):
  # a look that changes nothing is not an event a tick. The outcomes it would have had
  # are what this checks instead.
  tick 3
  assert_eq "$(jq -r '.[0].state' "$E2E_CTRL/gh/prs.json")" OPEN "green: not merged"
  assert_eq "$(bd_field status)" in_progress "green: bead waits, not closed"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pr merge " "no merge call"
  tick 2
  assert_eq "$(jq -r '.[0].state' "$E2E_CTRL/gh/prs.json")" OPEN "still open after a second poll"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pr merge " "still no merge call"
  assert_eq "$(view_bead .place)" merge "stays in the merge queue"
  assert_eq "$(view_bead .merge_mode)" external "merge_mode carried too"
  local awaiting
  awaiting=$(view_bead .awaiting_since)
  [ "${awaiting:-0}" -gt 0 ] 2>/dev/null && ok || bad "awaiting_since: expected a positive epoch, got [$awaiting]"
}

# Contrast with a red check that is required: external never holds on no checks at
# all either, their CI is their business.
case_external_nocheck() {
  MERGE=external setup 'test -e work.txt'
  echo '[]' >"$E2E_CTRL/gh/checks.json"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "no PR: $(events)"
  tick 3
  assert_eq "$(jq -r '.[0].state' "$E2E_CTRL/gh/prs.json")" OPEN "no checks: not merged"
  assert_eq "$(bd_field status)" in_progress "not held"
  assert_eq "$(view_bead .place)" merge "stays in the merge queue"
}

case_external_merged() {
  MERGE=external setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "no PR: $(events)"
  jq '.[0].state = "MERGED"' "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"
  until_event pr_merged 30 || bad "the merge was not seen: $(events)"
  assert_eq "$(bd_field status)" closed "MERGED closes the bead, same as any other merge mode"
  assert_nomatch "$(bd_field labels)" "loop:" "no loop label left on a closed bead"
}

case_external_red() {
  # Two attempts: a red charge sends it back to the dev queue, not to the stages'
  # last chance (case_parked_bead_whose_pr_merged below is that one, on the default
  # single attempt).
  MERGE=external STAGES=$(stage local fake/coder fake/reviewer 2) setup 'test -e work.txt'
  # A check the base requires, and the PR already red when it opens: without the
  # first, `pr checks --required` prints [] (the stub's default, nothing required),
  # which the loop reads as a red nobody asked for; without the second, a window
  # between the PR opening green and this setting it red lets auto merge it first.
  echo '[{"name":"ci","state":"FAILURE"}]' >"$E2E_CTRL/gh/required.json"
  echo '[{"context":"ci","state":"FAILURE"}]' >"$E2E_CTRL/gh/checks.json"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event checks_red 60 || bad "no red seen: $(events)"
  assert_eq "$(bd_field status)" in_progress "red: back in the dev queue, same as any other merge mode"
  assert_match "$(bd_field notes)" "CI red: ci" "the failing check named"
  assert_eq "$(view_bead .failures)" 1 "one failure, +1 as today"
  assert_eq "$(view_bead .place)" dev "out of the merge queue"
}

# Under pipeline, an adopted PR gets the configured merge_label too (not just its own
# PRs'), and is left for the pipeline's own merge step either way (#242's lesson again).
case_merge_pipeline_label_and_adoption() {
  MERGE=pipeline setup 'test -e work.txt'
  printf 'merge_label = "ship-it"\n' >>"$REPO/.bead-loop.toml"
  local other
  other=$(cd "$REPO" && bd create "Theirs" -d "z" --acceptance "true" --json | jq -r .id)
  jq -n --arg h "bead/$other" '[{number:41, url:"https://github.com/owner/repo/pull/41", headRefName:$h, state:"OPEN", mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", headRefOid:"deadbeef", statusCheckRollup:[{"context":"ci","state":"SUCCESS"}], author:{login:"someone-else"}, labels:[]}]' \
    >"$E2E_CTRL/gh/prs.json"
  tick 2
  assert_eq "$(jq -r --arg h "bead/$other" '[.[] | select(.headRefName==$h)][0].labels | map(.name) | join(",")' "$E2E_CTRL/gh/prs.json")" ship-it \
    "an adopted PR gets the configured label too"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pr merge " "and is left to the pipeline"
}

# An open bead/ID PR from anyone joins the merge queue; a branch that is not one is left
# alone; green under auto merges and closes its bead same as any PR the loop opened.
case_adopts_foreign_bead_prs() {
  setup 'test -e work.txt'
  local other
  other=$(cd "$REPO" && bd create "Theirs" -d "z" --acceptance "true" --json | jq -r .id)
  jq -n --arg h "bead/$other" '[
      {number:41, url:"https://github.com/owner/repo/pull/41", headRefName:$h, state:"OPEN", mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", headRefOid:"deadbeef", statusCheckRollup:[{"context":"ci","state":"SUCCESS"}], author:{login:"someone-else"}, labels:[]},
      {number:42, url:"https://github.com/owner/repo/pull/42", headRefName:"feature/not-a-bead", state:"OPEN", author:{login:"someone-else"}, labels:[]}
    ]' >"$E2E_CTRL/gh/prs.json"
  tick 3
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr merge bead/$other --squash" "green foreign bead PR merged"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pull/42" "non-bead branch left alone"
  assert_eq "$(cd "$REPO" && bd show "$other" --json | jq -r '.[0].status')" closed "its bead closed"
}

# An adopted PR waiting on CI does not count toward max_inflight: the dev lane still
# opens and lands its own bead with the cap at 1 and nothing of its own open yet.
case_adopted_prs_do_not_block_new_work() {
  setup 'test -e work.txt'
  printf 'max_inflight = 1\n' >>"$REPO/.bead-loop.toml"
  local other
  other=$(cd "$REPO" && bd create "Theirs" -d "z" --acceptance "true" --json | jq -r .id)
  jq -n --arg h "bead/$other" '[{number:41, url:"https://github.com/owner/repo/pull/41", headRefName:$h, state:"OPEN", mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", headRefOid:"deadbeef", statusCheckRollup:[{"context":"ci","state":"PENDING"}], author:{login:"someone-else"}, labels:[]}]' \
    >"$E2E_CTRL/gh/prs.json"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "max_inflight=1 with only an adopted PR open still blocked new work: $(events)"
  assert_eq "$(bd_field status)" closed "bd status"
  assert_eq "$(jq -r --arg id "$other" '.beads[] | select(.id==$id) | .adopted' "$(STATE)/view.json")" true \
    "the foreign PR tracked as adopted, apart from max_inflight"
}

case_adopt_off() {
  setup 'test -e work.txt'
  printf 'adopt = false\n' >>"$REPO/.bead-loop.toml"
  local other
  other=$(cd "$REPO" && bd create "Theirs" -d "z" --acceptance "true" --json | jq -r .id)
  jq -n --arg h "bead/$other" '[{number:41, url:"https://github.com/owner/repo/pull/41", headRefName:$h, state:"OPEN", mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", headRefOid:"deadbeef", statusCheckRollup:[{"context":"ci","state":"SUCCESS"}], author:{login:"someone-else"}, labels:[]}]' \
    >"$E2E_CTRL/gh/prs.json"
  tick 2
  assert_eq "$(jq -r --arg id "$other" '.beads[] | select(.id==$id) | .place' "$(STATE)/view.json")" "" "adopt = false: ignored"
  assert_eq "$(cd "$REPO" && bd show "$other" --json | jq -r '.[0].status')" open "adopt = false: the foreign bead untouched"
}

# A bead worked by hand or by a subagent, its PR merged before the loop ever ticked on
# it: still open in bd and `bd ready` lists it, so it is closed, not picked (tick's
# admit_tickets runs before adopt_prs, so the merged PRs are read against this tick's
# `ready` list). Ported from the Rust suite's case_closes_bead_merged_outside_the_loop.
case_closes_bead_merged_outside_the_loop() {
  setup 'test -e work.txt'
  local other
  other=$(cd "$REPO" && bd create "Theirs" -d "z" --acceptance "true" -l delegate:local --json | jq -r .id)
  jq -n --arg h1 "bead/$BEAD" --arg h2 "bead/$other" '[
      {number:50, url:"https://github.com/owner/repo/pull/50", headRefName:$h1, state:"MERGED", author:{login:"someone-else"}, labels:[]},
      {number:51, url:"https://github.com/owner/repo/pull/51", headRefName:$h2, state:"OPEN", mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", headRefOid:"deadbeef", statusCheckRollup:[{"context":"ci","state":"PENDING"}], author:{login:"someone-else"}, labels:[]}
    ]' >"$E2E_CTRL/gh/prs.json"
  tick 1
  assert_eq "$(bd_field status)" closed "merged outside the loop: closed"
  assert_match "$(bd_field close_reason)" "https://github.com/owner/repo/pull/50" "the url in the reason"
  assert_eq "$(events)" merged_outside "closed before any pick"
  assert_eq "$(find "$E2E_CTRL/requests" -name '*.json' 2>/dev/null | wc -l)" 0 "no model request made"
  assert_eq "$(cd "$REPO" && bd show "$other" --json | jq -r '.[0].status')" in_progress "the second bead adopted into the merge queue, not closed"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pr merge " "no merge call"
}

# bl-tka.2, bl-tka.6, bl-3x2.3, bl-iej.2.3's lesson, carried over: a red charge on the
# last stage parks the bead with its PR still open; watch_prs stops polling a parked
# place, and adopt_prs skips it too (its own pr is still set) — only a merge closes it.
case_parked_bead_whose_pr_merged() {
  # The default single attempt: a red charge has no other stage to go to, so it parks
  # with the branch (and the open PR) kept, on the spot. The PR is already red when it
  # opens, so there is no window for auto to merge a green look of it first.
  setup 'test -e work.txt'
  echo '[{"name":"ci","state":"FAILURE"}]' >"$E2E_CTRL/gh/required.json"
  echo '[{"context":"ci","state":"FAILURE"}]' >"$E2E_CTRL/gh/checks.json"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_place parked 60 || bad "not parked: $(events)"
  assert_eq "$(bd_field status)" blocked "red on the only stage: parked"
  local url
  url=$(jq -r '.[0].url' "$E2E_CTRL/gh/prs.json")
  tick 2
  assert_eq "$(bd_field status)" blocked "its PR only open: still parked"
  assert_eq "$(view_bead .place)" parked "and not adopted"
  jq '.[0].state = "MERGED"' "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"  # you merged it
  until_event merged_outside 30 || bad "the merge was not seen: $(events)"
  assert_eq "$(bd_field status)" closed "its PR merged: closed"
  assert_match "$(bd_field close_reason)" "$url" "the url in the reason"
  [ -e "$(STATE)/wt/$BEAD" ] && bad "the worktree is still there" || ok
  git -C "$REPO" show-ref -q "refs/heads/bead/$BEAD" && bad "the local branch is still there" || ok
}
