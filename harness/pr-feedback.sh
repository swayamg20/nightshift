#!/usr/bin/env bash
# Reports what blocks the open Nightshift PR: unresolved review threads started by the
# owner or by code scanning, and failing checks on its head commit. Threads from anyone
# else are left out, because the repository may be public and the text reaches the agent.
#
# Usage: pr-feedback.sh count   prints the number of findings (0 when there is no PR)
#        pr-feedback.sh key     prints which threads and checks the findings are, as
#                               sorted, comma-separated 8-hex-digit hashes, not their text
#                               (none when there are no findings)
#        pr-feedback.sh report  prints Markdown for the agent prompt (empty when none)
# Requires GH_TOKEN (read access), GH_REPO (owner/name), OWNER, NIGHTSHIFT_BRANCH (the
# working branch), and NIGHTSHIFT_BASE (the default branch the PR targets).
set -euo pipefail

# gh prints an API error's JSON body on stdout, even with --jq. Keep stdout only on
# success, so a capture with a fallback never mistakes an error for data.
gh() { local out; out="$(command gh "$@")" || return; [[ -z "$out" ]] || printf '%s\n' "$out"; }

usage() {
	echo "usage: pr-feedback.sh count|key|report" >&2
	exit 2
}
(($# == 1)) || usage
mode="$1"
case "$mode" in
count | key | report) ;;
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
            id
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
            ... on CheckRun { name conclusion title summary text detailsUrl databaseId }
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
	case "$mode" in
	count) echo 0 ;;
	key) echo none ;;
	esac
	exit 0
fi

threads="$(jq --arg owner "$OWNER" '[.reviewThreads.nodes[]
  | select(.isResolved | not)
  | select(.comments.nodes[0].author.login as $a | $a == $owner or $a == "github-advanced-security")]' <<<"$pr")"
failed_runs="$(jq '[.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [] | .[]
  | select((.conclusion // .state) as $s | $s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT")]
  | unique_by(.name // .context)' <<<"$pr")"
failing="$(jq '[.[] | (.name // .context)]' <<<"$failed_runs")"

if [[ "$mode" == count ]]; then
	jq -n --argjson t "$threads" --argjson f "$failing" '($t | length) + ($f | length)'
	exit 0
fi
# A thread or a failing check name hashes the same on any head commit, so the gate can
# tell new findings from ones a run has already seen.
if [[ "$mode" == key ]]; then
	hashes="$(jq -rn --argjson t "$threads" --argjson f "$failing" '($t | map("thread " + .id)) + ($f | map("check " + .)) | .[]' |
		while IFS= read -r id; do printf '%s' "$id" | sha256sum | cut -c1-8; done | sort -u | paste -sd, -)"
	echo "${hashes:-none}"
	exit 0
fi

if [[ "$(jq 'length' <<<"$threads")" == 0 && "$(jq 'length' <<<"$failing")" == 0 ]]; then
	exit 0
fi
number="$(jq -r .number <<<"$pr")"
printf 'Open PR #%s has findings that block merging. Fix them before new work.\n\n' "$number"
jq -r '.[] | "### Review finding in `\(.path):\(.line // "?")` (\(.comments.nodes[0].author.login))\(if .isOutdated then ", on a line that has since changed" else "" end)\n\n\(.comments.nodes[0].body[0:2000])\n"' <<<"$threads"
# Each failing check with its own output, and for workflow jobs the end of the job log,
# so the agent can fix the failure instead of asking what it was.
jq -c '.[]' <<<"$failed_runs" | while IFS= read -r check; do
	name="$(jq -r '.name // .context' <<<"$check")"
	printf '### Failing check: %s\n\n' "$name"
	jq -r '[.title, .summary, .text] | map(select(. != null and . != "")) | join("\n\n") | .[0:3000]' <<<"$check"
	url="$(jq -r '.detailsUrl // ""' <<<"$check")"
	job="$(jq -r '.databaseId // ""' <<<"$check")"
	# A workflow job's check run id is its job id.
	if [[ "$url" == *"/actions/runs/"* && "$job" =~ ^[0-9]+$ ]]; then
		if log="$(gh api "repos/$GH_REPO/actions/jobs/$job/logs" 2>/dev/null)"; then
			# shellcheck disable=SC2016 # Markdown code fence, not command substitution.
			log="$(sed -E 's/\x1b\[[0-9;]*m//g; s/^[0-9T:.-]+Z //' <<<"$log")"
			# The lines before the first error marker say what failed; the end of a job
			# log is only cleanup.
			first_error="$(grep -n -m1 '^##\[error\]' <<<"$log" | cut -d: -f1 || true)"
			if [[ -n "$first_error" ]]; then
				excerpt="$(sed -n "$((first_error > 60 ? first_error - 60 : 1)),$((first_error + 10))p" <<<"$log")"
			else
				excerpt="$(tail -n 80 <<<"$log")"
			fi
			# shellcheck disable=SC2016 # Markdown code fence, not command substitution.
			printf '\nFrom the job log:\n\n```text\n%s\n```\n' "$(cut -c1-300 <<<"$excerpt" | head -c 6000)"
		fi
	fi
	printf '\n'
done
