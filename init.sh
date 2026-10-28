#!/usr/bin/env bash
# Sets up Nightshift in the repository it is run from. It copies the caller workflows
# and the .nightshift/ files, fills in the model endpoint and commit identity, stores
# the model key as a repository secret, and checks the repository settings Nightshift
# depends on. It never commits or pushes: review the files and land them on the
# default branch yourself. Running it again keeps what is already there.
#
# Usage: /path/to/nightshift/init.sh [options]
#
#   --base-url URL     OpenAI-compatible Responses API base URL (agent.base_url)
#   --model NAME       primary model or deployment name (agent.model)
#   --name NAME        commit author and committer name (identity.name)
#   --email EMAIL      commit author and committer email (identity.email)
#   --repo OWNER/NAME  GitHub repository (default: the one gh resolves here)
#   --force            overwrite existing files, including GOALS.md and the agent's
#                      memory, and replace an existing key secret
#   --skip-secret      leave the NIGHTSHIFT_MODEL_API_KEY secret alone
#   --no-github        write files only; make no GitHub API calls
#   -h, --help         show this help
#
# The model key is read from stdin when stdin is not a terminal, for example
# `init.sh --base-url URL < key.txt`, and otherwise from a prompt that does not echo.
# It reaches `gh secret set` on stdin only, never as a command-line argument.
set -euo pipefail

# gh prints an API error's JSON body on stdout, even with --jq. Keep stdout only on
# success, so a capture with a fallback never mistakes an error for data.
gh() { local out; out="$(command gh "$@")" || return; [[ -z "$out" ]] || printf '%s\n' "$out"; }

secret_name=NIGHTSHIFT_MODEL_API_KEY
cfg=.nightshift/config.yml
base_url="" model="" name="" email="" repo=""
force=false skip_secret=false github=true
warnings=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; warnings=$((warnings + 1)); }
say() { printf '%-9s%s\n' "$1" "$2"; }
# Prompts go to stderr (read -p), so these work inside command substitution.
ask() {
	local reply=""
	read -rp "$1${2:+ [$2]}: " reply || true
	printf '%s' "${reply:-${2:-}}"
}
confirm() {
	local reply=""
	read -rp "$1 [y/N] " reply || return 1
	[[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}
# Single-quoted YAML scalar: no escapes except a doubled quote.
yaml_quote() {
	local q="'"
	printf "'%s'" "${1//$q/$q$q}"
}
# The value of a single-line scalar key in the config, without quotes or comment.
config_scalar() {
	local line
	line="$(grep -m1 -E "^[[:space:]]*$1:" "$cfg" 2>/dev/null)" || return 0
	sed -nE "s/^[[:space:]]*$1:[[:space:]]*['\"]?([^'\"#[:space:]]*).*/\1/p" <<<"$line"
}
# Fields from gh --jq are joined with the unit separator: unlike a tab, it does not
# collapse empty fields when read splits them.
us=$'\x1f'

while (($#)); do
	case "$1" in
	--base-url | --model | --name | --email | --repo)
		(($# >= 2)) || die "$1 needs a value"
		case "$1" in
		--base-url) base_url="$2" ;;
		--model) model="$2" ;;
		--name) name="$2" ;;
		--email) email="$2" ;;
		--repo) repo="$2" ;;
		esac
		shift 2
		;;
	--force) force=true && shift ;;
	--skip-secret) skip_secret=true && shift ;;
	--no-github) github=false && shift ;;
	-h | --help) usage && exit 0 ;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
done

interactive=false
[[ -t 0 ]] && interactive=true

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
src="$here/templates"
[[ -d "$src/.nightshift" && -d "$src/.github/workflows" ]] \
	|| die "templates/ not found next to init.sh; run init.sh from a clone of swayamg20/nightshift"
command -v git >/dev/null || die "git is required"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run init.sh from inside the repository to set up"
root="$(cd "$root" && pwd -P)"
[[ "$root" != "$here" ]] || die "run init.sh from the repository to set up, not from the Nightshift clone"
cd "$root"

# Repository facts, and the owner's identity as the default commit identity.
default_branch="" owner="" merge_commits="" default_name="" default_email=""
if $github; then
	command -v gh >/dev/null || die "the GitHub CLI (gh) is required; install it or pass --no-github"
	gh auth status >/dev/null 2>&1 || die "gh is not signed in; run: gh auth login"
	info="$(gh repo view ${repo:+"$repo"} \
		--json nameWithOwner,defaultBranchRef,owner,isInOrganization,mergeCommitAllowed,viewerCanAdminister \
		--jq '[.nameWithOwner, .defaultBranchRef.name, .owner.login, .isInOrganization, .mergeCommitAllowed, .viewerCanAdminister]
			| map(tostring) | join("\u001f")')" \
		|| die "could not find the GitHub repository for $root; pass --repo OWNER/NAME"
	IFS="$us" read -r repo default_branch owner in_org merge_commits can_admin <<<"$info"
	[[ -n "$default_branch" && "$default_branch" != null ]] \
		|| die "$repo has no default branch yet; push a first commit, then run init.sh again"
	# Every trigger compares the commenter with github.repository_owner, which for an
	# organization is the organization's login, so no comment would ever count.
	[[ "$in_org" != true ]] \
		|| die "$repo is owned by the organization $owner. Nightshift only accepts comments from the repository owner, so it needs a user-owned repository."
	viewer="$(gh api user --jq .login 2>/dev/null || true)"
	[[ -z "$viewer" || "$viewer" == "$owner" ]] \
		|| warn "only $owner's replies start runs and merges in $repo; you are signed in as $viewer"
	[[ "$can_admin" == true ]] \
		|| warn "you do not administer $repo, so setting the secret and Actions settings may fail"
	if ident="$(gh api "users/$owner" --jq '[.id, .login, .name // ""] | map(tostring) | join("\u001f")' 2>/dev/null)"; then
		IFS="$us" read -r owner_id owner_login owner_name <<<"$ident"
		default_name="${owner_name:-$owner_login}"
		default_email="$owner_id+$owner_login@users.noreply.github.com"
	fi
	echo "Setting up Nightshift in $root for $repo (default branch: $default_branch)"
else
	echo "Setting up Nightshift in $root (files only)"
fi

# Configuration values are needed only when config.yml is written. Collect them all
# before writing anything, so an interrupted prompt leaves nothing half done.
write_config=false
if [[ ! -e "$cfg" ]] || $force; then write_config=true; fi
if $write_config; then
	template_model="$(sed -nE "s/^  model:[[:space:]]*'?([^'#[:space:]]*).*/\1/p" "$src/$cfg")"
	if $interactive; then
		[[ -n "$base_url" ]] || base_url="$(ask "Model API base URL (OpenAI-compatible Responses API, for example https://api.openai.com/v1)")"
		[[ -n "$model" ]] || model="$(ask "Model or deployment name" "$template_model")"
		[[ -n "$name" ]] || name="$(ask "Commit author name" "$default_name")"
		[[ -n "$email" ]] || email="$(ask "Commit author email" "$default_email")"
	else
		model="${model:-$template_model}" name="${name:-$default_name}" email="${email:-$default_email}"
	fi
	# The same formats the harness enforces, so a bad value fails here rather than on
	# the first run.
	url_re='^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%-]*)*$'
	model_re='^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$'
	name_re='^[^<>"`$\\]{1,100}$'
	email_re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
	[[ -n "$base_url" ]] || die "agent.base_url is required; pass --base-url URL"
	base_url="${base_url%/}"
	[[ "$base_url" =~ $url_re ]] || die "the base URL must be an https:// URL with no query string: $base_url"
	[[ "$model" =~ $model_re ]] || die "the model must be a model or deployment name: $model"
	if [[ -n "$name" || -n "$email" ]]; then
		[[ -n "$name" && -n "$email" ]] || die "set both the identity name and email, or neither"
		[[ "$name" =~ $name_re && "$name" != *[[:cntrl:]]* ]] \
			|| die "the identity name must be one line of at most 100 characters, without < > \" \` \$ or \\"
		[[ "$email" =~ $email_re ]] || die "the identity email must be an email address: $email"
	fi
elif [[ -n "$base_url$model$name$email" ]]; then
	warn "$cfg already exists, so --base-url, --model, --name, and --email were ignored; edit it, or pass --force to rewrite it"
fi

# Copy the templates. Existing files are kept unless --force.
while IFS= read -r -d '' file; do
	rel="${file#"$src"/}"
	state=created
	if [[ -e "$rel" || -L "$rel" ]]; then
		if ! $force; then
			say kept "$rel"
			continue
		fi
		state=replaced
		rm -f "$rel"
	fi
	mkdir -p "$(dirname "$rel")"
	if [[ "$rel" == "$cfg" ]]; then
		ns_name="" ns_email=""
		if [[ -n "$name" ]]; then ns_name="$(yaml_quote "$name")" ns_email="$(yaml_quote "$email")"; fi
		NS_BASE_URL="$(yaml_quote "$base_url")" NS_MODEL="$(yaml_quote "$model")" \
			NS_NAME="$ns_name" NS_EMAIL="$ns_email" awk '
			/^  base_url:/ { print "  base_url: " ENVIRON["NS_BASE_URL"]; next }
			/^  model:/ { print "  model: " ENVIRON["NS_MODEL"]; next }
			ENVIRON["NS_NAME"] != "" && /^# identity:$/ { print "identity:"; next }
			ENVIRON["NS_NAME"] != "" && /^#   name:/ { print "  name: " ENVIRON["NS_NAME"]; next }
			ENVIRON["NS_NAME"] != "" && /^#   email:/ { print "  email: " ENVIRON["NS_EMAIL"]; next }
			{ print }' "$file" >"$rel"
		grep -q "^  base_url: '" "$rel" || die "could not fill in $rel; the template changed shape"
	else
		cp "$file" "$rel"
	fi
	say "$state" "$rel"
done < <(find "$src" -type f ! -name .DS_Store -print0 | sort -z)

work_branch="$(config_scalar branch)"
work_branch="${work_branch:-nightshift}"
ci=.github/workflows/ci.yml
if grep -qE '^[[:space:]]*ci_workflow:' "$cfg" 2>/dev/null; then ci="$(config_scalar ci_workflow)"; fi

# Local hints about the merge configuration. The default branch is what counts, but
# a missing file here usually means a wrong setting.
if [[ -z "$ci" ]]; then
	warn "merge.ci_workflow is empty, so reply merges will be refused; set it to the workflow that runs your checks on pull_request"
elif ! [[ "$ci" =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]]; then
	warn "merge.ci_workflow must be a path like .github/workflows/ci.yml, not $ci"
elif [[ ! -f "$ci" ]]; then
	warn "merge.ci_workflow is $ci, which does not exist here; point it at the workflow that runs your checks on pull_request"
elif ! grep -q 'pull_request' "$ci"; then
	warn "$ci does not seem to run on pull_request; merge.ci_workflow must be the PR's CI"
fi
# Only the flow form, [a.yml, b.yml], is read here; other forms skip this hint.
dispatch="$(sed -nE 's/^[[:space:]]*dispatch_on_main:[[:space:]]*\[(.*)\].*/\1/p' "$cfg" 2>/dev/null | tr ',' '\n' | tr -d " '\"" || true)"
for wf in $dispatch; do
	if [[ ! -f ".github/workflows/$wf" ]]; then
		warn "merge.dispatch_on_main lists $wf, which does not exist in .github/workflows"
	elif ! grep -q 'workflow_dispatch' ".github/workflows/$wf"; then
		warn "merge.dispatch_on_main lists $wf, which has no workflow_dispatch trigger, so it cannot be started after a merge"
	fi
done

if $github && ! $skip_secret; then
	set_secret=true
	names="$(gh secret list --repo "$repo" --json name --jq '.[].name' 2>/dev/null || true)"
	if grep -qx "$secret_name" <<<"$names"; then
		if $force; then
			:
		elif $interactive && confirm "$secret_name is already set. Replace it?"; then
			:
		else
			say kept "secret $secret_name"
			set_secret=false
		fi
	fi
	if $set_secret; then
		key=""
		if $interactive; then
			read -rsp "Model API key (input hidden): " key || true
			echo >&2
		else
			key="$(cat)"
			key="${key%$'\r'}"
		fi
		if [[ -z "$key" ]]; then
			warn "no model key given; set it later with: gh secret set $secret_name --repo $repo"
		elif printf '%s' "$key" | gh secret set "$secret_name" --repo "$repo" >/dev/null; then
			say set "secret $secret_name"
		else
			warn "could not set $secret_name; set it with: gh secret set $secret_name --repo $repo"
		fi
		unset key
	fi
fi

if $github; then
	if perms="$(gh api "repos/$repo/actions/permissions" --jq '"\(.enabled) \(.allowed_actions // "")"' 2>/dev/null)"; then
		read -r enabled allowed <<<"$perms"
		if [[ "$enabled" != true ]]; then
			warn "GitHub Actions is disabled for $repo; enable it in Settings > Actions > General"
		elif [[ "$allowed" != all ]]; then
			warn "$repo allows only some actions ($allowed); allow swayamg20/nightshift and the actions its workflows pin"
		fi
	else
		warn "could not read the Actions settings of $repo"
	fi

	# The publish job opens the draft PR with GITHUB_TOKEN, which GitHub refuses unless
	# this is on. The current default token permissions are sent back unchanged.
	if wf="$(gh api "repos/$repo/actions/permissions/workflow" \
		--jq '"\(.default_workflow_permissions) \(.can_approve_pull_request_reviews)"' 2>/dev/null)"; then
		read -r default_perms can_approve <<<"$wf"
		if [[ "$can_approve" == true ]]; then
			say ok "Actions can create and approve pull requests"
		elif gh api -X PUT "repos/$repo/actions/permissions/workflow" \
			-f default_workflow_permissions="$default_perms" -F can_approve_pull_request_reviews=true >/dev/null 2>&1; then
			say enabled "Allow GitHub Actions to create and approve pull requests"
		else
			warn "could not enable \"Allow GitHub Actions to create and approve pull requests\" (an organization or enterprise policy may forbid it); enable it in Settings > Actions > General"
		fi
	else
		warn "could not read the Actions workflow permissions of $repo; enable \"Allow GitHub Actions to create and approve pull requests\" in Settings > Actions > General"
	fi

	[[ "$merge_commits" != false ]] \
		|| warn "$repo does not allow merge commits, which reply merges use; enable \"Allow merge commits\" in Settings > General"

	# Reply merges wait for the checks that rulesets or branch protection require on
	# the default branch (read the same way as the merge workflow does), and refuse to
	# merge when there are none.
	required="" linear="" approvals=0
	if rules="$(gh api "repos/$repo/rules/branches/$default_branch" --jq '[
			([.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | join(", ")),
			(any(.[]; .type == "required_linear_history")),
			([.[] | select(.type == "pull_request") | .parameters.required_approving_review_count] | max // 0)
		] | map(tostring) | join("\u001f")' 2>/dev/null)"; then
		IFS="$us" read -r required linear approvals <<<"$rules"
	else
		warn "could not read the rulesets for $default_branch"
	fi
	classic="$(gh api "repos/$repo/branches/$default_branch" \
		--jq '[.protection.required_status_checks // {} | (.contexts // [])[], ((.checks // [])[] | .context)] | unique | join(", ")' \
		2>/dev/null || true)"
	required="${required}${required:+${classic:+, }}${classic}"
	if [[ -n "$required" ]]; then
		say ok "$default_branch requires checks: $required"
	else
		warn "$default_branch has no ruleset or branch protection requiring status checks. Require your CI's checks on it, or, where that is unavailable (for example a private repository on a free plan), list them under merge.required_checks in .nightshift/config.yml; otherwise reply merges refuse to merge"
	fi
	[[ "$linear" != true ]] \
		|| warn "$default_branch requires linear history, but reply merges create merge commits and merge $default_branch into the working branch"
	((${approvals:-0} == 0)) \
		|| warn "$default_branch requires $approvals approving review(s); each reply merge will stop until you approve the PR on GitHub"

	# The publish and merge jobs push to, force-push over a discarded PR's leftovers,
	# and delete the working branch with GITHUB_TOKEN.
	if wrules="$(gh api "repos/$repo/rules/branches/$work_branch" --jq '[.[].type] | unique | join(", ")' 2>/dev/null)" \
		&& [[ -n "$wrules" ]]; then
		warn "rulesets apply to the working branch $work_branch ($wrules); exclude it, because Nightshift pushes to, force-pushes, and deletes that branch with GITHUB_TOKEN"
	fi
else
	warn "--no-github: set the $secret_name secret, enable \"Allow GitHub Actions to create and approve pull requests\", and require status checks on the default branch yourself"
fi

base="${default_branch:-the default branch}"
cat <<EOF

Next steps:
  1. Edit $cfg. List your test commands under checks, and use
     setup.root and setup.install if the checks need services or dependencies.
     Reference: https://github.com/swayamg20/nightshift/blob/main/docs/configuration.md
  2. Write the goal in .nightshift/GOALS.md. Leave status: paused for now.
  3. Commit the new files and land them on $base.
     Schedules and comment triggers only run from workflows on that branch.
  4. When you are ready, set status: running in .nightshift/GOALS.md on
     $base, then start the first run: gh workflow run nightshift.yml
  5. Run reports and questions mention you, so check that GitHub emails you
     about mentions: https://github.com/settings/notifications
Nothing was committed or pushed.
EOF
((warnings == 0)) || printf '\n%s warning(s) above need attention.\n' "$warnings"
