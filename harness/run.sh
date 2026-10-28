#!/usr/bin/env bash
# Runs repeated Codex sessions until the run deadline, the session cap, or a STOP file.
# Each session starts with a fresh context and resumes from .nightshift/STATE.md.
#
# The harness (this script, PROMPT.md, codex-config.toml, GOALS.md, and the resolved
# configuration) is read from NIGHTSHIFT_HARNESS, a root-owned copy taken from the
# default branch, so the agent cannot change its own instructions. The model is reached
# through a key-injecting proxy at NIGHTSHIFT_MODEL_URL that runs as another user; no
# API key is in this environment.
#
# Required env: NIGHTSHIFT_OUT, NIGHTSHIFT_DEADLINE (epoch seconds), NIGHTSHIFT_HARNESS,
#               NIGHTSHIFT_MODEL_URL (for example http://127.0.0.1:18080/v1),
#               NIGHTSHIFT_MODEL
# Optional env: NIGHTSHIFT_FALLBACK_MODEL, NIGHTSHIFT_MAX_SESSIONS, NIGHTSHIFT_RUN_ID,
#               NIGHTSHIFT_BASE (the default branch, named in the prompt)
set -uo pipefail

: "${NIGHTSHIFT_OUT:?}" "${NIGHTSHIFT_DEADLINE:?}" "${NIGHTSHIFT_HARNESS:?}" "${NIGHTSHIFT_MODEL_URL:?}" "${NIGHTSHIFT_MODEL:?}"
model="$NIGHTSHIFT_MODEL"
fallback="${NIGHTSHIFT_FALLBACK_MODEL:-}"
max_sessions="${NIGHTSHIFT_MAX_SESSIONS:-8}"
run_id="${NIGHTSHIFT_RUN_ID:-local}"
base="${NIGHTSHIFT_BASE:-}"
# Both feed shell arithmetic, which evaluates anything that is not a plain number.
[[ "$NIGHTSHIFT_DEADLINE" =~ ^[0-9]+$ && "$max_sessions" =~ ^[0-9]+$ ]] || {
	echo "::error::NIGHTSHIFT_DEADLINE and NIGHTSHIFT_MAX_SESSIONS must be whole numbers."
	exit 1
}
models=("$model")
[[ -n "$fallback" && "$fallback" != "$model" ]] && models+=("$fallback")
branch="$(jq -r '.branch // empty' "$NIGHTSHIFT_HARNESS/config.json" 2>/dev/null || true)"

export CODEX_HOME="$NIGHTSHIFT_OUT/codex-home"
mkdir -p "$CODEX_HOME" "$NIGHTSHIFT_OUT/questions"
cp "$NIGHTSHIFT_HARNESS/codex-config.toml" "$CODEX_HOME/config.toml"
touch "$NIGHTSHIFT_OUT/inbox.md" "$NIGHTSHIFT_OUT/sessions.log"

# One bullet per check command. A command that contains a backtick gets a double-backtick
# span so it still renders as one literal command.
# shellcheck disable=SC2016 # Markdown code spans, not command substitutions.
check_list() {
	local cmd
	while IFS= read -r cmd || [[ -n "$cmd" ]]; do
		[[ -n "$cmd" ]] || continue
		if [[ "$cmd" == *'`'* ]]; then
			printf -- '- `` %s ``\n' "$cmd"
		else
			printf -- '- `%s`\n' "$cmd"
		fi
	done <"$NIGHTSHIFT_HARNESS/checks.txt"
}

# shellcheck disable=SC2016 # Markdown code spans, not command substitutions.
build_prompt() {
	local session="$1" minutes_left="$2" active_model="$3"
	cat "$NIGHTSHIFT_HARNESS/PROMPT.md"
	printf '\n## Goals\n\n'
	cat "$NIGHTSHIFT_HARNESS/GOALS.md"
	if [[ -s "$NIGHTSHIFT_HARNESS/instructions.md" ]]; then
		printf '\n## Repository instructions\n\n'
		cat "$NIGHTSHIFT_HARNESS/instructions.md"
	fi
	if [[ -s "$NIGHTSHIFT_HARNESS/checks.txt" ]]; then
		printf '\n## Checks\n\n'
		check_list
	fi
	printf '\n## Owner inbox\n\n'
	if [[ -s "$NIGHTSHIFT_OUT/inbox.md" ]]; then cat "$NIGHTSHIFT_OUT/inbox.md"; else echo "No open questions."; fi
	if [[ -s "$NIGHTSHIFT_OUT/pr-feedback.md" ]]; then
		printf '\n## Pull request feedback\n\n'
		cat "$NIGHTSHIFT_OUT/pr-feedback.md"
	fi
	printf '\n## This session\n\n'
	printf -- '- Run id: %s\n- Model: %s\n- Session %s of at most %s\n' "$run_id" "$active_model" "$session" "$max_sessions"
	[[ -n "$branch" ]] && printf -- '- Working branch: `%s`\n' "$branch"
	[[ -n "$base" ]] && printf -- '- Default branch: `%s` (compare against `origin/%s`)\n' "$base" "$base"
	printf -- '- About %s minutes remain in this run. Leave time to commit and update memory.\n' "$minutes_left"
}

for ((session = 1; session <= max_sessions; session++)); do
	[[ -e "$NIGHTSHIFT_OUT/STOP" ]] && { echo "STOP file present; ending run."; break; }
	minutes_left=$(((NIGHTSHIFT_DEADLINE - $(date +%s)) / 60))
	((minutes_left < 15)) && { echo "Less than 15 minutes left; ending run."; break; }

	ok=false
	for active_model in "${models[@]}"; do
		# Recomputed per attempt, so a fallback never runs past the deadline.
		minutes_left=$(((NIGHTSHIFT_DEADLINE - $(date +%s)) / 60))
		((minutes_left < 10)) && { echo "Too little time left for $active_model."; break; }
		budget=$((minutes_left < 75 ? minutes_left - 5 : 70))
		echo "::group::session $session · $active_model · ${budget}m budget"
		build_prompt "$session" "$minutes_left" "$active_model" |
			timeout -k 2m "${budget}m" codex exec \
				--model "$active_model" \
				-c "model_providers.keyproxy.base_url=\"$NIGHTSHIFT_MODEL_URL\"" \
				--dangerously-bypass-approvals-and-sandbox \
				--output-last-message "$NIGHTSHIFT_OUT/session-$session.md" \
				-
		rc=$?
		echo "::endgroup::"
		printf '%s\tsession=%s\tmodel=%s\texit=%s\n' "$(date -u +%FT%TZ)" "$session" "$active_model" "$rc" >>"$NIGHTSHIFT_OUT/sessions.log"
		# 0 is a normal finish; 124 means the session used its whole time budget.
		if ((rc == 0 || rc == 124)); then
			ok=true
			break
		fi
		echo "::warning::$active_model exited with $rc"
	done
	$ok || { echo "::error::All models failed in session $session; ending run."; break; }
done
