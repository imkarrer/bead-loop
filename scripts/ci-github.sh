#!/usr/bin/env bash
# shellcheck disable=SC2034  # token and repo are for the sourcing script
# The agent's GitHub credential and repo, for the steps that write to GitHub
# (ci-merge.sh, ci.sh release). Sourced, not run: sets `token` and `repo`.
#
# The token is GITHUB_TOKEN when set, else the x-access-token in the git url rewrite
# the agent clones with (GIT_CONFIG_KEY_n). The repo is owner/name from BUILDKITE_REPO
# (git@github.com:owner/name.git or https://github.com/owner/name(.git)): POSIX ERE has
# no lazy `+?`, so the .git comes off in a second step.
token=${GITHUB_TOKEN:-}
if [ -z "$token" ]; then
  # GIT_CONFIG_KEY_n=url.https://x-access-token:TOKEN@github.com/.insteadOf
  while IFS='=' read -r k v; do
    case $k in GIT_CONFIG_KEY_*) t=$(printf '%s' "$v" | sed -nE 's|.*x-access-token:([^@]+)@github\.com.*|\1|p'); [ -n "$t" ] && token=$t;; esac
  done < <(env)
fi
repo=$(printf '%s' "${BUILDKITE_REPO:-}" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)$|\1|p' | sed 's/\.git$//')
