#!/usr/bin/env bash
# Build the supervisor, link this checkout into opencode (user skills + agents), put
# the binary and the UI server on PATH, install and start the user units so the loop is
# running when this script returns: systemd user units on Linux, launchd agents on macOS.
# Re-runnable; what the pipeline's deploy step runs on this box after every merge to main
# (scripts/deploy.sh).
#
# The flox package carries this script as bin/bead-loop-install. Run from there, nothing
# is built: the binary and the page are the environment's that installed the package,
# and the links go through that environment, whose path an upgrade does not change.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OC=${XDG_CONFIG_HOME:-$HOME/.config}/opencode
OS=${BEAD_LOOP_OS:-$(uname -s)}   # BEAD_LOOP_OS: the suite drives the macOS path on Linux

# SRC is where the links point: the checkout, or the environment holding the package.
packaged=
SRC=$HERE
if [ "$(basename "$HERE")" = bin ] && [ -d "$HERE/../agents" ] && [ ! -f "$HERE/../Cargo.toml" ]; then
  packaged=1
  HERE=$(cd "$HERE/.." && pwd)
  SRC=$HERE
  if sup=$(command -v bead-supervisor) && [ -d "$(dirname "$sup")/../agents" ]; then
    SRC=$(cd "$(dirname "$sup")/.." && pwd)
  fi
fi

mkdir -p "$OC/skills" "$OC/agents" "$HOME/.local/bin" "$HOME/.config/bead-loop"
for s in "$SRC"/skills/*/; do
  s=${s%/}; n=$(basename "$s"); ln -sfn "$s" "$OC/skills/$n"; echo "skill  $OC/skills/$n -> $s"
done
for a in "$SRC"/agents/*.md; do
  n=$(basename "$a"); ln -sfn "$a" "$OC/agents/$n"; echo "agent  $OC/agents/$n -> $a"
done
# Claude Code (the claude/<model> stages, and you at the terminal) reads ~/.claude/skills.
if command -v claude >/dev/null; then
  mkdir -p "$HOME/.claude/skills"
  for s in "$SRC"/skills/*/; do s=${s%/}; n=$(basename "$s"); ln -sfn "$s" "$HOME/.claude/skills/$n"; echo "skill  ~/.claude/skills/$n -> $s (Claude Code)"; done
fi

# The binary: a prebuilt one in BEAD_SUPERVISOR_BIN (the deploy's, downloaded from the
# release the pipeline built and tested), else cargo from PATH, else this checkout's
# flox env. `install` replaces the file rather than writing into it, so a running loop
# keeps its old inode until it re-execs at an idle moment (it watches the path for
# exactly this).
build() { (cd "$HERE" && cargo build --release --quiet); }
bin=${BEAD_SUPERVISOR_BIN:-}
if [ -n "$packaged" ]; then
  echo "bin    $SRC/bin/bead-supervisor, $SRC/bin/bead-loop-ui (the flox package)"
elif [ -n "$bin" ]; then [ -x "$bin" ] || { echo "       BEAD_SUPERVISOR_BIN=$bin is not an executable"; exit 1; }
elif command -v cargo >/dev/null; then build; bin=$HERE/target/release/bead-supervisor
elif command -v flox >/dev/null; then (cd "$HERE" && flox activate -- cargo build --release --quiet); bin=$HERE/target/release/bead-supervisor
else echo "       cargo is missing: install rust, or flox (the env in .flox/ has it)"; exit 1; fi
if [ -z "$packaged" ]; then
  install -m 755 "$bin" "$HOME/.local/bin/bead-supervisor"
  ln -sfn "$HERE/bin/bead-loop-ui" "$HOME/.local/bin/bead-loop-ui"
  echo "bin    ~/.local/bin/bead-supervisor ($(bead-supervisor --help 2>/dev/null | head -1 | cut -c1-60 || true))"
  echo "bin    ~/.local/bin/bead-loop-ui -> $HERE/bin/bead-loop-ui"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "       (add ~/.local/bin to PATH)";; esac
fi

if [ ! -f "$HOME/.config/bead-loop/config.toml" ]; then
  cat >"$HOME/.config/bead-loop/config.toml" <<CFG
# bead-loop global config. A key in a repo's .bead-loop.toml wins over the same key here.
repos = []                       # e.g. ["~/src/inquire-platform"]; each has .beads/ and a .bead-loop.toml
# attach = "http://127.0.0.1:4096"   # run sessions inside opencode-web.service; watch them live in the browser
worker_timeout = 3600            # seconds per model session
# max_inflight = 2               # unset: no cap — bd's dependencies are the only gate on the dev lane
on_exhaust = "park"              # after the last stage: park (for you) | repeat (around again)
# precheck_model = "local/small" # a small resident model: pre-check after the gate, post-mortem on a send-back; unset: neither
# Provider catalogue (commented shapes):
# [providers.local]
# probe = "http://127.0.0.1:8080/health"   # GET answers 2xx, else its rounds wait
# [providers.paid]
# parallel = 4
# cost = "metered"
# [providers.claude]
# harness = "claude-code"
# cost = "metered"
# [providers.aid]
# harness = "aider"
# via = "local"
# [providers.cmd]
# harness = "command"
# command = "my-agent --print"
[[stages]]
worker = "local/coder"
failures = 2
# reviewer = ["local/reviewer", "paid/model"]
# approvals = "all"
# [[lanes]] is optional: unset, one lane per provider the stages name, as wide as its parallel.
CFG
  echo "config ~/.config/bead-loop/config.toml (set repos)"
fi

# macOS: launchd agents in place of the units. The loop and the page, each kept up by
# launchd (KeepAlive), logging to ~/Library/Logs/bead-loop. A re-run whose agent is
# unchanged and loaded leaves it alone, so it never interrupts sessions in flight.
launchd_agents() {
  local agents=$HOME/Library/LaunchAgents logs=$HOME/Library/Logs/bead-loop domain
  local run_sup run_ui path supervisor name label plist run new
  domain=gui/$(id -u)
  mkdir -p "$agents" "$logs"
  if [ -n "$packaged" ]; then
    supervisor=$SRC/bin/bead-supervisor
    run_sup="    <string>$supervisor</string>"
    run_ui="    <string>$SRC/bin/bead-loop-ui</string>"
    path="$SRC/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  else
    # A checkout: through its flox env, as the systemd units are.
    local flox_bin; flox_bin=$(command -v flox) || { echo "       flox is missing: the agents run the checkout through its env"; exit 1; }
    supervisor=$HOME/.local/bin/bead-supervisor
    run_sup=$(printf '    <string>%s</string>\n' "$flox_bin" activate -d "$HERE" -- "$supervisor")
    run_ui=$(printf '    <string>%s</string>\n' "$flox_bin" activate -d "$HERE" -- bead-loop-ui)
    path="$HOME/.local/bin:$(dirname "$flox_bin"):/usr/bin:/bin:/usr/sbin:/sbin"
  fi
  for name in supervisor ui; do
    label=dev.bead-loop.$name
    plist=$agents/$label.plist
    run=$run_sup; [ "$name" = ui ] && run=$run_ui
    new=$(cat "$HERE/launchd/$label.plist")
    new=${new//@RUN@/$run}; new=${new//@PATH@/$path}; new=${new//@SUPERVISOR@/$supervisor}; new=${new//@LOGS@/$logs}
    if [ -f "$plist" ] && [ "$(cat "$plist")" = "$new" ] && launchctl print "$domain/$label" >/dev/null 2>&1; then
      echo "agent  $label: unchanged, running"; continue
    fi
    launchctl bootout "$domain/$label" 2>/dev/null || true
    printf '%s\n' "$new" >"$plist"
    if launchctl bootstrap "$domain" "$plist"; then
      echo "agent  $label: started ($plist)"
    else
      echo "agent  $label: could not start it; by hand: launchctl bootstrap $domain $plist"
    fi
  done
  echo "loop   bead-supervisor is running, bead-loop-ui at http://127.0.0.1:4097; logs in $logs"
}
if [ "$OS" = Darwin ]; then launchd_agents; exit 0; fi

# Linux: the systemd user units.
mkdir -p "$HOME/.config/systemd/user"
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
