#!/usr/bin/env bash
# Link this checkout into opencode (user skills + agent), put the supervisor on
# PATH, install the user timer. Re-runnable.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OC=${XDG_CONFIG_HOME:-$HOME/.config}/opencode

mkdir -p "$OC/skills" "$OC/agents" "$HOME/.local/bin" "$HOME/.config/bead-loop" "$HOME/.config/systemd/user"
for s in "$HERE"/skills/*/; do
  n=$(basename "$s"); ln -sfnT "$s" "$OC/skills/$n"; echo "skill  $OC/skills/$n -> $s"
done
for a in "$HERE"/agents/*.md; do
  n=$(basename "$a"); ln -sfnT "$a" "$OC/agents/$n"; echo "agent  $OC/agents/$n -> $a"
done
ln -sfnT "$HERE/bin/bead-supervisor" "$HOME/.local/bin/bead-supervisor"
echo "bin    ~/.local/bin/bead-supervisor"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "       (add ~/.local/bin to PATH, or call $HERE/bin/bead-supervisor)";; esac

if [ ! -f "$HOME/.config/bead-loop/config" ]; then
  cat >"$HOME/.config/bead-loop/config" <<CFG
# bead-loop global config. KEY=VALUE, no shell.
MODEL=devbox/coder
REVIEW_MODEL=
# ATTACH=http://127.0.0.1:4096   # run sessions inside opencode-web.service; watch them live in the browser
REPOS=
WORKER_TIMEOUT=3600
MAX_INFLIGHT=1
CFG
  echo "config ~/.config/bead-loop/config (set REPOS)"
fi
cp "$HERE"/systemd/*.service "$HERE"/systemd/*.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
echo "timer  installed, not enabled. Start the loop with:"
echo "       systemctl --user enable --now bead-supervisor.timer"
