#!/usr/bin/env bash
# bead-loop integration tests: the supervisor's state machine against stub
# bd/opencode/gh (test/bin) and a real git origin. Every row of the README's
# outcome table is a case here. Run: test/run.sh [case-name...]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUP=$HERE/../bin/bead-supervisor
# The stubs in test/bin shadow curl; the UI case talks to a real server with the real one.
REAL_CURL=$(command -v curl || true)
export PATH=$HERE/bin:$PATH
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com
PASS=0 FAIL=0

# ---- fixture -----------------------------------------------------------------
# stages 'worker[:reviewer[:attempts[:timeout]]]'...: [[stages]] tables for EXTRA_TOML.
stages() {
  local s w r a t
  for s in "$@"; do
    IFS=: read -r w r a t <<<"$s"
    printf '[[stages]]\nworker = "%s"\n' "$w"
    [ -n "$r" ] && printf 'reviewer = "%s"\n' "$r"
    [ -n "$a" ] && printf 'attempts = %s\n' "$a"
    [ -n "$t" ] && printf 'timeout = %s\n' "$t"
  done; true
}
setup() {  # setup [GATE] [MERGE] [REVIEW_MODEL] [EXTRA_TOML]
  T=$(mktemp -d); export T
  export BEAD_LOOP_CONFIG=$T/config BEAD_LOOP_STATE=$T/state TEST_CTRL=$T/ctrl BD_STATE=$T/bd
  mkdir -p "$BEAD_LOOP_CONFIG" "$TEST_CTRL" "$BD_STATE"
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  REPO=$T/repo
  mkdir -p "$REPO/.beads"; echo base >"$REPO/README"; touch "$REPO/.beads/issues.jsonl"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm base && git -C "$REPO" branch -qM main && git -C "$REPO" push -q -u origin main
  printf 'label = "delegate:local"\nbase = "main"\ngate = \047%s\047\nmerge = "%s"\nreview_model = "%s"\n%s\n' "${1:-true}" "${2:-auto}" "${3-stub/reviewer}" "${4-}" >"$REPO/.bead-loop.toml"
  printf 'model = "stub/worker"\nrepos = ["%s"]\nworker_timeout = 60\n' "$REPO" >"$BEAD_LOOP_CONFIG/config.toml"
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
  assert_match "$(sed -n 2p "$TEST_CTRL/calls")" " stub/reviewer " "reviewer model from .bead-loop.toml"
  assert_match "$(cat "$TEST_CTRL/prompt.1")" "ACCEPTANCE CRITERIA" "bead rendered into the prompt"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "<diff>" "reviewer sees the diff"
  assert_branch bead/t-1 "branch pushed"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "inflight recorded"
  assert_eq "$(bead .status)" in_progress "bead parked in_progress until merge"
  assert_eq "$(bead .assignee)" delegate:local "claimed as the label, not the git user"
  assert_match "$(bead '.comments[0]')" "pull/7" "PR url on the bead"
  assert_nofile "$BEAD_LOOP_STATE/repo/wt/t-1" "worktree removed after push"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr create --base main --head bead/t-1" "PR against base"
  ! grep -q -- '--auto' "$TEST_CTRL/gh.log" && ok || bad "never asks GitHub to auto-merge"
}
case_actor_from_env() {
  setup; BEADS_ACTOR=delegate:acbox sup work "$REPO"
  assert_eq "$(bead .assignee)" delegate:acbox "BEADS_ACTOR in the environment wins over the label"
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
  # REJECT sends the bead back to the dev queue with the branch kept; the next dev round
  # resumes it, and the reviewer sees the fixed commit on top of the first.
  setup; printf 'reject\napprove\n' >"$TEST_CTRL/review"; sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-reviewer" "rejected: the round ends"
  assert_eq "$(bead .status)" open "back in the dev queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1")" 1 "one failure"
  assert_file "$BEAD_LOOP_STATE/repo/wt/t-1/work.txt" "worktree kept for the fix"
  sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-reviewer bead-worker bead-reviewer" "second round: dev, then review"
  assert_match "$(cat "$TEST_CTRL/prompt.3")" "REJECT: work.txt:1" "rejection fed back verbatim"
  assert_match "$(cat "$TEST_CTRL/prompt.3")" "already carries your earlier commit" "told to fix, not restart"
  assert_eq "$(tr '\n' '|' <"$TEST_CTRL/titles")" "t-1 · worker · round 1|t-1 · reviewer · round 1|t-1 · worker · round 2|t-1 · reviewer · round 2|" "every session titled by bead, role and round"
  assert_branch bead/t-1 "pushed after approval"
  assert_eq "$(git -C "$T/origin.git" rev-list --count main..bead/t-1)" 2 "both rounds' commits on the branch"
  assert_nofile "$BEAD_LOOP_STATE/repo/review/t-1" "out of the review queue"
}
case_reject_until_parked() {
  # The default stage takes three failures; the fourth send-back parks the bead.
  setup; printf 'reject\nreject\nreject\n' >"$TEST_CTRL/review"
  sup work "$REPO"; sup work "$REPO"; sup work "$REPO"
  assert_eq "$(bead .status)" in_progress "three failures: parked"
  assert_match "$(bead .notes)" "round 3 (stub/worker)" "the last round's note"
  assert_nofile "$BEAD_LOOP_STATE/repo/wt/t-1" "worktree removed when parked"
  assert_nobranch bead/t-1 "nothing pushed"
  : >"$TEST_CTRL/calls"; sup work "$REPO"; assert_eq "$(calls)" "" "parked bead is not picked up"
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
  # CI red sends the bead back to the dev queue on the same branch; the next push
  # updates the same PR, and until then the branch is not re-adopted.
  setup; sup work "$REPO"
  set_checks '[{"context":"ci","state":"FAILURE"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "red: not merged"
  assert_eq "$(bead .status)" open "red: back in the dev queue"
  assert_match "$(bead .notes)" "CI red on https://github.com/example/repo/pull/7: ci" "the failing check named"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1")" 1 "one failure"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "out of the merge queue"
  sup reconcile "$REPO"; assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "not adopted back while dev fixes it"
  : >"$TEST_CTRL/gh.log"; printf 'approve\napprove\n' >"$TEST_CTRL/review"; sup work "$REPO"
  assert_match "$(cat "$TEST_CTRL/prompt.3")" "already carries your earlier commit" "resumed the branch"
  ! grep -q 'pr create' "$TEST_CTRL/gh.log" && ok || bad "no second PR: the push updated the first"
  assert_match "$(bead .comments | tr '\n' ' ')" "pushed round 2 to https://github.com/example/repo/pull/7" "said so on the bead"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "back in the merge queue"
  assert_eq "$(git -C "$T/origin.git" rev-list --count main..bead/t-1)" 2 "the fix is on the branch"
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
case_merge_pipeline() {
  setup true pipeline; sup work "$REPO"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr edit 7 --add-label automerge" "labelled as soon as the PR opens"
  assert_eq "$(jq -r '.labels | join(",")' "$TEST_CTRL/pr.json")" automerge "default label is automerge"
  set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "green: the tick does not merge, the pipeline does"
  ! grep -q 'pr merge' "$TEST_CTRL/gh.log" && ok || bad "no merge call from the loop"
  assert_eq "$(bead .status)" in_progress "bead waits on the PR"
  jq '.state="MERGED"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"  # the pipeline merged it
  sup reconcile "$REPO"
  assert_eq "$(bead .status)" closed "the next tick sees MERGED and closes the bead"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "no longer in flight"
}
case_merge_pipeline_label_and_adoption() {
  setup true pipeline stub/reviewer 'merge_label = "ship-it"'
  jq '. + [{id:"t-9", title:"Theirs", description:"z", status:"open", priority:2, labels:[]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  jq -n '[{number:41, headRefName:"bead/t-9", url:"https://github.com/example/repo/pull/41", state:"OPEN", checks:[{context:"ci",state:"SUCCESS"}]}]' >"$TEST_CTRL/extra-prs.json"
  sup reconcile "$REPO"
  assert_eq "$(cat "$TEST_CTRL/labels-extra")" "41 ship-it" "an adopted PR gets the configured label too"
  ! grep -q 'pr merge 41' "$TEST_CTRL/gh.log" && ok || bad "and is left to the pipeline"
}
case_merge_pipeline_label_missing() {
  setup true pipeline; touch "$TEST_CTRL/label-missing"; sup work "$REPO"
  assert_match "$(bead .notes)" "could not label .* with automerge" "noted for you"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "still tracked"
  set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "green: still nobody merges but you"
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
  : >"$TEST_CTRL/calls"; sup --once tick
  assert_eq "$(calls)" "" "max_inflight = 1: no new bead while a PR is open"
  assert_eq "$(jq -r '.[]|select(.id=="t-2")|.status' "$BD_STATE/issues.json")" open "t-2 untouched"
}
case_nothing_ready() {
  setup; jq '.[0].labels=[]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup --once tick; assert_eq "$(calls)" "" "label filter respected"
}
case_lock_skips() {
  setup; mkdir -p "$BEAD_LOOP_STATE"
  ( exec 9>"$BEAD_LOOP_STATE/lock"; flock 9; sleep 3 ) &
  sleep 0.5; rc=0; sup --once tick || rc=$?
  assert_eq "$rc" 0 "held lock is a clean skip"
  assert_eq "$(calls)" "" "nothing ran"
  wait
}
case_config_comments() {
  setup; sed -i "s|^gate = 'true'$|gate = 'true'   # trailing comment|" "$REPO/.bead-loop.toml"; sup work "$REPO"
  assert_branch bead/t-1 "gate with a trailing comment still runs as `true`"
}
case_config_layers() {
  # repo file over global over default; a global stages table serves every repo;
  # ~ in repos expands; a config that does not parse is a loud stop.
  setup true auto ''
  printf 'model = "stub/worker"\nrepos = ["~/repo"]\nworker_timeout = 60\nmax_inflight = 3\n%s\n' "$(stages stub/global::1)" >"$BEAD_LOOP_CONFIG/config.toml"
  out=$(sup --dry-run work "$REPO")
  assert_match "$out" "model: stub/global" "stages from the global file"
  printf 'max_inflight = 1\n%s\n' "$(stages stub/repo::1)" >>"$REPO/.bead-loop.toml"
  out=$(sup --dry-run work "$REPO")
  assert_match "$out" "model: stub/repo" "repo stages win over global"
  out=$(HOME=$T sup --dry-run tick); assert_match "$out" "Do the thing" "~ in repos is the home directory"
  echo 'gate = "unterminated' >>"$REPO/.bead-loop.toml"
  rc=0; sup work "$REPO" || rc=$?; assert_eq "$rc" 1 "unparseable config dies"
}

case_escalation_stages() {
  setup true auto '' "$(stages stub/fast::2 stub/slow:stub/senior:1)"; echo nocommit >"$TEST_CTRL/worker"
  sup --once tick; assert_eq "$(bead .status)" open "round 1 failed: back in the queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1")" 1 "failure counted"
  sup --once tick; sup --once tick
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | tr '\n' ' ' | sed 's/ $//')" "stub/fast stub/fast stub/slow" "two fast attempts, then the slow stage"
  assert_eq "$(bead .status)" in_progress "exhausted: parked"
  assert_match "$(bead .notes)" "round 3 (stub/slow)" "note names the round and model"
  : >"$TEST_CTRL/calls"; sup --once tick; assert_eq "$(calls)" "" "parked bead is not retried"
}
case_repeat_cycles() {
  setup true auto '' "$(echo 'on_exhaust = "repeat"'; stages stub/fast::1 stub/slow::1)"; echo nocommit >"$TEST_CTRL/worker"
  sup --once tick; sup --once tick; sup --once tick; sup --once tick
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | tr '\n' ' ' | sed 's/ $//')" "stub/fast stub/slow stub/fast stub/slow" "cycles through the stages"
  assert_eq "$(bead .status)" open "still in the queue"
}
case_blocked_at_last_stage_parks() {
  setup true auto '' "$(echo 'on_exhaust = "repeat"'; stages stub/fast::1 stub/slow::1)"; echo blocked >"$TEST_CTRL/worker"
  sup --once tick; assert_eq "$(bead .status)" open "BLOCKED at the first stage: a stronger model may not be"
  sup --once tick; assert_eq "$(bead .status)" in_progress "BLOCKED at the last stage: parked even with repeat"
}
case_history_in_prompt() {
  setup true auto '' "$(stages stub/fast::2)"; echo nocommit >"$TEST_CTRL/worker"
  sup --once tick; ! grep -q '<previous-attempts>' "$TEST_CTRL/prompt.1" && ok || bad "first attempt has no history"
  sup --once tick; assert_match "$(cat "$TEST_CTRL/prompt.2")" "<previous-attempts>" "second attempt sees the history"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "round 1 (stub/fast): worker made no commit" "with the note"
}
case_fair_pick() {
  setup true auto '' "$(stages stub/fast::3)"; echo nocommit >"$TEST_CTRL/worker"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup --once tick; sup --once tick
  assert_match "$(cat "$TEST_CTRL/prompt.1")" "id: t-1" "first pick is bd's order"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "id: t-2" "then the untried bead, not t-1 again"
  sup --once tick; assert_match "$(cat "$TEST_CTRL/prompt.3")" "id: t-1" "then t-1's second attempt"
}
case_dry_run_names_stage() {
  setup true auto '' "$(stages stub/fast::1:7)"; out=$(sup --dry-run work "$REPO")
  assert_match "$out" "failures: 0  model: stub/fast" "dry run names the stage"
}

case_claude_stage_after_local_ones() {
  setup true auto '' "$(stages stub/fast::1 claude/opus:claude/opus:1)"; echo nocommit >"$TEST_CTRL/worker"
  sup --once tick; assert_eq "$(bead .status)" open "local attempt failed, requeued"
  sup --once tick
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls" | tr '\n' '|')" "stub/fast none|claude/opus claude|claude/opus claude|" "then Claude Code implements and reviews"
  assert_match "$(cat "$TEST_CTRL/system.2")" "delegated developer for one bead" "worker agent body is the system prompt"
  assert_match "$(cat "$TEST_CTRL/system.3")" "senior reviewer" "reviewer agent body is the system prompt"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "<previous-attempts>" "Claude sees the local attempt's note"
  assert_branch bead/t-1 "pushed"
  assert_match "$(git -C "$T/origin.git" log -1 --format=%s bead/t-1)" "opus round" "the commit is Claude's"
}

case_adopts_foreign_bead_prs() {
  setup
  jq '. + [{id:"t-9", title:"Theirs", description:"z", status:"open", priority:2, labels:[]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  jq -n '[{number:41, headRefName:"bead/t-9-some-slug", url:"https://github.com/example/repo/pull/41", state:"OPEN", checks:[{context:"ci",state:"SUCCESS"}]},
          {number:42, headRefName:"feature/not-a-bead", url:"https://github.com/example/repo/pull/42", state:"OPEN", checks:[{context:"ci",state:"SUCCESS"}]}]' >"$TEST_CTRL/extra-prs.json"
  sup reconcile "$REPO"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr merge 41 --squash" "green foreign bead PR merged"
  ! grep -q 'pr merge 42' "$TEST_CTRL/gh.log" && ok || bad "non-bead branch left alone"
  assert_eq "$(jq -r '.[]|select(.id=="t-9")|.status' "$BD_STATE/issues.json")" closed "its bead closed"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-9" "untracked after merge"
}
case_adopted_prs_do_not_block_new_work() {
  setup
  jq -n '[{number:41, headRefName:"bead/x-1", url:"https://github.com/example/repo/pull/41", state:"OPEN", checks:[{context:"ci",state:"PENDING"}]}]' >"$TEST_CTRL/extra-prs.json"
  sup --once tick
  assert_file "$BEAD_LOOP_STATE/repo/inflight/x-1" "adopted and tracked"
  assert_eq "$(calls)" "bead-worker bead-reviewer" "an adopted PR pending CI does not count toward max_inflight"
  assert_match "$(sup status "$REPO")" "x-1 .*\[adopted\]" "status says adopted"
}
case_adopt_off() {
  setup true auto stub/reviewer 'adopt = false'
  jq -n '[{number:41, headRefName:"bead/x-1", url:"https://github.com/example/repo/pull/41", state:"OPEN", checks:[{context:"ci",state:"SUCCESS"}]}]' >"$TEST_CTRL/extra-prs.json"
  sup reconcile "$REPO"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/x-1" "adopt = false: ignored"
}
case_dotted_ids_count_as_inflight() {
  setup; jq '.[0].id="t-1.2"' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup work "$REPO"; assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1.2" "tracked"
  jq '. + [{id:"t-3", title:"Next", description:"x", status:"open", priority:2, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  : >"$TEST_CTRL/calls"; sup --once tick
  assert_eq "$(calls)" "" "a bead id with a dot still counts toward max_inflight"
}

case_status_lists_worktree_sessions() {
  setup true auto stub/reviewer 'attach = "http://oc.test:4096"'
  wt=$BEAD_LOOP_STATE/repo/wt/t-1; mkdir -p "$wt" "$BEAD_LOOP_STATE/repo/failures"; echo 2 >"$BEAD_LOOP_STATE/repo/failures/t-1"
  jq -n '[{id:"ses_rev", parentID:null, agent:"bead-reviewer", model:{providerID:"slow",id:"m"}, title:"Reviewing", time:{created:0, updated:(now*1000)}},
          {id:"ses_wrk", parentID:null, agent:"bead-worker",   model:{providerID:"fast",id:"m"}, title:"Working",   time:{created:0, updated:(now*1000-7200000)}},
          {id:"ses_sub", parentID:"ses_wrk", agent:"explore", model:{providerID:"fast",id:"m"}, title:"Sub", time:{created:0, updated:(now*1000)}}]' >"$TEST_CTRL/sessions.json"
  echo '{"ses_rev":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"
  out=$(sup status "$REPO")
  assert_match "$out" "dev lane:    idle" "lanes idle"
  assert_match "$out" "ORPHAN  bead-reviewer  slow/m .* Reviewing" "busy on the server, no client here: orphan"
  assert_match "$out" "curl -X POST http://oc.test:4096/session/ses_rev/abort" "with the abort hint"
  ! printf '%s' "$out" | grep -q 'ses_wrk' && ok || bad "idle sessions are history, not shown"
  assert_match "$out" "http://oc.test:4096/$(printf '%s' "$wt" | base64 -w0 | tr '+/' '-_' | tr -d '=')/session/ses_rev" "web UI url under the worktree"
  ! printf '%s' "$out" | grep -q ses_sub && ok || bad "subagent sessions hidden"
  assert_match "$(cat "$TEST_CTRL/curl.log")" "session/status $wt" "asked the server about that worktree"
  # A client process for the worktree makes the same busy session a live one.
  (exec -a "opencode run --dir $wt --agent bead-reviewer" bash -c "sleep 30; true") & cpid=$!
  out=$(sup status "$REPO"); kill $cpid
  assert_match "$out" "busy    bead-reviewer" "busy with a client: not an orphan"
  # Without attach there is no server to ask, so no session lines at all.
  sed -i '/^attach/d' "$REPO/.bead-loop.toml"
  ! sup status "$REPO" | grep -q 'ses_' && ok || bad "no attach: no server to ask"
}
case_timeout_aborts_server_session() {
  setup true auto '' "$(echo 'attach = "http://oc.test:4096"'; stages stub/fast::1:1)"; echo hang >"$TEST_CTRL/worker"
  wt=$BEAD_LOOP_STATE/repo/wt/t-1
  echo '{"ses_hang":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"
  sup --once tick
  assert_eq "$(bead .status)" in_progress "timed out: parked (one stage)"
  assert_match "$(bead .notes)" "worker exited 124 (timeout=1 s)" "note says timeout"
  assert_match "$(cat "$TEST_CTRL/curl.log")" "session/status $wt" "asked the server what runs in the worktree"
  assert_match "$(cat "$TEST_CTRL/curl.log")" "http://oc.test:4096/session/ses_hang/abort" "and aborted it"
  assert_match "$(cat "$T/sup.log")" "aborting session ses_hang" "logged"
}
case_sigterm_aborts_server_session() {
  # systemctl stop signals the whole cgroup at once: the client dies with the supervisor.
  # setsid + kill of the process group is the closest a test gets.
  setup true auto '' 'attach = "http://oc.test:4096"'; echo hang >"$TEST_CTRL/worker"
  echo '{"ses_hang":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"
  setsid "$SUP" --once tick 2>>"$T/sup.log" & pid=$!
  until grep -q '^bead-worker' "$TEST_CTRL/calls" 2>/dev/null; do sleep 0.1; done; sleep 0.3
  kill -TERM -- -"$pid"
  rc=0; wait "$pid" || rc=$?
  assert_eq "$rc" 143 "exits 143 on TERM"
  assert_match "$(cat "$TEST_CTRL/curl.log")" "http://oc.test:4096/session/ses_hang/abort" "the session on the server was aborted"
  assert_match "$(cat "$T/sup.log")" "aborting session ses_hang" "logged"
}
case_new_attempt_aborts_leftover_session() {
  setup true auto '' 'attach = "http://oc.test:4096"'
  echo '{"ses_old":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"
  sup work "$REPO"
  assert_match "$(head -2 "$TEST_CTRL/curl.log" | tr '\n' ' ')" "session/status .*wt/t-1 .*/session/ses_old/abort" "before the worktree is recreated, what ran there is stopped"
}

case_status_json_and_ui() {
  # Three queues and two lanes, laid out by hand: t-1 in the merge queue (red), t-2 and
  # t-3 ready (t-3 has failed once, so t-2 goes first), t-4 waiting for review, t-6 on
  # the dev lane, t-5 parked.
  setup true auto stub/reviewer "$(printf 'attach = "http://oc.test:4096"\n%s' "$(stages stub/worker:stub/reviewer:2 stub/slow::1)")"
  R=$BEAD_LOOP_STATE/repo; wt=$R/wt/t-1; mkdir -p "$wt" "$R/failures" "$R/inflight" "$R/review"; echo 2 >"$R/failures/t-1"; echo 1 >"$R/failures/t-3"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:2, labels:["delegate:local"]},
          {id:"t-3", title:"Third", description:"z", status:"open", priority:1, labels:["delegate:local"]},
          {id:"t-4", title:"Fourth", description:"w", status:"in_progress", priority:2, labels:["delegate:local"]},
          {id:"t-6", title:"Sixth", description:"v", status:"in_progress", priority:2, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  echo "DONE: did it" >"$R/review/t-4"; echo t-6 >"$R/lane.dev"
  jq -n '[{id:"ses_rev", parentID:null, agent:"bead-reviewer", model:{providerID:"slow",id:"m"}, title:"Reviewing", time:{created:0, updated:(now*1000)}}]' >"$TEST_CTRL/sessions.json"
  echo '{"ses_rev":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"
  echo https://github.com/example/repo/pull/7 >"$BEAD_LOOP_STATE/repo/inflight/t-1"; : >"$BEAD_LOOP_STATE/repo/inflight/.t-1.red"
  jq '. + [{id:"t-5", title:"Parked one", description:"p", status:"in_progress", priority:2, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  j=$(sup --json status "$REPO")
  assert_eq "$(printf '%s' "$j" | jq -r '.slug, .attach, .stages[0].worker, .stages[0].failures, .lanes.dev.id, (.lanes.review // "idle")' | tr '\n' ' ')" "repo http://oc.test:4096 stub/worker 2 t-6 idle " "config and lanes"
  assert_eq "$(printf '%s' "$j" | jq -r '.queues.dev | map("\(.id):\(.failures):\(.stage.worker)") | join(" ")')" "t-2:0:stub/worker t-3:1:stub/worker" "dev queue in order: fewest failures first, with its stage"
  assert_eq "$(printf '%s' "$j" | jq -r '.queues.review | map("\(.id):\(.title)") | join(" ")')" "t-4:Fourth" "review queue"
  assert_eq "$(printf '%s' "$j" | jq -c '.queues.merge[0] | [.id, .red, .adopted, .failures]')" '["t-1",true,false,2]' "merge queue with its markers"
  assert_eq "$(printf '%s' "$j" | jq -r '.parked | map(.id) | join(" ")')" "t-5" "parked = in_progress minus the queues and lanes"
  assert_eq "$(printf '%s' "$j" | jq -r '.worktrees[0] | "\(.id) \(.failures) \(.sessions[0].state) \(.sessions[0].model) \(.sessions[0].url)"')" \
    "t-1 2 orphan slow/m http://oc.test:4096/$(printf '%s' "$wt" | base64 -w0 | tr '+/' '-_' | tr -d '=')/session/ses_rev" "worktree with its session"
  assert_eq "$(printf '%s' "$j" | jq -r '.queues.merge[0].stage.worker // "n/a"')" "n/a" "merge rows carry no stage"
  assert_match "$(sup status "$REPO")" "dev lane:    t-6 Sixth" "text status names the lane's bead"
  assert_match "$(sup status "$REPO")" "1   t-2            0× stub/worker    Second" "text status orders the dev queue"
  command -v node >/dev/null || { echo "  (no node: ui server not exercised)"; return; }
  # The UI server: the page, the state it reads, and the two guards on its levers.
  port=$((20000 + RANDOM % 20000))
  mkdir -p "$T/gpu"; echo game >"$T/gpu/mode"; echo auto >"$T/gpu/by"
  GPU_MODE_STATE=$T/gpu BEAD_LOOP_UI_PORT=$port node "$HERE/../bin/bead-loop-ui" >"$T/ui.log" 2>&1 & upid=$!
  for _ in $(seq 50); do "$REAL_CURL" -sf -m 1 "http://127.0.0.1:$port/api/state" >"$T/state.json" 2>/dev/null && break; sleep 0.1; done
  assert_eq "$(jq -r '.repos[0].slug, (.repos[0].worktrees[0].sessions[0].state), (.repos[0].queues.dev[0].id), (.error // "none")' "$T/state.json" | tr '\n' ' ')" "repo orphan t-2 none " "/api/state carries the supervisor's JSON"
  assert_match "$("$REAL_CURL" -s -m 3 "http://127.0.0.1:$port/")" "<title>bead-loop</title>" "the page"
  assert_eq "$(jq -r '.gpu | "\(.available) \(.mode) \(.by)"' "$T/state.json")" "true game auto" "gpu-mode read from its state dir"
  assert_match "$(timeout 5 "$REAL_CURL" -sN -m 4 "http://127.0.0.1:$port/api/events" | head -1)" '^data: {"now":[0-9]*,"repos":\[{"slug":"repo"' "the event stream opens with the state"
  # The second page gets the last state replayed at once, with a fresh now in front: still one JSON object.
  assert_eq "$(timeout 5 "$REAL_CURL" -sN -m 4 "http://127.0.0.1:$port/api/events" | head -1 | sed 's/^data: //' | jq -r '.repos[0].slug, (.now | type)' | tr '\n' ' ')" "repo number " "the replayed state is valid JSON"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d '{"name":"review","paused":true}' "http://127.0.0.1:$port/api/lane")" '"paused":true' "pause a lane from the page"
  assert_file "$BEAD_LOOP_STATE/pause.review" "the marker the lane checks"
  assert_eq "$("$REAL_CURL" -sf -m 3 "http://127.0.0.1:$port/api/state" | jq -r '.repos[0].paused.review')" true "state says so"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'sec-fetch-site: cross-site' "http://127.0.0.1:$port/api/tick")" "same-origin only" "cross-site lever refused"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d '{"attach":"http://elsewhere","session":"s"}' "http://127.0.0.1:$port/api/abort")" "unknown server" "abort only against a configured server"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d '{"repo":"/nope","id":"t-5"}' "http://127.0.0.1:$port/api/reopen")" "unknown repo" "reopen only in a configured repo"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-5\"}" "http://127.0.0.1:$port/api/reopen")" '"reopened":"t-5"' "reopen runs bd"
  assert_eq "$(jq -r '.[]|select(.id=="t-5")|.status' "$BD_STATE/issues.json")" open "the bead is open again"
  kill $upid
}

case_tick_goes_round_while_there_is_work() {
  # Two ready beads: the dev lane works both back to back (the review queue fills), the
  # review lane takes them in turn; the tick ends when both queues are drained.
  setup true auto stub/reviewer 'max_inflight = 3'; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup --serial tick
  assert_eq "$(calls)" "bead-worker bead-worker bead-reviewer bead-reviewer" "dev drains its queue, then review drains its own"
  assert_match "$(cat "$T/sup.log")" "dev: nothing ready with label" "the dev pass that finds nothing ends its lane"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "t-1 in the merge queue"; assert_file "$BEAD_LOOP_STATE/repo/inflight/t-2" "t-2 too"
  # The merge queue full (max_inflight = 1): the dev lane waits on CI; the tick ends; the timer looks again.
  setup; mkdir -p "$BEAD_LOOP_STATE/repo/inflight"; echo https://github.com/example/repo/pull/9 >"$BEAD_LOOP_STATE/repo/inflight/t-9"
  sup --serial tick
  assert_eq "$(calls)" "" "one PR in flight: no bead started"
  assert_match "$(cat "$T/sup.log")" "dev: 1 in flight (max 1); waiting on CI" "said so"
  # --once: one pass of each lane, in turn.
  setup true auto stub/reviewer 'max_inflight = 3'; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup --once tick
  assert_eq "$(calls)" "bead-worker bead-reviewer" "--once: one bead through both lanes"
}
case_lanes_run_side_by_side() {
  # The real tick: both lanes at once. The review lane waits while dev is busy, takes
  # t-1 as soon as it is queued, and dev goes on to t-2 meanwhile.
  setup true auto stub/reviewer 'max_inflight = 3'; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  LANE_WAIT=0.2 sup tick
  assert_eq "$(cut -d' ' -f1 "$TEST_CTRL/calls" | sort | uniq -c | awk '{print $2"="$1}' | tr '\n' ' ')" "bead-reviewer=2 bead-worker=2 " "every bead through both lanes"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "t-1 in the merge queue"; assert_file "$BEAD_LOOP_STATE/repo/inflight/t-2" "t-2 too"
  assert_nofile "$BEAD_LOOP_STATE/repo/lane.dev" "dev lane clear"; assert_nofile "$BEAD_LOOP_STATE/repo/lane.review" "review lane clear"
}


case_pause_one_lane() {
  # A paused lane starts nothing; the other lane goes on. Resume, and the next tick picks it up.
  setup; sup pause review; sup --serial tick
  assert_eq "$(calls)" "bead-worker" "dev worked; review paused"
  assert_file "$BEAD_LOOP_STATE/repo/review/t-1" "the bead waits in the review queue"
  assert_match "$(cat "$T/sup.log")" "review lane paused; starting nothing" "said so"
  assert_match "$(sup status "$REPO")" "review lane: idle  \[paused\]" "status shows it"
  sup resume review; sup --serial tick
  assert_eq "$(calls)" "bead-worker bead-reviewer" "resumed: reviewed on the next tick"
  assert_branch bead/t-1 "and pushed"
}

case_stale_assignee_does_not_block() {
  # A bead sent back to open keeps its old assignee; bd refuses --claim for another actor.
  # The loop takes it anyway: an open bead's assignee is stale by definition.
  setup; jq '.[0].assignee="Somebody Else"' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup work "$REPO"
  assert_eq "$(calls)" "bead-worker bead-reviewer" "worked despite the stale assignee"
  assert_eq "$(bead .status)" in_progress "claimed"
  assert_branch bead/t-1 "and pushed"
}
case_attempts_carry_over() {
  # The older attempts/ counter moves into failures/ file by file, even when failures/
  # already exists (a status run makes it), and the old directory goes.
  setup; R=$BEAD_LOOP_STATE/repo; mkdir -p "$R/attempts" "$R/failures"
  echo 2 >"$R/attempts/t-1"; echo "round 1 (x): y" >"$R/attempts/t-1.notes"; echo 5 >"$R/failures/t-9"
  sup status "$REPO" >/dev/null
  assert_eq "$(cat "$R/failures/t-1") $(cat "$R/failures/t-9")" "2 5" "both counters in failures/"
  assert_file "$R/failures/t-1.notes" "the history too"; assert_nofile "$R/attempts" "attempts/ gone"
}

# ---- main ----------------------------------------------------------------------------
cases=$(declare -F | awk '{print $3}' | grep '^case_')
[ $# -gt 0 ] && cases=$(printf 'case_%s\n' "$@")
for CASE in $cases; do
  printf '%s\n' "$CASE"; "$CASE"
  [ -n "${KEEP:-}" ] || rm -rf "$T"
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
