# shellcheck shell=bash
# Infrastructure holds (docs/state-machine.md: "infrastructure is never the bead's
# failure") and a round whose process is gone with no result. Ported from the Rust
# suite (`git show 8907dfa:test/run.sh`), minus one case the BAML loop has no code path
# for:
#
#   case_stop_charges_no_failure: the Rust loop ran a worker inside a long-lived
#   supervisor process attached to a model session, and a SIGTERM raced a signal
#   thread against the session's abort to tell "cut short by the stop" apart from a
#   genuine client failure. The BAML loop has no such session or signal thread: a round
#   is its own detached process, `KillMode=process` leaves it running when the
#   supervisor stops (docs/operating.md, "Stop, restart, recover"; invariant 4 in
#   docs/state-machine.md), and the next tick — whether before or after a restart —
#   reads its result normally. There is nothing for a stop to race, so the case has no
#   analogue. The nearest real risk, a round whose process is gone outright (the host
#   restarted, something killed it), is `case_recover_reopens_an_interrupted_round`
#   below.

# kill_tree PID: SIGKILL pid and everything under it. A round is `sh -c '... timeout
# ... round'`, and GNU timeout puts the command it times in its own process group, so
# killing the wrapper alone leaves the round running orphaned, racing the resumed round
# for the same scripted replies.
kill_tree() {
  local pid=$1 kid
  for kid in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$kid"
  done
  kill -9 "$pid" 2>/dev/null || true
}

# git refusing a worktree it cannot make (a hand test run left one behind) is the
# world's doing, not the bead's: held, no failure, nothing asked of a model. Once the
# obstacle is gone the hold clears and the round runs.
case_git_refusing_the_worktree_holds() {
  setup 'test -e work.txt'
  git -C "$REPO" worktree add -q "$T/elsewhere" -b "bead/$BEAD" origin/main
  tick 1
  assert_eq "$(events)" "picked infra" "held, no round"
  assert_eq "$(view_bead .failures)" 0 "no failure charged"
  assert_match "$(view_bead .why)" "already used by worktree" "held, with git's words"
  assert_eq "$(ls "$E2E_CTRL/requests" 2>/dev/null | wc -l)" 0 "no model asked"
  git -C "$REPO" worktree remove --force "$T/elsewhere" && git -C "$REPO" branch -D "bead/$BEAD" -q
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tick 6
  until_event pr_merged 90 || bad "never merged once the obstacle was gone: $(events)"
  assert_eq "$(bd_field status)" closed "bd status"
}

# Setup runs in a fresh worktree before the first round; it failing is the
# environment's fault, not the bead's: held with the reason, no model asked, no
# failure. Fixed, the next round runs.
case_setup_failure_is_held() {
  setup 'test -e work.txt'
  echo 'setup = "false"' >>"$REPO/.bead-loop.toml"
  tick 1
  assert_eq "$(events)" "picked infra" "held, no round"
  assert_eq "$(view_bead .failures)" 0 "no failure charged"
  assert_match "$(view_bead .why)" "setup failed" "held, with the reason"
  assert_eq "$(ls "$E2E_CTRL/requests" 2>/dev/null | wc -l)" 0 "no model asked"
  sed -i 's/^setup = .*/setup = "true"/' "$REPO/.bead-loop.toml"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tick 6
  until_event pr_merged 90 || bad "never merged once setup was fixed: $(events)"
  assert_eq "$(bd_field status)" closed "bd status"
}

# A round the supervisor itself did not stop, but whose process is simply gone (the box
# came back up, something else killed it): recover finds no process for a bead it left
# Working, counts no failure, and keeps the branch for the round that resumes it.
case_recover_reopens_an_interrupted_round() {
  setup 'test -e work.txt'
  reply coder '{"tool":"run","args":{"command":"sleep 2"}}' "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tick 1
  local pid
  pid=$(cat "$(STATE)/rounds/$BEAD.pid" 2>/dev/null || echo "")
  [ -n "$pid" ] || bad "no round pid after the pick"
  sleep 0.2
  kill_tree "$pid"
  until_event pr_merged 90 || bad "never merged after the interrupted round: $(events)"
  assert_eq "$(events)" "picked round_lost picked committed gate_passed review_picked approved pr_opened checks_green pr_merged" "events"
  assert_eq "$(bd_field status)" closed "bd status"
}
