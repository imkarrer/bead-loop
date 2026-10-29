#!/usr/bin/env bash
# The flox package: `flox build bead-loop`, then what `flox install imkarrer/bead-loop`
# would put on a machine. Run inside the checkout's env (scripts/ci.sh package).
#
#   test/package.sh             build, then check the result
#   test/package.sh RESULT      check an existing result (a store path or result link)
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

out=${1:-}
if [ -z "$out" ]; then
  flox build bead-loop
  out=$HERE/result-bead-loop
fi

fails=0
check() { if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

check "bin/bead-supervisor runs" sh -c '"$1" --help >/dev/null' _ "$out/bin/bead-supervisor"
check "bin/bead-loop-ui parses" node --check "$out/bin/bead-loop-ui"
for a in agents/*.md; do check "$a" test -f "$out/$a"; done
for s in skills/*/SKILL.md; do check "$s" test -f "$out/$s"; done
check "ui/index.html" test -f "$out/ui/index.html"
check "bin/bead-loop-install" test -x "$out/bin/bead-loop-install"
for l in launchd/*.plist; do check "$l" test -f "$out/$l"; done

# What a round shells out to is on the package's own PATH: flox's wrapper activates the
# build's runtime environment, named on its --env line.
env_dir=$(sed -n 's/.*--env \([^ ]*\) .*/\1/p' "$out/bin/bead-supervisor")
for t in bd git gh jq curl node timeout bash; do check "runtime has $t" test -x "$env_dir/bin/$t"; done

[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
