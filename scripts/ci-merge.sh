#!/usr/bin/env bash
# Merge the pull request this build is for. The last step of a PR build, behind a
# wait, so it runs only when every step before it passed. The opt-in is the `automerge`
# label on the live PR, read here and not from the build: the build's copy is taken when
# its event arrived, and the loop labels a PR a moment after opening it, so that copy is
# usually empty. Squash, as the merges done by hand are. A label added after the build
# ended is not lost: the pipeline object also builds on the `labeled` event for this
# label (homelab hub/pipelines/bead-loop.json), and that build runs this step again.
#
# Two things keep this honest. The merge names the commit the build tested, and GitHub
# refuses (409) if the PR head has moved since — or, when main requires this build's own
# status check and so cannot be merged from inside it, GitHub's auto-merge is armed for
# that sha and merges when the build reports green. And a label removed while the build ran
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

# The merge names the commit this build tested. When main requires the build's own
# status check (branch protection on a public repo), that check is still pending while
# this step — part of the build — runs, and GitHub refuses with 405; then the request
# becomes GitHub's auto-merge, bound to the same sha (expectedHeadOid: a moved head is
# refused here too), and GitHub squash-merges the moment the build reports green, a
# few seconds after this step ends. Any other refusal is a failure, as before.
title=$(printf '%s' "$pr" | jq -r .title); base=$(printf '%s' "$pr" | jq -r .base.ref)
#
# The two can race: the PUT a moment before GitHub counts the last required check says
# 405 "pending", and by the time auto-merge is asked for, GitHub counts it and refuses
# auto-merge because the PR is already mergeable ("clean status" / "unstable status",
# the latter when only an unrequired status such as this build's own is not green:
# bl-3x2.3's #131, 25 Sep). That refusal means "merge it now": the PUT is tried again.
body=$(jq -cn --arg sha "$sha" '{merge_method: "squash", sha: $sha}')
node_id=$(printf '%s' "$pr" | jq -r .node_id)
q='mutation($id: ID!, $sha: GitObjectID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH, expectedHeadOid: $sha}) { pullRequest { autoMergeRequest { enabledAt } } } }'
for attempt in 1 2 3; do
  out=$(curl -sS -X PUT "https://api.github.com/repos/$repo/pulls/$number/merge" \
    -H "authorization: Bearer $token" -H "accept: application/vnd.github+json" -H "x-github-api-version: 2022-11-28" \
    -H "content-type: application/json" -d "$body" -w '\n%{http_code}')
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" -lt 300 ]; then
    echo "merged #$number \"$title\" as $(printf '%s' "$out" | jq -r '.sha[0:7]') into $base"
    exit 0
  fi
  message=$(printf '%s' "$out" | jq -r '.message // "(no message)"')
  case "$code:$message" in
    405:*"status check"*"pending"*|405:*"status check"*"expected"*) ;;
    *) fail "PUT /repos/$repo/pulls/$number/merge → $code: $message" ;;
  esac
  gql=$(curl -sS -X POST https://api.github.com/graphql -H "authorization: Bearer $token" -H "content-type: application/json" \
    -d "$(jq -cn --arg q "$q" --arg id "$node_id" --arg sha "$sha" '{query: $q, variables: {id: $id, sha: $sha}}')")
  errors=$(printf '%s' "$gql" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null || true)
  if [ -z "$errors" ] || grep -qi 'already' <<<"$errors"; then   # armed ("already enabled": a rerun)
    echo "#$number \"$title\": $message — auto-merge armed for ${sha:0:7}; GitHub squash-merges it into $base when this build reports green"
    exit 0
  fi
  if grep -qiE '(clean|unstable) status' <<<"$errors" && [ "$attempt" -lt 3 ]; then
    echo "#$number: auto-merge refused as already mergeable ($errors); merging directly (attempt $((attempt + 1)))"
    sleep 3
    continue
  fi
  fail "auto-merge for #$number refused: $errors"
done
