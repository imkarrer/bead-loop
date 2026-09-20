#!/usr/bin/env bash
# One CI step, with the cargo cache where the agent keeps it between builds.
#
#   scripts/ci.sh rust      fmt --check, clippy -D warnings, build, unit tests
#   scripts/ci.sh scripts   syntax, shellcheck, the skills/agents lint
#   scripts/ci.sh suite     test/run.sh against the binary the rust step built
#
# The cache: the agent runs `git clean -ffxdq` in the checkout before every job, which
# would take target/ with it, so the registry and the target directory live beside the
# checkouts — <build-path>/.cache/bead-loop on a Buildkite agent (the one directory
# every layout of the ac-box agent persists), or CI_CACHE_DIR anywhere; with neither, a
# cold build. Cargo's own fingerprints then do the rest: a crate whose inputs did not
# change is not rebuilt, and a push that touches only docs costs a no-op build.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

cache=${CI_CACHE_DIR:-${BUILDKITE_BUILD_PATH:+$BUILDKITE_BUILD_PATH/.cache/bead-loop}}
if [ -n "$cache" ]; then
  mkdir -p "$cache/cargo" "$cache/target"
  export CARGO_HOME=$cache/cargo CARGO_TARGET_DIR=$cache/target
  echo "cargo cache: $cache"
fi
export CARGO_TERM_COLOR=never
target=${CARGO_TARGET_DIR:-$HERE/target}

case ${1:-} in
  rust)
    echo "--- :rust: fmt"; cargo fmt --check
    echo "--- :rust: clippy"; cargo clippy --quiet -- -D warnings
    echo "--- :rust: build"; cargo build --quiet
    echo "--- :rust: unit tests"; cargo test --quiet
    ;;
  scripts)
    echo "--- :bash: syntax"
    bash -n install.sh scripts/*.sh test/run.sh test/lint-skills.sh test/bin/*
    node --check bin/bead-loop-ui test/ui-onclicks.js
    echo "--- :bash: shellcheck"
    shellcheck -S warning install.sh scripts/*.sh test/run.sh test/lint-skills.sh test/bin/*
    echo "--- :memo: skills and agents"
    test/lint-skills.sh
    ;;
  suite)
    [ -x "$target/debug/bead-supervisor" ] || { echo "--- :rust: build"; cargo build --quiet; }
    echo "--- :repeat: the state machine, against $target/debug/bead-supervisor"
    # SUP for the suite; BEAD_SUPERVISOR for the UI server the suite starts (the binary
    # is in the cache dir here, not under the checkout's target/).
    SUP=$target/debug/bead-supervisor BEAD_SUPERVISOR=$target/debug/bead-supervisor test/run.sh
    ;;
  *) echo "usage: scripts/ci.sh rust|scripts|suite" >&2; exit 2 ;;
esac
