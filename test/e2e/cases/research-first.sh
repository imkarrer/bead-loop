# shellcheck shell=bash
# The research round: a brief before the worker's first turn, and what a BLOCKED does.
# Ported from the Rust suite's cases of the same name (git show 8907dfa:test/run.sh), to
# what the BAML loop actually does with each (baml_src/ns_agents/research.baml,
# ns_rounds/round.baml's research_round, ns_machine/step.baml's on_researching).
#
# Two things the Rust cases checked have no BAML counterpart, so neither is asserted here:
# - The second opinion's prompt carries no `<first-research>` tag: round.baml's Research
#   function takes only the bead's own text, never the first reply, so the second round
#   is a second independent read, not an argument against the first (already how core.sh's
#   case_read_research_block_stands works).
# - `brief_model = "none"` does not turn the second opinion off: config.baml's
#   `policy.second_opinion` is `research_model(global).length() > 0` alone; there is no key
#   that keeps research on but drops the second opinion.
#
# Other Rust research cases (case_researched_bead_runs_under_aider, case_research_every_
# refreshes, case_research_skips_an_aider_bead, case_research_lane_feeds_the_worker_lane,
# the two rejoin cases) are not in this bead's scope and are left for another one.

# assert_nofile PATH REASON: lib.sh has no file-absence check; this is the one case file
# that needs it.
assert_nofile() { [ -e "$1" ] && bad "$2" || ok; }

# research_model set: a ready bead with no brief is a research round first. The brief
# goes to beads/ID/brief, the bead back to the queue, and the worker's prompt carries it.
case_research_round_before_the_worker() {
  GLOBAL_EXTRA=$'research = "first"\nresearch_model = "fake/researcher"' setup 'test -e work.txt'
  reply researcher '{"content":"{\"outcome\":\"brief\",\"files\":\"work.txt: append one line\",\"shape\":\"append a line to work.txt\",\"check\":\"test -e work.txt\",\"pitfalls\":\"none - trivial change\"}"}'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_eq "$(events)" "research_picked brief_written picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" "events"
  assert_match "$(cat "$(STATE)/beads/$BEAD/brief")" "^Files:" "the brief on disk"
  assert_match "$(cat "$(STATE)/beads/$BEAD/brief")" "work.txt: append one line" "the researcher's words"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "<research>" "the worker's prompt carries the brief"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "work.txt: append one line" "verbatim"
  assert_match "$(bd_field notes)" "brief written" "noted on the bead"
}

# The researcher's BLOCKED:, upheld by the second opinion (the same model reading the bead
# again, since brief_model is unset), parks the bead before a single edit.
case_research_blocked_parks() {
  GLOBAL_EXTRA=$'research = "first"\nresearch_model = "fake/researcher"' setup 'test -e work.txt'
  local blocked='{"content":"{\"outcome\":\"blocked\",\"files\":\"\",\"shape\":\"\",\"check\":\"\",\"pitfalls\":\"\",\"line\":\"BLOCKED: work.txt is not the file the bead means\"}"}'
  reply researcher '{"tool":"read_file","args":{"path":"README"}}' "$blocked" \
    '{"tool":"read_file","args":{"path":"README"}}' "$blocked"
  until_place parked 90 || bad "not parked: $(events)"
  assert_eq "$(events)" "research_picked research_blocked research_picked research_blocked" "the researcher, then the second opinion; no worker round"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_match "$(bd_field labels)" "loop:parked" "bd label"
  assert_match "$(bd_field notes)" "BLOCKED: work.txt is not the file the bead means" "the researcher's line on the bead"
  assert_match "$(bd_field notes)" "parked: BLOCKED:" "and the park itself"
  assert_nofile "$(STATE)/beads/$BEAD/brief" "no brief kept"
  assert_nofile "$(STATE)/wt/$BEAD" "the worktree gone"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && bad "a branch pushed" || ok
}

# A researcher's BLOCK the second opinion does not share: its brief goes to the worker,
# nothing is parked.
case_research_second_opinion_overrules_a_block() {
  GLOBAL_EXTRA=$'research = "first"\nresearch_model = "fake/researcher"' setup 'test -e work.txt'
  reply researcher '{"tool":"read_file","args":{"path":"README"}}' \
    '{"content":"{\"outcome\":\"blocked\",\"files\":\"\",\"shape\":\"\",\"check\":\"\",\"pitfalls\":\"\",\"line\":\"BLOCKED: work.txt is not the file the bead means\"}"}' \
    '{"content":"{\"outcome\":\"brief\",\"files\":\"work.txt: append one line\",\"shape\":\"append a line to work.txt\",\"check\":\"test -e work.txt\",\"pitfalls\":\"none\"}"}'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_eq "$(events)" "research_picked research_blocked research_picked brief_written picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" "blocked, overruled, then the worker"
  assert_match "$(cat "$(STATE)/beads/$BEAD/brief")" "^Files:" "its brief on disk"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "work.txt: append one line" "the worker carries it"
  assert_match "$(bd_field notes)" "BLOCKED: work.txt is not the file the bead means" "the block noted"
  assert_match "$(bd_field notes)" "brief written: the second opinion overruled the block" "and why the bead went on"
  assert_nofile "$(STATE)/beads/$BEAD/park.md" "not parked"
}

# The worker's lane never waits on the researcher's: with the research provider's lane
# always busy (parallel = 0), nothing is ever researched to take, and the worker goes
# without a brief rather than wait.
case_research_worker_does_not_wait() {
  GLOBAL_EXTRA=$'research = "first"\nresearch_model = "other/researcher"\n\n[providers.other]\nparallel = 0' setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" "worked and reviewed, no research round"
  assert_nofile "$(STATE)/beads/$BEAD/brief" "no brief ever written"
}
