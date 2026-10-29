#!/usr/bin/env bash
# Point bead-loop at the shared models on llm-box, and, if you opt in, at a model on this
# Mac through Ollama: the setup docs/design-multiplayer.md describes. It writes opencode's
# providers (~/.config/opencode/opencode.json, merged, other providers kept) and the
# loop's stages (~/.config/bead-loop/config.toml, rewritten, its repos kept). Either
# file it replaces is copied to FILE.bak-DATE first.
#
#   bash configure-models.sh       asks as it goes; safe to run again
#
# Answers can come from the environment instead: LLMBOX_URL (llm-box's API, ending /v1),
# USE_OLLAMA (yes or no), and ASSUME_DEFAULTS=1 to take every default without asking.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# jq and bash 5 come from the checkout's env.
if ! command -v jq >/dev/null && [ -z "${BEAD_LOOP_IN_ENV:-}" ]; then
  BEAD_LOOP_IN_ENV=1 exec flox activate -d "$ROOT" -- bash "$0" "$@"
fi

OC=${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json
CONFIG=${BEAD_LOOP_CONFIG:-$HOME/.config/bead-loop}/config.toml
MAC_MODEL=gpt-oss-32k   # Ollama's gpt-oss:20b with a 32k context: what an opencode agent's prompts need

say() { printf '\n==> %s\n' "$*"; }
ask() {
  local a=
  if [ -z "${ASSUME_DEFAULTS:-}" ] && [ -r /dev/tty ]; then read -r -p "    $1${2:+ [$2]} " a </dev/tty || true; fi
  printf '%s' "${a:-${2:-}}"
}
backup() {
  [ -f "$1" ] || return 0
  local b; b="$1.bak-$(date +%Y%m%d%H%M%S)"
  cp "$1" "$b"; echo "    the old one is $b"
}

say "llm-box"
url=${LLMBOX_URL:-$(ask "llm-box's address (Isaac sends it; on his home network it is this):" http://192.168.1.51:8100/v1)}
url=${url%/}
if ! models=$(curl -fsS -m 10 "$url/models"); then
  echo "    Cannot reach $url/models. Is Tailscale connected, with llm-box shared to you?"
  exit 1
fi
for m in coder reviewer utility; do
  if ! jq -e --arg m "$m" 'any(.data[]; .id == $m)' <<<"$models" >/dev/null; then
    echo "    llm-box at $url does not serve \"$m\"; it serves: $(jq -r '[.data[].id] | join(", ")' <<<"$models")"
    exit 1
  fi
done
echo "    reachable; coder, reviewer and utility are there"

say "A model on this Mac (optional)"
echo "    Ollama can run gpt-oss:20b on this Mac as the first worker, so the shared box"
echo "    only reviews. It is a 13 GB download and needs about 16 GB of free memory."
gib=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
default=no; [ "$gib" -ge 24 ] && default=yes
[ "$gib" -gt 0 ] && echo "    This Mac has $gib GB."
use_ollama=${USE_OLLAMA:-$(ask "Use a model on this Mac? (yes/no)" "$default")}
if [ "$use_ollama" = yes ]; then
  if ! command -v ollama >/dev/null; then
    echo "    Ollama is not installed. Your browser will open its download page: install it and open it once."
    open https://ollama.com/download || true
    until command -v ollama >/dev/null; do ask "Press Return once Ollama is installed and open." >/dev/null; done
  fi
  ollama pull gpt-oss:20b
  mf=$(mktemp); printf 'FROM gpt-oss:20b\nPARAMETER num_ctx 32768\n' >"$mf"
  ollama create "$MAC_MODEL" -f "$mf"; rm -f "$mf"
fi

say "opencode's providers: $OC"
mkdir -p "$(dirname "$OC")"
backup "$OC"
current=$( [ -f "$OC" ] && cat "$OC" || echo '{}')
jq --arg url "$url" --arg mac "$use_ollama" --arg mm "$MAC_MODEL" '
  def model(n; ctx; out): {name: n, limit: {context: ctx, output: out}};
  .["$schema"] //= "https://opencode.ai/config.json"
  | .provider.llmbox = {npm: "@ai-sdk/openai-compatible", name: "llm-box", options: {baseURL: $url},
      models: {coder: model("coder"; 32768; 8192), reviewer: model("reviewer"; 32768; 8192), utility: model("utility"; 16384; 4096)}}
  | if $mac == "yes" then .provider.mac = {npm: "@ai-sdk/openai-compatible", name: "Ollama on this Mac",
      options: {baseURL: "http://127.0.0.1:11434/v1"}, models: {($mm): model("gpt-oss 20b, 32k context"; 32768; 8192)}}
    else . end' <<<"$current" >"$OC.tmp" && mv "$OC.tmp" "$OC"
echo "    llmbox$([ "$use_ollama" = yes ] && echo ", mac")"

say "bead-loop's stages: $CONFIG"
mkdir -p "$(dirname "$CONFIG")"
repos=$(grep -E '^repos *=' "$CONFIG" 2>/dev/null | head -n1 || true)
backup "$CONFIG"
{
  echo "# Written by scripts/configure-models.sh on $(date +%Y-%m-%d); the file before it is beside it as .bak-DATE."
  echo "${repos:-repos = []}"
  echo 'worker_timeout = 1800'
  echo 'on_exhaust = "park"'
  echo 'precheck_model = "llmbox/utility"   # llm-box'"'"'s small model checks a passing gate before review'
  echo
  echo '[providers.llmbox]                  # shared with others: one round at a time from here'
  echo 'parallel = 1'
  if [ "$use_ollama" = yes ]; then
    echo
    echo '[providers.mac]                     # Ollama: one model in memory at a time'
    echo 'parallel = 1'
    echo
    echo '[[stages]]                          # this Mac writes, llm-box reviews'
    echo "worker = \"mac/$MAC_MODEL\""
    echo 'reviewer = "llmbox/reviewer"'
    echo 'failures = 2'
  fi
  echo
  echo '[[stages]]                          # llm-box'"'"'s 80B writes'
  echo 'worker = "llmbox/coder"'
  echo 'reviewer = "llmbox/reviewer"'
  echo "failures = $([ "$use_ollama" = yes ] && echo 1 || echo 2)"
} >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
grep -E '^worker' "$CONFIG" | sed 's/^/    /'

say "Done. The loop reads its config afresh every round: nothing to restart."
