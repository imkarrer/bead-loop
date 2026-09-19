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
# Claude Code (the claude/<model> stages, and you at the terminal) reads ~/.claude/skills.
if command -v claude >/dev/null; then
  mkdir -p "$HOME/.claude/skills"
  for s in "$HERE"/skills/*/; do n=$(basename "$s"); ln -sfnT "$s" "$HOME/.claude/skills/$n"; echo "skill  ~/.claude/skills/$n -> $s (Claude Code)"; done
fi
ln -sfnT "$HERE/bin/bead-supervisor" "$HOME/.local/bin/bead-supervisor"
echo "bin    ~/.local/bin/bead-supervisor"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "       (add ~/.local/bin to PATH, or call $HERE/bin/bead-supervisor)";; esac

command -v yq >/dev/null || echo "       yq (mikefarah, v4) is missing: the supervisor reads its TOML config with it"
if [ ! -f "$HOME/.config/bead-loop/config.toml" ]; then
  cat >"$HOME/.config/bead-loop/config.toml" <<CFG
# bead-loop global config. A key in a repo's .bead-loop.toml wins over the same key here.
repos = []                       # e.g. ["~/src/inquire-platform"]; each has .beads/ and a .bead-loop.toml
model = "devbox/coder"           # worker, when no stages table is set
# review_model = "acbox/coder"   # the senior model that judges the diff before the push
# attach = "http://127.0.0.1:4096"   # run sessions inside opencode-web.service; watch them live in the browser
worker_timeout = 3600            # seconds per model session
max_inflight = 1                 # open PRs per repo before the loop waits for CI
on_exhaust = "park"              # after the last stage: park (for you) | repeat (around again)

# Escalation, in order; a failed attempt requeues the bead for the next one.
# [[stages]]
# worker = "devbox/coder"
# reviewer = "acbox/coder"
# attempts = 3
CFG
  echo "config ~/.config/bead-loop/config.toml (set repos)"
fi
cp "$HERE"/systemd/*.service "$HERE"/systemd/*.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
echo "timer  installed, not enabled. Start the loop with:"
echo "       systemctl --user enable --now bead-supervisor.timer"
