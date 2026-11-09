# shellcheck shell=bash
# A usage limit holds the provider that hit it, not just the bead. Ported from the Rust
# suite (`git show 8907dfa:test/run.sh`), minus two cases the BAML loop has no code path
# for:
#
#   case_claude_signed_out_beads_wait: the Rust loop asked `claude auth status` before
#   ever starting a round, and a lane whose provider failed that left its beads queued,
#   untried — no round, no failure. The BAML loop has no such pre-check (urls_of,
#   config.baml, only turns a provider's `probe` into its URL; nothing ever calls
#   `claude auth status` or looks at the answer). A signed-out Claude Code still starts a
#   round here, and the round fails the way any Claude CLI failure does — the usage-limit
#   cases below, and core.sh's case_claude_failure_is_kept, are what that looks like now.
#
#   case_provider_probe_down_beads_wait: same code path, for a `[providers.NAME] probe`
#   URL instead of Claude's. The Rust loop GET it before a round and held the lane, no
#   round attempted, on a failure. Nothing in the BAML loop makes that GET; a provider
#   whose server is actually down is only found out by trying a round on it and having it
#   fail, which core.sh's case_server_down_is_a_hold already covers.
#
# What is left: a usage limit's own words hold every claude/* round, not only the bead
# that hit it (round.baml's limit_hit, supervisor.baml's lane_free). core.sh's
# case_usage_limit_ends_at_its_reset is the one-bead half of this — one bead held and
# tried again at its stated reset; the cases below are the rest: another bead queued
# behind it, and the way that limit is read whether it is answered before a token is
# spent or well into a session's turns.

# A hard CLI failure before the model ever answers: no tokens spent, and Claude's own
# words are read from stderr alone (claude_said, claude.baml). A second bead on the same
# provider is left in its queue, untried, while the limit lasts (bl-boc.1: 330 holds a
# day, one per bead, on what was really one provider's limit).
case_usage_limit_holds_the_provider() {
  STAGES=$(stage frontier claude/sonnet claude/sonnet 1) setup 'test -e work.txt'
  local future second
  future=$(date -u -d '+10 min' '+%-I:%M%P')
  claude_reply 001 --arg r "$future" '{exit:1, stderr:("You'"'"'ve hit your weekly limit · resets "+$r+" (UTC)")}'
  until_event infra 60 || bad "no hold: $(events)"
  assert_match "$(jq -r 'select(.kind=="infra") | .words' "$(STATE)/beads/$BEAD/events.jsonl")" "usage limit on claude" "the hold's words"
  assert_eq "$(view_bead .failures)" 0 "no failure charged"
  second=$(cd "$REPO" && bd create "Second" -d "z" --acceptance "true" -l delegate:local --json | jq -r .id)
  tick 1
  assert_eq "$(jq -r --arg id "$second" '.beads[] | select(.id==$id) | .place' "$(STATE)/view.json")" dev "the second bead left in its queue"
  [ ! -e "$E2E_CTRL/claude/argv-002" ] && ok || bad "a round ran for the second bead while the provider is limited"
}

# The limit can land after a few turns, tokens already spent (bl-boc.5): claude_said
# reads the session's last words whether or not they ever parsed as a report, so a plain
# "You've hit your session limit" answer — no CLI exit at all — is still read as the
# provider's limit, not the round's own failure, and holds every other claude/* bead too.
case_usage_limit_mid_session() {
  STAGES=$(stage frontier claude/sonnet claude/sonnet 1) setup 'test -e work.txt'
  local future second
  future=$(date -u -d '+10 min' '+%-I:%M%P')
  claude_reply 001 --arg r "$future" '{result:("You'"'"'ve hit your session limit · resets "+$r+" (UTC)")}'
  until_event infra 60 || bad "no hold: $(events)"
  assert_match "$(jq -r 'select(.kind=="infra") | .words' "$(STATE)/beads/$BEAD/events.jsonl")" "hit your session limit" "held, with Claude's own words"
  assert_eq "$(view_bead .failures)" 0 "no failure charged"
  second=$(cd "$REPO" && bd create "Second" -d "z" --acceptance "true" -l delegate:local --json | jq -r .id)
  tick 1
  assert_eq "$(jq -r --arg id "$second" '.beads[] | select(.id==$id) | .place' "$(STATE)/view.json")" dev "the second bead left in its queue too"
  [ ! -e "$E2E_CTRL/claude/argv-002" ] && ok || bad "a round ran for the second bead while the provider is limited"
}

# The rest of Rust's case_usage_limit_holds_the_provider: once the stated reset has
# passed, not just the bead that hit the limit but everything that queued up behind it
# gets a round too.
case_usage_limit_ends_for_every_bead() {
  STAGES=$(stage frontier claude/sonnet claude/sonnet 1) setup 'test -e work.txt'
  local now second start
  now=$(date -u +%s)
  claude_reply 001 --arg r "$now" '{exit:1, stderr:("usage limit reached|"+$r)}'
  until_event infra 60 || bad "no hold: $(events)"
  second=$(cd "$REPO" && bd create "Second" -d "z" --acceptance "true" -l delegate:local --json | jq -r .id)
  claude_reply 002 '{result:"{\"outcome\":\"done\",\"summary\":\"ok\"}"}'
  claude_reply 003 '{result:"{\"outcome\":\"done\",\"summary\":\"ok\"}"}'
  start=$SECONDS
  while [ $((SECONDS - start)) -lt 90 ] && [ ! -e "$E2E_CTRL/claude/argv-003" ]; do
    tick 1
  done
  [ -e "$E2E_CTRL/claude/argv-002" ] && ok || bad "the held bead's round never ran once the reset passed"
  [ -e "$E2E_CTRL/claude/argv-003" ] && ok || bad "the queued second bead's round never ran either"
}
