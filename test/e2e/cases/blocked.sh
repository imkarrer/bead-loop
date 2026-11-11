# shellcheck shell=bash
# A round that reports BLOCKED with its change uncommitted. Removing the bead's worktree
# (baml_src/ns_world/live.baml's `remove_branch`) once took that change with it: on 9 Nov
# bl-lkb.24's round wrote a right fix, left it uncommitted because one assertion could
# not pass, reported BLOCKED on the last stage, and the park deleted the fix. The change
# is now saved as a patch in the bead's state directory before the worktree goes, and a
# note on the bead says where.

# blocked_reply TEXT: a worker's BLOCKED, with no commit (ns_rounds/round.baml's
# work_outcome).
blocked_reply() {
  printf '{"content":"{\\"outcome\\":\\"blocked\\",\\"summary\\":\\"%s\\"}"}' "$1"
}

# BLOCKED on a one-attempt stage parks at once, and with no earlier gated work on the
# branch the worktree and branch are removed; the uncommitted work.txt survives as
# STATE/beads/ID/uncommitted.patch, which applies to the base.
case_blocked_round_keeps_its_uncommitted_work() {
  setup
  reply coder "$(write_work)" "$(blocked_reply "one acceptance assertion cannot pass")"
  until_place parked 90 || bad "not parked: $(events)"
  local patch
  patch=$(STATE)/beads/$BEAD/uncommitted.patch
  [ -s "$patch" ] && ok || bad "no patch at $patch"
  assert_match "$(cat "$patch" 2>/dev/null)" "work.txt" "the patch names the file"
  assert_match "$(cat "$patch" 2>/dev/null)" "^+done$" "and carries its content"
  (cd "$REPO" && git apply --check "$patch" 2>/dev/null) && ok || bad "the patch does not apply to the base"
  assert_match "$(bd_field notes)" "uncommitted change was saved at $patch" "the bead says where"
  [ -e "$(STATE)/wt/$BEAD" ] && bad "the worktree is still there" || ok
  assert_eq "$(cd "$REPO" && git branch --list "bead/$BEAD")" "" "the branch is gone"
}
