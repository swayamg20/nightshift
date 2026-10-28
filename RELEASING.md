# Releasing

Target repositories call the reusable workflows at a major tag such as `@v1`. Each
release is an immutable `vX.Y.Z` tag plus a moving major tag that points at the
newest `v1.Y.Z`.

## Why a release needs its own commit

`uses:` cannot contain expressions, and a reusable workflow cannot address its own
repository with `./`. On `main`, `.github/workflows/agent.yml` therefore loads the
harness as `swayamg20/nightshift/harness@main`. A release must not do that: a caller
pinned to `@v1` would otherwise run the current `main` harness, not the one that was
reviewed and tagged.

So every release tag points at a commit, made off `main`, in which each
`harness@main` reference is rewritten to that same tag. The commit is never merged
back, so `main` keeps loading the harness from `main` during development.

## Steps

Run these from a clean clone with push access. Replace the version.

1. Check that `main` is ready:

   ```sh
   git switch main && git pull --ff-only
   actionlint .github/workflows/*.yml
   bash -n init.sh harness/*.sh
   ```

2. Make the release commit on a detached head:

   ```sh
   version=v1.2.0
   git switch --detach main
   grep -rl 'swayamg20/nightshift/harness@main' .github/workflows \
     | xargs sed -i.bak "s#swayamg20/nightshift/harness@main#swayamg20/nightshift/harness@${version}#g"
   rm -f .github/workflows/*.bak
   ! grep -rn 'harness@main' .github/workflows   # must print nothing
   git diff --stat                                # only harness references change
   git commit -am "chore(release): pin harness to ${version}"
   ```

3. Tag it and push only the tag:

   ```sh
   git tag -a "$version" -m "$version"
   git push origin "$version"
   ```

   Never move or delete a pushed `vX.Y.Z` tag. If the release is wrong, release
   the next patch version.

4. Move the major tag to the same commit. `^{commit}` keeps `v1` pointing at the
   commit rather than at the `vX.Y.Z` tag object:

   ```sh
   git tag -fa v1 -m "v1 -> ${version}" "${version}^{commit}"
   git push --force origin v1
   ```

   Callers on `@v1` pick up the release on their next run. Their `agent.yml@v1`
   loads `harness@vX.Y.Z` from the same commit, so the workflow and the harness
   always match.

5. Optionally publish release notes:

   ```sh
   gh release create "$version" --verify-tag --title "$version" --notes-file notes.md
   ```

6. Go back to `main` and confirm it still loads the harness from `main`:

   ```sh
   git switch main
   grep -rn 'harness@main' .github/workflows
   ```

## After releasing

In a test repository set up with `init.sh` and `status: running`, run
`gh workflow run nightshift.yml` and check that the agent job, the publish job, and
the run report work. Reply `merge` to that report to check the merge workflow.

## Breaking changes

A change that needs callers to edit their caller workflows or `.nightshift/config.yml`
is a new major version. First change `templates/` and the README on `main` to
reference `@v2`. Then release `v2.0.0` and create a `v2` tag in step 4 instead of
moving `v1`. Leave `v1` where it was so existing callers keep working.
