#!/usr/bin/env bash
# Deploy a merge to main to this box: the pipeline's last step on main, on the agent
# that runs here (queue devbox). The live checkout (~/src/bead-loop, the one the units
# run) fast-forwards to what was merged, install.sh builds the binary and refreshes the
# links and units, and the whole stack is recycled: the opencode server, the UI, the
# loop. Restarting the loop aborts the rounds it is on; it reopens them with no failure
# when it comes back (recover). Re-runnable by hand: scripts/deploy.sh.
#
# The agent runs as the user whose units these are, so `systemctl --user` reaches them;
# the binary is replaced with `install` (a new inode), so a loop mid-round that we
# choose not to restart would still re-exec at its next idle moment.
set -euo pipefail
LIVE=${BEAD_LOOP_LIVE:-$HOME/src/bead-loop}
REF=${1:-origin/main}

echo "--- :git: $LIVE to $REF"
[ -d "$LIVE/.git" ] || { echo "no checkout at $LIVE; clone it first" >&2; exit 1; }
git -C "$LIVE" fetch -q origin main
if [ -n "$(git -C "$LIVE" status --porcelain --untracked-files=no)" ]; then
  echo "$LIVE has uncommitted changes; not touching it" >&2; git -C "$LIVE" status --short --untracked-files=no >&2; exit 1
fi
git -C "$LIVE" checkout -q main
git -C "$LIVE" merge -q --ff-only "$REF"
echo "at $(git -C "$LIVE" log -1 --format='%h %s')"

echo "--- :rust: build and install"
"$LIVE/install.sh"

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
