# shellcheck shell=bash
# The end-to-end suite's fixture: the packed binary run as the unit runs it, against real
# git, real bd and a real gate, with gh and the model servers scripted. Sourced by
# test/e2e/run.sh; each case calls `setup` first and gets a world of its own under $T.
#
#   $T/origin.git        the bare remote the loop pushes to
#   $T/repo              the checkout it watches, with a bd database and .bead-loop.toml
#   $T/home              HOME: the global config, the state dir, nothing of yours
#   $T/ctrl              the stubs' scripts and records (model.mjs, bin/gh)
E2E=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP=${SUP:-$E2E/../../target/bead-supervisor}
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com
export DO_NOT_TRACK=1 BAML_CLI_ALLOW_DIRECT=1 BOUNDARY_API_KEY=local
unset BEAD_LOOP_WORKTREE
REAL_PATH=$PATH

# setup [GATE]: a repo with one bead, t's own, labelled for the loop (MERGE=... for a
# merge mode other than auto), on stages
# fake/coder (worker) and fake/reviewer, one attempt each.
setup() {
  T=$(cd "$(mktemp -d)" && pwd -P)
  export T E2E_CTRL=$T/ctrl E2E_ORIGIN=$T/origin.git HOME=$T/home
  export PATH=$E2E/bin:$REAL_PATH
  mkdir -p "$E2E_CTRL/gh" "$E2E_CTRL/replies" "$HOME/.config/bead-loop"
  git init -q --bare -b main "$E2E_ORIGIN"
  git clone -q "$E2E_ORIGIN" "$T/repo" 2>/dev/null
  REPO=$T/repo
  (
    cd "$REPO" || exit
    git checkout -q -b main
    echo base >README
    bd init --quiet --prefix t >/dev/null 2>&1
    printf 'label = "delegate:local"\nbase = "main"\ngate = %s\nmerge = "%s"\nsandbox = false\n' \
      "'${1:-true}'" "${MERGE:-auto}" >.bead-loop.toml   # a TOML literal string: a gate may quote, not use '
    git add -A && git commit -qm base && git push -q -u origin main
  )
  BEAD=$(cd "$REPO" && bd create "Do the thing" -d "Write work.txt" --acceptance "test -e work.txt" \
    -l delegate:local --json | jq -r .id)
  node "$E2E/model.mjs" "$E2E_CTRL" &
  MODEL_PID=$!
  until [ -s "$E2E_CTRL/port" ]; do sleep 0.05; done
  local url
  url=http://127.0.0.1:$(cat "$E2E_CTRL/port")/v1
  cat >"$HOME/.config/bead-loop/config.toml" <<EOF
on_exhaust = "park"
heartbeat_seconds = 1

[providers.fake]
url = "$url"
parallel = 2

[providers.claude]
harness = "claude-code"
parallel = 2

${STAGES:-$(stage local fake/coder fake/reviewer 1)}
EOF
  export DEVBOX_URL=$url ACBOX_URL=$url
}

# stage NAME WORKER REVIEWER ATTEMPTS: one [[stages]] table, for STAGES=... before setup.
stage() {
  printf '[[stages]]\nname = "%s"\nworker = "%s"\nreviewer = "%s"\nattempts = %s\n\n' "$@"
}

teardown() {
  if [ -n "${MODEL_PID:-}" ]; then kill "$MODEL_PID" 2>/dev/null || true; fi
  MODEL_PID=
  # Rounds the loop started outlive its tick; stop this case's, by pid (never pkill -f:
  # a live loop's rounds carry the same words in their command lines).
  local pids
  pids=$(ps -eo pid=,comm=,args= | awk -v t="$T" '$2 == "bead-supervisor" && index($0, t) {print $1}')
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  true
}

# reply MODEL JSON...: queue scripted replies for MODEL, in order.
reply() {
  local model=$1; shift
  local dir=$E2E_CTRL/replies/$model n
  mkdir -p "$dir"
  n=$(find "$dir" -maxdepth 1 -name '*.json' | wc -l)
  for r in "$@"; do
    n=$((n + 1))
    printf '%s\n' "$r" >"$dir/$(printf '%03d' "$n").json"
  done
}

# tick N: the loop for N passes, as the unit runs it.
tick() {
  (cd "$REPO" && "$SUP" run --config_file "$REPO/.bead-loop.toml" --ticks "${1:-1}") >>"$T/sup.log" 2>&1
}

STATE() { echo "$HOME/.local/state/bead-loop/repo/baml"; }
events() { jq -r .kind "$(STATE)/beads/$BEAD/events.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
last_event() { jq -r .kind "$(STATE)/beads/$BEAD/events.jsonl" 2>/dev/null | tail -1; }
# until_event KIND [SECONDS]: tick until the bead's newest event is KIND.
until_event() {
  local want=$1 limit=${2:-60} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    tick 1
    events | grep -qw -- "$want" && return 0
  done
  return 1
}
bd_field() { (cd "$REPO" && bd show "$BEAD" --json | jq -r ".[0].$1"); }

# ---- assertions -----------------------------------------------------------------
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$CASE" "$1"; }
assert_eq() { [ "$1" = "$2" ] && ok || bad "$3: expected [$2] got [$1]"; }
assert_match() { grep -q -- "$2" <<<"$1" && ok || bad "$3: [$1] lacks [$2]"; }
assert_nomatch() { grep -q -- "$2" <<<"$1" && bad "$3: [$1] has [$2]" || ok; }

# until_place PLACE [SECONDS]: tick until the page's view has the bead at PLACE.
until_place() {
  local want=$1 limit=${2:-60} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    tick 1
    [ "$(jq -r --arg id "$BEAD" '.beads[] | select(.id==$id) | .place' "$(STATE)/view.json" 2>/dev/null)" = "$want" ] && return 0
  done
  return 1
}

# tell WHAT [ARGS...]: a lever, as the page and `bead-supervisor tell` pull it.
tell() {
  local what=$1; shift
  (cd "$REPO" && "$SUP" tell --config_file "$REPO/.bead-loop.toml" --id "$BEAD" --what "$what" "$@") >>"$T/sup.log" 2>&1
}

# ---- replies and reads the cases share ------------------------------------------

done_report() { printf '{"content":"{\\"outcome\\":\\"done\\",\\"summary\\":\\"%s\\"}"}' "${1:-ok}"; }
approve() { echo '{"content":"{\"decision\":\"Approve\",\"reason\":\"ok\",\"work_order\":null}"}'; }
write_work() { echo '{"tool":"write_file","args":{"path":"work.txt","content":"done\n"}}'; }
commit() { printf '{"tool":"run","args":{"command":"git add -A && git commit -q -m \\"%s: work\\""}}' "$BEAD"; }
# The tool result the model was sent last, in the newest request.
last_tool_result() {
  local f; f=$(find "$E2E_CTRL/requests" -name '*.json' | sort | tail -1)
  jq -r '[.messages[] | select(.role=="tool")] | last | .content' "$f"
}
claude_reply() { local n=$1; shift; mkdir -p "$E2E_CTRL/claude/replies"; jq -cn "$@" >"$E2E_CTRL/claude/replies/$n.json"; }
view_bead() { jq -r --arg id "$BEAD" ".beads[] | select(.id==\$id) | $1" "$(STATE)/view.json"; }

