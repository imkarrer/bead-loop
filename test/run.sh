#!/usr/bin/env bash
# bead-loop integration tests: the supervisor's state machine against stub
# bd/opencode/gh (test/bin) and a real git origin. Every row of the README's
# outcome table is a case here. Run: test/run.sh [case-name...]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUP=$HERE/../bin/bead-supervisor
export PATH=$HERE/bin:$PATH
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com
PASS=0 FAIL=0

# ---- fixture -----------------------------------------------------------------
setup() {  # setup [GATE] [MERGE] [REVIEW_MODEL]
  T=$(mktemp -d); export T
  export BEAD_LOOP_CONFIG=$T/config BEAD_LOOP_STATE=$T/state TEST_CTRL=$T/ctrl BD_STATE=$T/bd
  mkdir -p "$BEAD_LOOP_CONFIG" "$TEST_CTRL" "$BD_STATE"
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  REPO=$T/repo
  mkdir -p "$REPO/.beads"; echo base >"$REPO/README"; touch "$REPO/.beads/issues.jsonl"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm base && git -C "$REPO" branch -qM main && git -C "$REPO" push -q -u origin main
  printf 'LABEL=delegate:local\nBASE=main\nGATE=%s\nMERGE=%s\nREVIEW_MODEL=%s\n' "${1:-true}" "${2:-auto}" "${3-stub/reviewer}" >"$REPO/.bead-loop"
  printf 'MODEL=stub/worker\nREPOS=%s\nWORKER_TIMEOUT=60\n' "$REPO" >"$BEAD_LOOP_CONFIG/config"
  jq -n '[{id:"t-1", title:"Do the thing", description:"Edit work.txt", acceptance_criteria:"work.txt exists", status:"open", priority:2, issue_type:"task", labels:["delegate:local"]}]' >"$BD_STATE/issues.json"
  echo "done" >"$TEST_CTRL/worker"; echo approve >"$TEST_CTRL/review"; : >"$TEST_CTRL/calls"
}
sup() { "$SUP" "$@" 2>>"$T/sup.log"; }
bead() { jq -r ".[] | select(.id==\"t-1\") | $1" "$BD_STATE/issues.json"; }
set_checks() {  # set_checks '[{"context":"ci","state":"SUCCESS"}]'
  jq --argjson c "$1" '.statusCheckRollup=$c' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"
}

# ---- assertions ----------------------------------------------------------------
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s: %s\n' "$CASE" "$1"; }
assert_eq() { [ "$1" = "$2" ] && ok || bad "$3: expected [$2] got [$1]"; }
assert_match() { printf '%s' "$1" | grep -q -- "$2" && ok || bad "$3: [$1] lacks [$2]"; }
assert_file() { [ -e "$1" ] && ok || bad "$2: missing $1"; }
assert_nofile() { [ ! -e "$1" ] && ok || bad "$2: unexpected $1"; }
assert_branch() { git -C "$T/origin.git" show-ref -q "refs/heads/$1" && ok || bad "$2: origin has no branch $1"; }
assert_nobranch() { git -C "$T/origin.git" show-ref -q "refs/heads/$1" && bad "$2: origin has branch $1" || ok; }
calls() { cut -d' ' -f1 "$TEST_CTRL/calls" | tr '\n' ' ' | sed 's/ $//'; }

# ---- cases -------------------------------------------------------------------------
case_dry_run() {
  setup; out=$(sup --dry-run work "$REPO")
  assert_match "$out" "Do the thing" "prompt printed"
  assert_eq "$(bead .status)" open "bead untouched"
  assert_eq "$(calls)" "" "no model called"
}
case_done_to_pr() {
  setup; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-reviewer" "worker then reviewer"
  assert_match "$(sed -n 1p "$TEST_CTRL/calls")" " stub/worker " "worker model from global config"
  assert_match "$(sed -n 2p "$TEST_CTRL/calls")" " stub/reviewer " "reviewer model from .bead-loop"
  assert_match "$(cat "$TEST_CTRL/prompt.1")" "ACCEPTANCE CRITERIA" "bead rendered into the prompt"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "<diff>" "reviewer sees the diff"
  assert_branch bead/t-1 "branch pushed"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "inflight recorded"
  assert_eq "$(bead .status)" in_progress "bead parked in_progress until merge"
  assert_match "$(bead '.comments[0]')" "pull/7" "PR url on the bead"
  assert_nofile "$BEAD_LOOP_STATE/repo/wt/t-1" "worktree removed after push"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr create --base main --head bead/t-1" "PR against base"
  ! grep -q -- '--auto' "$TEST_CTRL/gh.log" && ok || bad "never asks GitHub to auto-merge"
}
case_blocked() {
  setup; echo blocked >"$TEST_CTRL/worker"; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker" "stops after the worker"
  assert_eq "$(bead .status)" in_progress "parked"
  assert_match "$(bead .notes)" "BLOCKED: lib/x.ts:3" "worker's line in the note"
  assert_nobranch bead/t-1 "nothing pushed"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "no PR"
}
case_no_commit() {
  setup; echo nocommit >"$TEST_CTRL/worker"; sup work "$REPO"
  assert_match "$(bead .notes)" "no commit" "noted"
  assert_nobranch bead/t-1 "nothing pushed"
}
case_uncommitted_is_settled() {
  setup; echo uncommitted >"$TEST_CTRL/worker"; sup work "$REPO"
  assert_branch bead/t-1 "supervisor committed the leftovers and pushed"
  assert_match "$(git -C "$T/origin.git" log -1 --format=%s bead/t-1)" "t-1: Do the thing" "commit named after the bead"
}
case_gate_fails_twice() {
  setup 'false'; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-worker" "one revision round, no review"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "<gate-output>" "gate output fed back"
  assert_match "$(bead .notes)" "gate failed twice: false" "noted"
  assert_nobranch bead/t-1 "nothing pushed"
}
case_gate_fixed_on_revision() {
  setup '[ -e "$TEST_CTRL/gateok" ] || { touch "$TEST_CTRL/gateok"; false; }'; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-worker bead-reviewer" "gate revision, then review"
  assert_branch bead/t-1 "pushed once the gate passes"
  assert_eq "$(git -C "$T/origin.git" rev-list --count main..bead/t-1)" 2 "the fix is a second commit"
}
case_reject_then_approve() {
  setup; printf 'reject\napprove\n' >"$TEST_CTRL/review"; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-reviewer bead-worker bead-reviewer" "one revision round"
  assert_match "$(cat "$TEST_CTRL/prompt.3")" "REJECT: work.txt:1" "rejection fed back verbatim"
  assert_branch bead/t-1 "pushed after approval"
  assert_eq "$(git -C "$T/origin.git" rev-list --count main..bead/t-1)" 2 "both rounds' commits on the branch"
}
case_reject_twice() {
  setup; printf 'reject\nreject\n' >"$TEST_CTRL/review"; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-reviewer bead-worker bead-reviewer" "no third round"
  assert_match "$(bead .notes)" "review rejected twice" "noted"
  assert_nobranch bead/t-1 "nothing pushed"
}
case_no_reviewer() {
  setup true auto ''; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker" "no review round without REVIEW_MODEL"
  assert_branch bead/t-1 "pushed"
}
case_ci_pending_then_green() {
  setup; sup work "$REPO"
  set_checks '[{"context":"ci","state":"PENDING"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "pending: not merged"
  assert_eq "$(bead .status)" in_progress "pending: bead waits"
  set_checks '[{"context":"ci","state":"SUCCESS"},{"__typename":"CheckRun","conclusion":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" MERGED "green: merged"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr merge 7 --squash --delete-branch" "squash, branch deleted"
  assert_eq "$(bead .status)" closed "green: bead closed"
  assert_match "$(bead .close_reason)" "ci=SUCCESS" "close reason quotes the checks"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "inflight cleared"
}
case_ci_red() {
  setup; sup work "$REPO"
  set_checks '[{"context":"ci","state":"FAILURE"}]'; sup reconcile "$REPO"; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "red: not merged"
  assert_eq "$(bead .status)" in_progress "red: parked"
  assert_eq "$(bead .notes | grep -c 'CI red')" 1 "noted once across ticks"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "still tracked, may go green on rerun"
}
case_ci_mixed_is_not_green() {
  setup; sup work "$REPO"
  set_checks '[{"context":"a","state":"SUCCESS"},{"context":"b","state":"PENDING"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "one pending check holds the merge"
}
case_ci_none_reported() {
  setup; sup work "$REPO"; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "no checks: not merged"
  assert_match "$(bead .notes)" "no CI checks" "noted"
}
case_merge_manual() {
  setup true manual; sup work "$REPO"
  set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "manual: green stays open"
  assert_eq "$(bead .status)" in_progress "manual: bead waits for you"
}
case_behind_updates_branch() {
  setup; sup work "$REPO"
  jq '.mergeStateStatus="BEHIND"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"
  set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr update-branch 7" "behind: branch updated, not merged"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "behind: waits for CI to rerun"
}
case_pr_closed_unmerged() {
  setup; sup work "$REPO"
  jq '.state="CLOSED"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"; sup reconcile "$REPO"
  assert_match "$(bead .notes)" "closed without merging" "noted"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "untracked"
}
case_inflight_limits_tick() {
  setup; sup work "$REPO"
  jq '. + [{id:"t-2", title:"Next", description:"x", status:"open", priority:2, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  : >"$TEST_CTRL/calls"; sup tick
  assert_eq "$(calls)" "" "MAX_INFLIGHT=1: no new bead while a PR is open"
  assert_eq "$(jq -r '.[]|select(.id=="t-2")|.status' "$BD_STATE/issues.json")" open "t-2 untouched"
}
case_nothing_ready() {
  setup; jq '.[0].labels=[]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup tick; assert_eq "$(calls)" "" "label filter respected"
}
case_lock_skips() {
  setup; mkdir -p "$BEAD_LOOP_STATE"
  ( exec 9>"$BEAD_LOOP_STATE/lock"; flock 9; sleep 3 ) &
  sleep 0.5; rc=0; sup tick || rc=$?
  assert_eq "$rc" 0 "held lock is a clean skip"
  assert_eq "$(calls)" "" "nothing ran"
  wait
}
case_config_comments() {
  setup 'true   # trailing comment'; sup work "$REPO"
  assert_branch bead/t-1 "GATE with a trailing comment still runs as `true`"
}

# ---- main ----------------------------------------------------------------------------
cases=$(declare -F | awk '{print $3}' | grep '^case_')
[ $# -gt 0 ] && cases=$(printf 'case_%s\n' "$@")
for CASE in $cases; do
  printf '%s\n' "$CASE"; "$CASE"
  rm -rf "$T"
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
