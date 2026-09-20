#!/usr/bin/env bash
# One CI step, with the cargo cache where the agent keeps it between builds.
#
#   scripts/ci.sh rust      fmt --check, clippy -D warnings, build, unit tests
#   scripts/ci.sh scripts   syntax, shellcheck, the skills/agents lint
#   scripts/ci.sh suite     test/run.sh against the binary the rust step built
#   scripts/ci.sh release   main only: the release binary as the GitHub release main-<sha7>
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
  release)
    # main only, after every check passed: the tested commit's release binary, published
    # as the GitHub release `main-<sha7>` (the tag at that commit, the binary its one
    # asset). scripts/deploy.sh on the loop's box downloads exactly the release named by
    # origin/main — so what runs there is the build the pipeline proved, byte for byte,
    # and the box needs no compiler. The binary links the flox env's glibc by store
    # path; the box runs it inside the same pinned env (manifest.lock), so the path is
    # there. A rerun replaces the release; the last ten stay, older ones go.
    sha=${BUILDKITE_COMMIT:-$(git rev-parse HEAD)}; tag=main-${sha:0:7}
    # shellcheck source=scripts/ci-github.sh
    . "$HERE/scripts/ci-github.sh"   # token, repo
    [ -n "$token" ] || { echo "release: no GitHub token on the agent" >&2; exit 1; }
    [ -n "$repo" ] || repo=$(git remote get-url origin | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)$|\1|p' | sed 's/\.git$//')
    export GH_TOKEN=$token
    echo "--- :rust: release build"; cargo build --release --quiet
    bin=$target/release/bead-supervisor
    "$bin" --help >/dev/null
    echo "--- :github: release $tag on $repo"
    if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
      gh release delete "$tag" -R "$repo" -y --cleanup-tag; echo "replaced the earlier $tag"
    fi
    gh release create "$tag" -R "$repo" --target "$sha" --latest=false \
      --title "$(git log -1 --format=%s "$sha" | cut -c1-100)" \
      --notes "bead-supervisor built from $sha by the pipeline (fmt, clippy, unit tests, scripts, the state-machine suite: green). scripts/deploy.sh on the loop's box installs this asset." \
      "$bin#bead-supervisor"
    echo "published $tag: $(gh release view "$tag" -R "$repo" --json url --jq .url)"
    echo "--- :wastebasket: prune"
    gh release list -R "$repo" --limit 100 --json tagName,createdAt --jq '[.[] | select(.tagName | startswith("main-"))] | sort_by(.createdAt) | reverse | .[10:] | .[].tagName' \
      | while read -r old; do [ -n "$old" ] && gh release delete "$old" -R "$repo" -y --cleanup-tag && echo "pruned $old"; done
    ;;
  *) echo "usage: scripts/ci.sh rust|scripts|suite|release" >&2; exit 2 ;;
esac
