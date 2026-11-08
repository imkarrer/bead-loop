#!/usr/bin/env bash
# Print the directory that holds baml-cli 0.25.2, downloading the static binary once.
# The flox env has no baml package, so CI, the gate and the package build call this.
# Prints one path and nothing else.
set -euo pipefail
ver=0.25.2
# The build the tests on this branch were written against.
sha=c5f36acf027ca77e0bf97809ee4b6df0ea6cb200da881cf7cafdccd4ceb8acd7
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset=baml-language-${ver}-x86_64-unknown-linux-musl.tar.gz ;;
  *) echo "baml-cli $ver is pinned for Linux x86_64; this is $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
cache=${CI_CACHE_DIR:-${BUILDKITE_BUILD_PATH:+$BUILDKITE_BUILD_PATH/.cache/bead-loop}}
cache=${cache:-${XDG_CACHE_HOME:-$HOME/.cache}/bead-loop}
dest=$cache/baml-$ver
if [ ! -x "$dest/bin/baml-cli" ]; then
  mkdir -p "$dest"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  url=https://github.com/BoundaryML/baml/releases/download/baml-language-${ver}/${asset}
  curl -fsSL "$url" -o "$tmp/$asset"
  echo "$sha  $tmp/$asset" | sha256sum -c -
  tar -xzf "$tmp/$asset" -C "$dest"
fi
[ -x "$dest/bin/baml-cli" ] || { echo "baml-cli was not in $asset" >&2; exit 1; }
printf '%s\n' "$dest/bin"
