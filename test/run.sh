#!/usr/bin/env bash
# bead-loop integration tests: the supervisor's state machine against stub
# bd/opencode/gh (test/bin) and a real git origin. Every row of the README's
# outcome table is a case here. Run: test/run.sh [case-name...]
#
# What belongs here is a transition the state machine makes through its tools — a
# round, a queue, a PR, a session — and what it leaves on the bead and on disk. The
# shape of a prompt, a note, a queue order or the status JSON is a unit test in src/
# (cargo test); a case here proves the wiring once, not every variant.
#
# Every case has its own scratch dir, state dir and stub control dir, so with no case
# named they run side by side, one process per case (JOBS=N; JOBS=1 for one at a time).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUP=${SUP:-$HERE/../target/debug/bead-supervisor}   # the Rust binary; SUP=... to point elsewhere
# The stubs in test/bin shadow curl; the UI case talks to a real server with the real one
# (found before the stubs go on PATH, and handed down to the cases run side by side).
export REAL_CURL=${REAL_CURL:-$(command -v curl || true)}
export PATH=$HERE/bin:$PATH
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com
# A lane with nothing to do looks at the other lane three times, LANE_WAIT apart, before
# it leaves a tick: 10 s in production, where the pause is what makes the check cheap;
# here it would be 20 s of nothing per idle lane. A case about the wait sets its own.
export LANE_WAIT=${LANE_WAIT:-0.1}
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
# A here-string, not a pipe: `grep -q` leaves at the first match, and under pipefail a
# printf still writing a large page (the UI case) then failed the assertion with SIGPIPE.
assert_match() { grep -q -- "$2" <<<"$1" && ok || bad "$3: [$1] lacks [$2]"; }
assert_file() { [ -e "$1" ] && ok || bad "$2: missing $1"; }
assert_nofile() { [ ! -e "$1" ] && ok || bad "$2: unexpected $1"; }
assert_branch() { git -C "$T/origin.git" show-ref -q "refs/heads/$1" && ok || bad "$2: origin has no branch $1"; }
assert_nobranch() { git -C "$T/origin.git" show-ref -q "refs/heads/$1" && bad "$2: origin has branch $1" || ok; }
calls() { cut -d' ' -f1 "$TEST_CTRL/calls" | tr '\n' ' ' | sed 's/ $//'; }
# render_page STATE.json [JS]: the page's script run against that state under a stub DOM
# (the elements it looks up, an EventSource that pushes the state once), then JS — a
# click, say — and prints main's HTML.
render_page() {
  sed -n '/^<script>/,/^<\/script>/p' "$HERE/../ui/index.html" | sed '1d;$d' >"$T/page.js"
  node -e '
    const els = {}; const el = (id) => els[id] ||= { id, innerHTML: "", textContent: "", hidden: false, dataset: {}, scrollTop: 0, scrollHeight: 0, value: "" };
    global.document = { getElementById: el, addEventListener() {}, hidden: false };
    global.window = global; global.setInterval = () => {};
    global.EventSource = class { constructor() { setTimeout(() => { this.onopen(); this.onmessage({ data: require("fs").readFileSync(process.argv[1], "utf8") }); if (process.argv[3]) new Function(process.argv[3])(); console.log(el("main").innerHTML); }, 0); } };
    require(process.argv[2]);' "$1" "$T/page.js" "${2-}"
}

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
  # One stage: BLOCKED there parks the bead, and the brief follows — in the worktree,
  # before it goes, by the last stage's worker.
  assert_eq "$(calls)" "bead-worker bead-briefer" "stops after the worker; the brief follows"
  assert_eq "$(sed -n 2p "$TEST_CTRL/calls")" "bead-briefer $BEAD_LOOP_STATE/repo/wt/t-1 stub/worker none" "the brief runs in the worktree, on the stage's worker"
  assert_eq "$(bead .status)" in_progress "parked"
  assert_match "$(bead .notes)" "BLOCKED: lib/x.ts:3" "worker's line in the note"
  assert_match "$(bead .notes)" "parked (BLOCKED at the last stage). Is the flag called --dry-run" "the brief's question on the bead"
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
  assert_match "$(cat "$TEST_CTRL/prompt.3" | tr '\n' ' ')" "For the worker: - What is wrong: work.txt:1 says round 1 - What to do: append the word fixed - How to check: grep -c fixed work.txt prints 1" "the whole work order, not one line"
  assert_match "$(cat "$TEST_CTRL/prompt.3")" "a work order from the senior reviewer" "told to act on it"
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
  # The history: one record per round, the whole rejection, the round's log files.
  assert_eq "$(jq -r '[.round, .model, .stage] | @tsv' "$BEAD_LOOP_STATE/repo/failures/t-1.rounds.jsonl" | tr '\t\n' ' ;')" "1 stub/worker 1;2 stub/worker 1;3 stub/worker 1;" "three rounds on stage 1"
  assert_match "$(jq -r 'select(.round==2) | .note' "$BEAD_LOOP_STATE/repo/failures/t-1.rounds.jsonl")" "How to check: grep -c fixed work.txt prints 1" "the whole work order kept"
  assert_match "$(jq -r 'select(.round==2) | .logs | join(" ")' "$BEAD_LOOP_STATE/repo/failures/t-1.rounds.jsonl")" 't-1\.[0-9T]*\.review\.jsonl' "the reviewer's log named"
  assert_nofile "$BEAD_LOOP_STATE/repo/failures/t-1.notes" "the one-line notes file is history"
  # The brief read the rounds and their logs; the worktree was still there for it.
  bp=$(grep -l "^The automated loop has parked" "$TEST_CTRL"/prompt.*)
  assert_match "$(cat "$bp")" "every stage has had its turn (3 rounds, all sent back)" "the brief's prompt says why"
  assert_match "$(cat "$bp")" "round 3 · stub/worker (stage 1) · " "and lists the rounds"
  assert_match "$(cat "$bp")" -- "--- round 3: t-1\.[0-9T]*\.review\.jsonl, the end:" "with the end of each log"
  assert_match "$(cat "$bp")" "> REJECT: work.txt:1 wrong, fix it" "rendered as the session's lines"
  assert_eq "$(jq -r .question "$BEAD_LOOP_STATE/repo/parked/t-1")" "Is the flag called --dry-run (add it to the bead), or should the criterion go?" "the brief's question is the record's"
  assert_match "$(jq -r .stopped_on "$BEAD_LOOP_STATE/repo/parked/t-1")" "^review (stub/reviewer) rejected:" "and what it stopped on"
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
  # The verdict on a check list is a unit test (merge::verdicts); here, what each one
  # does to the PR and the bead: nothing while a check is pending, the merge on green.
  setup; sup work "$REPO"
  set_checks '[{"context":"a","state":"SUCCESS"},{"context":"b","state":"PENDING"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "one pending check holds the merge"
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
case_behind_then_closed_unmerged() {
  setup; sup work "$REPO"
  jq '.mergeStateStatus="BEHIND"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"
  set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr update-branch 7" "behind: branch updated, not merged"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "behind: waits for CI to rerun"
  # Someone closes it instead: parked for you, out of the merge queue.
  jq '.state="CLOSED"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"; sup reconcile "$REPO"
  assert_match "$(bead .notes)" "closed without merging" "noted"
  assert_eq "$(bead .status)" in_progress "parked"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "untracked"
}
case_inflight_limits_tick() {
  setup true auto stub/reviewer 'max_inflight = 1'; sup work "$REPO"
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
  ( exec 9>"$BEAD_LOOP_STATE/lock"; flock 9; sleep 1 ) &
  sleep 0.2; rc=0; sup --once tick || rc=$?
  assert_eq "$rc" 0 "held lock is a clean skip"
  assert_eq "$(calls)" "" "nothing ran"
  wait
}
case_config_layers() {
  # The layering, the parse and ~ are unit tests (config::tests); here, that a run reads
  # the two files: a global stages table serves every repo, the repo's wins, tick finds
  # the repo through `repos`, and a config that does not parse is a loud stop.
  setup true auto ''
  printf 'model = "stub/worker"\nrepos = ["~/repo"]\nworker_timeout = 60\nmax_inflight = 3\n%s\n' "$(stages stub/global::1:7)" >"$BEAD_LOOP_CONFIG/config.toml"
  out=$(sup --dry-run work "$REPO")
  assert_match "$out" "failures: 0  model: stub/global" "dry run names the stage, from the global file"
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
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | tr '\n' ' ' | sed 's/ $//')" "stub/fast stub/fast stub/slow stub/slow" "two fast attempts, then the slow stage, then its brief"
  assert_eq "$(bead .status)" in_progress "exhausted: parked"
  assert_match "$(bead .notes)" "round 3 (stub/slow)" "note names the round and model"
  assert_match "$(bead .notes)" "parked (stages exhausted after 3 rounds)" "and the parking, with its count"
  assert_eq "$(jq -r '.reason + " " + (.failures|tostring) + " " + (.stage.index|tostring) + " " + .brief_model' "$BEAD_LOOP_STATE/repo/parked/t-1")" "exhausted 3 2 stub/slow" "the record: why, the count, the stage it stopped on, who briefed"
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
case_claude_stage_after_local_ones() {
  # One --once tick: the dev lane's stub round fails and requeues t-1 on the Claude stage;
  # the claude lane, passing after it, takes it straight away.
  setup true auto '' "$(stages stub/fast::1 claude/opus:claude/opus:1)"; echo nocommit >"$TEST_CTRL/worker"
  sup --once tick
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls" | tr '\n' '|')" "stub/fast none|claude/opus claude|claude/opus claude|" "the local attempt fails, then Claude Code implements and reviews"
  ! grep -q '<previous-attempts>' "$TEST_CTRL/prompt.1" && ok || bad "first attempt has no history"
  assert_match "$(cat "$TEST_CTRL/system.2")" "delegated developer for one bead" "worker agent body is the system prompt"
  assert_match "$(cat "$TEST_CTRL/system.3")" "senior reviewer" "reviewer agent body is the system prompt"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "<previous-attempts>" "Claude sees the local attempt's note"
  assert_match "$(cat "$TEST_CTRL/prompt.2")" "round 1 (stub/fast): worker made no commit" "the note the send-back left"
  assert_branch bead/t-1 "pushed"
  assert_match "$(git -C "$T/origin.git" log -1 --format=%s bead/t-1)" "opus round" "the commit is Claude's"
}
case_aider_stage() {
  # worker aider:stub/worker runs aider in the worktree on the files the bead's description
  # names, against the opencode provider's server, the gate as its lint; no DONE: line is
  # needed, settle_worktree commits the edit and the round goes on to review and the PR.
  setup true auto stub/reviewer "$(printf '[[stages]]\nworker = "aider:stub/worker"\nreviewer = "stub/reviewer"\n')"
  echo base >"$REPO/work.txt"; git -C "$REPO" add -A && git -C "$REPO" commit -qm "work.txt" && git -C "$REPO" push -q origin main
  jq '.[0].description = "Edit work.txt (leave README alone); see docs/none.md."' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  jq -n '{provider:{stub:{options:{baseURL:"http://stub.test/v1", apiKey:"not-needed"}}}}' >"$T/opencode.json"
  OPENCODE_CONFIG=$T/opencode.json sup work "$REPO"
  assert_eq "$(cut -d' ' -f1,3,4 "$TEST_CTRL/calls" | tr '\n' '|')" "bead-worker openai/worker aider|bead-reviewer stub/reviewer none|" "aider implements, opencode reviews"
  assert_eq "$(sed -n 1p "$TEST_CTRL/aider.args")" "base=http://stub.test/v1 key=not-needed" "the provider's server and key from opencode.json"
  assert_match "$(sed -n 2p "$TEST_CTRL/aider.args")" "^--yes-always --no-auto-commits --no-gitignore --model openai/worker " "non-interactive, no commits of its own"
  assert_match "$(sed -n 2p "$TEST_CTRL/aider.args")" " --lint-cmd true " "the gate is aider's lint"
  assert_match "$(sed -n 2p "$TEST_CTRL/aider.args")" " work.txt$" "the file the description names, and only that one"
  assert_match "$(cat "$TEST_CTRL/prompt.1")" "ACCEPTANCE CRITERIA" "the bead is the message"
  assert_branch bead/t-1 "pushed"
  assert_match "$(git -C "$T/origin.git" log -1 --format=%s bead/t-1)" "t-1: Do the thing" "settle_worktree committed aider's edit"
  assert_eq "$(git -C "$T/origin.git" diff --name-only main bead/t-1 | tr '\n' ' ')" "work.txt " "aider's scratch files stayed out of the commit"
  assert_match "$(cat "$TEST_CTRL/gh.log")" "pr create" "and a PR"
  # No provider config: aider runs without OPENAI_API_BASE and the log says so.
  setup true auto '' "$(printf '[[stages]]\nworker = "aider:stub/worker"\n')"
  echo base >"$REPO/work.txt"; git -C "$REPO" add -A && git -C "$REPO" commit -qm "work.txt" && git -C "$REPO" push -q origin main
  OPENCODE_CONFIG=$T/none.json sup work "$REPO"
  assert_eq "$(sed -n 1p "$TEST_CTRL/aider.args")" "base=unset key=unused" "no base, a dummy key"
  assert_match "$(cat "$T/sup.log")" "no baseURL for opencode provider stub" "said so"
  assert_branch bead/t-1 "still worked"
}
case_harness_label() {
  # A bead's label picks its worker's harness over the stage's: harness:opencode takes an
  # aider: model out of aider, harness:aider puts an opencode model under it; claude/* is not touched.
  setup true auto '' "$(printf '[[stages]]\nworker = "aider:stub/worker"\n')"
  jq '.[0].labels += ["harness:opencode"]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup work "$REPO"
  assert_eq "$(cut -d' ' -f1,3,4 "$TEST_CTRL/calls")" "bead-worker stub/worker none" "worked by opencode, not aider"
  assert_nofile "$TEST_CTRL/aider.args" "aider never ran"
  assert_match "$(cat "$T/sup.log")" "label harness:opencode: worker stub/worker runs in opencode, not aider" "the choice and why, logged"
  assert_branch bead/t-1 "pushed"
  setup true auto '' "$(stages stub/worker::1)"
  echo base >"$REPO/work.txt"; git -C "$REPO" add -A && git -C "$REPO" commit -qm "work.txt" && git -C "$REPO" push -q origin main
  jq '.[0].labels += ["harness:aider"]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup work "$REPO"
  assert_eq "$(cut -d' ' -f1,3,4 "$TEST_CTRL/calls")" "bead-worker openai/worker aider" "worked by aider, not opencode"
  assert_match "$(sed -n 2p "$TEST_CTRL/aider.args")" " work.txt$" "with the bead's file"
  assert_match "$(cat "$T/sup.log")" "label harness:aider: worker aider:stub/worker runs in aider, not opencode" "the choice and why, logged"
  assert_branch bead/t-1 "pushed"
  setup true auto '' "$(stages claude/opus::1)"
  jq '.[0].labels += ["harness:aider"]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup work "$REPO"
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls")" "claude/opus claude" "claude/* stays in Claude Code"
  ! grep -q 'harness:' "$T/sup.log" && ok || bad "nothing changed, nothing logged"
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
  # A client process for the worktree makes the same busy session a live one: a bash
  # under that name, blocked on opening a fifo nobody writes (no child, so the kill ends
  # it and nothing outlives the case; a renamed sleep would not do — coreutils on NixOS
  # dispatches on argv[0]).
  mkfifo "$T/client"; (exec -a "opencode run --dir $wt --agent bead-reviewer" bash -c 'read -r <"$0" || true' "$T/client") & cpid=$!
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
case_stop_charges_no_failure() {
  # A stop (a deploy recycles the stack) aborts the session and signals the client; the
  # client comes back non-zero and the lane, still running until the signal thread exits,
  # judged that as the round's failure: one charged, a note, the branch removed. Now the
  # signal thread raises a flag before it aborts anything, and a round that ends under it
  # is cut short, not failed: the bead stays in_progress with its worktree and branch —
  # what recover reopens with no failure at the next start. The stub server takes a
  # second to abort (abort-delay), as the real one does, so the lane has its chance.
  setup true auto '' 'attach = "http://oc.test:4096"'; echo hang >"$TEST_CTRL/worker"
  echo '{"ses_hang":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"; echo 1 >"$TEST_CTRL/abort-delay"
  setsid "$SUP" --once tick 2>>"$T/sup.log" & pid=$!
  until grep -q '^bead-worker' "$TEST_CTRL/calls" 2>/dev/null; do sleep 0.1; done; sleep 0.3
  kill -TERM -- -"$pid"
  rc=0; wait "$pid" || rc=$?
  assert_eq "$rc" 143 "exits 143 on TERM"
  assert_match "$(cat "$T/sup.log")" "t-1: round cut short by the stop; nothing charged" "the lane saw the stop, not a failure"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure charged"
  ! grep -q 'round 1' <<<"$(bead .notes)" && ok || bad "no round note on the bead: $(bead .notes)"
  assert_eq "$(bead .status)" in_progress "the bead is as the stop left it"
  git -C "$REPO" show-ref -q refs/heads/bead/t-1 && ok || bad "the branch is kept for recover"
  [ -d "$BEAD_LOOP_STATE/repo/wt/t-1" ] && ok || bad "the worktree is kept for recover"
  echo '{}' >"$TEST_CTRL/session-status.json"   # the abort took: the server shows nothing running
  sup recover "$REPO"
  assert_eq "$(bead .status)" open "recover reopened it"
  assert_match "$(bead .notes)" "round interrupted by a stop; back in the dev queue, no failure charged" "with the stop's note"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "still no failure"
}
case_restart_rejoins_the_worker_session() {
  # A deploy restarts the loop alone: the opencode server, and the session it is running
  # for the round, outlive the process. The deploy drops $STATE/restart before the
  # restart; the stop then leaves the session running instead of aborting it, and the
  # next process's recover finds it under the worktree and rejoins it — the bead back in
  # the dev queue first, the lane that takes it waiting on that session rather than
  # starting one, its messages read off the server as the round's text. One worker call
  # in all, and the bead reaches its PR.
  setup true auto stub/reviewer 'attach = "http://oc.test:4096"'; echo hang >"$TEST_CTRL/worker"
  mkdir -p "$BEAD_LOOP_STATE"; touch "$BEAD_LOOP_STATE/restart"
  setsid "$SUP" --once tick 2>>"$T/sup.log" & pid=$!
  until grep -q '^bead-worker' "$TEST_CTRL/calls" 2>/dev/null; do sleep 0.1; done
  echo '{"ses_live":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"   # the server is on it now
  sleep 0.3
  kill -TERM -- -"$pid"; rc=0; wait "$pid" || rc=$?
  assert_eq "$rc" 143 "exits 143 on TERM"
  assert_match "$(cat "$T/sup.log")" "restart: 1 session(s) left running on the server for the next process to rejoin" "a restart keeps the session"
  ! grep -q abort "$TEST_CTRL/curl.log" && ok || bad "no abort on a restart: $(grep abort "$TEST_CTRL/curl.log")"
  assert_nofile "$BEAD_LOOP_STATE/restart" "the marker is consumed"
  R=$BEAD_LOOP_STATE/repo
  sup recover "$REPO"
  assert_match "$(cat "$T/sup.log")" "t-1: worker session ses_live still running on the server after the stop; rejoining it" "recover found it"
  ! grep -q abort "$TEST_CTRL/curl.log" && ok || bad "recover did not abort it"
  assert_eq "$(cat "$R/rejoin/t-1" 2>/dev/null)" "ses_live worker" "the rejoin marker"
  assert_eq "$(bead .status)" open "back in the dev queue"
  ! grep -q 'interrupted by a stop' <<<"$(bead .notes)" && ok || bad "not noted as interrupted: it goes on"
  assert_eq "$(sup --json status "$REPO" | jq -r '.queues.dev[0].id')" t-1 "first in the dev queue"
  # The session finishes on the server while the lane waits on it: its work in the
  # worktree, its DONE among its messages, then the server shows it idle.
  echo work >"$R/wt/t-1/work.txt"
  jq -cn '[{info:{role:"user"},parts:[{type:"text",text:"Work the bead"}]},{info:{role:"assistant"},parts:[{type:"text",text:"I did it."},{type:"tool"},{type:"text",text:"DONE: work.txt written"}]}]' >"$TEST_CTRL/messages.json"
  ( sleep 0.6; echo '{}' >"$TEST_CTRL/session-status.json" ) &
  BEAD_LOOP_REJOIN_POLL=0.1 sup --once tick; wait
  assert_match "$(cat "$T/sup.log")" "dev: bead t-1 .*rejoining session ses_live" "the lane rejoined rather than started"
  assert_match "$(cat "$T/sup.log")" "rejoined session ses_live: finished after" "and waited for it"
  assert_eq "$(calls)" "bead-worker bead-reviewer" "one worker call in all; the reviewer took its DONE"
  assert_file "$R/inflight/t-1" "to a PR"
  assert_nofile "$R/rejoin/t-1" "the marker is spent"
  assert_match "$(cat "$R"/logs/t-1.*.worker.jsonl | tail -1)" "DONE: work.txt written" "the session's text is the round's log"
  assert_eq "$(cat "$R/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure anywhere"
  # A stop that is not a restart (a hand stop, gpu-mode) still aborts the session.
  setup true auto stub/reviewer 'attach = "http://oc.test:4096"'; echo hang >"$TEST_CTRL/worker"
  setsid "$SUP" --once tick 2>>"$T/sup.log" & pid=$!
  until grep -q '^bead-worker' "$TEST_CTRL/calls" 2>/dev/null; do sleep 0.1; done
  echo '{"ses_live":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"   # the server is on it now
  sleep 0.3
  kill -TERM -- -"$pid"; wait "$pid" 2>/dev/null || true
  assert_match "$(cat "$TEST_CTRL/curl.log")" "session/ses_live/abort" "a plain stop aborts"
}

case_restart_rejoins_the_reviewer_session() {
  # The same for a reviewer round: review/ID survives the stop, recover finds the
  # session under the worktree, the review lane waits on it and takes its APPROVE.
  setup true auto stub/reviewer 'attach = "http://oc.test:4096"'; echo hang >"$TEST_CTRL/review"
  mkdir -p "$BEAD_LOOP_STATE"; touch "$BEAD_LOOP_STATE/restart"
  setsid "$SUP" --once tick 2>>"$T/sup.log" & pid=$!
  until grep -q '^bead-reviewer' "$TEST_CTRL/calls" 2>/dev/null; do sleep 0.1; done
  echo '{"ses_rev":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"   # the server is on it now
  sleep 0.3
  kill -TERM -- -"$pid"; rc=0; wait "$pid" || rc=$?
  assert_eq "$rc" 143 "exits 143 on TERM"
  R=$BEAD_LOOP_STATE/repo
  assert_file "$R/review/t-1" "still in the review queue"
  sup recover "$REPO"
  assert_match "$(cat "$T/sup.log")" "t-1: reviewer session ses_rev still running on the server after the stop; rejoining it" "recover found it"
  assert_eq "$(cat "$R/rejoin/t-1" 2>/dev/null)" "ses_rev reviewer" "the rejoin marker"
  jq -cn '[{info:{role:"assistant"},parts:[{type:"text",text:"APPROVE: checked every criterion"}]}]' >"$TEST_CTRL/messages.json"
  ( sleep 0.6; echo '{}' >"$TEST_CTRL/session-status.json" ) &
  BEAD_LOOP_REJOIN_POLL=0.1 sup --once tick; wait
  assert_match "$(cat "$T/sup.log")" "review: t-1 by stub/reviewer (0 failures, rejoining session ses_rev)" "the review lane rejoined"
  assert_eq "$(calls)" "bead-worker bead-reviewer" "one reviewer call in all"
  assert_file "$R/inflight/t-1" "to a PR"
  assert_match "$(cat "$T/sup.log")" "t-1: review approved" "its APPROVE taken"
}
case_new_attempt_aborts_leftover_session() {
  setup true auto '' 'attach = "http://oc.test:4096"'
  echo '{"ses_old":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"
  sup work "$REPO"
  assert_match "$(head -2 "$TEST_CTRL/curl.log" | tr '\n' ' ')" "session/status .*wt/t-1 .*/session/ses_old/abort" "before the worktree is recreated, what ran there is stopped"
}

case_status_json_and_ui() {
  # Three queues and two lanes, laid out by hand: t-1 in the merge queue (red), t-2, t-3
  # and t-7 ready (t-3 has failed once, so t-2 goes first; t-7 twice, so it is on the
  # last stage, Claude's), t-4 waiting for review, t-6 on the dev lane, t-5 parked.
  # The JSON's shape from this layout is a unit test (status::tests); here, that the
  # binary reads bd and the attached server into it, and what the UI does with it.
  setup true auto stub/reviewer "$(printf 'attach = "http://oc.test:4096"\n%s' "$(stages stub/worker:stub/reviewer:2 claude/opus::1)")"
  R=$BEAD_LOOP_STATE/repo; wt=$R/wt/t-1; mkdir -p "$wt" "$R/failures" "$R/inflight" "$R/review"; echo 2 >"$R/failures/t-1"; echo 1 >"$R/failures/t-3"; echo 2 >"$R/failures/t-7"
  printf 'round 1 (stub/worker): BLOCKED: which flag?\nround 2 (stub/worker): REJECT: x.ts:1 wrong\n' >"$R/failures/t-7.notes"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:2, labels:["delegate:local"]},
          {id:"t-3", title:"Third", description:"z", status:"open", priority:1, labels:["delegate:local"]},
          {id:"t-4", title:"Fourth", description:"w", status:"in_progress", priority:2, labels:["delegate:local"]},
          {id:"t-6", title:"Sixth", description:"v", status:"in_progress", priority:2, labels:["delegate:local"]},
          {id:"t-7", title:"Seventh", description:"u", status:"open", priority:2, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  echo "DONE: did it" >"$R/review/t-4"; echo t-6 >"$R/lane.dev"
  jq -n '[{id:"ses_rev", parentID:null, agent:"bead-reviewer", model:{providerID:"slow",id:"m"}, title:"Reviewing", time:{created:0, updated:(now*1000)}}]' >"$TEST_CTRL/sessions.json"
  echo '{"ses_rev":{"type":"busy"}}' >"$TEST_CTRL/session-status.json"
  echo https://github.com/example/repo/pull/7 >"$BEAD_LOOP_STATE/repo/inflight/t-1"; : >"$BEAD_LOOP_STATE/repo/inflight/.t-1.red"
  jq '. + [{id:"t-5", title:"Parked one", description:"p", status:"in_progress", priority:2, labels:["delegate:local"], notes:"someone: a human note\nbead-loop 2026-09-18T17:05+00:00: stages exhausted after REJECT: x.ts:1 wrong"}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  # t-5 as the loop parks a bead now: the rounds record with a round's log, and the
  # parked record — the reason, the brief's question and its brief.
  mkdir -p "$R/logs" "$R/parked"; printf 'boom: 1 of 2 tests failed\n' >"$R/logs/t-5.20260918T170000.gate"
  printf '{"round":1,"model":"stub/worker","stage":1,"when":"2026-09-18T17:00+00:00","note":"gate failed twice: npm test\\nboom: 1 of 2 tests failed","logs":["t-5.20260918T170000.gate"]}\n{"round":2,"model":"stub/worker","stage":1,"when":"2026-09-18T17:05+00:00","note":"review (stub/reviewer) rejected:\\nREJECT: x.ts:1 wrong","logs":[]}\n' >"$R/failures/t-5.rounds.jsonl"
  echo 2 >"$R/failures/t-5"
  mkdir -p "$R/parked"; printf '{"when":"2026-09-18T17:05+00:00","reason":"exhausted","failures":2,"stage":{"index":1,"worker":"stub/worker","reviewer":"stub/reviewer"},"stopped_on":"review (stub/reviewer) rejected:\\nREJECT: x.ts:1 wrong","question":"Does x.ts:1 have to print the total, or only the count? The bead says both.","brief":"WHAT HAPPENED:\\nround 1 broke a test.\\nWHY:\\nthe bead asks for two things.","brief_model":"stub/worker"}\n' >"$R/parked/t-5"
  # t-8: a decision — a question for the human, type decision (a needs-human label does the same).
  jq '. + [{id:"t-8", title:"Which ntfy topic?", description:"The loop can post to ntfy. Which topic, and for which events?", status:"open", priority:1, issue_type:"decision", labels:[]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  # t-9: landed by the loop an hour ago, one send-back on the way; a session log for its round.
  jq '. + [{id:"t-9", title:"Landed one", description:"l", status:"closed", priority:2, labels:["delegate:local"], started_at:((now-7200)|todate), closed_at:((now-3600)|todate),
          close_reason:"bead-loop: https://github.com/example/repo/pull/3 merged; checks at merge: ci=SUCCESS",
          notes:("bead-loop round 1 (stub/worker) " + ((now-5400)|strftime("%Y-%m-%dT%H:%M+00:00")) + ": gate failed twice: make")}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  mkdir -p "$R/logs"; printf '{"a":1}\n{"b":2}\n' >"$R/logs/t-9.$(date -d @$(($(date +%s) - 7000)) +%Y%m%dT%H%M%S).worker.jsonl"; : >"$R/logs/t-9.$(date -d @$(($(date +%s) - 300)) +%Y%m%dT%H%M%S).worker.jsonl"
  st=$(sup stats "$REPO")
  assert_match "$st" "24h  landed 1 (first try 0%, without Claude 100%)  rounds/landed 2.0  time to land 1h00  send-backs 1" "stats: the landing, its rounds and its hour"
  assert_match "$st" "empty rounds 1" "stats: the session the server never answered"
  assert_match "$st" "send-backs by reason: gate 1" "stats: why the round went back"
  assert_eq "$(sup --json stats "$REPO" | jq -r '.windows["7d"].landed_by["stub/worker"], .windows["7d"].model_time.worker_rounds, .finished[0].id, .finished[0].how, .finished[0].rounds' | tr '\n' ' ')" "1 1 t-9 landed 2 " "stats --json: by model, the rounds, the finished list"
  j=$(sup --json status "$REPO")
  assert_eq "$(printf '%s' "$j" | jq -r '.slug, .attach, .lanes.dev.id, (.queues.dev | map(.id) | join(",")), (.queues.review[0].title), (.queues.merge[0].red), (.parked | map(.id) | join(","))' | tr '\n' ' ')" \
    "repo http://oc.test:4096 t-6 t-2,t-3,t-7 Fourth true t-5 " "bd's beads laid into the queues, the lanes and parked"
  assert_eq "$(printf '%s' "$j" | jq -r '.decisions | map("\(.id):\(.title)") | join(" ")')" "t-8:Which ntfy topic?" "decisions: the open decision beads, with the question"
  assert_eq "$(printf '%s' "$j" | jq -r '.queues.dev | map(.id) | index("t-8") // "absent"')" absent "a decision is not work for the lanes"
  assert_eq "$(printf '%s' "$j" | jq -r '.worktrees[0] | "\(.id) \(.failures) \(.sessions[0].state) \(.sessions[0].model) \(.sessions[0].url)"')" \
    "t-1 2 orphan slow/m http://oc.test:4096/$(printf '%s' "$wt" | base64 -w0 | tr '+/' '-_' | tr -d '=')/session/ses_rev" "worktree with its session from the server"
  assert_match "$(sup status "$REPO")" "dev lane:    t-6 Sixth" "text status names the lane's bead"
  command -v node >/dev/null || { echo "  (no node: ui server not exercised)"; return; }
  # The UI server: the page, the state it reads, and the two guards on its levers.
  port=$((20000 + RANDOM % 20000))
  mkdir -p "$T/gpu"; echo game >"$T/gpu/mode"; echo auto >"$T/gpu/by"
  GPU_MODE_STATE=$T/gpu BEAD_LOOP_UI_PORT=$port BEAD_SUPERVISOR=$SUP node "$HERE/../bin/bead-loop-ui" >"$T/ui.log" 2>&1 & upid=$!
  for _ in $(seq 50); do "$REAL_CURL" -sf -m 1 "http://127.0.0.1:$port/api/state" >"$T/state.json" 2>/dev/null && break; sleep 0.1; done
  # The scoreboard comes a moment later: computed off the request path, pushed when done.
  for _ in $(seq 100); do "$REAL_CURL" -sf -m 2 "http://127.0.0.1:$port/api/state" >"$T/state.json" 2>/dev/null && jq -e '.stats.windows' "$T/state.json" >/dev/null 2>&1 && break; sleep 0.2; done
  assert_eq "$(jq -r '.stats.windows["24h"].landed' "$T/state.json")" 1 "/api/state carries the scoreboard"
  assert_eq "$(jq -r '.repos[0].slug, (.repos[0].worktrees[0].sessions[0].state), (.repos[0].queues.dev[0].id), (.error // "none")' "$T/state.json" | tr '\n' ' ')" "repo orphan t-2 none " "/api/state carries the supervisor's JSON"
  assert_match "$("$REAL_CURL" -s -m 3 "http://127.0.0.1:$port/")" "<title>bead-loop</title>" "the page"
  assert_eq "$(jq -r '.gpu | "\(.available) \(.mode) \(.by)"' "$T/state.json")" "true game auto" "gpu-mode read from its state dir"
  # The page rendered against that state: the Claude column lists t-7 (dev queue, on the
  # claude/opus stage) and where it sits, and nothing else.
  html=$(render_page "$T/state.json")
  node --check "$T/page.js" 2>/dev/null && ok || bad "the page's script parses"
  # The scoreboard card: the tiles from the 7d window (the default), the landing listed.
  score=$(printf '%s' "$html" | tr '\n' ' ' | grep -o '<section class="card" id="score">.*' | cut -c1-6000)
  assert_match "$score" '<div class="label">Landed</div><div class="value ">1<small>' "the Landed tile"
  assert_match "$score" '<div class="label">Without Claude</div><div class="value ">100%</div>' "the Without Claude tile"
  assert_match "$score" '<span class="k">gate</span><span class="bar" title="1 of 1">' "where rounds go back"
  assert_match "$score" 'class="id">t-9</td>.*<span class="chip ok">landed</span>.*<td class="num">2</td><td class="mono muted fit">stub/worker</td><td class="num">1h00</td>' "the finished row: rounds, who landed it, how long"
  assert_match "$score" '<button class="cur" onclick="setWin(.7d.)">7d</button>' "the window picker, 7d by default"
  # The decision under Needs you: the question, its text in full, and the answer box.
  assert_match "$(printf '%s' "$html" | grep -o '<h3 class="human">Needs you<span class="n">[0-9]*</span>')" '<span class="n">2</span>' "Needs you counts the decision with the parked bead"
  dec=$(printf '%s' "$html" | tr '\n' ' ' | grep -o '<table class="decisions">.*' | cut -c1-1200)
  assert_match "$dec" 'class="id">t-8</td><td class="title"><b>Which ntfy topic?</b>' "the decision, first"
  assert_match "$dec" 'Which topic, and for which events?' "with its text in full"
  assert_match "$dec" "onclick=\"act('decide',{repo:" "and the Answer &amp; close lever"
  assert_match "$(printf '%s' "$html" | grep -o '<div class="q claude">.*' | cut -c1-400)" '<h3>Claude<span class="n">1</span></h3>' "the Claude column, with its count"
  assert_match "$(printf '%s' "$html" | grep -o '<div class="q claude">.*' | cut -c1-600)" 'class="id">t-7</td>.*dev queue #3' "t-7 in it, with where it sits"
  assert_match "$(printf '%s' "$html" | grep -o '<div class="q dev">.*' | cut -c1-3000)" 'title="sent back to dev 2 times">2×</span> <button class="hist" onclick="toggleHist(.t-7.)"[^>]*>▸ 2 rounds</button>' "t-7's round history behind a toggle, closed"
  assert_eq "$(printf '%s' "$html" | grep -c 'pre class="hist"')" 0 "no history listed until opened"
  # The parked bead under Needs you: the question first, the reason, the brief and the
  # bead's notes folded, the rounds behind their toggle; opened, each round with its note
  # and its log to open in place.
  hum=$(printf '%s' "$html" | tr '\n' ' ' | grep -o '<h3 class="human">.*' | cut -c1-4000)
  assert_match "$hum" 'class="id">t-5</td>.*<span class="chip bad" title="every stage has had its failures">exhausted</span>' "the reason as the chip"
  assert_match "$hum" '<div class="ask"><div class="head">The question<span class="muted">parked 2026-09-18 17:05 · stopped on stage 1 (stub/worker) · brief by stub/worker</span></div><pre class="text">Does x.ts:1 have to print the total, or only the count? The bead says both.</pre></div>' "the question, first, with when and who asked"
  assert_match "$hum" '<button class="hist" onclick="toggleFold(&quot;brief:t-5&quot;)">▸ what happened, and why</button>' "the brief folded"
  assert_match "$hum" 'toggleFold(&quot;notes:t-5&quot;)">▸ the bead&#39;s notes</button>' "the notes folded"
  assert_eq "$(printf '%s' "$hum" | grep -c 'WHAT HAPPENED')" 0 "closed: the brief not shown"
  opened=$(render_page "$T/state.json" "toggleHist('t-5'); toggleFold('brief:t-5')" | tr '\n' ' ' | grep -o '<h3 class="human">.*' | cut -c1-6000)
  assert_match "$opened" '<div class="round"><div class="head">round 1 <span class="chip worker">stub/worker</span><span class="muted">stage 1</span><span class="muted">2026-09-18 17:00</span></div><pre class="note">gate failed twice: npm test boom: 1 of 2 tests failed</pre><div class="logs">logs: <button class="link " onclick="toggleLog(&quot;'"$REPO"'&quot;,&quot;t-5.20260918T170000.gate&quot;)" title="t-5.20260918T170000.gate">▸ gate</button></div></div>' "round 1: who, when, the note in full, its gate log to open"
  assert_match "$opened" '<div class="round"><div class="head">round 2 .*<pre class="note">review (stub/reviewer) rejected: REJECT: x.ts:1 wrong</pre></div>' "round 2, no logs"
  assert_match "$opened" '<pre class="text">WHAT HAPPENED: round 1 broke a test. WHY: the bead asks for two things.</pre>' "the brief, opened"
  assert_match "$(printf '%s' "$html" | grep -o '<div class="q dev">.*' | cut -c1-3000)" 'onclick="toggleHist(.t-7.)"' "a queue row has the same toggle"
  # A note to a bead in a queue, from its row: the lever, the box under the row once
  # opened, and the action — an operator note on the bead, nothing else moved.
  assert_match "$(printf '%s' "$html" | grep -o '<div class="q dev">.*' | cut -c1-3000)" 'onclick="toggleNote(&quot;t-2&quot;)" title="a note on the bead; its next round reads it">✎ note</button>' "each queue row offers a note"
  assert_eq "$(printf '%s' "$html" | grep -c 'id="note-t-2"')" 0 "no box until opened"
  assert_match "$(render_page "$T/state.json" "toggleNote('t-2')" | tr '\n' ' ' | grep -o '<div class="q dev">.*' | cut -c1-4000)" '<textarea id="note-t-2" rows="2" placeholder="Context it lacked.*<button  onclick="act(.note.,{repo:' "opened: the box and Add note under the row"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-2\",\"text\":\"the flag is --dry-run, see lib/x.ts:9\"}" "http://127.0.0.1:$port/api/note")" '"noted":"t-2"' "note from the page"
  assert_match "$(jq -r '.[]|select(.id=="t-2")|.notes' "$BD_STATE/issues.json")" "^operator 20[0-9-]*T[0-9:]*+00:00: the flag is --dry-run, see lib/x.ts:9$" "an operator note on the bead, dated as answer's are"
  assert_eq "$(jq -r '.[]|select(.id=="t-2")|.status' "$BD_STATE/issues.json")" open "nothing else moved"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-2\",\"text\":\" \"}" "http://127.0.0.1:$port/api/note")" "write the note first" "an empty note is refused"
  # A round's log, from the server: by its name under the repo's logs dir, nothing else.
  assert_eq "$("$REAL_CURL" -s -m 3 "http://127.0.0.1:$port/api/log?repo=$REPO&file=t-5.20260918T170000.gate")" "boom: 1 of 2 tests failed" "/api/log serves the file"
  assert_match "$("$REAL_CURL" -s -m 3 "http://127.0.0.1:$port/api/log?repo=$REPO&file=../failures/t-5")" "bad log name" "no path, only a name"
  assert_match "$("$REAL_CURL" -s -m 3 "http://127.0.0.1:$port/api/log?repo=/nope&file=t-5.20260918T170000.gate")" "unknown repo" "only a configured repo's"
  assert_match "$("$REAL_CURL" -s -m 3 "http://127.0.0.1:$port/api/log?repo=$REPO&file=t-9.none")" "no such log" "a name that is not there"
  # The supervisor log with systemd's own lines in it: hidden by default, the box unchecked.
  jq '.log = [{t: now, msg: "Starting bead-supervisor.service - the bead loop..."}, {t: now, msg: "03:50:01 repo: dev: bead t-2 to stub/worker"}, {t: now, msg: "Finished bead-supervisor.service - the bead loop."}]' "$T/state.json" >"$T/state-log.json"
  log=$(render_page "$T/state-log.json" | grep -o '<section class="card"><h3 class="log">.*')
  assert_match "$log" '<input type="checkbox"  onchange="setSys(this.checked)">systemd lines</label>' "the systemd lines box, unchecked"
  assert_match "$log" '<span class="pick">repo: dev: bead t-2 to stub/worker</span>' "the loop's line shown"
  assert_eq "$(printf '%s' "$log" | grep -c 'class="sys"')" 0 "systemd's lines hidden"
  # The stream's first event comes at once; -m 1 is only so curl lets go of the socket.
  assert_match "$(timeout 3 "$REAL_CURL" -sN -m 1 "http://127.0.0.1:$port/api/events" | head -1)" '^data: {"now":[0-9]*,"repos":\[{"slug":"repo"' "the event stream opens with the state"
  # Every button the page renders for this state must be a button: the onclick parses as JS.
  node "$HERE/ui-onclicks.js" "$T/state.json" >"$T/onclicks.txt" 2>&1 && ok || bad "onclick attributes: $(tail -3 "$T/onclicks.txt" | tr '\n' ' ')"
  # The second page gets the last state replayed at once, with a fresh now in front: still one JSON object.
  assert_eq "$(timeout 3 "$REAL_CURL" -sN -m 1 "http://127.0.0.1:$port/api/events" | head -1 | sed 's/^data: //' | jq -r '.repos[0].slug, (.now | type)' | tr '\n' ' ')" "repo number " "the replayed state is valid JSON"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d '{"name":"review","paused":true}' "http://127.0.0.1:$port/api/lane")" '"paused":true' "pause a lane from the page"
  assert_file "$BEAD_LOOP_STATE/pause.review" "the marker the lane checks"
  assert_eq "$("$REAL_CURL" -sf -m 3 "http://127.0.0.1:$port/api/state" | jq -r '.repos[0].paused.review')" true "state says so"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'sec-fetch-site: cross-site' "http://127.0.0.1:$port/api/wake")" "same-origin only" "cross-site lever refused"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\"}" "http://127.0.0.1:$port/api/priority")" "\"priority\":\"$REPO\"" "priority repo from the page"
  assert_eq "$("$REAL_CURL" -sf -m 3 "http://127.0.0.1:$port/api/state" | jq -r '.repos[0].priority')" true "state says so"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d '{"repo":"/nope"}' "http://127.0.0.1:$port/api/priority")" "unknown repo" "priority only for a configured repo"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-1\"}" "http://127.0.0.1:$port/api/reopen")" "in the merge queue" "reopen refused on a bead under a PR"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d '{"attach":"http://elsewhere","session":"s"}' "http://127.0.0.1:$port/api/abort")" "unknown server" "abort only against a configured server"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d '{"repo":"/nope","id":"t-5"}' "http://127.0.0.1:$port/api/reopen")" "unknown repo" "reopen only in a configured repo"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-5\"}" "http://127.0.0.1:$port/api/escalate")" '"escalated":"t-5"' "work with Claude from the page"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-5")" 2 "on the last stage"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-5\",\"text\":\"use the other flag\"}" "http://127.0.0.1:$port/api/answer")" '"answered":"t-5"' "answer from the page"
  assert_match "$(jq -r '.[]|select(.id=="t-5")|.notes' "$BD_STATE/issues.json")" "operator .*: use the other flag" "the answer on the bead"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-5\"}" "http://127.0.0.1:$port/api/reopen")" '"reopened":"t-5"' "reopen runs bd"
  assert_eq "$(jq -r '.[]|select(.id=="t-5")|.status' "$BD_STATE/issues.json")" open "the bead is open again"
  # The decision answered from the page: closed with the answer as the reason.
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-5\",\"text\":\"x\"}" "http://127.0.0.1:$port/api/decide")" "not an open decision" "decide only on a decision bead"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-8\",\"text\":\"\"}" "http://127.0.0.1:$port/api/decide")" "write the decision first" "an empty answer is refused"
  assert_match "$("$REAL_CURL" -s -m 3 -X POST -H 'content-type: application/json' -d "{\"repo\":\"$REPO\",\"id\":\"t-8\",\"text\":\"the bead-loop topic, for Needs you only\"}" "http://127.0.0.1:$port/api/decide")" '"decided":"t-8"' "answered from the page"
  assert_eq "$(jq -r '.[]|select(.id=="t-8")|"\(.status) \(.close_reason)"' "$BD_STATE/issues.json")" "closed decided: the bead-loop topic, for Needs you only" "closed with the answer as the reason"
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
  setup true auto stub/reviewer 'max_inflight = 1'; mkdir -p "$BEAD_LOOP_STATE/repo/inflight"; echo https://github.com/example/repo/pull/9 >"$BEAD_LOOP_STATE/repo/inflight/t-9"
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
case_review_lane_waits_for_dev_to_claim() {
  # At a tick's start the dev lane spends a moment picking before it claims; the review
  # lane, finding its queue empty and no lane marker yet, must not conclude the tick is
  # over. It leaves only after the dev lane has looked idle three checks in a row.
  setup; echo 0.3 >"$TEST_CTRL/slow-ready"
  LANE_WAIT=0.2 sup tick
  assert_eq "$(calls)" "bead-worker bead-reviewer" "review waited, then took the bead"
  ! grep -q 'going round again' "$T/sup.log" && ok || bad "no second round needed"
  # A hand-run review lane holding its lock when the tick starts: the tick's review lane
  # skips, dev fills the review queue and leaves; the tick notices work is still queued
  # and runs the lanes again rather than leave it for later.
  setup; echo 0.3 >"$TEST_CTRL/slow-ready"; mkdir -p "$BEAD_LOOP_STATE"
  ( exec 8>"$BEAD_LOOP_STATE/lock.review"; flock 8; sleep 0.5 ) &
  sleep 0.1; LANE_WAIT=0.1 sup tick; wait
  assert_eq "$(calls)" "bead-worker bead-reviewer" "reviewed within the same tick"
  assert_match "$(cat "$T/sup.log")" "another review lane holds .*lock.review; skipping" "the first review lane stood down"
  assert_match "$(cat "$T/sup.log")" "lanes done but work is queued; going round again" "the tick went round again"
  assert_branch bead/t-1 "and pushed"
}

case_escalate_to_the_last_stage() {
  # "Work with Claude": a parked bead goes to the last stage and back into the dev queue,
  # ahead of its failure count; the next round runs there.
  setup true auto '' "$(stages stub/fast::2 stub/slow::2 claude/opus:claude/opus:1)"; echo nocommit >"$TEST_CTRL/worker"
  sup --once tick; sup --once tick   # two failures: stage 1 spent, stage 2 next
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1")" 2 "two failures"
  sup escalate "$REPO" t-1
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1")" 4 "failure count set to the last stage's first value"
  assert_eq "$(bead .status)" open "back in the dev queue"
  assert_match "$(bead .notes)" "escalated by hand to the last stage (worker claude/opus, reviewer claude/opus)" "noted on the bead"
  assert_eq "$(sup --json status "$REPO" | jq -r '.queues.dev[0] | "\(.id) \(.failures) \(.stage.worker) \(.stage.index)"')" "t-1 4 claude/opus 3" "status shows it on the last stage"
  echo "done" >"$TEST_CTRL/worker"; sup --once tick
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls" | tail -1)" "claude/opus claude" "the next round runs in Claude Code"
  # A parked bead: escalate reopens it.
  setup true auto '' "$(stages stub/fast::1 stub/slow::1)"; echo nocommit >"$TEST_CTRL/worker"
  sup --once tick; sup --once tick; assert_eq "$(bead .status)" in_progress "parked after the stages"
  sup escalate "$REPO" t-1; assert_eq "$(bead .status)" open "escalate reopens a parked bead"
}

case_human_queue_answer_and_open() {
  # BLOCKED at the last stage parks the bead with the question; the answer goes on the
  # bead and sends it back to the dev queue at the same stage; the next round reads it.
  setup true auto '' "$(stages stub/fast::1)"; echo blocked >"$TEST_CTRL/worker"
  sup --once tick; assert_eq "$(bead .status)" in_progress "parked with the question"
  j=$(sup --json status "$REPO")
  assert_eq "$(printf '%s' "$j" | jq -r '.parked[0] | "\(.question) \(.parked.reason) \(.why.what[0:8])"')" "true blocked parked (" "status marks it a question, with the reason"
  assert_eq "$(printf '%s' "$j" | jq -r '.parked[0].parked.question')" "Is the flag called --dry-run (add it to the bead), or should the criterion go?" "the brief's question"
  assert_match "$(printf '%s' "$j" | jq -r '.parked[0].parked.brief')" "^WHAT HAPPENED:" "and its brief"
  assert_eq "$(printf '%s' "$j" | jq -r '.parked[0].history | length, .[0].round, (.[0].logs|length)' | tr '\n' ' ')" "1 1 1 " "the round, with its worker log"
  assert_match "$(printf '%s' "$j" | jq -r '.parked[0].notes')" "BLOCKED: lib/x.ts:3" "the bead's notes, whole"
  assert_eq "$(printf '%s' "$j" | jq -r '.parked[0].open_cmd')" "bead-supervisor open $REPO t-1" "and says how to open it"
  sup answer "$REPO" t-1 "the flag is called --dry-run, see lib/x.ts:9"
  assert_eq "$(bead .status)" open "answered: back in the dev queue"
  assert_nofile "$BEAD_LOOP_STATE/repo/parked/t-1" "answered: the question is closed"
  assert_match "$(bead .notes)" "operator .*: the flag is called --dry-run" "the answer on the bead"
  echo "done" >"$TEST_CTRL/worker"; sup --once tick
  assert_match "$(tr '\n' ' ' <"$TEST_CTRL/prompt.3")" "parked (BLOCKED at the last stage). Is the flag called --dry-run.*operator .*: the flag is called --dry-run" "the next round reads the question and the answer under it"
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | tail -1)" "stub/fast" "at the same stage, not escalated"
  # open: an interactive Claude Code session in the bead's worktree, the bead, the loop's
  # question and brief in the first prompt, on the branch a round left when there is one.
  setup true auto '' "$(stages stub/fast::1)"; echo blocked >"$TEST_CTRL/worker"; sup --once tick
  sup open "$REPO" t-1
  assert_eq "$(cat "$TEST_CTRL/opened")" "$BEAD_LOOP_STATE/repo/wt/t-1" "claude opened in the worktree"
  assert_match "$(cat "$TEST_CTRL/opened.prompt")" "branch bead/t-1" "on the bead's branch"
  assert_match "$(cat "$TEST_CTRL/opened.prompt")" "The automated loop parked it (blocked). Its question for the owner: Is the flag called --dry-run" "with the question"
  assert_match "$(cat "$TEST_CTRL/opened.prompt")" "The loop's brief of the rounds so far:" "and the brief"
  assert_match "$(cat "$TEST_CTRL/opened.prompt")" "title: Do the thing" "and the bead"
  assert_eq "$(git -C "$BEAD_LOOP_STATE/repo/wt/t-1" rev-parse --abbrev-ref HEAD)" bead/t-1 "the worktree is on the branch"
}

case_brief_falls_back_to_the_loops_question() {
  # The brief is one model call; without it — no model (brief_model = "none"), a model
  # that answers out of shape, a harness that dies, Claude signed out — the loop's own
  # question stands: the BLOCKED line, and what the owner can do about it.
  setup true auto '' "$(echo 'brief_model = "none"'; stages stub/fast::1)"; echo blocked >"$TEST_CTRL/worker"; sup --once tick
  assert_eq "$(calls)" "bead-worker" "no brief model: no call"
  assert_eq "$(jq -r '.question' "$BEAD_LOOP_STATE/repo/parked/t-1")" "The last stage (stub/fast) stopped: BLOCKED: lib/x.ts:3 has no such flag — Answer what it needs to know, fix the bead's text if a claim in it is false, or take it yourself." "the loop's question"
  assert_eq "$(jq -r '.brief, .brief_model' "$BEAD_LOOP_STATE/repo/parked/t-1" | tr '\n' ' ')" "null null " "no brief"
  assert_match "$(bead .notes)" "parked (BLOCKED at the last stage). The last stage (stub/fast) stopped: BLOCKED: lib/x.ts:3" "on the bead"
  setup true auto '' "$(echo 'brief_model = "stub/senior"'; stages stub/fast::1)"; echo blocked >"$TEST_CTRL/worker"; echo plain >"$TEST_CTRL/brief"; sup --once tick
  assert_eq "$(sed -n 2p "$TEST_CTRL/calls" | cut -d' ' -f1,3)" "bead-briefer stub/senior" "brief_model names who briefs"
  assert_match "$(jq -r '.question' "$BEAD_LOOP_STATE/repo/parked/t-1")" "^The last stage (stub/fast) stopped: BLOCKED:" "out of shape: the loop's question"
  assert_eq "$(jq -r '.brief' "$BEAD_LOOP_STATE/repo/parked/t-1")" "I read the rounds; it looks like the flag is missing." "what the model said is kept as the brief"
  setup true auto '' "$(stages stub/fast::1)"; echo blocked >"$TEST_CTRL/worker"; echo crash >"$TEST_CTRL/brief"; sup --once tick
  assert_eq "$(bead .status)" in_progress "the brief dying does not unpark the bead"
  assert_match "$(jq -r '.question' "$BEAD_LOOP_STATE/repo/parked/t-1")" "^The last stage (stub/fast) stopped: BLOCKED:" "harness down: the loop's question"
  assert_match "$(grep 'brief did not come' "$T/sup.log")" "stub/fast exited 7" "said in the log"
  # A Claude brief needs Claude signed in; signed out, the loop's question stands and the
  # bead is parked all the same — nothing waits on the brief.
  setup true auto '' "$(echo 'brief_model = "claude/opus"'; stages stub/fast::1)"; echo blocked >"$TEST_CTRL/worker"; touch "$TEST_CTRL/claude-signed-out"; sup --once tick
  assert_eq "$(calls)" "bead-worker" "Claude signed out: no brief call"
  assert_match "$(grep 'no brief' "$T/sup.log")" "claude/opus cannot run now" "said in the log"
  assert_match "$(jq -r '.question' "$BEAD_LOOP_STATE/repo/parked/t-1")" "^The last stage (stub/fast) stopped: BLOCKED:" "the loop's question"
  rm "$TEST_CTRL/claude-signed-out"; sup answer "$REPO" t-1 "try again"; sup --once tick
  assert_eq "$(sed -n 3p "$TEST_CTRL/calls" | cut -d' ' -f1,3)" "bead-briefer claude/opus" "signed in: Claude Code writes the brief, read-only"
  assert_match "$(cat "$TEST_CTRL/system.3")" "You write the brief a bead's owner reads" "with the briefer's agent body as its system prompt"
  assert_eq "$(jq -r '.question' "$BEAD_LOOP_STATE/repo/parked/t-1")" "Is the flag called --dry-run, or should the criterion go?" "Claude's brief"
}

case_claude_signed_out_beads_wait() {
  # A claude/* round while Claude is signed out would die in seconds and cost a failure for
  # nothing: the lane leaves such a bead in its queue and takes the next one; escalate
  # refuses; status says so; signing in (the file gone) lets it run.
  setup true auto '' "$(printf 'max_inflight = 3\n%s' "$(stages stub/fast::1 claude/opus:claude/opus:1)")"; echo nocommit >"$TEST_CTRL/worker"
  : >"$TEST_CTRL/claude-signed-out"
  sup --once tick   # t-1 fails on stub/fast: 1 failure, next round is Claude's — and Claude is signed out
  rc=0; sup escalate "$REPO" t-1 || rc=$?; assert_eq "$rc" 1 "escalate refused while signed out"
  : >"$TEST_CTRL/calls"; sup --once tick
  assert_eq "$(calls)" "" "t-1 left in the queue, no round run"
  assert_match "$(cat "$T/sup.log")" "dev: 1 bead(s) wait for Claude — it is signed out" "said so"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1")" 1 "t-1 not charged a failure"
  assert_eq "$(sup --json status "$REPO" | jq -r '.claude_ok, (.queues.dev | map(.id) | join(" "))' | tr '\n' ' ')" "false t-1 " "status: claude_ok false; t-1 still queued"
  # Another bead can still be worked meanwhile.
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  echo "done" >"$TEST_CTRL/worker"; : >"$TEST_CTRL/calls"; sup --once tick
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | head -1)" "stub/fast" "the lane took t-2 on stub/fast"
  assert_match "$(cat "$TEST_CTRL/prompt.1")" "id: t-2" "t-2 was the one worked"
  rm "$TEST_CTRL/claude-signed-out"; : >"$TEST_CTRL/calls"; sup --once tick
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls" | head -1)" "claude/opus claude" "signed in: t-1's Claude round runs"
}

case_conflicting_pr_rebased_by_the_last_stage() {
  # GitHub says our PR conflicts with the base: no failure, back to the dev queue on its
  # branch, and that round's worker is the last stage's (Claude), told to rebase; the push
  # updates the same PR and the merge queue has it again.
  setup true auto stub/reviewer "$(printf 'max_inflight = 3\n%s' "$(stages stub/fast:stub/reviewer:2 claude/sonnet:claude/sonnet:1)")"
  sup work "$REPO"; assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "PR up"
  jq '.mergeable="CONFLICTING"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"
  sup reconcile "$REPO"
  assert_eq "$(bead .status)" open "back in the dev queue"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/t-1" "out of the merge queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure charged"
  assert_match "$(bead .notes)" "conflicts with main; back to dev for a rebase by the last stage" "noted"
  assert_match "$(cat "$T/sup.log")" "conflicts with main → dev queue for a rebase" "logged"
  jq '.mergeable="MERGEABLE"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"
  : >"$TEST_CTRL/calls"; printf 'approve\napprove\n' >"$TEST_CTRL/review"; sup work "$REPO"
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls" | head -1)" "claude/sonnet claude" "the rebase round runs on the last stage's worker"
  assert_match "$(cat "$TEST_CTRL/prompt.1")" "Your job this round is the rebase, not new work. Run: git fetch origin && git rebase origin/main" "with the rebase order"
  assert_match "$(cat "$T/sup.log")" "dev: bead t-1 .*rebase)" "the round says it is a rebase"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "back in the merge queue"
  assert_nofile "$BEAD_LOOP_STATE/repo/inflight/.t-1.conflict" "conflict marker cleared"
  assert_match "$(bead .comments | tr '\n' ' ')" "pushed round 1 to https://github.com/example/repo/pull/7" "the same PR, updated"
  # conflict_worker names who rebases; an adopted PR that conflicts is left alone.
  setup true auto stub/reviewer "$(printf 'max_inflight = 3\nconflict_worker = "stub/senior"\n%s' "$(stages stub/fast:stub/reviewer:2)")"
  sup work "$REPO"; jq '.mergeable="CONFLICTING"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"; sup reconcile "$REPO"
  jq '.mergeable="MERGEABLE"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"
  : >"$TEST_CTRL/calls"; printf 'approve\napprove\n' >"$TEST_CTRL/review"; sup work "$REPO"
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | head -1)" "stub/senior" "conflict_worker does the rebase"
}

# ---- the state machine's exits (docs/state-machine.md) ------------------------------------
case_git_refusing_the_worktree_holds() {
  # The bead's branch is checked out in a worktree nobody pruned (a hand test run left
  # one): git refuses the lane's worktree add. That is the world's doing, not the bead's
  # — held, no failure, the supervisor alive for the next bead — and once the obstacle is
  # gone the next pass works it. (Before: git_must died, and the whole loop with it.)
  setup; git -C "$REPO" worktree add -q "$T/elsewhere" -b bead/t-1 origin/main
  rc=0; sup --once tick || rc=$?
  assert_eq "$rc" 0 "the supervisor lives"
  assert_eq "$(calls)" "" "no model ran"
  assert_eq "$(bead .status)" open "still in the dev queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure charged"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "cannot make the worktree: git worktree add .* fatal: 'bead/t-1' is already used by worktree at '$T/elsewhere'" "held, with git's words"
  assert_match "$(bead .notes)" "held, no failure charged: cannot make the worktree" "noted"
  assert_nofile "$BEAD_LOOP_STATE/repo/lane.dev" "the lane is free"
  git -C "$REPO" worktree remove --force "$T/elsewhere" && git -C "$REPO" branch -D bead/t-1 -q
  BEAD_LOOP_HOLD_BACKOFF=0 sup --once tick
  assert_eq "$(calls)" "bead-worker bead-reviewer" "the obstacle gone: worked on the next pass"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "to a PR"
  assert_eq "$(grep -c 'cannot make the worktree' "$BEAD_LOOP_STATE/repo/held/t-1" 2>/dev/null || true)" 0 "that hold is gone (the watcher's own, on the stub PR's missing checks, is another)"
}

case_setup_failure_is_held() {
  # Setup runs on a fresh worktree of the base, so it failing is the environment's fault,
  # not the bead's: no failure, the bead stays in the dev queue held with the reason; the
  # pick skips it while the hold is young and takes it again once it has aged.
  setup true auto stub/reviewer 'setup = "false"'; sup --once tick
  assert_eq "$(calls)" "" "no model ran"
  assert_eq "$(bead .status)" open "still in the dev queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure charged"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "setup failed: false" "held, with the reason"
  assert_match "$(bead .notes)" "held, no failure charged: setup failed: false" "noted"
  assert_match "$(cat "$T/sup.log")" "t-1: held: setup failed: false" "logged"
  assert_eq "$(sup --json status "$REPO" | jq -r '.held[0] | "\(.id) \(.where)"')" "t-1 dev" "status lists it as held, in dev"
  assert_match "$(sup status "$REPO")" "held (waiting on you or the world" "text status too"
  : >"$T/sup.log"; sup --once tick; assert_match "$(cat "$T/sup.log")" "dev: nothing ready" "skipped while the hold is young"
  sed -i 's/^setup = .*/setup = "true"/' "$REPO/.bead-loop.toml"
  BEAD_LOOP_HOLD_BACKOFF=0 sup --once tick
  assert_eq "$(calls)" "bead-worker bead-reviewer" "aged and the world fixed: worked"
  assert_eq "$(grep -c 'setup failed' "$BEAD_LOOP_STATE/repo/held/t-1" 2>/dev/null || true)" 0 "the setup hold is released (the stub PR's no-checks hold may follow)"
}
case_harness_down_is_held() {
  # The model harness exits with nothing said — its server is down: not the model's
  # failure. The bead stays where it was (dev queue; review queue) with no failure, and
  # the round runs once the hold has aged.
  setup; echo crash >"$TEST_CTRL/worker"; sup --once tick
  assert_eq "$(bead .status)" open "back in the dev queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "worker stub/worker exited 7 with no output" "held with the reason"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "connection refused" "and the harness's last words"
  assert_nobranch bead/t-1 "nothing pushed"
  echo "done" >"$TEST_CTRL/worker"; : >"$TEST_CTRL/calls"; BEAD_LOOP_HOLD_BACKOFF=0 sup --once tick
  assert_eq "$(calls)" "bead-worker bead-reviewer" "server back: worked"
  # A timeout is the model's own: it ran for the whole budget and said nothing useful.
  setup true auto '' "$(stages stub/fast::1:1)"; echo hang >"$TEST_CTRL/worker"; sup --once tick
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1")" 1 "a timeout is still a failure"
  # The reviewer's server down: the bead stays in the review queue, no failure.
  setup; printf 'crash\napprove\n' >"$TEST_CTRL/review"; sup work "$REPO"
  assert_file "$BEAD_LOOP_STATE/repo/review/t-1" "stays in the review queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "reviewer stub/reviewer exited 7 with no output" "held"
  assert_eq "$(sup --json status "$REPO" | jq -r '.held[0].where')" review "status: held in review"
  BEAD_LOOP_HOLD_BACKOFF=0 sup --once lane review
  assert_eq "$(calls)" "bead-worker bead-reviewer bead-reviewer" "reviewed once the hold aged"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "and pushed to a PR"
}
case_recover_reopens_an_interrupted_round() {
  # A dev round the last stop cut short: the bead is in_progress with a worktree and in no
  # queue. recover (what run does first) puts it back in the dev queue with no failure and
  # clears the stale lane marker. A parked bead — no worktree — is left alone.
  setup; R=$BEAD_LOOP_STATE/repo; mkdir -p "$R/wt"; echo t-1 >"$R/lane.dev"
  git -C "$REPO" fetch -q origin main; git -C "$REPO" worktree add -q -b bead/t-1 "$R/wt/t-1" origin/main
  jq '.[0].status="in_progress"' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup recover "$REPO"
  assert_eq "$(bead .status)" open "reopened"
  assert_nofile "$R/lane.dev" "stale lane marker cleared"
  assert_match "$(bead .notes)" "round interrupted by a stop; back in the dev queue, no failure charged" "noted"
  assert_match "$(cat "$T/sup.log")" "stale lane.dev from a stop; cleared" "logged"
  assert_eq "$(cat "$R/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure"
  sup --once tick; assert_eq "$(calls)" "bead-worker bead-reviewer" "then worked, resuming the branch"
  setup; jq '.[0].status="in_progress"' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup recover "$REPO"; assert_eq "$(bead .status)" in_progress "a parked bead stays parked"
}
case_merge_queue_holds() {
  # Every way a PR can sit in the merge queue with nothing the loop can do: held with the
  # reason, in the human list, still polled, released the moment it moves.
  # pipeline: green for longer than a pipeline takes, and not merged.
  setup true pipeline; sup work "$REPO"; set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_nofile "$BEAD_LOOP_STATE/repo/held/t-1" "green just now: not held"
  touch -d '-40 minutes' "$BEAD_LOOP_STATE/repo/inflight/.t-1.green"; sup reconcile "$REPO"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "green for [0-9]* min and the pipeline has not merged it" "held"
  assert_match "$(bead .notes)" "waiting on you: .*the pipeline has not merged it" "noted once"
  assert_eq "$(sup --json status "$REPO" | jq -r '.held[0].where, .queues.merge[0].held.why' | head -1)" merge "status: held, in merge"
  sup reconcile "$REPO"; assert_eq "$(grep -c 'waiting on you' <<<"$(bead .notes)")" 1 "a second pass does not note it again"
  jq '.state="MERGED"' "$TEST_CTRL/pr.json" >"$TEST_CTRL/pr.tmp" && mv "$TEST_CTRL/pr.tmp" "$TEST_CTRL/pr.json"; sup reconcile "$REPO"
  assert_eq "$(bead .status)" closed "merged: closed"; assert_nofile "$BEAD_LOOP_STATE/repo/held/t-1" "released at the merge"
  # CI pending for hours: held, still polled; green later closes it.
  setup; sup work "$REPO"; set_checks '[{"context":"ci","state":"PENDING"}]'
  touch -d '-3 hours' "$BEAD_LOOP_STATE/repo/inflight/t-1"; sup reconcile "$REPO"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "pending for 3 h" "held"
  set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"; assert_eq "$(bead .status)" closed "green later: closed"
  # manual: green is yours to merge.
  setup true manual; sup work "$REPO"; set_checks '[{"context":"ci","state":"SUCCESS"}]'; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "manual: green stays open"
  assert_eq "$(bead .status)" in_progress "manual: bead waits for you"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "yours to merge" "held for you"
  # auto: GitHub refuses the merge (branch protection) — held, not retried into the void.
  setup; sup work "$REPO"; set_checks '[{"context":"ci","state":"SUCCESS"}]'; touch "$TEST_CTRL/merge-refused"; sup reconcile "$REPO"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "GitHub refuses the merge (CLEAN)" "held"
  assert_eq "$(bead .status)" in_progress "waits"
  rm "$TEST_CTRL/merge-refused"; sup reconcile "$REPO"; assert_eq "$(bead .status)" closed "protection lifted: merged"
  # no checks reported: not merged, noted, held (the human list too).
  setup; sup work "$REPO"; sup reconcile "$REPO"
  assert_eq "$(jq -r .state "$TEST_CTRL/pr.json")" OPEN "no checks: not merged"
  assert_match "$(bead .notes)" "no CI checks" "noted"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "reports no CI checks" "held"
}
case_one_place_invariant() {
  # A bead in the merge queue is not reopened under its PR: answer and escalate refuse,
  # and a bead reopened by hand while in review or merge is not handed to the dev lane.
  setup true auto stub/reviewer "$(stages stub/fast::1 claude/opus::1)"; sup work "$REPO"
  rc=0; sup answer "$REPO" t-1 "x" 2>>"$T/sup.log" || rc=$?; assert_eq "$rc" 1 "answer refused"
  rc=0; sup escalate "$REPO" t-1 2>>"$T/sup.log" || rc=$?; assert_eq "$rc" 1 "escalate refused"
  assert_match "$(cat "$T/sup.log")" "t-1 is in the merge queue at https://github.com/example/repo/pull/7" "and says why"
  assert_eq "$(bead .status)" in_progress "left where it is"
  bd update t-1 --status open   # by hand
  : >"$TEST_CTRL/calls"; sup --once tick; assert_eq "$(calls)" "" "in the merge queue: not handed to dev whatever bd says"
  assert_eq "$(sup --json status "$REPO" | jq -r '.queues.dev | length')" 0 "and not in the dev queue on the page"
}
case_priority_repo() {
  setup; sup priority "$REPO"
  assert_eq "$(sup --json status "$REPO" | jq -r .priority)" true "status says so"
  assert_match "$(sup status "$REPO")" "\[priority\]" "text status too"
  assert_eq "$(cat "$BEAD_LOOP_STATE/priority")" "$(cd "$REPO" && pwd -P)" "the marker holds the repo"
  sup priority none; assert_eq "$(sup --json status "$REPO" | jq -r .priority)" false "cleared"
}
case_run_is_resident() {
  # run: the loop stays; a lane with nothing to do blocks on the bell; a bead that appears
  # is worked as soon as the bell rings; TERM ends it with 143.
  setup; jq '.[0].labels=[]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  setsid "$SUP" run 2>>"$T/sup.log" & pid=$!
  for _ in $(seq 50); do grep -q 'dev: nothing ready' "$T/sup.log" 2>/dev/null && break; sleep 0.1; done
  assert_eq "$(calls)" "" "nothing to do: nothing ran"
  assert_match "$(cat "$T/sup.log")" "bead-loop resident" "said so"
  assert_match "$(cat "$T/sup.log")" "dev: nothing ready with label" "the dev lane looked and is blocked on the bell"
  jq '.[0].labels=["delegate:local"]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  "$SUP" wake 2>>"$T/sup.log"
  for _ in $(seq 100); do grep -q '^bead-reviewer' "$TEST_CTRL/calls" 2>/dev/null && [ -e "$BEAD_LOOP_STATE/repo/inflight/t-1" ] && break; sleep 0.1; done
  assert_eq "$(calls)" "bead-worker bead-reviewer" "worked as soon as the bell rang"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "to a PR"
  kill -TERM -- -"$pid"; rc=0; wait "$pid" || rc=$?
  assert_eq "$rc" 143 "exits 143 on TERM"
}

case_claude_lane_waits_on_no_local_model() {
  # A stage that names claude/* gets a lane of its own: a bead on the Claude stage is not
  # behind the GPU's queue. t-1 is on the Claude stage (one failure spent), t-2 is fresh
  # on the stub; the dev lane takes t-2 and leaves t-1 to the claude lane, which carries
  # it through its worker and its reviewer round. Both reach a PR in one tick.
  setup true auto stub/reviewer "$(stages stub/fast:stub/reviewer:1 claude/opus:claude/opus:1)"; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  mkdir -p "$BEAD_LOOP_STATE/repo/failures"; echo 1 >"$BEAD_LOOP_STATE/repo/failures/t-1"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  LANE_WAIT=0.2 sup tick
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "the Claude bead reached its PR"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-2" "the stub bead too"
  assert_eq "$(grep -c ' claude/opus claude$' "$TEST_CTRL/calls")" 2 "Claude implemented and reviewed t-1"
  assert_match "$(grep 'claude/opus claude' "$TEST_CTRL/calls" | head -1)" "wt/t-1 " "in t-1's worktree"
  assert_eq "$(grep -c ' stub/' "$TEST_CTRL/calls")" 2 "the stub pair did t-2"
  assert_nofile "$BEAD_LOOP_STATE/repo/lane.claude" "claude lane clear at the end"
  # --once, serial: the dev lane passes the Claude bead by; the claude lane takes it, and
  # keeps its rounds together (worker, then its Claude reviewer) — as the old dev+review
  # pair did in one --once tick.
  setup true auto stub/reviewer "$(stages stub/fast:stub/reviewer:1 claude/opus:claude/opus:1)"; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  mkdir -p "$BEAD_LOOP_STATE/repo/failures"; echo 1 >"$BEAD_LOOP_STATE/repo/failures/t-1"
  sup --once tick
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls" | tr '\n' '|')" "claude/opus claude|claude/opus claude|" "worker then reviewer, both Claude's"
  assert_match "$(cat "$T/sup.log")" "dev: nothing ready with label" "the dev lane had nothing of its own"
  # Pause the claude lane alone: the Claude bead waits, the stub bead is worked.
  setup true auto stub/reviewer "$(stages stub/fast:stub/reviewer:1 claude/opus:claude/opus:1)"; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  mkdir -p "$BEAD_LOOP_STATE/repo/failures"; echo 1 >"$BEAD_LOOP_STATE/repo/failures/t-1"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup pause claude; sup --serial tick
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | sort -u | tr '\n' ' ')" "stub/fast stub/reviewer " "only the stub pair ran"
  assert_match "$(cat "$T/sup.log")" "claude lane paused; starting nothing" "said so"
  assert_match "$(sup status "$REPO")" "claude lane: idle  \[paused\]" "status shows the third lane"
  assert_eq "$(sup --json status "$REPO" | jq -r '.paused.claude, (.queues.dev | map(.id) | join(" "))' | tr '\n' ' ')" "true t-1 " "json too; t-1 still queued"
  sup resume claude; : >"$TEST_CTRL/calls"; sup --serial tick
  assert_eq "$(grep -c ' claude/opus claude$' "$TEST_CTRL/calls")" 2 "resumed: the Claude bead went through"
}
case_claude_sign_in_expiring_is_held() {
  # Claude Code's sign-in expires mid-run: it answers with a JSON error, no token spent,
  # exit 1 — the harness, not the model. The bead is held with Claude's words, no failure
  # charged, and the next pick asks `claude auth status` again instead of trusting the
  # minute-old answer.
  setup true auto '' "$(stages claude/opus::1)"; : >"$TEST_CTRL/claude-api-error"
  sup --once tick
  assert_eq "$(bead .status)" open "back in the dev queue"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/failures/t-1" 2>/dev/null || echo 0)" 0 "no failure charged"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "worker claude/opus exited 1 with no output" "held"
  assert_match "$(cat "$BEAD_LOOP_STATE/repo/held/t-1")" "OAuth session expired" "with Claude's own words"
  assert_match "$(cat "$T/sup.log")" "claude did nothing: Failed to authenticate" "logged"
  rm "$TEST_CTRL/claude-api-error"; : >"$TEST_CTRL/calls"; BEAD_LOOP_HOLD_BACKOFF=0 sup --once tick
  assert_eq "$(cut -d' ' -f3,4 "$TEST_CTRL/calls" | head -1)" "claude/opus claude" "signed in again: the round runs"
  assert_branch bead/t-1 "and lands"
}

case_lanes_from_toml() {
  # [[lanes]] in the global config: a lane per model server, each taking the worker and
  # reviewer rounds of its models. t-1 is on the slow stage (one failure spent), t-2 on
  # the fast one; both lanes work at once and each carries its bead to the PR itself.
  setup true auto stub/fast "$(stages stub/fast:stub/fast:1 stub/slow:stub/slow:1)"; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  printf '[[lanes]]\nname = "fast"\nmodels = ["stub/fast"]\n[[lanes]]\nname = "slow"\nmodels = ["stub/slow"]\n' >>"$BEAD_LOOP_CONFIG/config.toml"
  mkdir -p "$BEAD_LOOP_STATE/repo/failures"; echo 1 >"$BEAD_LOOP_STATE/repo/failures/t-1"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  LANE_WAIT=0.2 sup tick
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-1" "the slow lane carried t-1 to its PR"
  assert_file "$BEAD_LOOP_STATE/repo/inflight/t-2" "the fast lane carried t-2 to its PR"
  assert_eq "$(grep -c ' stub/slow ' "$TEST_CTRL/calls")" 2 "t-1: worker and reviewer on stub/slow"
  assert_eq "$(grep -c ' stub/fast ' "$TEST_CTRL/calls")" 2 "t-2: worker and reviewer on stub/fast"
  assert_match "$(grep ' stub/slow ' "$TEST_CTRL/calls" | head -1)" "wt/t-1 " "the slow rounds were t-1's"
  assert_nofile "$BEAD_LOOP_STATE/repo/lane.fast" "fast lane clear"; assert_nofile "$BEAD_LOOP_STATE/repo/lane.slow" "slow lane clear"
  assert_match "$(sup status "$REPO")" "fast lane: *idle" "status names the configured lanes"
  assert_eq "$(sup --json status "$REPO" | jq -r '.lane_names | join(" ")')" "fast slow" "json lists them"
  # Pause one configured lane: its bead waits, the other lane's bead goes through.
  setup true auto stub/fast "$(stages stub/fast:stub/fast:1 stub/slow:stub/slow:1)"; printf 'approve\napprove\n' >"$TEST_CTRL/review"
  printf '[[lanes]]\nname = "fast"\nmodels = ["stub/fast"]\n[[lanes]]\nname = "slow"\nmodels = ["stub/slow"]\n' >>"$BEAD_LOOP_CONFIG/config.toml"
  mkdir -p "$BEAD_LOOP_STATE/repo/failures"; echo 1 >"$BEAD_LOOP_STATE/repo/failures/t-1"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  sup pause slow; sup --serial tick
  assert_eq "$(cut -d' ' -f3 "$TEST_CTRL/calls" | sort -u | tr '\n' ' ')" "stub/fast " "only the fast lane's rounds ran"
  assert_match "$(cat "$T/sup.log")" "slow lane paused; starting nothing" "said so"
  assert_eq "$(sup --json status "$REPO" | jq -r '.paused.slow, (.queues.dev | map(.id) | join(" "))' | tr '\n' ' ')" "true t-1 " "json: paused; t-1 still queued"
  rc=0; sup pause gpu 2>>"$T/sup.log" || rc=$?; assert_eq "$rc" 1 "a lane the config does not name is refused"
  sup resume slow; : >"$TEST_CTRL/calls"; sup --serial tick
  assert_eq "$(grep -c ' stub/slow ' "$TEST_CTRL/calls")" 2 "resumed: t-1 went through on the slow lane"
  # Mid-round, each lane's marker carries its own name and its bead: status shows both
  # lanes busy, and nothing is written under the default pair's names — two rounds in
  # one repo sharing lane.dev left the second to erase the first, and the page reading
  # only the configured names showed every lane idle while both models were working.
  setup true auto stub/fast "$(stages stub/fast:stub/fast:1 stub/slow:stub/slow:1)"; echo hang >"$TEST_CTRL/worker"
  printf '[[lanes]]\nname = "fast"\nmodels = ["stub/fast"]\n[[lanes]]\nname = "slow"\nmodels = ["stub/slow"]\n' >>"$BEAD_LOOP_CONFIG/config.toml"
  mkdir -p "$BEAD_LOOP_STATE/repo/failures"; echo 1 >"$BEAD_LOOP_STATE/repo/failures/t-1"
  jq '. + [{id:"t-2", title:"Second", description:"y", status:"open", priority:3, labels:["delegate:local"]}]' "$BD_STATE/issues.json" >"$BD_STATE/i.tmp" && mv "$BD_STATE/i.tmp" "$BD_STATE/issues.json"
  setsid "$SUP" tick 2>>"$T/sup.log" & pid=$!
  for _ in $(seq 100); do [ "$(grep -c '^bead-worker' "$TEST_CTRL/calls" 2>/dev/null)" = 2 ] && break; sleep 0.1; done
  sleep 0.2
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/lane.slow" 2>/dev/null)" t-1 "the slow lane's marker names its bead"
  assert_eq "$(cat "$BEAD_LOOP_STATE/repo/lane.fast" 2>/dev/null)" t-2 "the fast lane's marker names its bead"
  assert_nofile "$BEAD_LOOP_STATE/repo/lane.dev" "nothing under the default pair's name"
  out=$(sup status "$REPO")
  assert_match "$out" "slow lane:   *t-1 " "status: the slow lane is on t-1"
  assert_match "$out" "fast lane:   *t-2 " "status: the fast lane is on t-2"
  assert_eq "$(sup --json status "$REPO" | jq -r '(.queues.dev | length), (.parked | length)' | tr '\n' ' ')" "0 0 " "json: neither bead is queued or parked while on a lane"
  kill -TERM -- -"$pid"; wait "$pid" 2>/dev/null || true
}

# ---- main ----------------------------------------------------------------------------
# A command that exits non-zero outside an assertion (the supervisor dying, a stub
# erroring) aborts the run under set -e with no FAIL line: say where, and show the
# supervisor's last words, so a CI log names the cause. An EXIT trap, not ERR: ERR
# would fire inside every $(...) whose command legitimately returns non-zero.
DONE=
trap 'if [ -z "$DONE" ]; then printf "\n  ABORT in %s (exit %s); the supervisor'"'"'s last lines:\n" "${CASE:-?}" "$?"; tail -n 15 "${T:-/nonexistent}/sup.log" 2>/dev/null | sed "s/^/    /"; fi' EXIT
cases=$(declare -F | awk '{print $3}' | grep '^case_')
[ $# -gt 0 ] && cases=$(printf 'case_%s\n' "$@")
jobs=${JOBS:-$(nproc 2>/dev/null || echo 4)}
if [ "$jobs" -gt 1 ] && [ "$(printf '%s\n' "$cases" | wc -l)" -gt 1 ]; then
  # Side by side: this script once per case, each into its own file, then the outputs in
  # the cases' order — the case's line, its FAIL lines, its count — summed up here. A
  # case that died outside an assertion (set -e) has no count line and is a failure; its
  # own ABORT lines are in its file.
  out=$(mktemp -d); DONE=1; trap 'rm -rf "$out"' EXIT
  printf '%s\n' "$cases" | sed 's/^case_//' \
    | xargs -P "$jobs" -I{} bash -c 'JOBS=1 "$1" "$2" >"$3/$2.out" 2>&1 || true' _ "$HERE/run.sh" {} "$out"
  for CASE in $cases; do
    f=$out/${CASE#case_}.out
    if grep -q ' passed, .* failed$' "$f"; then
      grep -v ' passed, .* failed$' "$f" | grep -v '^$'
      read -r p _ n _ < <(tail -1 "$f"); PASS=$((PASS + p)); FAIL=$((FAIL + n))
    else
      cat "$f"; printf '  FAIL %s: died without a count\n' "$CASE"; FAIL=$((FAIL + 1))
    fi
  done
else
  for CASE in $cases; do
    t0=$(date +%s%N); "$CASE"
    printf '%-48s %5d ms\n' "$CASE" "$(( ($(date +%s%N) - t0) / 1000000 ))"
    [ -n "${KEEP:-}" ] || rm -rf "$T"
  done
  DONE=1
fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
