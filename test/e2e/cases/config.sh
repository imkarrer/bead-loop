# shellcheck shell=bash
# A config file that does not parse. The BAML loop once read one as an empty table, so a
# repo ran with merge = "auto", no gate and no setup, and a broken global file left no
# stages, so every pick parked. Now such a repo gets no supervisor at all, and its own
# STATE/loop.log says why (main.baml's start_all, config.baml's toml_problem). The Rust
# suite's case_config_layers checked the same: bad TOML stops the loop.

config_loop_log() { cat "$(STATE)/loop.log" 2>/dev/null; }

# The repo's .bead-loop.toml does not parse: nothing is picked, bd is untouched, and the
# loop's log names the file.
case_repo_config_that_does_not_parse_runs_nothing() {
  setup 'test -e work.txt'
  printf 'merge = "auto\n' >>"$REPO/.bead-loop.toml"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tick 3
  assert_eq "$(events)" "" "nothing picked"
  assert_eq "$(bd_field status)" open "bd untouched"
  assert_match "$(config_loop_log)" "error .*\.bead-loop\.toml does not parse, so the loop leaves" "the loop's log says why"
}

# The global config.toml does not parse: the same, for every repo it would have served.
case_global_config_that_does_not_parse_runs_nothing() {
  setup 'test -e work.txt'
  printf 'on_exhaust = "park\n' >>"$HOME/.config/bead-loop/config.toml"
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  tick 3
  assert_eq "$(events)" "" "nothing picked"
  assert_eq "$(bd_field status)" open "bd untouched"
  assert_match "$(config_loop_log)" "error .*config\.toml does not parse, so the loop leaves" "the loop's log says why"
}

# primer names a file in the repo: it reaches the worker's prompt, wrapped in its own tag.
case_primer_reaches_the_worker() {
  setup 'test -e work.txt'
  (
    cd "$REPO" || exit
    echo "MARKER-REPO-NOTE" >NOTES.md
    printf 'primer = "NOTES.md"\n' >>.bead-loop.toml
    git add -A && git commit -qm notes && git push -q
  )
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "<repo-notes>" "the primer is wrapped in its tag"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "MARKER-REPO-NOTE" "the primer's text reaches the worker"
}

# AGENTS.md reaches the worker when no primer is set: it is the default primer file.
case_agents_file_is_the_default_primer() {
  setup 'test -e work.txt'
  (
    cd "$REPO" || exit
    echo "MARKER-AGENTS-NOTE" >AGENTS.md
    # No primer line in .bead-loop.toml, so AGENTS.md is used as the default primer
    git add -A && git commit -qm agents && git push -q
  )
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_event pr_merged 90 || bad "never merged: $(events)"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "<repo-notes>" "the primer is wrapped in its tag"
  assert_match "$(cat "$E2E_CTRL"/requests/*.json)" "MARKER-AGENTS-NOTE" "the primer's text reaches the worker"
}

# The fixer runs before the gate: a fixer command is configured, and the gate checks for a file it creates.
case_fixer_runs_before_the_gate() {
  setup 'test -e work.txt && test -e fixed.txt'
  (
    cd "$REPO" || exit
    printf 'fixer = "echo fixed > fixed.txt"\n' >>.bead-loop.toml
    git add -A && git commit -qm fixer && git push -q
  )
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  # The merge, once seen, also deletes the branch in the same tick, so the branch's log is
  # read on every tick and the last reading before it is gone is what gets asserted on.
  local subjects="" seen="" start=$SECONDS
  while [ $((SECONDS - start)) -lt 90 ]; do
    tick 1
    seen=$(git -C "$E2E_ORIGIN" log "bead/$BEAD" --format=%s 2>/dev/null) && [ -n "$seen" ] && subjects=$seen
    events | grep -qw pr_merged && break
  done
  events | grep -qw pr_merged || bad "never merged: $(events)"
  assert_match "$subjects" "$BEAD: fixer\$" "the fixer's commit landed on the branch before the gate ran"
}
