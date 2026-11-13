#!/usr/bin/env bash
# Skills: frontmatter with name matching the directory and a description that says when.

set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); rc=0
fm() { awk 'NR==1 && $0!="---" {exit 1} NR>1 && $0=="---" {exit} NR>1' "$1"; }
field() { fm "$1" | sed -n "s/^$2: *//p" | head -1; }
for s in "$HERE"/skills/*/SKILL.md; do
  d=$(basename "$(dirname "$s")")
  [ "$(field "$s" name)" = "$d" ] || { echo "$s: name != $d"; rc=1; }
  case $(field "$s" description) in *"Use when"*) ;; *) echo "$s: description lacks 'Use when'"; rc=1;; esac
  [ "$(wc -w <"$s")" -le 700 ] || { echo "$s: over 700 words; keep a skill under ~1k tokens"; rc=1; }
done
grep -q 'planned-in:' "$HERE"/skills/delegate/SKILL.md || { echo "skills/delegate/SKILL.md: no planned-in label"; rc=1; }
grep -q 'bead-supervisor lint' "$HERE"/skills/delegate/SKILL.md || { echo "skills/delegate/SKILL.md: no lint step"; rc=1; }
[ $rc = 0 ] && echo "skills ok"
exit $rc
