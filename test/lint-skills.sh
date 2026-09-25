#!/usr/bin/env bash
# Skills: frontmatter with name matching the directory and a description that says when.
# Agents: frontmatter with description, mode and an explicit permission block.
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
for a in "$HERE"/agents/*.md; do
  for k in description mode; do [ -n "$(field "$a" $k)" ] || { echo "$a: no $k"; rc=1; }; done
  fm "$a" | grep -q '^permission:' || { echo "$a: no permission block"; rc=1; }
  fm "$a" | grep -q '^  task: deny' || { echo "$a: subagents not denied"; rc=1; }
done
[ $rc = 0 ] && echo "skills and agents ok"
exit $rc
