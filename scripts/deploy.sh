#!/usr/bin/env bash
# Deploy a merge to main to this box. The pipeline merges and, on main, publishes the
# tested release binary as the GitHub release main-<sha7> (scripts/ci.sh release); this
# box pulls: bead-loop-deploy.timer runs this every two minutes, and it does nothing
# unless origin/main has moved past what is deployed. When it has, the deploy's own
# clone (~/.local/state/bead-loop/deploy/src — nothing else ever writes there, so a
# reset to origin/main is always safe) is put at that commit, the release's binary is
# downloaded and checked, install.sh installs it and refreshes the links and units from
# the clone, and the stack is recycled: the opencode server, the UI, the loop.
# Restarting the loop aborts the rounds it is on; it reopens them with no failure when
# it comes back (recover).
#
# What this box needs: git, gh (signed in), flox — no compiler. The binary links the
# flox env's glibc by store path, and `flox activate` on the clone realizes that env at
# the deployed commit's manifest.lock before the binary runs. The release is named by
# origin/main exactly: while the pipeline is still on that commit there is no release
# yet, and the timer's next firing finds it.
#
# Development never blocks a deploy: ~/src/bead-loop (the project the loop works, where
# bd writes .beads/ and the bead worktrees hang) is not read here.
#
#   scripts/deploy.sh            deploy if origin/main moved (what the timer runs)
#   scripts/deploy.sh --force    deploy origin/main's release again, as it is
#   scripts/deploy.sh --dry-run  fetch, download and check; install nothing
set -euo pipefail
DEPLOY=${BEAD_LOOP_DEPLOY:-$HOME/.local/state/bead-loop/deploy}
SRC=$DEPLOY/src
FORCE=0; DRY=0
case ${1:-} in --force) FORCE=1;; --dry-run) DRY=1;; "") ;; *) echo "usage: deploy.sh [--force|--dry-run]" >&2; exit 2;; esac

# The clone: from this script's own checkout's origin (the first run's is ~/src/bead-loop;
# afterwards the unit runs the clone's copy of this script).
HERE=$(cd "$(dirname "$0")/.." && pwd)
url=$(git -C "$HERE" remote get-url origin 2>/dev/null || echo "https://github.com/imkarrer/bead-loop.git")
repo=$(printf '%s' "$url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)$|\1|p' | sed 's/\.git$//')
[ -n "$repo" ] || { echo "cannot tell owner/name from $url" >&2; exit 1; }
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$DEPLOY"
  echo "--- :git: clone $url into $SRC"
  git clone -q "$url" "$SRC"
fi
git -C "$SRC" fetch -q origin main
want=$(git -C "$SRC" rev-parse origin/main)
have=$(cat "$DEPLOY/deployed" 2>/dev/null || true)
if [ "$want" = "$have" ] && [ "$FORCE" = 0 ] && [ "$DRY" = 0 ]; then exit 0; fi   # nothing new: the timer's usual outcome

tag=main-${want:0:7}
echo "--- :github: release $tag ($(git -C "$SRC" log -1 --format=%s "$want" | cut -c1-80))"
dl=$DEPLOY/dl; rm -rf "$dl"; mkdir -p "$dl"
if ! gh release download "$tag" -R "$repo" -p bead-supervisor -D "$dl" 2>"$dl/err"; then
  if grep -q "release not found" "$dl/err"; then
    echo "no release $tag yet: the pipeline is still on $want (deployed: ${have:-nothing}); next time"
    exit 0
  fi
  echo "gh release download $tag failed:" >&2; cat "$dl/err" >&2; exit 1
fi
chmod 755 "$dl/bead-supervisor"

echo "--- :git: $SRC to $want"
git -C "$SRC" reset -q --hard "$want"   # nothing else writes here: always safe
echo "--- :flox: the env at this commit (the binary's glibc)"
flox activate -d "$SRC" -- true
"$dl/bead-supervisor" --help >/dev/null || { echo "the downloaded binary does not run here" >&2; exit 1; }

if [ "$DRY" = 1 ]; then
  echo "dry run: would install $tag ($(stat -c %s "$dl/bead-supervisor") bytes) over ${have:-nothing}, and recycle the stack"
  exit 0
fi

echo "--- :package: install"
BEAD_SUPERVISOR_BIN=$dl/bead-supervisor "$SRC/install.sh"
echo "$want" >"$DEPLOY/deployed"
echo "at $tag: $(git -C "$SRC" log -1 --format='%h %s')"

echo "--- :arrows_counterclockwise: recycle the stack"
systemctl --user daemon-reload
for u in opencode-web.service bead-loop-ui.service bead-supervisor.service; do
  if systemctl --user is-enabled -q "$u" 2>/dev/null || systemctl --user is-active -q "$u" 2>/dev/null; then
    systemctl --user restart "$u" && echo "restarted $u"
  else
    echo "$u is not enabled here; left alone"
  fi
done
systemctl --user is-active -q bead-supervisor.timer || systemctl --user start bead-supervisor.timer || true
sleep 2
systemctl --user --no-pager --lines=0 status opencode-web.service bead-loop-ui.service bead-supervisor.service | grep -E '^\S|Active:' || true
