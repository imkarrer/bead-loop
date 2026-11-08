#!/usr/bin/env bash
# One CI step. baml-cli is not in the flox env; scripts/ensure-baml.sh downloads the
# pinned static binary into the agent's cache (or ~/.cache) and prints its directory.
#
#   scripts/ci.sh baml      fmt --check, then the BAML tests (the state machine)
#   scripts/ci.sh scripts   syntax, shellcheck, the skills/agents lint
#   scripts/ci.sh suite     pack the binary and check the subcommands the unit execs
#   scripts/ci.sh package   flox build bead-loop, and test/package.sh on what it built
#   scripts/ci.sh release   main only: that binary as the GitHub release main-<sha7>
#
# The cache: the agent runs `git clean -ffxdq` in the checkout before every job, so
# the downloaded cli lives beside the checkouts — <build-path>/.cache/bead-loop on a
# Buildkite agent, or CI_CACHE_DIR anywhere; with neither, a cold download.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

cache=${CI_CACHE_DIR:-${BUILDKITE_BUILD_PATH:+$BUILDKITE_BUILD_PATH/.cache/bead-loop}}
if [ -n "$cache" ]; then
  mkdir -p "$cache"
  echo "baml cache: $cache"
fi

baml_env() {
  baml_bin=$(scripts/ensure-baml.sh)
  export PATH="$baml_bin:$PATH"
  export DO_NOT_TRACK=1 BAML_CLI_ALLOW_DIRECT=1
  export BOUNDARY_API_KEY=${BOUNDARY_API_KEY:-local}
  export DEVBOX_URL=${DEVBOX_URL:-http://127.0.0.1:8100/v1}
  export ACBOX_URL=${ACBOX_URL:-http://192.168.1.51:8100/v1}
}

case ${1:-} in
  baml)
    baml_env
    echo "--- :hammer: fmt"; baml-cli --agent-skill-check off fmt --check
    echo "--- :test_tube: tests"; baml-cli --agent-skill-check off test
    ;;
  scripts)
    echo "--- :bash: syntax"
    bash -n install.sh scripts/*.sh test/lint-skills.sh test/package.sh
    bash -n bin/bead-loop-ui
    echo "--- :bash: shellcheck"
    shellcheck -S warning install.sh scripts/*.sh test/lint-skills.sh test/package.sh bin/bead-loop-ui
    echo "--- :memo: skills and agents"
    test/lint-skills.sh
    echo "--- :spider_web: the page"
    node scripts/page-html.mjs --check
    node test/ui-onclicks.js test/ui-state.json
    ;;
  suite)
    # The tests ran in the baml step. This is the binary the unit will exec, which the
    # tests never start: run, round and page, and --help, because deploy checks that.
    echo "--- :package: pack"
    scripts/pack.sh "$HERE/target/bead-supervisor"
    "$HERE/target/bead-supervisor" --help >/dev/null
    "$HERE/target/bead-supervisor" run --help >/dev/null
    "$HERE/target/bead-supervisor" round --help >/dev/null
    "$HERE/target/bead-supervisor" page --help >/dev/null
    ;;
  package)
    # What `flox install imkarrer/bead-loop` would install: the manifest's
    # [build.bead-loop], then its files, its runtime PATH and that the binary runs.
    echo "--- :package: flox build bead-loop"; test/package.sh
    ;;
  release)
    # main only, after every check passed: the tested commit's packed binary, published
    # as the GitHub release `main-<sha7>` (the tag at that commit, the binary its one
    # asset). The asset name stays `bead-supervisor`: the deploy script already running
    # on the box asks for that name, and only the next run uses the script from the
    # commit it just installed. A rerun replaces the release; the last ten stay.
    sha=${BUILDKITE_COMMIT:-$(git rev-parse HEAD)}; tag=main-${sha:0:7}
    # shellcheck source=scripts/ci-github.sh
    . "$HERE/scripts/ci-github.sh"   # token, repo
    [ -n "$token" ] || { echo "release: no GitHub token on the agent" >&2; exit 1; }
    [ -n "$repo" ] || repo=$(git remote get-url origin | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)$|\1|p' | sed 's/\.git$//')
    export GH_TOKEN=$token
    echo "--- :package: pack"; scripts/pack.sh "$HERE/target/bead-supervisor"
    bin=$HERE/target/bead-supervisor
    "$bin" --help >/dev/null
    echo "--- :github: release $tag on $repo"
    if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
      gh release delete "$tag" -R "$repo" -y --cleanup-tag; echo "replaced the earlier $tag"
    fi
    gh release create "$tag" -R "$repo" --target "$sha" --latest=false \
      --title "$(git log -1 --format=%s "$sha" | cut -c1-100)" \
      --notes "bead-supervisor packed from $sha by the pipeline (baml fmt, baml test, scripts, the packed binary: green). scripts/deploy.sh on the loop's box installs this asset." \
      "$bin#bead-supervisor"
    echo "published $tag: $(gh release view "$tag" -R "$repo" --json url --jq .url)"
    echo "--- :wastebasket: prune"
    gh release list -R "$repo" --limit 100 --json tagName,createdAt --jq '[.[] | select(.tagName | startswith("main-"))] | sort_by(.createdAt) | reverse | .[10:] | .[].tagName' \
      | while read -r old; do [ -n "$old" ] && gh release delete "$old" -R "$repo" -y --cleanup-tag && echo "pruned $old"; done
    ;;
  *) echo "usage: scripts/ci.sh baml|scripts|suite|package|release" >&2; exit 2 ;;
esac
