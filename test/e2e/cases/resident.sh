# shellcheck shell=bash
# The resident loop and its lock. Ported from the Rust suite's cases of the same name
# (git show 8907dfa:test/run.sh), to what the BAML loop actually does.
#
# case_lock_skips is not ported: the Rust loop held a $BEAD_LOOP_STATE/lock file with
# flock, so a second process sharing its state dir found it held and skipped its tick
# cleanly. The BAML loop has no such file: main.baml's `run` keeps its Supervisors as an
# in-memory value for the life of one process, never written to disk for a second
# process to contend (design-baml-native.md, "Green threads ... No lock files"). There is
# nothing here to port.

# await_event KIND [SECONDS]: poll for KIND as the bead's newest event, without ticking —
# the loop under test is already running on its own, in the background.
await_event() {
  local want=$1 limit=${2:-60} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    events | grep -qw -- "$want" && return 0
    sleep 0.2
  done
  return 1
}

# run: the loop stays up on its own, one process for many ticks (main.baml's `run`, ticks
# unbounded). A bead with no label it is reading for is never worked; one that gets the
# label is worked on the loop's own next heartbeat, with nothing to prod it. TERM ends it
# with the shell's ordinary 143, there being no signal handling to do otherwise.
case_run_is_resident() {
  setup
  (cd "$REPO" && bd label remove "$BEAD" delegate:local >/dev/null)
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  setsid "$SUP" run --config_file "$REPO/.bead-loop.toml" >>"$T/sup.log" 2>>"$T/sup.log" &
  local pid=$!
  sleep 2
  assert_eq "$(events)" "" "nothing to do: nothing ran"
  (cd "$REPO" && bd label add "$BEAD" delegate:local >/dev/null)
  await_event pr_opened 60 || bad "never worked once labelled: $(events)"
  assert_eq "$(events)" "picked committed gate_passed review_picked approved pr_opened" "worked on the loop's own heartbeat"
  kill -TERM -- -"$pid"
  local rc=0
  wait "$pid" || rc=$?
  assert_eq "$rc" 143 "exits 143 on TERM"
}
