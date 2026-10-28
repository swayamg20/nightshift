# Security model

Nightshift runs a coding agent with a shell, network access, and no human watching,
then publishes its work to your repository. This document says what it protects,
from whom, how, and what it does not protect. The numbered invariants match
[`design.md`](design.md); a change that weakens one of them is a security bug.

## What is protected

- **The model API key** (`NIGHTSHIFT_MODEL_API_KEY`). It is the only secret Nightshift
  uses.
- **The default branch.** Nothing reaches it without a `merge` from the owner, the
  default branch's required checks passing, and a path guard.
- **The write token.** `GITHUB_TOKEN` with write access exists only in jobs that run
  no repository code.
- **The owner's attention.** Emails must say truthfully what happened, and nobody
  but the owner can start runs or merges.

## Who is not trusted

- **The agent.** Model output is treated as hostile, not just mistaken. The agent
  reads issues, dependencies, web pages, and test fixtures, any of which can carry
  prompt injection.
- **The working branch.** Everything on it was written by the agent, including
  `package.json` scripts, test configuration, and repository instruction files.
- **Everything the agent job produces.** Commits, files, logs, and its result are
  checked again by a job the agent cannot influence.
- **Other GitHub users.** On a public repository anyone can open issues, comment,
  review, and open pull requests from forks, including from a branch with the same
  name as the working branch.

Out of scope: a compromised owner account, GitHub itself, the model provider, and
code the owner reviews and merges by hand.

## How a run is isolated

A run has two jobs on two fresh GitHub-hosted runners.

The **agent job** holds a read-only `GITHUB_TOKEN` and restore-only cache access, and
assumes the agent can reach anything in it. It does every privileged step first and
then removes root, so the agent never runs as root:

1. It checks out the default branch, reads `.nightshift/config.yml` and
   `.nightshift/GOALS.md` from it, and installs the harness root-owned in
   `/opt/nightshift-harness`. The agent cannot edit its own prompt, goals, checks,
   or session loop, even on its branch.
2. It installs toolchains, runs `setup.root`, and installs Codex.
3. It starts `codex responses-api-proxy` as a separate system user and passes the
   key on stdin. The proxy adds the key to each model request. No process the agent
   can inspect holds the key.
4. It drops root: removes `/etc/sudoers.d/*`, makes the Docker socket root-only, and
   stops if `sudo -n true` still works.
5. Only then does it check out the working branch. No code from the branch runs
   before the agent itself.

The **publish job** holds the write token. It runs no repository code: it reads the
agent's commits as a git bundle, validates and rewrites them with git, pushes, and
posts. Its own notes live outside the downloaded artifact.

## Invariants

1. **Agent job.** Read-only token (`contents`, `issues`, `pull-requests: read`) and
   `cache-mode: read`, so nothing the agent does can plant cache entries for the
   default branch. The harness and configuration are copied root-owned from the
   default branch. Toolchains, `setup.root`, Codex, and the key proxy are set up and
   root is dropped before the working branch is checked out. `setup.install` runs
   only when the run starts fresh from the default branch; on a continued branch the
   agent installs dependencies itself, inside its own step. The agent step uses
   literal environment values and an absolute shell
   (`/usr/bin/bash --noprofile --norc -eo pipefail {0}`), and reads the proxy port
   from the root-owned info file, so nothing written to `GITHUB_ENV` or `GITHUB_PATH`
   earlier can redirect it to another harness or model endpoint.

2. **Branch selection.** The open pull request is found by exact `owner:branch`
   lookup, filtered to this repository, so a fork's branch with the same name never
   counts. A run continues the branch only when the PR head equals the branch tip;
   it retries, then fails, if they disagree. Otherwise it starts fresh from the
   default branch. If merging the default branch into the working branch conflicts,
   the run stops and opens a single question, reused on later runs, instead of
   asking again.

3. **Hand-off.** After the agent, the index is reset and only `.nightshift/STATE.md`
   and `.nightshift/JOURNAL.md` are committed; everything else uncommitted is
   discarded and listed in the report. The new commits are bundled with
   `git bundle create … HEAD --not <default branch> [remote branch tip]` before the
   time-limited checks run, so slow checks cannot lose the work. The uploaded
   artifact leaves out the Codex home directory.

4. **Publish.** The bundle must name exactly `HEAD`. It is fetched with `--no-tags`,
   and every later check uses SHAs and fully qualified refs, so a bundle cannot
   shadow a ref. The commits must build on the run's recorded base, which must be on
   the default branch (or, for a continued branch, be a merge of the default branch
   into the PR head). Merge commits are refused. Any change under `.github/`,
   including a rename, is refused. A continued run publishes only if its PR is still
   open (the PR is queried before the default branch is refetched, so a merge that
   lands in between still counts as merged); a fresh run publishes only if no PR
   opened meanwhile. Commit author and committer are rewritten to `identity`, and
   AI attribution lines are removed. If the branch moved forward during the run (for
   example, a reply merge brought the default branch in), the branch's new tip is
   merged into the run's commits; if the branch was rewritten instead, nothing is
   published. The push uses a lease on the tip seen before the bundle was read.

5. **Pull request and CI.** The PR title and body come from the agent's `pr.md`, with
   the head-commit marker neutralized and the size capped. A PR closed while the run
   was publishing is never reopened. The job approves only `action_required` runs of
   `merge.ci_workflow` whose head repository is this repository and whose head
   branch is the working branch, so a fork PR pointed at the same commit is never
   approved with it.

6. **Report.** Trusted sections come first: status, the run's own commits, the files
   changed according to `git diff --name-status`, the PR link, and the questions
   opened. The agent's text follows as fenced literal blocks, size-capped, with
   "head commit" rewritten so it cannot forge the merge marker. The
   ``Head commit: `<sha>` `` marker and the reply instruction come last. Reports stay
   under 60,000 characters, and at most five questions open per run.

7. **Gate.** `status: paused` in `GOALS.md` on the default branch stops every run. A
   scheduled run is skipped while a `nightshift:needs-you` question is open and
   nothing changed since the last run report: no comment from the owner on an open
   question and no newer commit on the default branch. Before the first report, it
   is skipped only while a question has no reply from the owner. Review findings or
   failing checks the agent can fix alone keep it running, and a lookup that fails
   never skips a run.

8. **Reply trigger.** Only a comment by the owner on an open `nightshift:needs-you`
   issue dispatches a run. The reply workflow reacts with a thumbs-up and does nothing
   else; it is
   separate from the agent workflow so comment events never enter its concurrency
   group.

9. **Merge.** The command is parsed in a job whose token has no permissions and that
   checks out nothing. Only the first non-empty
   line counts, and it must match a fixed vocabulary (`merge`, `merge it`,
   `yes, merge it`, and similar); negations and questions are not commands. A line
   that mentions merging without being a command gets a confused reaction and an
   explanation. The
   replied-to comment is taken from the last `/(issues|pull)/N#issuecomment-` link
   in the body, which GitHub's email footer adds. The merge job then:
   - binds to the exact commit named by the last marker in the replied-to bot
     comment; for a comment typed on the run log, the newest report that existed
     when the owner commented; for a comment on the PR page, the head only if it was
     pushed before the comment. If the PR now points elsewhere, nothing is merged;
   - lists changed files with `git diff -z --no-renames` and refuses any path that
     is not allowed (see "Path guard" below);
   - approves pending CI as above, merges the default branch in when the branch is
     behind, waits for the PR's own CI run to finish, and retries failed jobs once;
   - names unresolved review conversations when GitHub blocks the merge;
   - merges with `--match-head-commit`, so a push after the check cannot slip in;
   - closes the PR's `Closes #N` issues itself, dispatches `merge.dispatch_on_main`,
     deletes the branch with a lease, replies in the thread, and reacts with a rocket
     (merged) or a confused face (not merged).

10. **Comment text** is passed through environment variables and never interpolated
    into a script. Every comment trigger checks that the commenter is the repository
    owner.
    The issue snapshot and inbox given to the agent contain only owner-authored
    issues and comments, and PR feedback contains only threads started by the owner
    or by code scanning.

## Path guard

A reply merge is not a code review. The path guard limits what can land without one.
For each changed path, in order:

1. `.nightshift/STATE.md` and `.nightshift/JOURNAL.md` are allowed.
2. Anything else under `.nightshift/` is blocked.
3. A path matching `merge.deny` is blocked.
4. A path matching `merge.allow` is allowed.
5. Anything else is blocked.

One blocked path blocks the whole merge, and the reply names it. Keep CI and
workflow files, agent instruction files, dependency manifests and lockfiles,
migrations, infrastructure, and deploy configuration out of `merge.allow`, or deny
them explicitly.

## Residual risks

- **The agent has network access.** It can send anything it can read to anywhere:
  the repository contents, the issue snapshot, and its own output. Do not use
  Nightshift on a private repository whose code must not leave the runner.
- **The agent can spend model budget.** It cannot read the key, but it can send
  requests through the proxy until the job ends.
- **The agent job's own token.** Assume the agent can obtain the read-only token and
  the restore-only cache access. Neither can change the repository.
- **Artifacts.** The agent's output, including its commits as a bundle, is uploaded
  as the `nightshift-out` artifact for seven days. Anyone who can read the
  repository's Actions artifacts can download it.
- **Source code is still code.** The path guard and required checks do not detect
  malicious or wrong code in allowed paths. Read the PR before replying `merge`.
- **CI runs agent-written code.** With `merge.approve_ci: auto`, Nightshift approves
  the PR's CI only when that workflow grants read-only permissions and uses no secret
  other than `GITHUB_TOKEN`. With `always`, any secret the CI uses is reachable by
  agent-written code.
- **Scripts that `setup.root` runs.** `setup.root` itself comes from the protected
  configuration, but if it calls a script stored in the repository, add that script to
  `merge.deny`; otherwise a reply merge can change code that later runs as root.
- **Unprotected default branch.** With `merge.required_checks` instead of a ruleset,
  only Nightshift waits for the checks; GitHub does not enforce them.
- **Workflows started on the default branch.** `merge.dispatch_on_main` starts the
  listed workflows on the default branch after a reply merge. List only workflows
  that are safe to run on any code a reply merge can land.

## Requirements this model depends on

- **GitHub-hosted runners only.** Dropping root deletes `/etc/sudoers.d/*` and
  locks the Docker socket. On a self-hosted runner that damages the machine, and the
  isolation assumes a fresh virtual machine per job.
- **A user-owned repository.** The owner is `github.repository_owner`. For a
  repository owned by an organization, no user has that login, so no comment would
  ever count as the owner's.
- **Required status checks on the default branch,** through a ruleset or branch
  protection. Without them a reply merge has nothing to wait for, so it refuses to
  merge.
- **Pinned dependencies.** Third-party actions are pinned to commit SHAs, Codex to an
  exact version, and `yq` to a checksummed release. Keep them pinned when updating.
