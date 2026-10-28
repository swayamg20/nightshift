# Configuration

Nightshift reads `.nightshift/config.yml` from the default branch only, before the
working branch is checked out. Edits on the working branch have no effect, and the
agent cannot change the configuration it runs under.

- Every omitted or `null` key takes its default.
- A key Nightshift does not know is reported as a warning in the run log, so typos
  show up instead of being ignored silently.
- A value of the wrong type or format fails the run with an error that names the key.
- If the file is missing, every key takes its default. `agent.base_url` has no
  default, so runs fail until it is set.
- Versions keep their spelling: `python: 3.10` is read as `3.10`, not `3.1`.
- List entries must be non-empty strings on a single line.

A complete, commented file is in
[`templates/.nightshift/config.yml`](../templates/.nightshift/config.yml), and a real
setup is in [`examples/agentrelay/config.yml`](../examples/agentrelay/config.yml).

## Keys

| Key | Default |
|---|---|
| [`agent.base_url`](#agentbase_url) | required |
| [`agent.model`](#agentmodel) | `gpt-6.1-sol` |
| [`agent.fallback_model`](#agentfallback_model) | `''` (none) |
| [`agent.minutes`](#agentminutes) | `220` |
| [`agent.max_sessions`](#agentmax_sessions) | `8` |
| [`agent.instructions`](#agentinstructions) | `''` |
| [`identity.name`](#identityname-and-identityemail) | the repository owner's login |
| [`identity.email`](#identityname-and-identityemail) | the owner's GitHub noreply address |
| [`branch`](#branch) | `nightshift` |
| [`setup.node`](#setupnode) | `'22'` |
| [`setup.python`](#setuppython-and-setupgo) | `''` (not installed) |
| [`setup.go`](#setuppython-and-setupgo) | `''` (not installed) |
| [`setup.pnpm`](#setuppnpm) | `false` |
| [`setup.root`](#setuproot) | `''` |
| [`setup.install`](#setupinstall) | `''` |
| [`checks`](#checks) | `[]` |
| [`merge.ci_workflow`](#mergeci_workflow) | `.github/workflows/ci.yml` |
| [`merge.approve_ci`](#mergeapprove_ci) | `auto` |
| [`merge.required_checks`](#mergerequired_checks) | `[]` |
| [`merge.dispatch_on_main`](#mergedispatch_on_main) | `[ci.yml]` |
| [`merge.allow`](#mergeallow-and-mergedeny) | source, test, and docs paths |
| [`merge.deny`](#mergeallow-and-mergedeny) | CI, control, and agent instruction files |

### `agent.base_url`

The base URL of an OpenAI-compatible Responses API. Codex sends requests to
`<base_url>/responses` through a local proxy, which adds `NIGHTSHIFT_MODEL_API_KEY`
as a bearer token. It must be an `https://` URL without a query string.

```yaml
agent:
  base_url: https://api.openai.com/v1
  # Azure OpenAI or Azure AI Foundry:
  # base_url: https://my-resource.openai.azure.com/openai/v1
```

In a public repository you may not want the endpoint in the config. Leave
`base_url` empty and set the repository variable `NIGHTSHIFT_MODEL_BASE_URL`
instead; the caller workflow from `init.sh` passes it as the `base-url` input, which
overrides the config when set.

```sh
gh variable set NIGHTSHIFT_MODEL_BASE_URL --body https://my-resource.openai.azure.com/openai/v1
```

### `agent.model`

The primary model or deployment name. A manual run can override it with the `model`
input of `nightshift.yml`.

```yaml
agent:
  model: gpt-6.1-sol
```

### `agent.fallback_model`

A second model, tried in a session when the primary model's session exits with an
error. A session that runs out of time is not an error. Empty means no fallback.

```yaml
agent:
  fallback_model: my-fallback-deployment
```

### `agent.minutes`

The agent's time budget per run, in minutes. Accepted values are 15 to 300, but a run
uses at most 240: the agent job has a 300-minute timeout that also has to cover setup,
checks, and the hand-off. Each session gets at most 70 minutes, and no new session
starts with less than 15 minutes left. A manual run can override it with the
`minutes` input of `nightshift.yml`.

```yaml
agent:
  minutes: 120
```

### `agent.max_sessions`

The most Codex sessions per run, from 1 to 50. Each session starts with a fresh
context and resumes from `.nightshift/STATE.md`. The agent can also end a run early.

```yaml
agent:
  max_sessions: 4
```

### `agent.instructions`

Repository-specific guidance, added to the prompt under "Repository instructions".
The agent already follows the repository's own instruction files (`AGENTS.md`,
`CLAUDE.md`, `CONTRIBUTING.md`), so use this for what they do not say or for what is
different in an unattended job. Because it comes from the default branch, it takes
precedence over instruction files on the working branch.

```yaml
agent:
  instructions: |
    - Run `make test` after every change; `make e2e` needs a browser and does not
      work in this job.
    - Never edit generated files under `api/gen/`; change `api/schema.yaml` instead.
```

### `identity.name` and `identity.email`

The author and committer of every commit Nightshift publishes, and of the merges of
the default branch into the working branch. The agent's commits are rewritten to this
identity before they are pushed. The default is the repository owner's login and
`<owner id>+<owner login>@users.noreply.github.com`. The name must be one line of at
most 100 characters without `<`, `>`, `"`, `` ` ``, `$`, or `\`.

```yaml
identity:
  name: Jane Doe
  email: 123+jane@users.noreply.github.com
```

### `branch`

The working branch. Nightshift keeps one draft PR from it into the default branch,
continues that PR while it is open, and starts fresh from the default branch once it
is merged or closed. It must be a valid branch name and not the default branch.

Rulesets must not restrict this branch: Nightshift pushes to it, replaces it after a
discarded PR, and deletes it after a merge, all with `GITHUB_TOKEN`.

```yaml
branch: nightshift
```

### `setup.node`

The Node.js version for `actions/setup-node`. Node is always installed, because Codex
needs it. Quote versions so YAML keeps them as written.

```yaml
setup:
  node: '20'
```

### `setup.python` and `setup.go`

Versions for `actions/setup-python` and `actions/setup-go`. Empty means the toolchain
is not set up (the runner image's own version, if any, is still there).

```yaml
setup:
  python: '3.12'
  go: '1.23'
```

### `setup.pnpm`

`true` enables pnpm through corepack. The pnpm version comes from the
`packageManager` field of `package.json` on the default branch.

```yaml
setup:
  pnpm: true
```

### `setup.root`

A shell script for system packages and services the checks need. It runs as root
with `bash -eo pipefail` (it stops at the first failing command), from the default
branch's checkout, after the toolchains are installed. It runs before root is dropped,
before the model key reaches the job, and before any branch content is checked out.
Services it starts keep running for the rest of the job.

```yaml
setup:
  root: |
    apt-get update
    apt-get install -y redis-server
    systemctl start redis-server
```

### `setup.install`

A shell script that installs dependencies and prepares local state, without root,
with `bash -eo pipefail`, from the repository root. When a run starts fresh, the
workflow runs it on the default branch's code before the agent starts. The agent also
runs it at the start of every session, which is the only install on a continued
branch, so no branch code runs before the agent step. It must be safe to run twice.

```yaml
setup:
  install: |
    npm ci
    npm run db:migrate
```

### `checks`

Commands that verify the agent's work. They appear in the prompt under "Checks" as the
commands to run before committing. After the agent finishes, the workflow runs each
one again with `bash -eo pipefail -c`, from the repository root, with a 10-minute
limit per command and 30 minutes for all of them. The results are in the run report
under "Agent job checks". They do not decide whether work is published; the PR's own
CI is the merge gate.

```yaml
checks:
  - npm ci
  - npm run lint
  - npm test
  - DATABASE_URL=postgres://localhost:5432/test npm run test:integration
```

### `merge.ci_workflow`

The workflow that runs your checks on `pull_request`, as a path such as
`.github/workflows/ci.yml`. CI on a PR opened by `github-actions` waits for approval.
The publish job and the merge workflow approve only this workflow's waiting runs for
the working branch of this repository. A reply merge then waits for this workflow's
runs to finish and retries failed jobs once.

If it is empty, nothing is approved and every reply merge is refused.

```yaml
merge:
  ci_workflow: .github/workflows/test.yml
```

### `merge.approve_ci`

Whether Nightshift approves the PR's CI runs, which GitHub holds for approval because
the PR is opened by `github-actions`. That CI runs code the agent wrote.

- `auto` (default): approve only when `merge.ci_workflow`, as it is on the default
  branch, declares read-only `permissions` at the top level and in every job, and
  references no secret other than `GITHUB_TOKEN`. Otherwise the run report and merge
  replies ask you to approve the run yourself after reviewing the change.
- `always`: approve regardless. Use only if your CI's secrets and token permissions
  are safe to expose to agent-written code.
- `never`: you always approve CI by hand.

```yaml
merge:
  approve_ci: auto
```

### `merge.required_checks`

Check names a reply merge waits for when the default branch has no ruleset or branch
protection requiring status checks, for example a private repository on a free plan.
When GitHub does require checks, those are used and this list is ignored.

This is weaker than protection: Nightshift waits for these checks before merging,
but GitHub does not stop anyone with write access from pushing to the default branch.

```yaml
merge:
  required_checks: [test]
```

### `merge.dispatch_on_main`

Workflow file names started on the default branch after a reply merge, with
`gh workflow run <file> --ref <default branch>`. Merges made with `GITHUB_TOKEN` do
not trigger `push` workflows, so CI, deploys, or anything else that should follow a
merge has to be started this way. Each listed workflow needs a `workflow_dispatch`
trigger. The merge reply says which ones started.

```yaml
merge:
  dispatch_on_main: [ci.yml, docs.yml]
```

### `merge.allow` and `merge.deny`

The paths a reply merge may change. Each entry is a bash `case` glob matched against
the full path from the repository root, where `*` also matches `/`: `docs/*` matches
everything under `docs/`, and `*.md` matches Markdown files anywhere. For each changed
path:

1. `.nightshift/STATE.md` and `.nightshift/JOURNAL.md` are always allowed.
2. Anything else under `.nightshift/` is always blocked.
3. A path matching `merge.deny` is blocked.
4. A path matching `merge.allow` is allowed.
5. Any other path is blocked.

If any path is blocked, nothing is merged, and the reply names the blocked paths so
you can review and merge the PR on GitHub instead. Setting a list replaces its
default entirely, so copy the defaults you want to keep.

Defaults:

```yaml
merge:
  allow: ['src/*', '*/src/*', 'test/*', 'tests/*', '*/test/*', '*/tests/*', 'docs/*', '*.md']
  deny: ['.github/*', '*/.github/*', '.nightshift/*', 'AGENTS.md', '*/AGENTS.md', 'CLAUDE.md', '*/CLAUDE.md']
```

Keep dependency manifests, lockfiles, migrations, infrastructure, and deploy
configuration out of `merge.allow`, or deny them explicitly when an allowed glob would
match them:

```yaml
merge:
  allow: ['src/*', 'tests/*', 'docs/*', '*.md']
  deny: ['.github/*', '.nightshift/*', 'AGENTS.md', 'CLAUDE.md', '*/migrations/*', 'src/config/production.*']
```

The publish job never pushes changes under `.github/`, whatever these lists say.

## Goals and status

`.nightshift/GOALS.md` on the default branch holds the current goal and the switch:

```markdown
status: running
```

The first line starting with `status:` counts. `running` lets runs work; anything else,
such as `paused`, makes every run exit at once. The rest of the file is the goal,
given to the agent verbatim.

## Caller workflows

The three files in `.github/workflows/` call the reusable workflows at `@v1`.

- `nightshift.yml` holds the schedule (cron, in UTC) and the manual trigger. Its
  `model` and `minutes` inputs override `agent.model` and `agent.minutes` for one run.
  It passes the secret `NIGHTSHIFT_MODEL_API_KEY` as `model-api-key`.
- `nightshift-reply.yml` passes `agent-workflow`, the file name of the workflow to
  start when the owner answers a question. Change it if you rename `nightshift.yml`.
- `nightshift-merge.yml` needs no inputs.

To keep the configuration somewhere else, pass the same `config-path` to `agent.yml`
(in `nightshift.yml`) and to `merge.yml` (in `nightshift-merge.yml`).

## Repository settings

`init.sh` sets or checks these:

- The `NIGHTSHIFT_MODEL_API_KEY` repository secret.
- "Allow GitHub Actions to create and approve pull requests" (Settings > Actions >
  General), so the publish job can open the PR.
- Required status checks on the default branch, through a ruleset or branch
  protection. Reply merges wait for them and refuse to merge without them.
- "Allow merge commits" (Settings > General). Reply merges use merge commits.
- No rulesets on the working branch.
