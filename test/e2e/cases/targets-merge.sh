# shellcheck shell=bash
# Targets (docs/design-targets.md): a bead labelled work:NAME works and opens its PR in
# another checkout, not the beads repo's own. Ported from the Rust suite's cases of the
# same name (git show 8907dfa:test/run.sh), to what the BAML loop actually does with each.
#
# case_target_unknown is not ported: the Rust loop held a bead whose work:NAME labelled no
# configured target, naming the label, with no failure charged. The BAML loop's
# `tickets()` (ns_world/live.baml) only filters: `takes()` (the same file, ~line 1281)
# drops a bead whose labels match no supervisor's `only` and whose repo's own `skip`
# ("work:") matches one of them — so a bead like this is never on any supervisor's ready
# list, silently, forever. There is no hold, no note, no label, nothing a tick says. That
# is a gap (its own bead), not a case to assert here as if it already held.

# target_checkout NAME: a second bare repo, $T/NAME-upstream.git, with its own main (so a
# fetch of base_remote proves the round forked from it, not a stale copy of the beads
# repo's own main); $T/NAME is the checkout the round works in, cloned from the beads
# repo's own remote ($E2E_ORIGIN, this suite's one GitHub) with an extra "upstream" remote
# added for the new repo.
target_checkout() {
  local name=$1
  git init -q --bare -b main "$T/$name-upstream.git"
  local tmp
  tmp=$(mktemp -d)
  git clone -q "$T/$name-upstream.git" "$tmp" 2>/dev/null
  (cd "$tmp" && echo upstream >README && git add -A && git commit -qm upstream && git push -q -u origin main)
  rm -rf "$tmp"
  git clone -q "$E2E_ORIGIN" "$T/$name" 2>/dev/null
  git -C "$T/$name" remote add upstream "$T/$name-upstream.git"
}

# target_toml NAME [EXTRA-LINE...]: a `[targets.NAME]` table naming NAME's checkout, a
# foreign pr_repo (so open_pr must be asked for explicitly to land the PR itself, same as
# a real one whose owner is the signed-in account) and its base_remote. `adopt = false`
# at the root: the stub `gh` (test/e2e/bin/gh) is one flat PR list for every repo, where
# the real `gh pr list` with no `-R` is scoped by cwd to the checkout's own GitHub repo —
# without that scoping the repo's own adopt_prs (ns_supervisor/supervisor.baml) would
# "adopt" and merge the target's PR itself, a false positive the stub invents and a real
# GitHub repo never would.
target_toml() {
  local name=$1
  shift
  printf 'adopt = false\n' >>"$REPO/.bead-loop.toml"
  {
    printf '\n[targets.%s]\n' "$name"
    printf 'path = "%s"\n' "$T/$name"
    printf 'pr_repo = "up/target"\n'
    printf 'base_remote = "upstream"\n'
    printf 'open_pr = "auto"\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } >>"$REPO/.bead-loop.toml"
}

# target_bead NAME: a second bead, labelled for NAME's target, prints its id.
target_bead() {
  local name=$1
  (cd "$REPO" && bd create "Theirs" -d "Write work.txt" --acceptance "test -e work.txt" \
    -l "delegate:local,work:$name" --json | jq -r .id)
}

# A target's events live under its own state, STATE/targets/NAME (docs/state-machine.md).
target_events() {
  jq -r .kind "$(STATE)/targets/$1/beads/$2/events.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}
until_target_event() {  # until_target_event NAME ID KIND [SECONDS]
  local name=$1 id=$2 want=$3 limit=${4:-60} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    tick 1
    target_events "$name" "$id" | grep -qw -- "$want" && return 0
  done
  return 1
}
target_view_bead() {  # target_view_bead NAME ID FIELD
  jq -r --arg id "$2" ".beads[] | select(.id==\$id) | $3" "$(STATE)/targets/$1/view.json" 2>/dev/null
}
bead_field() { (cd "$REPO" && bd show "$1" --json | jq -r ".[0].$2"); }  # bead_field ID FIELD

# A bead labelled work:t claims the [targets.t] checkout: its round works there (forked
# from target-upstream's main, not a stale copy of the beads repo's own), its PR opens
# against the configured pr_repo, and it lands the same as any other bead once green.
case_target() {
  setup 'test -e work.txt'
  (cd "$REPO" && bd label remove "$BEAD" delegate:local >/dev/null)
  target_checkout t
  target_toml t
  local tid
  tid=$(target_bead t)
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_target_event t "$tid" pr_opened 60 || bad "never opened: $(target_events t "$tid")"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "pr create --head bead/$tid --base main" "the PR, from the target's branch"
  assert_match "$(cat "$E2E_CTRL/gh/calls")" "\-R up/target" "opened against the configured pr_repo"
  # The commit's own sha, from the pr_opened event: the branch is gone by the time the
  # bead closes (DeleteRemoteBranch, ns_machine/step.baml), but the object it named stays.
  local sha
  sha=$(jq -r 'select(.kind=="pr_opened") | .head' "$(STATE)/targets/t/beads/$tid/events.jsonl")
  assert_eq "$(git -C "$E2E_ORIGIN" show "$sha:README")" upstream "forked from the target's upstream, not the beads repo's own main"
  until_target_event t "$tid" pr_merged 60 || bad "never merged: $(target_events t "$tid")"
  assert_eq "$(bead_field "$tid" status)" closed "merged: closed"
}

# The repo merges on green (auto); its target t is merged by the maintainer (external).
# The merge row carries the PR's own mode, so the page shows t as awaiting the maintainer
# (view.baml's merge_mode, read from the target's own policy, not the repo's), and a green
# PR there is not an event a tick logs or a merge the loop makes.
case_target_external_merge_mode() {
  setup 'test -e work.txt'
  (cd "$REPO" && bd label remove "$BEAD" delegate:local >/dev/null)
  target_checkout t
  target_toml t 'merge = "external"'
  local tid
  tid=$(target_bead t)
  reply coder "$(write_work)" "$(commit)" "$(done_report)"
  reply reviewer "$(approve)"
  until_target_event t "$tid" pr_opened 60 || bad "never opened: $(target_events t "$tid")"
  assert_eq "$(target_view_bead t "$tid" .merge_mode)" external "the PR's merge mode is its target's, not the repo's"
  tick 3
  assert_eq "$(target_events t "$tid" | tr ' ' '\n' | grep -c checks_green)" 0 "green on an external target is not logged"
  assert_eq "$(jq -r '.[0].state' "$E2E_CTRL/gh/prs.json")" OPEN "green on an external target: not merged"
  assert_nomatch "$(cat "$E2E_CTRL/gh/calls")" "pr merge" "the loop never merges an external target's PR"
}
