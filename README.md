# Nightshift

Nightshift runs an unattended coding agent on a GitHub repository and lets you steer
it by email. A few times a day, GitHub Actions runs [Codex](https://github.com/openai/codex)
toward the goal you write in `.nightshift/GOALS.md`. Its work lands on one branch
behind a draft pull request. Run reports and questions reach you as GitHub
notification emails, and you answer, or merge, by replying.

A repository opts in with three short caller workflows and a `.nightshift/`
directory. The agent job, the publish job, and the merge logic live here as reusable
workflows, so every repository gets fixes by following the `v1` tag.

Nightshift was extracted from the autopilot that develops
[AgentRelay](https://github.com/swayamg20/AgentRelay). Its configuration is in
[`examples/agentrelay/config.yml`](examples/agentrelay/config.yml).

## How a run works

1. A schedule (or your reply to a question) starts `nightshift.yml`.
2. The agent job reads the goal and configuration from the default branch, sets up
   toolchains and services, starts a proxy that holds the model key, drops root, and
   only then checks out the working branch. Codex works in sessions until the time
   budget runs out, the goal is done, or it is blocked on you. It commits locally; it
   cannot push or call GitHub.
3. A separate publish job validates the commits, rewrites their author to your
   identity, pushes them, updates the draft PR, approves the PR's CI, opens your
   questions as issues, and posts a run report.
4. The agent keeps its memory in `.nightshift/STATE.md` (working memory) and
   `.nightshift/JOURNAL.md` (an append-only log), committed on the branch.

## The email loop

| Email you receive | Meaning | Your reply |
|---|---|---|
| `Nightshift: <question>` | The agent needs a decision | A plain answer. A run starts at once (👍 on your reply) |
| Comment on "Nightshift run log" | A run finished: commits, files changed, checks, summary, PR | `merge` to land exactly the named head commit (👍, then 🚀 or 😕) |
| `Merged #N into <default branch>…` | A reply merge landed | Nothing |
| `Did not merge #N: …` | Why a merge was refused | Usually reply `merge` to that message, or do what it says |

The merge command is the first non-empty line of your reply. `merge`, `merge it`,
`yes, merge it`, and `ok merge it please` work; questions and negations do not. A line
that mentions merging without being a command gets a confused reaction and an
explanation. You can also
comment `merge` on the PR itself.

A reply merge brings the branch up to date with the default branch, waits for the
default branch's required checks, retries failed jobs once, and merges only if every
changed path is allowed by `merge.allow` (by default source, tests, and docs).
Anything else stays for you to review and merge on GitHub.

Controls live in `.nightshift/GOALS.md` on the default branch: `status: running` or
`status: paused`, and the current goal. Closing the Nightshift PR discards its work;
the next run starts fresh.

## Quick start

You need:

- A repository owned by your GitHub user account, with a CI workflow that runs on
  `pull_request`.
- An OpenAI-compatible Responses API endpoint and key, such as OpenAI or Azure
  OpenAI.
- `git` and the [GitHub CLI](https://cli.github.com/), signed in as the repository
  owner.

Clone Nightshift once, then run `init.sh` from each repository you want to set up:

```sh
git clone --depth 1 --branch v1 https://github.com/swayamg20/nightshift ~/nightshift
cd ~/code/my-repo
~/nightshift/init.sh --base-url https://api.openai.com/v1
```

`init.sh` copies the caller workflows and `.nightshift/` files without overwriting
existing ones, fills in the model and your commit identity, asks for the model key
without echoing it and stores it as the `NIGHTSHIFT_MODEL_API_KEY` secret, enables
"Allow GitHub Actions to create and approve pull requests", and warns about missing
required status checks or other settings that would block merges. It never commits or
pushes. Run `init.sh --help` for every option; in scripts, pass the key on stdin.

Then:

1. Edit `.nightshift/config.yml`: list your test commands under `checks`, and set up
   services or dependencies with `setup.root` and `setup.install` if they need them.
2. Write your goal in `.nightshift/GOALS.md`. It starts as `status: paused`.
3. Commit the files and land them on the default branch.
4. Set `status: running` on the default branch and start the first run:
   `gh workflow run nightshift.yml`.

Make sure GitHub emails you about mentions. Reports and questions mention you.

## Configuration

`.nightshift/config.yml` on the default branch. Everything has a default except
`agent.base_url`.

```yaml
agent:
  base_url: https://api.openai.com/v1   # required
  model: gpt-6.1-sol
  minutes: 220                          # agent time per run
  instructions: |                       # added to the prompt
    Run `make test` after every change.
setup:
  python: '3.12'
  install: pip install -e '.[test]'
checks:
  - make lint
  - make test
merge:
  ci_workflow: .github/workflows/ci.yml
  allow: ['src/*', 'tests/*', 'docs/*', '*.md']
```

Every key, with its default and an example, is in
[docs/configuration.md](docs/configuration.md). The schedule is the cron list in
`.github/workflows/nightshift.yml`.

## Security model

The agent is treated as untrusted. It never holds the model key or a token that can
write to the repository:

- The model key is held by a proxy running as a separate user; the agent reaches the
  model through it.
- The agent runs without root, after everything privileged is set up, and nothing
  from its branch runs before it does.
- Its harness, prompt, goals, and configuration are root-owned copies from the default
  branch.
- Its commits are handed to a separate job as a git bundle, then checked: they must
  build on the run's base, contain no merge commits, and not touch `.github/`.
- Only the repository owner's comments start runs or merges, and only owner-written
  issues and comments reach the agent.
- Reports put the agent's text in literal blocks after the trusted sections, and a
  merge is bound to the exact commit named in the message you replied to.

The full threat model, the invariants, and the residual risks are in
[docs/security.md](docs/security.md). In short: the agent has network access and can
send anywhere whatever it can read, and a reply merge is not a code review.

## Limits

- **GitHub only.** Nightshift is built on GitHub Actions, issues, and notification
  emails, and runs on GitHub-hosted Ubuntu runners. Do not use self-hosted runners:
  dropping root deletes the runner's sudo configuration.
- **User-owned repositories only.** The owner is `github.repository_owner`, which for
  an organization is not a person who can comment.
- **Required status checks.** The default branch must require status checks through
  a ruleset or branch protection. Reply merges wait for them and refuse to merge
  without them.
- **Merges do not trigger `push` workflows.** Merges and pushes made with
  `GITHUB_TOKEN` start no workflows, so nothing that runs on `push` to the default
  branch runs after a reply merge. `merge.dispatch_on_main` lists workflows to start
  explicitly; each needs a `workflow_dispatch` trigger.
- **Merge commits.** Reply merges create merge commits, so the repository must allow
  them, and the default branch cannot require linear history.
- **One model API.** Codex, through an OpenAI-compatible Responses API.
- **Cost.** Each run can use up to `agent.minutes` of model time and Actions minutes,
  several times a day. Actions minutes are free for public repositories only.

## Versioning

Callers use `@v1`, which moves to each `v1.x.y` release. See
[RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE)
