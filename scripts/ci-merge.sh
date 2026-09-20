#!/usr/bin/env bash
# Merge the pull request this build is for. The last step of a PR build, behind a
# wait, so it runs only when every step before it passed. The opt-in is the `automerge`
# label on the live PR, read here and not from the build: the build's copy is taken when
# its event arrived, and the loop labels a PR a moment after opening it, so that copy is
# usually empty. Squash, as the merges done by hand are.
#
# Two things keep this honest. The merge names the commit the build tested, and GitHub
# refuses (409) if the PR head has moved since. And a label removed while the build ran
# is a withdrawn request, not a failure.
#
# The credential is the agent's token for this repo — GITHUB_TOKEN when set, else the
# x-access-token in the git url rewrite the agent clones with (GIT_CONFIG_KEY_n). No
# token with the label set is a failure, not a skip: the label asked for a merge, and a
# green build that quietly did not merge is the outcome nobody can tell from a merge
# that has not happened yet.
#
# The same script as inquire-platform's scripts/ci-merge.mjs, in bash: this repo's
# checks need no node beyond the UI server.
set -euo pipefail
LABEL=${AUTOMERGE_LABEL:-automerge}

fail() { echo "automerge: $*" >&2; exit 1; }

number=${BUILDKITE_PULL_REQUEST:-}
sha=${BUILDKITE_COMMIT:-}
# shellcheck source=scripts/ci-github.sh
. "$(dirname "$0")/ci-github.sh"   # token, repo (build #2's automerge got a 404 on "bead-loop.git")
if [ -z "$number" ] || [ "$number" = false ] || [ -z "$sha" ] || [ -z "$repo" ]; then
  fail "not a pull request build (BUILDKITE_PULL_REQUEST=$number, BUILDKITE_REPO=${BUILDKITE_REPO:-})"
fi
[ -n "$token" ] || fail "no GitHub token: set GITHUB_TOKEN on the agent, or a GIT_CONFIG_KEY_n url rewrite with x-access-token"

github() {  # github METHOD PATH [BODY]
  local method=$1 path=$2 body=${3:-} out code
  out=$(curl -sS -X "$method" "https://api.github.com$path" \
    -H "authorization: Bearer $token" -H "accept: application/vnd.github+json" -H "x-github-api-version: 2022-11-28" \
    ${body:+-H "content-type: application/json" -d "$body"} -w '\n%{http_code}')
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" -ge 300 ]; then
    # 405: not mergeable (conflicts, or a check GitHub itself requires); 409: head moved;
    # 404/403: the token cannot see or write the repo.
    fail "$method $path → $code: $(printf '%s' "$out" | jq -r '.message // "(no message)"')"
  fi
  printf '%s' "$out"
}

pr=$(github GET "/repos/$repo/pulls/$number")
state=$(printf '%s' "$pr" | jq -r .state)
if [ "$state" != open ]; then
  echo "#$number is $([ "$(printf '%s' "$pr" | jq -r .merged)" = true ] && echo 'already merged' || echo "$state"); nothing to do"; exit 0
fi
if [ "$(printf '%s' "$pr" | jq -r .draft)" = true ]; then echo "#$number is a draft; not merging"; exit 0; fi
if ! printf '%s' "$pr" | jq -e --arg l "$LABEL" '.labels | any(.name == $l)' >/dev/null; then
  echo "#$number no longer has the $LABEL label; not merging"; exit 0
fi
head=$(printf '%s' "$pr" | jq -r .head.sha)
if [ "$head" != "$sha" ]; then
  # A newer push has its own build (and "cancel intermediate builds" is probably
  # cancelling this one). Say so rather than let GitHub's 409 do it.
  fail "#$number head is ${head:0:7}, this build tested ${sha:0:7}; the newer build merges"
fi

result=$(github PUT "/repos/$repo/pulls/$number/merge" "$(jq -cn --arg sha "$sha" '{merge_method: "squash", sha: $sha}')")
echo "merged #$number \"$(printf '%s' "$pr" | jq -r .title)\" as $(printf '%s' "$result" | jq -r '.sha[0:7]') into $(printf '%s' "$pr" | jq -r .base.ref)"
