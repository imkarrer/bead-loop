#!/usr/bin/env bash
# The end-to-end suite: the packed binary (scripts/pack.sh target/bead-supervisor) run as
# the unit runs it, one `run --ticks 1` process per tick, so every tick is also a restart.
# Real git, a real bd database, a real gate; gh, claude and the model servers are scripted
# (test/e2e/bin, test/e2e/model.mjs). The fixture is test/e2e/lib.sh.
#
# What belongs here is what the BAML tests cannot see: the loop's calls into the world. A
# state the machine reaches, a prompt's shape, a note's words are BAML tests in baml_src/.
#
#   test/e2e/run.sh [CASE...]      every case side by side, or the ones named
#   JOBS=1 test/e2e/run.sh         one at a time
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test/e2e/lib.sh
. "$HERE/lib.sh"

# Every case file is sourced into this one shell, so a helper two files define is the
# last file's in both: targets-merge.sh's target_bead once labelled targets-lanes.sh's
# beads for a target that did not exist, and its cases failed on main. Give each its own.
twice=$(grep -ho '^[a-zA-Z_][a-zA-Z0-9_]*()' "$HERE/lib.sh" "$HERE"/cases/*.sh | sort | uniq -d | tr '\n' ' ')
if [ -n "$twice" ]; then
  echo "test/e2e: defined in more than one file (they share one shell): $twice" >&2
  exit 2
fi

for f in "$HERE"/cases/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

# ---- the runner ---------------------------------------------------------------------

run_case() {
  CASE=$1
  set +e
  PASS=0 FAIL=0
  trap teardown EXIT
  "$CASE"
  teardown
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ] && [ -z "${KEEP:-}" ] && rm -rf "$T"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 0 ] && bad "asserted nothing"
  printf '%s %s (%d checks)%s\n' "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" "$CASE" \
    "$((PASS + FAIL))" "$([ "$FAIL" -eq 0 ] || echo ", kept $T")"
  [ "$FAIL" -eq 0 ]
}

[ -x "$SUP" ] || { echo "no binary at $SUP: scripts/pack.sh target/bead-supervisor" >&2; exit 2; }
if [ $# -gt 0 ]; then
  cases=("$@")
else
  mapfile -t cases < <(declare -F | awk '{print $3}' | grep '^case_')
fi
out=$(mktemp -d)
jobs=${JOBS:-4}
for c in "${cases[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n || true; done
  ( run_case "$c" >"$out/$c" 2>&1 ) &
done
wait || true
failed=0
for c in "${cases[@]}"; do
  cat "$out/$c"
  grep -q "^PASS $c " "$out/$c" || failed=$((failed + 1))
done
rm -rf "$out"
echo "${#cases[@]} cases, $failed failed"
[ "$failed" -eq 0 ]
