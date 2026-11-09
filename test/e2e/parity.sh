#!/usr/bin/env bash
# test/e2e/parity.md lists the 148 cases of the Rust suite that #225 deleted, and where the
# BAML loop stands on each. This keeps the list honest: one row per case, numbered 1 to 148,
# a known status, and every case an e2e or changed row names is one test/e2e/cases defines.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); doc=$HERE/parity.md; rc=0
rows=$(grep -E '^\| [0-9]+ \|' "$doc" || true)
nums=$(printf '%s\n' "$rows" | awk -F'|' '{ gsub(/ /, "", $2); print $2 }' | sort -n)
[ "$nums" = "$(seq 1 148)" ] || { echo "parity.md: the rows are not numbered 1 to 148, once each"; rc=1; }
while IFS='|' read -r _ num name _ status _ _ evidence _; do
  num=${num// /} name=${name// /} status=${status// /}
  case $status in
    e2e|changed|core|untested|missing|dropped|moot) ;;
    *) echo "parity.md row $num ($name): unknown status '$status'"; rc=1 ;;
  esac
  [ "$status" = e2e ] || [ "$status" = changed ] || continue
  cases=$(grep -oE 'case_[a-z0-9_]+' <<<"$evidence" || true)
  [ -n "$cases" ] || { echo "parity.md row $num ($name): $status, but names no case"; rc=1; }
  for c in $cases; do
    grep -qE "^$c\(\)" "$HERE"/cases/*.sh || { echo "parity.md row $num ($name): no $c in test/e2e/cases"; rc=1; }
  done
done <<<"$rows"
[ $rc = 0 ] && echo "parity list ok"
exit $rc
