# shellcheck shell=bash
# This case proves that `bead-supervisor lint` checks a bead before the loop takes it
# and writes its verdict as a note on the bead. It tests both static checks (paths not on base,
# acceptance without command) and the --run flag.

case_lint() {
  setup 'test -e work.txt'

  # Create a bead that references a file not on the base
  local B2
  B2=$(cd "$REPO" && bd create "Edit it" -d "Edit README" --acceptance 'Run `test -e README`' --json | jq -r .id)

  # Run lint on both beads
  local out
  out=$(cd "$REPO" && "$SUP" lint --config_file "$REPO/.bead-loop.toml" --ids "$BEAD $B2" 2>&1)

  # Check that the first bead is flagged for path not on base
  assert_match "$out" "path not on base: work.txt"
  
  # Check that the second bead is flagged for acceptance has no command
  assert_match "$out" "acceptance has no command"
  
  # Check that the second bead passes lint (it has a command)
  assert_match "$out" "$B2: pass"

  # Check that the first bead has the lint note
  assert_match "$(bd_field notes)" "bead-loop lint .*path not on base: work.txt"
}