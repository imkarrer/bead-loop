#!/usr/bin/env bash
# Set up bead-loop on a Mac, start to finish, for someone who has not used it before:
# Flox, this repo checked out to ~/bead-loop, install.sh (the loop and its page as launchd
# agents), a GitHub sign-in, and the first repo the loop works. docs/setup-macos.md is
# the guide that sends people here.
#
#   bash setup-macos.sh            asks as it goes; safe to run again
#
# BEAD_LOOP_DIR (default ~/bead-loop) and BEAD_LOOP_REF (default main) pick where and
# what to check out. It runs under macOS's own bash 3.2, before Flox exists, so it keeps
# to what that bash has.
set -euo pipefail

DIR=${BEAD_LOOP_DIR:-$HOME/bead-loop}
REF=${BEAD_LOOP_REF:-main}
URL=https://github.com/imkarrer/bead-loop
CONFIG=${BEAD_LOOP_CONFIG:-$HOME/.config/bead-loop}/config.toml

say() { printf '\n==> %s\n' "$*"; }
# ask QUESTION [DEFAULT]: the answer, or the default on an empty line or no terminal.
ask() {
  local a=
  if [ -r /dev/tty ]; then read -r -p "    $1${2:+ [$2]} " a </dev/tty || true; fi
  printf '%s' "${a:-${2:-}}"
}

# add_repo CONFIG PATH: put PATH in the config's `repos` list, the one-line form install.sh
# writes (`repos = []` or `repos = ["a", "b"]`). Says so and changes nothing when the path
# is already there or the list is not on one line.
add_repo() {
  local cfg=$1 path=$2 line
  if grep -qF "\"$path\"" "$cfg"; then echo "    $path is already in $cfg"; return 0; fi
  line=$(grep -E '^repos *= *\[.*\] *(#.*)?$' "$cfg" | head -n1 || true)
  if [ -z "$line" ]; then
    echo "    add it by hand: repos = [\"$path\"] in $cfg"; return 0
  fi
  awk -v path="$path" '
    !done && /^repos *= *\[.*\]/ {
      lb = index($0, "["); rb = index($0, "]")
      inside = substr($0, lb + 1, rb - lb - 1)
      gsub(/^ +| +$/, "", inside)
      sep = (inside == "") ? "" : ", "
      $0 = substr($0, 1, lb) inside sep "\"" path "\"" substr($0, rb)
      done = 1
    }
    { print }' "$cfg" >"$cfg.tmp" || { rm -f "$cfg.tmp"; return 1; }
  mv "$cfg.tmp" "$cfg"
  echo "    added $path to $cfg"
}

main() {
  say "1/5 Flox"
  if ! command -v flox >/dev/null; then
    echo "    Flox is not installed. Your browser will open its download page:"
    echo "    download the macOS installer, open it, and follow its steps."
    open https://flox.dev/download || true
    until command -v flox >/dev/null || [ -x /usr/local/bin/flox ]; do
      ask "Press Return once the Flox installer has finished." >/dev/null
      PATH=/usr/local/bin:$PATH
    done
  fi
  echo "    $(flox --version 2>/dev/null | head -n1)"

  say "2/5 bead-loop, in $DIR"
  if [ -d "$DIR/.git" ]; then
    flox run -p git -- git -C "$DIR" pull --ff-only
  else
    flox run -p git -- git clone --branch "$REF" "$URL" "$DIR"
  fi

  say "3/5 Install: the loop and its page start in the background, and at every login"
  echo "    The first time, this builds bead-loop, which takes a few minutes."
  (cd "$DIR" && flox activate -- ./install.sh)

  say "4/5 GitHub"
  if (cd "$DIR" && flox activate -- gh auth status >/dev/null 2>&1); then
    echo "    already signed in"
  else
    echo "    Your browser opens GitHub: copy the code shown here, paste it there, approve."
    (cd "$DIR" && flox activate -- gh auth login --web --git-protocol https --hostname github.com)
  fi

  say "5/5 Your first repo"
  local repo
  repo=$(ask "The folder of a repo with beads in it (Return to skip for now):")
  repo=${repo/#\~/$HOME}
  if [ -z "$repo" ]; then
    echo "    skipped: add one later to repos in $CONFIG"
  elif [ ! -d "$repo/.beads" ]; then
    echo "    $repo has no .beads folder, so there is nothing for the loop to work yet."
    echo "    Add it later, to repos in $CONFIG, once it has beads."
  else
    add_repo "$CONFIG" "$(cd "$repo" && pwd)"
  fi

  if [ "$(ask "Point bead-loop at the shared models on llm-box now? (y/N)" n)" = y ]; then
    bash "$DIR/scripts/configure-models.sh"
  else
    echo
    echo "    To use the shared models later: bash $DIR/scripts/configure-models.sh"
  fi

  say "Done. The page is at http://127.0.0.1:4097"
  echo "    The first time the loop reaches a model on the network, macOS asks whether"
  echo "    opencode may find devices on your local network: click Allow."
  open http://127.0.0.1:4097 || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
