# shellcheck shell=bash
# Lanes and the merge queue's cap. Ported from the Rust suite's cases of the same name
# (git show 8907dfa:test/run.sh): there, a lane was a named thing in its own
# `[[lanes]]` table, with a marker file, a `sup status` row and `sup pause`/`sup resume`
# of its own. The BAML loop has none of that: `config.baml`'s `capacity_of` reads only
# `[providers.NAME] parallel` (docs/config.md: "a provider is a model server, and a
# lane"), and `tell` knows five words (queue.sh), none of them pause or resume. So each
# case below is the behaviour the Rust one proved, read off the provider's own table and
# the page's view instead of a lane's marker or `sup status`:
#
#   case_lane_with_two_slots: its "pause stub" half is not ported (no lane to pause); the
#   rest — two slots from one provider's `parallel = 2`, one bead each, at once — is.

# bd_field_of ID FIELD, events_of ID, view_of ID FILTER: lib.sh's bd_field/events/view_bead,
# parametrised, for a second bead this file's cases need alongside $BEAD.
bd_field_of() { (cd "$REPO" && bd show "$1" --json | jq -r ".[0].$2"); }
events_of() { jq -r .kind "$(STATE)/beads/$1/events.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
view_of() { jq -r --arg id "$1" ".beads[] | select(.id==\$id) | $2" "$(STATE)/view.json"; }
# until_event_of ID KIND [SECONDS]: until_event, for a second bead.
until_event_of() {
  local id=$1 want=$2 limit=${3:-60} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    tick 1
    events_of "$id" | grep -qw -- "$want" && return 0
  done
  return 1
}
# commit_for ID: commit(), for a round on a bead other than $BEAD.
commit_for() { printf '{"tool":"run","args":{"command":"git add -A && git commit -q -m \\"%s: work\\""}}' "$1"; }
# set_parallel PROVIDER N: rewrites that provider's `parallel` in the global config lib.sh
# already wrote, once its url (and so its table) exists.
set_parallel() {
  sed -i '/^\[providers\.'"$1"'\]/,/^$/ s/^parallel = .*/parallel = '"$2"'/' "$HOME/.config/bead-loop/config.toml"
}
# set_checks_all JSON: every open PR's statusCheckRollup, not just the first's (merge.sh's
# set_checks, for the two this file opens at once).
set_checks_all() {
  jq --argjson c "$1" '[.[] | .statusCheckRollup = $c]' "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" \
    && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"
}
# a_second_bead: t's own bead, ready beside $BEAD, same acceptance, same label.
a_second_bead() {
  (cd "$REPO" && bd create "Second" -d "Write work.txt" --acceptance "test -e work.txt" -l delegate:local --json | jq -r .id)
}

# max_inflight pauses new work while a PR of this bead's own is already in the queue
# (supervisor.baml's dev_paused): a second ready bead sits untouched, no round started.
case_inflight_limits_tick() {
  setup 'test -e work.txt'
  printf 'max_inflight = 1\n' >>"$REPO/.bead-loop.toml"
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "never opened: $(events)"
  assert_eq "$(view_bead .place)" merge "the first bead's own PR fills the queue"
  local bead2
  bead2=$(a_second_bead)
  tick 1
  assert_eq "$(events_of "$bead2")" "" "max_inflight = 1: no round while that PR is open"
  assert_eq "$(bd_field_of "$bead2" status)" open "t-2 untouched"
}

# The review queue and the dev queue share one provider's capacity (parallel = 2, lib.sh's
# default setup), so neither waits for the other to drain: both beads reach the merge queue
# together, and both land.
case_lanes_run_side_by_side() {
  setup 'test -e work.txt'
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  local bead2
  bead2=$(a_second_bead)
  reply coder "$(write_work)" "$(commit)" "$(done_report)" "$(write_work)" "$(commit_for "$bead2")" "$(done_report)"
  reply reviewer "$(approve)" "$(approve)"
  until_event pr_opened 90 || bad "the first bead's PR never opened: $(events)"
  until_event_of "$bead2" pr_opened 90 || bad "the second bead's PR never opened: $(events_of "$bead2")"
  assert_eq "$(view_bead .place)" merge "the first bead waits in the merge queue"
  assert_eq "$(view_of "$bead2" .place)" merge "the second bead too, at the same time"
  set_checks_all '[{"context":"ci","state":"SUCCESS"}]'
  until_event pr_merged 30 || bad "the first bead never merged: $(events)"
  until_event_of "$bead2" pr_merged 30 || bad "the second bead never merged: $(events_of "$bead2")"
}

# parallel = 2 is two slots on the one provider: a bead each, at once, each in its own
# worktree and on its own branch, and both run through to their own PRs.
case_lane_with_two_slots() {
  setup 'test -e work.txt'
  local bead2
  bead2=$(a_second_bead)
  reply coder "$(write_work)" "$(commit)" "$(done_report)" "$(write_work)" "$(commit_for "$bead2")" "$(done_report)"
  reply reviewer "$(approve)" "$(approve)"
  tick 1
  assert_match "$(events)" "picked" "the first slot took $BEAD"
  assert_match "$(events_of "$bead2")" "picked" "the second slot took $bead2, the same tick"
  until_event pr_merged 90 || bad "the first bead never merged: $(events)"
  local calls
  calls=$(cat "$E2E_CTRL/gh/calls")
  assert_match "$calls" "pr create --head bead/$BEAD --base main" "the first bead's own branch"
  assert_match "$calls" "pr create --head bead/$bead2 --base main" "the second's own branch, its own worktree"
  until_event_of "$bead2" pr_merged 90 || bad "the second bead never merged: $(events_of "$bead2")"
}

# No `[[lanes]]` table to set: a provider's `parallel` alone is its lane's capacity.
# Turned down to one, the provider (worker and reviewer both) serializes every round
# on it rather than running two at once.
case_lanes_derive_from_providers() {
  setup 'test -e work.txt'
  set_parallel fake 1
  local bead2
  bead2=$(a_second_bead)
  reply coder "$(write_work)" "$(commit)" "$(done_report)" "$(write_work)" "$(commit_for "$bead2")" "$(done_report)"
  reply reviewer "$(approve)" "$(approve)"
  tick 1
  local picked
  picked=$( (events_of "$BEAD"; events_of "$bead2") | tr ' ' '\n' | grep -cx picked)
  assert_eq "$picked" 1 "parallel = 1: one round at a time, with no separate lane config"
  until_event pr_merged 90 || bad "the first bead never merged: $(events)"
  until_event_of "$bead2" pr_merged 90 || bad "the second bead never merged, just serialized: $(events_of "$bead2")"
}
