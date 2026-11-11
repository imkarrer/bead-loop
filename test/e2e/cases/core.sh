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
  assert_match "$(cat "$(STATE)/loop.log" 2>/dev/null)" "info repo: $BEAD: pr_merged" "the loop's own log has the bead's moves"
  assert_match "$(cat "$(STATE)/loop.log" 2>/dev/null)" "info repo: $BEAD: committed" "a result taken at start names its repo too"
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


# Under pipeline the loop puts the merge label on the PR it opens, and CI's merge step
# merges it; a green PR waiting for that is not an event a tick (#242 sat unlabelled,
# logging checks_green 55 times).
case_pipeline_labels_its_pr() {
  MERGE=pipeline setup 'test -e work.txt'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_opened 60 || bad "no PR: $(events)"
  assert_eq "$(jq -r '[.[0].labels[].name] | join(",")' "$E2E_CTRL/gh/prs.json")" automerge "the PR's labels"
  tick 3
  assert_eq "$(events | tr ' ' '\n' | grep -c checks_green)" 0 "green looks logged"
  # CI's merge step merges it; the loop sees the merge and closes the bead.
  jq '.[0].state = "MERGED"' "$E2E_CTRL/gh/prs.json" >"$E2E_CTRL/gh/prs.tmp" && mv "$E2E_CTRL/gh/prs.tmp" "$E2E_CTRL/gh/prs.json"
  until_event pr_merged 30 || bad "the merge was not seen: $(events)"
  assert_eq "$(bd_field status)" closed "bd status"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pr merge" "the loop merging a pipeline PR itself"
}

# A researcher's BLOCK about code it never read is no brief: the worker goes, and lands
# it (bl-dze.6 parked on "no `lane_wait` function" from a researcher that read nothing).
case_unread_research_block_is_no_brief() {
  GLOBAL_EXTRA=$'research = "first"\nresearch_model = "fake/researcher"' setup 'test -e work.txt'
  reply researcher '{"content":"{\"outcome\":\"blocked\",\"files\":\"\",\"shape\":\"\",\"check\":\"\",\"pitfalls\":\"\",\"line\":\"BLOCKED: work.txt has no such thing\"}"}'
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event committed 90 || bad "the worker never ran: $(events)"
  assert_match "$(events)" "research_picked brief_written picked" "research, then the worker"
  assert_nomatch "$(events)" "research_blocked" "a BLOCK from nothing read"
}

# A researcher that read the code and found a false claim still blocks, and its second
# opinion is asked.
case_read_research_block_stands() {
  GLOBAL_EXTRA=$'research = "first"\nresearch_model = "fake/researcher"' setup 'test -e work.txt'
  local blocked='{"content":"{\"outcome\":\"blocked\",\"files\":\"\",\"shape\":\"\",\"check\":\"\",\"pitfalls\":\"\",\"line\":\"BLOCKED: README:1 says base, not work\"}"}'
  reply researcher '{"tool":"read_file","args":{"path":"README"}}' "$blocked" \
    '{"tool":"read_file","args":{"path":"README"}}' "$blocked"
  until_place parked 90 || bad "not parked: $(events)"
  assert_match "$(events)" "research_blocked research_picked research_blocked" "the BLOCK and its second opinion"
}

# A `stage:NAME` label in bd starts the bead on that stage: here the Claude stage, with
# no round on the local model first (bl-lkb's stage:frontier beads queued for devbox).
case_stage_label_starts_there() {
  STAGES="$(stage local fake/coder fake/reviewer 2)"$'\n'"$(stage frontier claude/sonnet claude/sonnet 1)" setup 'test -e work.txt'
  (cd "$REPO" && bd label add "$BEAD" stage:frontier >/dev/null)
  claude_reply 001 --arg b "$BEAD" '{sh:("echo done > work.txt && git add -A && git commit -qm \""+$b+": work\""), result:"{\"outcome\":\"done\",\"summary\":\"ok\"}"}'
  claude_reply 002 '{result:"{\"decision\":\"Approve\",\"reason\":\"ok\",\"work_order\":null}"}'
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_match "$(events)" "^stage_labelled picked" "the label, then the round"
  [ -e "$E2E_CTRL/claude/argv-001" ] && ok || bad "no Claude round"
  [ -z "$(ls "$E2E_CTRL"/requests 2>/dev/null)" ] && ok || bad "a round on the local model"
}

# A usage limit holds the provider until the reset Claude states, not a fixed half hour:
# one whose reset has passed is tried again on the next tick, and the bead lands (the
# bl-lkb beads met a limit that reset at 00:40 and waited to 01:06).
case_usage_limit_ends_at_its_reset() {
  STAGES=$(stage frontier claude/sonnet claude/sonnet 1) setup 'test -e work.txt'
  local passed
  passed=$(date -u -d '-2 min' '+%-I:%M%P')
  claude_reply 001 --arg r "$passed" '{exit:1, stderr:("You'"'"'ve hit your session limit · resets "+$r+" (UTC)")}'
  claude_reply 002 --arg b "$BEAD" '{sh:("echo done > work.txt && git add -A && git commit -qm \""+$b+": work\""), result:"{\"outcome\":\"done\",\"summary\":\"ok\"}"}'
  claude_reply 003 '{result:"{\"decision\":\"Approve\",\"reason\":\"ok\",\"work_order\":null}"}'
  until_event infra 60 || bad "no hold: $(events)"
  assert_match "$(jq -r 'select(.kind=="infra") | .words' "$(STATE)/beads/$BEAD/events.jsonl")" "usage limit on claude" "the hold's words"
  until_event pr_merged 45 || bad "still held after its reset: $(events)"
  assert_eq "$(bd_field status)" closed "bd status"
}
