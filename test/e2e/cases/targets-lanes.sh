# shellcheck shell=bash
# A target's own checkout, remote and cap (docs/design-targets.md). Ported from the Rust
# suite's cases of the same name (git show 8907dfa:test/run.sh), minus one:
#
#   case_target_skills: "house rules travel" — the beads repo's .agents/skills/ linked
#   into the target's worktree, its own skills of the same name kept, .agents/ in the
#   target's shared exclude. Nothing in baml_src/ links a skill into a worktree or writes
#   to .git/info/exclude; the BAML loop has no code path for it, so there is nothing to
#   port against.
#
# The gh stub (test/e2e/bin/gh) keeps one bare remote ($E2E_ORIGIN) and one fixed
# `owner/repo`, with no `--repo`/`-R` routing to a second one — unlike the Rust suite's,
# which the ported cases relied on for a fork. So the target fixture below gives the
# checkout its own "origin" (the beads repo's own $E2E_ORIGIN, which the stub already
# knows) and a *second*, separate bare remote as "upstream" — enough to prove the target
# routes its base and its cap through base_remote and [targets.t] on its own, without
# needing the gh stub to understand a second repo.

# setup_target_t: a target "t" beside the beads repo's own bead ($BEAD, closed — these
# cases are about the target's queue, and a bead left ready in the default one would
# race it for the same scripted replies). "upstream" is a bare remote of its own, seeded
# with a README carrying a marker origin/main (the beads repo's own tree) lacks; the
# target's gate greps for it, so a worktree built off the wrong remote fails there
# instead of silently passing.
setup_target_t() {
  setup 'test -e work.txt'
  git init -q --bare -b main "$T/target-upstream.git"
  git clone -q "$T/target-upstream.git" "$T/target-seed" 2>/dev/null
  (
    cd "$T/target-seed" || exit
    echo "from upstream" >README
    git add -A && git commit -qm base && git push -q -u origin main
  )
  rm -rf "$T/target-seed"
  git clone -q "$E2E_ORIGIN" "$T/target" 2>/dev/null
  git -C "$T/target" remote add upstream "$T/target-upstream.git"
  printf '\n[targets.t]\npath = "%s"\nbase_remote = "upstream"\ngate = \047grep -q "from upstream" README \046\046 test -e work.txt\047\n' \
    "$T/target" >>"$REPO/.bead-loop.toml"
  (cd "$REPO" && bd close "$BEAD" --reason "unused: these cases work the target, not the default bead" >/dev/null)
}

# lanes_target_bead TITLE: a bead labelled for target t, beside the closed default one.
# (targets-merge.sh's target_bead takes the target's name instead; the case files share
# one shell, so each helper has a name of its own.)
lanes_target_bead() {
  (cd "$REPO" && bd create "$1" -d "Write work.txt" --acceptance "work.txt exists" -l delegate:local,work:t --json | jq -r .id)
}

# default_bead TITLE: a bead on the default target, same shape as lib.sh's own $BEAD.
default_bead() {
  (cd "$REPO" && bd create "$1" -d "Write work.txt" --acceptance "test -e work.txt" -l delegate:local --json | jq -r .id)
}

# A target's state sits under the repo's own, named after the [targets.NAME] table
# (config.baml's target_config): events_of_t/until_event_of_t/view_of_t are lib.sh's
# events/until_event/view_bead, read from there instead, for a bead on target t.
tstate() { echo "$(STATE)/targets/t"; }
events_of_t() { jq -r .kind "$(tstate)/beads/$1/events.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
until_event_of_t() {
  local id=$1 want=$2 limit=${3:-60} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    tick 1
    events_of_t "$id" | grep -qw -- "$want" && return 0
  done
  return 1
}
view_of_t() { jq -r --arg id "$1" ".beads[] | select(.id==\$id) | $2" "$(tstate)/view.json"; }

# The reviewer's diff is taken in the target's own checkout, against its own base_remote
# (upstream/main) — not origin/main, which the gh stub's single bare remote would still
# resolve, just to the beads repo's own tree.
case_target_review_lane() {
  setup_target_t
  local tb
  tb=$(lanes_target_bead Theirs)
  reply coder "$(write_work)" "$(commit_for "$tb")" "$(done_report)"
  reply reviewer "$(approve)"
  until_event_of_t "$tb" pr_merged 90 || bad "the target bead's round never reached a PR: $(events_of_t "$tb")"
  assert_eq "$(events_of_t "$tb")" "picked committed gate_passed review_picked approved pr_opened pr_merged" \
    "the round ran to a PR off the target's own base: origin/main (the beads repo's own tree, lacking the gate's \"from upstream\" marker) would have failed the gate instead"
  local reviewed
  reviewed=$(grep -l '"model":"reviewer"' "$E2E_CTRL"/requests/*.json | xargs cat)
  assert_match "$reviewed" "<diff>" "the reviewer got a diff"
  assert_match "$reviewed" "work.txt" "the diff shows the worker's change"
}

# max_inflight counts per target (docs/design-targets.md): a work:t PR already in the
# merge queue does not stop the default target's own beads, only a second work:t one.
case_inflight_limits_per_target() {
  setup_target_t
  printf 'max_inflight = 1\n' >>"$REPO/.bead-loop.toml"   # inside [targets.t], the last table
  echo '[{"context":"ci","state":"PENDING"}]' >"$E2E_CTRL/gh/checks.json"
  local tb1 tb2 d
  tb1=$(lanes_target_bead First)
  reply coder "$(write_work)" "$(commit_for "$tb1")" "$(done_report)"
  reply reviewer "$(approve)"
  until_event_of_t "$tb1" pr_opened 90 || bad "the first work:t bead's PR never opened: $(events_of_t "$tb1")"
  assert_eq "$(view_of_t "$tb1" .place)" merge "t's queue is full: its one PR, pending CI"
  tb2=$(lanes_target_bead Second)
  tick 1
  assert_eq "$(events_of_t "$tb2")" "" "a second work:t bead gets no round: t's max_inflight is already spent"
  d=$(default_bead Default)
  reply coder "$(write_work)" "$(commit_for "$d")" "$(done_report)"
  reply reviewer "$(approve)"
  until_event_of "$d" pr_opened 90 || bad "the default target's own bead never got a round: t's cap is not the default's: $(events_of "$d")"
}
