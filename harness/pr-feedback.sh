#!/usr/bin/env bash
# Reports what blocks the open Nightshift PR: unresolved review threads started by the
# owner or by code scanning, and failing checks on its head commit. Threads from anyone
# else are left out, because the repository may be public and the text reaches the agent.
#
# Usage: pr-feedback.sh count   prints the number of findings (0 when there is no PR)
#        pr-feedback.sh report  prints Markdown for the agent prompt (empty when none)
# Requires GH_TOKEN (read access), GH_REPO (owner/name), OWNER, NIGHTSHIFT_BRANCH (the
# working branch), and NIGHTSHIFT_BASE (the default branch the PR targets).
set -euo pipefail

# gh prints an API error's JSON body on stdout, even with --jq. Keep stdout only on
# success, so a capture with a fallback never mistakes an error for data.
gh() { local out; out="$(command gh "$@")" || return; [[ -z "$out" ]] || printf '%s\n' "$out"; }

usage() {
	echo "usage: pr-feedback.sh count|report" >&2
	exit 2
}
(($# == 1)) || usage
mode="$1"
case "$mode" in
count | report) ;;
*) usage ;;
esac
: "${GH_REPO:?}" "${OWNER:?}" "${NIGHTSHIFT_BRANCH:?}" "${NIGHTSHIFT_BASE:?}"
[[ "$GH_REPO" =~ ^[^/]+/[^/]+$ ]] || {
	echo "GH_REPO must be owner/name" >&2
	exit 2
}

# Runs from the root-owned harness copy, before any branch content exists. Branch names
# travel as GraphQL variables, never as query text.
# shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
query='query($owner: String!, $name: String!, $head: String!, $base: String!) {
  repository(owner: $owner, name: $name) {
    pullRequests(headRefName: $head, baseRefName: $base, states: OPEN, first: 5) {
      nodes {
        number
        headRepository { nameWithOwner }
        reviewThreads(first: 100) {
          nodes {
            isResolved
            isOutdated
            path
            line
            comments(first: 1) { nodes { author { login } body } }
          }
        }
        commits(last: 1) {
          nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name conclusion }
            ... on StatusContext { context state }
          } } } } }
        }
      }
    }
  }
}'

data="$(gh api graphql -f query="$query" -f owner="${GH_REPO%/*}" -f name="${GH_REPO#*/}" \
	-f head="$NIGHTSHIFT_BRANCH" -f base="$NIGHTSHIFT_BASE")"
# Same-repository PRs only; a fork can open a PR from a branch with the same name.
pr="$(jq --arg repo "$GH_REPO" '[.data.repository.pullRequests.nodes[] | select(.headRepository.nameWithOwner == $repo)][0] // empty' <<<"$data")"
if [[ -z "$pr" ]]; then
	[[ "$mode" == count ]] && echo 0
	exit 0
fi

threads="$(jq --arg owner "$OWNER" '[.reviewThreads.nodes[]
  | select(.isResolved | not)
  | select(.comments.nodes[0].author.login as $a | $a == $owner or $a == "github-advanced-security")]' <<<"$pr")"
failing="$(jq '[.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [] | .[]
  | select((.conclusion // .state) as $s | $s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT")
  | (.name // .context)] | unique' <<<"$pr")"

if [[ "$mode" == count ]]; then
	jq -n --argjson t "$threads" --argjson f "$failing" '($t | length) + ($f | length)'
	exit 0
fi

if [[ "$(jq 'length' <<<"$threads")" == 0 && "$(jq 'length' <<<"$failing")" == 0 ]]; then
	exit 0
fi
number="$(jq -r .number <<<"$pr")"
printf 'Open PR #%s has findings that block merging. Fix them before new work.\n\n' "$number"
jq -r '.[] | "### Review finding in `\(.path):\(.line // "?")` (\(.comments.nodes[0].author.login))\(if .isOutdated then ", on a line that has since changed" else "" end)\n\n\(.comments.nodes[0].body[0:2000])\n"' <<<"$threads"
if [[ "$(jq 'length' <<<"$failing")" != 0 ]]; then
	printf '### Failing checks\n\n'
	jq -r '.[] | "- \(.)"' <<<"$failing"
fi
