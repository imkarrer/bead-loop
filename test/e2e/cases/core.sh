# shellcheck shell=bash
# The core path: one bead from ready to closed, and each seam this week's bugs crossed
# (the Claude stage's tools, bd's status, the gate's environment, Harmony replies, the
# levers). Sourced by test/e2e/run.sh, which names a case by its function.

# One bead from ready to closed: a round on a local model, the gate, a review, the PR,
# the merge, and every move on the bead in bd.
case_lands() {
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" "events"
  assert_eq "$(bd_field status)" closed "bd status"
  assert_nomatch "$(bd_field labels)" "loop:" "a loop label left on a closed bead"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr create --head bead/$BEAD --base main" "the PR"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr merge bead/$BEAD --squash" "the merge"
}

# While a round runs, bd says so: in_progress, and a label naming where it is.
case_bd_follows_the_round() {
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  echo '{"status":500,"error":"down"}' >"$E2E_CTRL/replies/reviewer.last"
  until_event review_picked 60 || bad "never reviewed: $(events)"
  assert_eq "$(bd_field status)" in_progress "bd status in review"
  assert_match "$(bd_field labels)" "loop:" "a loop label in review"
}

# The Claude stage: the worker gets tools that edit, the reviewer tools that only read,
# both allowed inside the worktree alone (pw-xl2 ran with --tools "" and parked).
case_claude_stage() {
  STAGES=$(stage frontier claude/sonnet claude/sonnet 1) setup 'test -e work.txt'
  claude_reply 001 --arg b "$BEAD" '{sh:("echo done > work.txt && git add -A && git commit -qm \""+$b+": work\""), result:"{\"outcome\":\"done\",\"summary\":\"ok\"}"}'
  claude_reply 002 '{result:"{\"decision\":\"Approve\",\"reason\":\"ok\",\"work_order\":null}"}'
  until_event pr_merged 90 || bad "never merged: $(events)"
  local worker reviewer
  worker=$(cat "$E2E_CTRL/claude/argv-001" 2>/dev/null)
  reviewer=$(cat "$E2E_CTRL/claude/argv-002" 2>/dev/null)
  assert_match "$worker" "^Read,Edit,Write,Glob,Grep,Bash$" "the worker's tools"
  assert_match "$worker" "allowedTools=Read(./\*\*),Edit" "the worker's allow-list"
  assert_match "$reviewer" "^Read,Glob,Grep$" "the reviewer's tools"
  assert_nomatch "$reviewer" "Bash" "a shell for the reviewer"
}

# A Claude CLI that fails leaves what it said where the bead's history shows it.
case_claude_failure_is_kept() {
  STAGES=$(stage frontier claude/sonnet claude/sonnet 1) setup
  claude_reply 001 '{exit:1, stderr:"Credit balance is too low"}'
  until_event worker_crashed 60 || until_event infra 5 || bad "no outcome: $(events)"
  assert_match "$(jq -c . "$(STATE)/beads/$BEAD/events.jsonl")" "Credit balance is too low" "the CLI's words"
}

# The confinement is the model's file tools'. The gate and the commands a round runs are
# the repo's own (#240: bead-loop's own tests ran confined and failed in every round).
case_gate_runs_unconfined() {
  setup 'test -e work.txt && test -z "${BEAD_LOOP_WORKTREE:-}"'
  reply coder "$(write_work)" \
    '{"tool":"run","args":{"command":"echo wt=[${BEAD_LOOP_WORKTREE:-}]"}}' \
    "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event review_picked 60 || bad "the gate failed: $(events)"
  local said
  said=$(jq -r '.messages[] | select(.role=="tool") | .content' "$E2E_CTRL"/requests/*.json | grep 'wt=' || true)
  assert_match "$said" "wt=\[\]" "the command tool's environment"
}

# The file tools stay in the worktree: a path outside it is refused, and nothing is written.
case_file_tools_confined() {
  setup 'test -e work.txt'
  reply coder "{\"tool\":\"write_file\",\"args\":{\"path\":\"$T/escaped.txt\",\"content\":\"x\"}}" \
    "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event committed 60 || bad "no commit: $(events)"
  local said
  said=$(jq -r '.messages[] | select(.role=="tool") | .content' "$E2E_CTRL"/requests/*.json | head -3)
  assert_match "$said" "outside the worktree" "the refusal"
  [ ! -e "$T/escaped.txt" ] && ok || bad "a file written outside the worktree"
}

# gpt-oss on llama-server can stop in its analysis channel, tags and all. BAML asks again
# with that reply in the history, and the server's chat template refuses a tagged history
# with a 500 (#237: web-2ad.4's review was held on it). The loop strips the tags, so the
# second answer is read.
case_harmony_reply_is_read() {
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer '{"content":"<|channel|>analysis<|message|>The file is there; approve.<|end|>"}' "$(approve)"
  until_event approved 60 && ok || bad "the review was not read: $(events)"
}

# A gate that stays red on the last attempt parks the bead, and bd says it is blocked.
case_red_gate_parks() {
  setup 'false'
  reply coder "$(write_work)" "$(commit)"
  done_report >"$E2E_CTRL/replies/coder.last"
  until_event gate_failed_twice 90 || bad "no gate failure: $(events)"
  tick 2
  assert_eq "$(view_bead .place)" parked "the page's place"
  assert_eq "$(bd_field status)" blocked "bd status"
  assert_match "$(bd_field labels)" "loop:parked" "bd label"
}

# A REJECT is a work order: the next round's prompt carries it, and the bead lands.
case_reject_then_approve() {
  STAGES=$(stage local fake/coder fake/reviewer 2) setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)" \
    '{"tool":"run","args":{"command":"echo more >> work.txt && git commit -qam more"}}' "$(done_report)"
  reply reviewer \
    '{"content":"{\"decision\":\"Reject\",\"reason\":\"thin\",\"work_order\":{\"what_is_wrong\":\"work.txt:1 is thin\",\"why_it_fails\":\"criterion 1\",\"what_to_do\":\"append the word XYZZY-ORDER\",\"how_to_check\":\"grep XYZZY work.txt\",\"leave_alone\":\"the rest\"}}"}' \
    "$(approve)"
  until_event pr_merged 120 || bad "never merged: $(events)"
  assert_match "$(events)" "rejected" "the REJECT"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "XYZZY-ORDER" "the work order in the next prompt"
}

# A model server that fails is a hold, not a charge against the bead.
case_server_down_is_a_hold() {
  setup 'test -e work.txt'
  echo '{"status":500,"error":"llama-server is loading"}' >"$E2E_CTRL/replies/coder.last"
  until_event infra 60 || bad "no hold: $(events)"
  tick 1
  assert_eq "$(view_bead .failures)" 0 "failures charged"
  assert_nomatch "$(bd_field status)" "blocked" "bd status"
}

# The page's two levers on a parked bead whose branch holds gated work: Ready for PR
# (`tell publish`) pushes it, then Open PR (`tell open_pr`) opens it with the title and
# body you gave. Each is mail the running loop carries out (#232, #234).
case_ready_for_pr_then_open_pr() {
  setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer '{"content":"{\"decision\":\"Reject\",\"reason\":\"needs a person\",\"work_order\":{\"what_is_wrong\":\"x\",\"why_it_fails\":\"y\",\"what_to_do\":\"z\",\"how_to_check\":\"w\",\"leave_alone\":\"v\"}}"}'
  until_place parked 90 || bad "not parked: $(events)"
  assert_eq "$(view_bead .has_work)" true "the page offers Ready for PR"
  tell publish
  until_event branch_pushed 30 || bad "not pushed: $(events)"
  git -C "$E2E_ORIGIN" show-ref -q "refs/heads/bead/$BEAD" && ok || bad "no branch on origin"
  tell open_pr --title "Hand-picked title" --text "The body you wrote"
  until_event pr_opened 30 || bad "no PR: $(events)"
  assert_eq "$(jq -r '.[0].title' "$E2E_CTRL/gh/prs.json")" "Hand-picked title" "the PR's title"
  assert_eq "$(jq -r '.[0].body' "$E2E_CTRL/gh/prs.json")" "The body you wrote" "the PR's body"
}

