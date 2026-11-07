# Nightshift goals

status: paused

<!--
Owner-controlled. Edit this file on the default branch (the GitHub web editor or
mobile app is fine). Every run reads the latest version from the default branch
before it starts; the agent cannot change the copy it reads.

- `status: running` lets runs work. `status: paused` makes them exit immediately.
  Keep the line exactly in the form `status: <value>`.
- Changing the goal takes effect on the next run. The agent rewrites its plan in
  `.nightshift/STATE.md` when the goal changes.
- Close the Nightshift draft PR without merging to discard its work. The next run
  starts fresh from the default branch.
- Runs start on the schedule in `.github/workflows/nightshift.yml`, and immediately
  when the owner replies on an open `nightshift:needs-you` issue. While such an issue
  is open, a scheduled run is skipped unless something changed since the last
  successful run started (an owner comment on an open question, or a different
  commit on the default branch such as a merge or an edit to this file) or the PR has
  review findings or failing checks.
- Reply `merge` to a run-report email (or comment `merge` on the Nightshift PR) to
  merge the exact commit that report names, once the default branch's required
  checks pass. A reply can merge only paths that `merge.allow` in
  `.nightshift/config.yml` permits and `merge.deny` does not; anything else must be
  reviewed and merged on GitHub.
- Reactions on your comment show progress: a thumbs-up when a reply or `merge` is
  picked up, then a rocket when the merge lands or a confused face when it does not
  (a reply explains why).

The goal below is a starting point. Replace it with your own before setting
`status: running`.
-->

## Current goal

Work through the open issues the owner wrote, one at a time. Read them together with
the code they touch, pick the most valuable one you can finish and verify in one run,
implement it, and say which issue you picked and why in the run summary and the PR
description, with `Closes #N`. Then pick the next one. Do not ask the owner to choose;
ask only when no open issue can be done without something only the owner can give.

## Done when

- Each issue you pick lands on the Nightshift PR with passing checks and tests.

## Priorities and constraints

- Keep changes small and reviewable. Prefer one concern per commit.

## Off-limits

- Release, publish, and deploy workflows, and infrastructure configuration.
- Package version bumps and changelog release entries.
- Anything under `.nightshift/` except `STATE.md` and `JOURNAL.md`.
