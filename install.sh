#!/usr/bin/env bash
# Build the supervisor, link this checkout into opencode (user skills + agents), put
# the binary and the UI server on PATH, install and start the user units so the loop is
# running when this script returns. Re-runnable; what the pipeline's deploy step runs on
# this box after every merge to main (scripts/deploy.sh).
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

# The binary: a prebuilt one in BEAD_SUPERVISOR_BIN (the deploy's, downloaded from the
# release the pipeline built and tested), else cargo from PATH, else this checkout's
# flox env. `install` replaces the file rather than writing into it, so a running loop
# keeps its old inode until it re-execs at an idle moment (it watches the path for
# exactly this).
build() { (cd "$HERE" && cargo build --release --quiet); }
bin=${BEAD_SUPERVISOR_BIN:-}
if [ -n "$bin" ]; then [ -x "$bin" ] || { echo "       BEAD_SUPERVISOR_BIN=$bin is not an executable"; exit 1; }
elif command -v cargo >/dev/null; then build; bin=$HERE/target/release/bead-supervisor
elif command -v flox >/dev/null; then (cd "$HERE" && flox activate -- cargo build --release --quiet); bin=$HERE/target/release/bead-supervisor
else echo "       cargo is missing: install rust, or flox (the env in .flox/ has it)"; exit 1; fi
install -m 755 "$bin" "$HOME/.local/bin/bead-supervisor"
ln -sfnT "$HERE/bin/bead-loop-ui" "$HOME/.local/bin/bead-loop-ui"
echo "bin    ~/.local/bin/bead-supervisor ($(bead-supervisor --help 2>/dev/null | head -1 | cut -c1-60 || true))"
echo "bin    ~/.local/bin/bead-loop-ui -> $HERE/bin/bead-loop-ui"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "       (add ~/.local/bin to PATH)";; esac

if [ ! -f "$HOME/.config/bead-loop/config.toml" ]; then
  cat >"$HOME/.config/bead-loop/config.toml" <<CFG
# bead-loop global config. A key in a repo's .bead-loop.toml wins over the same key here.
repos = []                       # e.g. ["~/src/inquire-platform"]; each has .beads/ and a .bead-loop.toml
model = "devbox/coder"           # worker, when no stages table is set
# review_model = "acbox/reviewer" # the model that judges the diff before the push -- a different family from the worker
# attach = "http://127.0.0.1:4096"   # run sessions inside opencode-web.service; watch them live in the browser
worker_timeout = 3600            # seconds per model session
# max_inflight = 2               # unset: no cap — bd's dependencies are the only gate on the dev lane
on_exhaust = "park"              # after the last stage: park (for you) | repeat (around again)
# Escalation, in order; each send-back to dev is a failure, a stage takes the next N.
# [[stages]]
# worker = "devbox/coder"
# failures = 3
# The lanes, one per model server; unset: dev + review by role (+ claude when a stage names it).
# [[lanes]]
# name = "gpu"
# models = ["devbox/*"]
# [[lanes]]
# name = "cpu"
# models = ["acbox/*"]
# [[lanes]]
# name = "claude"
# models = ["claude/*"]
CFG
  echo "config ~/.config/bead-loop/config.toml (set repos)"
fi
# Substitute the HERE path into the service files before copying them
for service_file in "$HERE"/systemd/*.service; do
  service_name=$(basename "$service_file")
  sed "s|@HERE@|$HERE|g" "$service_file" > "$HOME/.config/systemd/user/$service_name"
done
cp "$HERE"/systemd/*.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload

# bead-supervisor.service is the resident loop; bead-supervisor.timer is its keeper (it
# starts the service at once and again a minute after it stops — gpu-mode's start/stop
# unit, see systemd/bead-supervisor.timer). Enabling the timer, not the service, is what
# makes the loop survive: `enable --now` on an already-running unit only starts it if it
# isn't running, so a re-run (every deploy) never interrupts sessions in flight.
if systemctl --user enable --now opencode-web.service bead-loop-ui.service bead-supervisor.timer; then
  echo "loop   started: bead-supervisor is running, bead-loop-ui at http://127.0.0.1:4097"
else
  echo "loop   could not start the units here (no systemd --user session?); by hand:"
  echo "       systemctl --user enable --now opencode-web.service bead-loop-ui.service bead-supervisor.timer"
fi

# Linger: without it, user units stop at logout and only restart at the next login — no
# good on a box nobody logs into. Granting it to yourself needs root, so this can only
# ask, once, rather than always fix it.
me=$(id -un)
linger=$(loginctl show-user "$me" -p Linger --value 2>/dev/null || echo "")
if [ "$linger" != "yes" ] && loginctl enable-linger "$me" 2>/dev/null; then linger=yes; fi
if [ "$linger" = "yes" ]; then
  echo "linger enabled for $me: the loop stays up across logout and reboot"
else
  echo "linger not enabled for $me — the loop stops at logout without it; once, as root:"
  echo "       sudo loginctl enable-linger $me"
fi

echo "deploy bead-loop-deploy.timer pulls origin/main here every two minutes and redeploys when it moved:"
echo "       systemctl --user enable --now bead-loop-deploy.timer"
