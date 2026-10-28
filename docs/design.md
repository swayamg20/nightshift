# Nightshift design

Nightshift runs an unattended coding agent on a GitHub repository and lets the owner
steer it by email. It is a set of reusable GitHub Actions workflows plus a small
harness. A repository opts in with three short caller workflows and a `.nightshift/`
directory.

This document is the contract the implementation follows. It was extracted from the
AgentRelay autopilot (the reference implementation), which has run in production.

## Owner experience

| Email the owner receives | Meaning | Owner reply |
|---|---|---|
| `Nightshift: <question>` | The agent needs a decision | Plain answer; a run starts immediately (👍 on the reply) |
| Comment on "Nightshift run log" | A run finished: commits, files changed, checks, summary, PR | `merge` to land exactly the named head commit (👍, then 🚀 or 😕) |
| `Merged #N into main…` | A reply merge landed | Nothing |
| `Did not merge #N: …` | Why a merge was refused | Usually reply `merge` to that message, or follow it |

Controls live in `.nightshift/GOALS.md` on the default branch: `status: running|paused`
and the current goal. Closing the nightshift PR discards its work.

## Repository layout (this repo)

```
.github/workflows/agent.yml     reusable (workflow_call): jobs `agent` and `publish`
.github/workflows/merge.yml     reusable (workflow_call): jobs `parse`, `not-a-command`, `merge`
.github/workflows/reply.yml     reusable (workflow_call): job `start-run`
harness/action.yml              composite action: installs the harness root-owned
harness/run.sh                  session loop (codex exec through the key proxy)
harness/PROMPT.md               generic agent instructions
harness/codex-config.toml       codex provider config (keyproxy, no key)
harness/pr-feedback.sh          unresolved review findings + failing checks on the PR
templates/                      files `init.sh` installs into a target repository
init.sh                         scaffolds a target repository and configures it
docs/                           design, security model, configuration reference
examples/agentrelay/            the AgentRelay configuration, as a worked example
```

### Self-reference

`uses:` cannot contain expressions, and a reusable workflow cannot address its own
repository with `./`. The reusable workflows therefore reference the harness as
`swayamg20/nightshift/harness@main` during development. Releasing rewrites that to
the release tag (see `RELEASING.md`). The composite action exposes its files through
`github.action_path`; the agent never reads harness files from the target repository.

## Target repository layout

```
.github/workflows/nightshift.yml         schedule + workflow_dispatch → agent.yml
.github/workflows/nightshift-reply.yml   issue_comment → reply.yml
.github/workflows/nightshift-merge.yml   issue_comment → merge.yml
.nightshift/config.yml                   configuration (below)
.nightshift/GOALS.md                     owner-controlled goal and status
.nightshift/STATE.md                     agent working memory
.nightshift/JOURNAL.md                   agent long-term memory (append-only)
```

Caller `nightshift.yml` (template):

```yaml
name: Nightshift
on:
  schedule:
    - cron: '30 3 * * *'
    - cron: '30 8 * * *'
    - cron: '30 14 * * *'
  workflow_dispatch:
    inputs:
      model: { description: Primary model override, default: '' }
      minutes: { description: Agent time budget override, default: '' }
concurrency:
  group: nightshift
  cancel-in-progress: false
permissions: {}
jobs:
  nightshift:
    uses: swayamg20/nightshift/.github/workflows/agent.yml@v1
    permissions: { actions: write, checks: read, contents: write, issues: write, pull-requests: write, statuses: read }
    with:
      model: ${{ inputs.model }}
      minutes: ${{ inputs.minutes }}
    secrets:
      model-api-key: ${{ secrets.NIGHTSHIFT_MODEL_API_KEY }}
```

`nightshift-reply.yml` and `nightshift-merge.yml` trigger on `issue_comment: [created]`,
set `permissions: {}`, and call `reply.yml` / `merge.yml` with the same write
permissions. `reply.yml` takes input `agent-workflow` (default `nightshift.yml`) and
dispatches it.

## Configuration: `.nightshift/config.yml`

Read with `yq` from the default branch only, before any branch content is checked out.
The agent job copies it into the root-owned harness directory.

```yaml
agent:
  base_url: https://example.openai.azure.com/openai/v1  # OpenAI-compatible Responses API base
  model: gpt-6.1-sol          # primary model or deployment
  fallback_model: ''          # optional second model when the primary fails
  minutes: 220                # agent time budget per run
  max_sessions: 8
  instructions: |             # optional repository-specific guidance appended to the prompt
    ...
identity:                     # commits are rewritten to this author and committer
  name: Jane Doe
  email: 123+jane@users.noreply.github.com
branch: nightshift            # working branch; its PR targets the default branch
setup:
  node: '22'                  # always installed (codex needs it); version is configurable
  python: ''                  # optional actions/setup-python version
  go: ''                      # optional actions/setup-go version
  pnpm: false                 # enable corepack pnpm
  root: |                     # optional, runs with sudo before root is dropped (services)
    ...
  install: |                  # runs without root; before the agent on a fresh branch,
    ...                       # and by the agent itself on a continued branch
checks:                       # pre-push signal after the agent; also listed in the prompt
  - npm test
merge:
  ci_workflow: .github/workflows/ci.yml   # PR CI whose runs are approved and awaited
  dispatch_on_main: [ci.yml]              # started on the default branch after a reply merge
  allow: ['src/*', '*/src/*', 'test/*', 'tests/*', '*/test/*', '*/tests/*', 'docs/*', '*.md']
  deny: ['.github/*', '*/.github/*', '.nightshift/*', 'AGENTS.md', '*/AGENTS.md', 'CLAUDE.md', '*/CLAUDE.md']
```

Defaults apply to every omitted key. `.nightshift/STATE.md` and `.nightshift/JOURNAL.md`
are always reply-mergeable; everything else under `.nightshift/` never is. Patterns are
bash `case` globs (`*` matches `/`). Deny is checked before allow; a path matching
neither is blocked.

Repository secrets and variables:

- `NIGHTSHIFT_MODEL_API_KEY` (secret): the model key. Only the key proxy ever holds it.

## Invariants carried over from the reference implementation

These are security properties; the port must keep every one.

1. **Agent job** (`permissions: contents/issues/pull-requests: read`, `cache-mode: read`):
   harness + config copied root-owned from the default branch; toolchains and `setup.root`
   run; Codex installed; `codex responses-api-proxy` started as a separate system user
   with the key on stdin; root dropped (`/etc/sudoers.d/*` removed, docker socket
   chmod 600, `sudo -n true` must fail) **before** the working branch is checked out.
   No branch code runs before the agent step (install runs only in fresh mode, from
   the default branch). The agent step uses literal env and `shell: /usr/bin/bash
   --noprofile --norc -eo pipefail {0}` and reads the proxy port from the root-owned
   info file.
2. **Branch selection**: exact `owner:branch` PR lookup filtered to the same repository;
   continue only when the PR head equals the branch tip (retry, then fail); otherwise
   fresh from the default branch. Merge conflict → a single deduplicated question.
3. **Hand-off**: tidy resets the index, commits only memory files, discards leftovers;
   `git bundle create … HEAD --not <default> [remote]`; bundle before a time-limited
   Verify; artifact excludes `codex-home`.
4. **Publish job** (`cache-mode: none`, runs only `!cancelled()`, no repository code):
   bundle must list exactly `HEAD`; fetched with `--no-tags`; SHAs and fully qualified
   refs afterwards; base-ancestry checks; no merge commits; no `.github/` changes
   (`git diff --quiet --no-renames`); continue mode requires the PR still open (query PR,
   then refetch the default branch); fresh mode requires no PR; filter-branch identity and
   attribution rewrite; merge a moved branch only if it fast-forwards from REMOTE;
   lease push; publish notes live outside the artifact.
5. **PR + CI**: PR title/body from the agent's `pr.md` (marker-neutralized, capped);
   never reopen a PR closed mid-publish; approve only `action_required` runs of
   `merge.ci_workflow` whose head repository is this repository and head branch is the
   working branch.
6. **Report**: trusted sections first (status, commits not on the default branch,
   `git diff --name-status`, PR link, questions), then agent text as fenced literal blocks
   with "head commit" neutralized and size-capped, then the `Head commit: \`<sha>\`` marker
   and the reply instruction last. Comment ≤ 60,000 characters; questions capped at 5.
7. **Gate**: `status: paused` stops everything; a scheduled run is skipped while an
   open `nightshift:needs-you` issue has no owner reply, unless the PR has review
   findings or failing checks (`pr-feedback.sh count`).
8. **Reply trigger**: owner comment on an open `nightshift:needs-you` issue → dispatch
   the agent workflow and react 👍.
9. **Merge**: parse job without token (first non-empty line; vocabulary-only command
   regex; replied-to comment id from the last `/(issues|pull)/N#issuecomment-` link;
   quoted detection with here-strings); `not-a-command` job reacts 😕 and explains when
   the line mentions merge; merge job reacts 👍, binds to the replied-to bot comment's
   last marker, or the newest report at comment time, or for PR-page comments the head
   pushed before the comment; path guard from `git diff -z --no-renames` with allow/deny;
   approves pending CI, merges the default branch in when behind, waits for the PR's own
   CI to complete, retries failed jobs once; names unresolved review threads when blocked;
   merges with `--match-head-commit`; closes linked issues itself; dispatches
   `merge.dispatch_on_main`; deletes the branch with a lease; replies, then reacts 🚀 or 😕.
10. **Comment text** is never interpolated into a script; owner-only everywhere; issue
    snapshots and inbox include only owner-authored content.

## Generalization points

| Reference (AgentRelay) | Nightshift |
|---|---|
| `autopilot` branch, `autopilot/` dir, `autopilot:needs-you`, "Autopilot run log" | `branch` config (default `nightshift`), `.nightshift/`, `nightshift:needs-you`, "Nightshift run log" |
| Hard-coded Swayam identity | `identity.name` / `identity.email` |
| Postgres on 5433, pnpm, migrate | `setup.root`, `setup.pnpm`, `setup.install` |
| Verify command list | `checks` |
| Relay DB test instructions in PROMPT.md | `agent.instructions` |
| `ci.yml`, Pages dispatch on `landing/` | `merge.ci_workflow`, `merge.dispatch_on_main` |
| Path allowlist in the merge job | `merge.allow` / `merge.deny` |
| Azure base URL repo variable | `agent.base_url` |
| `AZURE_FOUNDRY_API_KEY` | `NIGHTSHIFT_MODEL_API_KEY` |
