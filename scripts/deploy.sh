#!/usr/bin/env bash
# Deploy a merge to main to this box. The pipeline merges and, on main, publishes the
# tested release binary as the GitHub release main-<sha7> (scripts/ci.sh release); this
# box pulls: bead-loop-deploy.timer runs this every two minutes, and it does nothing
# unless origin/main has moved past what is deployed. When it has, the deploy's own
# clone (~/.local/state/bead-loop/deploy/src — nothing else ever writes there, so a
# reset to origin/main is always safe) is put at that commit, the release's binary is
# downloaded and checked, install.sh installs it and refreshes the links and units from
# the clone, and what changed is restarted: the loop always (it is the binary); the
# opencode server only when the agents, the skills or its unit changed, since the model
# sessions live in it; the UI only when bin/, ui/ or its unit changed. The loop's restart
# drops $STATE_DIR/restart first, so it leaves its sessions running on the server and the
# next process rejoins them (recover): a change to src/ costs no round.
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
#   scripts/deploy.sh            deploy the newest released commit on main when it is newer than
#                                what runs (what the timer runs); waits up to 30 min for an
#                                aider round in flight (the restart would kill it)
#   scripts/deploy.sh --force    deploy the newest release on main again, without waiting
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
head=$(git -C "$SRC" rev-parse origin/main)
have=$(cat "$DEPLOY/deployed" 2>/dev/null || true)
if [ "$head" = "$have" ] && [ "$FORCE" = 0 ] && [ "$DRY" = 0 ]; then exit 0; fi   # nothing new: the timer's usual outcome

# The newest commit on main that has its release, newer than what runs. While merges
# land faster than the pipeline releases them, origin/main itself rarely has one yet
# (25 Sep: an hour of "no release yet" with three newer releases published).
released=$(gh release list -R "$repo" -L 50 --json tagName -q '.[].tagName' 2>/dev/null || true)
want=''
for c in $(git -C "$SRC" rev-list --first-parent -n 50 origin/main); do
  if [ "$c" = "$have" ] && [ "$FORCE" = 0 ]; then break; fi   # nothing newer is released yet
  if grep -qx "main-${c:0:7}" <<<"$released"; then want=$c; break; fi
done
if [ -z "$want" ]; then
  echo "no release newer than ${have:0:7} yet: the pipeline is still on ${head:0:7}; next time"
  exit 0
fi

tag=main-${want:0:7}
echo "--- :github: release $tag ($(git -C "$SRC" log -1 --format=%s "$want" | cut -c1-80))"
dl=$DEPLOY/dl; rm -rf "$dl"; mkdir -p "$dl"
if ! gh release download "$tag" -R "$repo" -p bead-supervisor -D "$dl" 2>"$dl/err"; then
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

# An aider round is a child of the loop, not a session on the server: the restart below
# would kill it (no failure charged, but the round's work is lost). Wait for it; the
# timer comes back in two minutes. The gpu lane starts the next aider round seconds
# after one ends, so the wait is capped: 30 min after the first deferral the deploy
# goes ahead and the round in flight is cut short. --force does not wait.
aider_wait=$DEPLOY/aider-wait
if [ "$FORCE" = 0 ] && pgrep -u "$(id -u)" -f -- '^timeout --foreground [0-9]+ aider ' >/dev/null; then
  [ -s "$aider_wait" ] || date +%s >"$aider_wait"
  waited=$(( $(date +%s) - $(cat "$aider_wait") ))
  if [ "$waited" -lt 1800 ]; then
    echo "an aider round is running; $tag waits for it (${waited}s so far; next time)"
    exit 0
  fi
  echo "aider rounds have held the deploy ${waited}s; $tag goes ahead (the round in flight is cut short, no failure charged)"
fi
rm -f "$aider_wait"

echo "--- :package: install"
BEAD_SUPERVISOR_BIN=$dl/bead-supervisor "$SRC/install.sh"
echo "$want" >"$DEPLOY/deployed"
echo "at $tag: $(git -C "$SRC" log -1 --format='%h %s')"

echo "--- :arrows_counterclockwise: restart what changed"
# The model sessions live in opencode-web.service: restarting it kills every round in
# flight, so it is restarted only when what it serves from the checkout changed (the
# agents, the skills, its unit) — a change to src/ leaves it, and the UI, running. The
# supervisor is the binary: restarted on every deploy. The first deploy, and --force,
# restart everything.
changed() {  # changed PATH...: since the deployed commit
  [ -z "$have" ] || [ "$FORCE" = 1 ] || ! git -C "$SRC" diff --quiet "$have" "$want" -- "$@"
}
restart() {  # restart UNIT
  if systemctl --user is-enabled -q "$1" 2>/dev/null || systemctl --user is-active -q "$1" 2>/dev/null; then
    systemctl --user restart "$1" && echo "restarted $1"
  else
    echo "$1 is not enabled here; left alone"
  fi
}
systemctl --user daemon-reload
if changed agents skills systemd/opencode-web.service; then restart opencode-web.service; else echo "opencode-web.service kept: agents, skills and its unit are as deployed (the sessions live)"; fi
if changed bin ui systemd/bead-loop-ui.service; then restart bead-loop-ui.service; else echo "bead-loop-ui.service kept: bin, ui and its unit are as deployed"; fi
# A restart, not a stop: the loop leaves its sessions running on the (kept) server and
# the next process rejoins them (recover) — the marker says which this is.
touch "${BEAD_LOOP_STATE:-$HOME/.local/state/bead-loop}/restart"
restart bead-supervisor.service
systemctl --user is-active -q bead-supervisor.timer || systemctl --user start bead-supervisor.timer || true
sleep 2
systemctl --user --no-pager --lines=0 status opencode-web.service bead-loop-ui.service bead-supervisor.service | grep -E '^\S|Active:' || true
