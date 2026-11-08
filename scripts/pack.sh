#!/usr/bin/env bash
# Pack the loop as one binary. Subcommands are the ones the unit and a round exec:
# `run` (the resident loop), `round` (one round), `page`.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
out=${1:?usage: scripts/pack.sh OUT}
baml_bin=$(scripts/ensure-baml.sh)
export PATH="$baml_bin:$PATH"
export DO_NOT_TRACK=1 BAML_CLI_ALLOW_DIRECT=1
export BOUNDARY_API_KEY=${BOUNDARY_API_KEY:-local}
mkdir -p "$(dirname "$out")"
baml-cli --agent-skill-check off pack -o "$out" \
  -f supervisor.run -f rounds.round -f page.page
