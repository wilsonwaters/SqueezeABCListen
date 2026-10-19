# Releasing SqueezeABCListen

Releases are made only by the **Release** workflow (`.github/workflows/release.yml`). It builds
`ABCListen-<version>.zip`, creates the tag and GitHub Release `v<version>` with the zip attached,
and then points `repo.xml` on `main` at that zip, which is what LMS users install from:

```
https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml
```

Nobody builds, tags or uploads releases by hand. The workflow creates the tag itself because
tags can't be pushed from the development container and no release-creation API is available
there; inside GitHub Actions, `GITHUB_TOKEN` can do both.

## How to release

Versions are `X.Y.Z` (digits only: no `v` prefix, no `-beta` suffix) and only ever go up.

**First, update `CHANGELOG.md`.** Add a section for the new version at the top, below
`## [Unreleased]`, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format: a
`## [X.Y.Z] - YYYY-MM-DD` heading with `### Added` / `### Changed` / `### Fixed` /
`### Known limitations` lists of the user-visible changes, and the links at the bottom
(`[X.Y.Z]: …/compare/vPREVIOUS...vX.Y.Z`, and `[unreleased]` moved on to `vX.Y.Z...HEAD`). That
section becomes the text of the GitHub Release; `scripts/changelog-section.sh X.Y.Z` prints
exactly what will be used. The CHANGELOG update can be its own pull request, or part of the
version-bump commit (the only other file that commit may touch). If `repo.xml`'s `<desc>` no
longer describes what the plugin does, update it in the same way (never its `version`, `url` or
`sha`).

There are two ways to cut a release; both release the version currently in
`ABCListen/install.xml` on `main`.

1. **Version-bump commit on `main`.** Change `<version>` in `ABCListen/install.xml` (and nothing
   else, apart from `CHANGELOG.md`) and get the commit onto `main`. A push to `main` that
   changes `<version>` in `ABCListen/install.xml` starts the release. (A push that touches
   `install.xml` without changing `<version>`, for example a new `optionsURL`, does nothing.)
2. **Run the workflow.** In GitHub: **Actions → Release → Run workflow**, branch `main`,
   leave *Dry run* unticked. Or through the REST API:

   ```
   POST /repos/wilsonwaters/SqueezeABCListen/actions/workflows/release.yml/dispatches
   {"ref":"main"}
   ```

   for example `curl -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" https://api.github.com/repos/wilsonwaters/SqueezeABCListen/actions/workflows/release.yml/dispatches -d '{"ref":"main"}'`.
   Add `"inputs":{"dry_run":"true"}` for a dry run. Running the workflow is how the first
   release (`0.1.0`, whose version was already in `install.xml`) is cut, and how an
   interrupted release is repaired.

Real releases only run from `main`; a real run dispatched on another branch fails at once.

## What the workflow does

0. **Version.** Reads `V` from `ABCListen/install.xml` and fails unless it is `X.Y.Z`. On a
   push, it compares `V` with the version before the push; if it is unchanged, the run ends
   here (a green no-op; the other jobs show as skipped).
1. **Checks.** Runs the same checks as CI (`ci.yml`, i.e. `scripts/check.sh`); a failure stops
   the run.
2. **Guards.** Fails if `V` is lower than the highest `vX.Y.Z` tag or than the version in
   `repo.xml` on the latest `main` (no downgrades), if `repo.xml` on `main` has no
   `name="ABCListen"` entry to update, or if tag `vV` exists without a release.
3. **Existing release.** If release `vV` already exists, it downloads its `ABCListen-V.zip` and
   hashes it. If `repo.xml` on `main` already has `version="V"`, that asset's URL and its SHA1,
   the run logs `nothing to do` and ends green. Otherwise it skips to step 7 using the
   downloaded asset's SHA1 (the repair path). An existing release is never rebuilt and its
   asset is never replaced.
4. **Build.** Runs `scripts/build.sh` once and takes the SHA1 from `dist/ABCListen-V.zip.sha1`.
   The zip is never rebuilt after it has been hashed.
5. **Release.** Creates tag and release `vV` server-side with `gh release create`, on the commit
   that was built, titled `ABC listen V`, with `ABCListen-V.zip` attached. The release notes are
   the body of `CHANGELOG.md`'s `## [V]` section (`scripts/changelog-section.sh V`); if there is
   no such section, or it is empty, GitHub generates notes from the merged pull requests instead.
6. **Verify.** Downloads the uploaded asset and compares its SHA1 with step 4's. On a mismatch
   the run fails before `repo.xml` is touched.
7. **repo.xml.** On top of the latest `main`: runs
   `scripts/update-repo-xml.pl --version V --sha <sha1> --url <asset URL>`, checks the result
   with `xmllint`, and commits **only** `repo.xml` with the message
   `Release vV: update repo.xml [skip ci]`, authored and committed as
   `Wilson Waters <wilsonwaters@users.noreply.github.com>` (the repository owner). That identity
   is set once, at the top of the workflow (`COMMIT_NAME` / `COMMIT_EMAIL`); change those two
   lines to commit as someone else. The push itself is made with `GITHUB_TOKEN`, i.e. by GitHub
   Actions (`github-actions[bot]`). If it is rejected because `main` moved, the workflow
   re-fetches `main`, re-applies the change and retries, up to 3 times, then fails.

The release is created before `repo.xml` is changed, so `repo.xml` never points at an asset
that doesn't exist. If a run stops between the two, `repo.xml` is stale (still the previous
release) but not broken, and the next run repairs it (step 3).

Pushes made with `GITHUB_TOKEN` don't start workflows, so the `repo.xml` commit doesn't
trigger another release; `[skip ci]` and the `paths` filter are extra guards.

## Dry runs

A dry run goes through steps 0–4 and step 7 up to, but not including, the commit. It creates
no release, tag or commit. It prints the version, the zip name, its SHA1, the `unzip -l`
listing, the release notes a release of that version would get (and where they come from) and
the `git diff` of `repo.xml`, and repeats them in the run summary. The notes are shown even
when release `vV` already exists.

- Every pull request that changes `.github/workflows/release.yml`, `ABCListen/install.xml`,
  `repo.xml`, `CHANGELOG.md`, `scripts/build.sh`, `scripts/check-package.sh`,
  `scripts/update-repo-xml.pl` or `scripts/changelog-section.sh` gets a dry run (the **Build and
  release** job of the **Release** workflow). On a pull request the change is applied to the
  pull request's merge commit.
- **Actions → Release → Run workflow** with *Dry run* ticked (or `"inputs":{"dry_run":"true"}`
  in the REST call) does a dry run on the chosen branch.

Dry runs don't wait for real releases, and real releases don't wait for dry runs. If release
`vV` already exists, a dry run shows the no-op or repair path instead of a build; CI builds
and checks the zip on every pull request anyway.

## Idempotency and repair

- Real runs share one concurrency group and a running release is never cancelled, so two
  runs for the same version (a dispatch plus a push, or a re-run) run one after the other, and
  the second one finds the release and ends with `nothing to do`.
- GitHub keeps only the newest *waiting* run of the group and cancels an older waiting one. If
  the version is bumped several times in quick succession (say 0.2.0, then 0.3.0 while the
  0.2.0 run is still waiting), the older waiting run is cancelled: that middle version is
  superseded and never gets a tag or a release. The newest version is still released and
  `repo.xml` points at it, so this is harmless for LMS users, who only ever see the version in
  `repo.xml`. To release every version, wait for each release run to finish before the next
  bump.
- A push that touches `install.xml` without changing the version releases nothing (step 0); a
  dispatch for an already released version finds the existing release and does nothing.
- **Release exists but `repo.xml` is stale** (a run failed after creating the release, for
  example on a rejected push): run the workflow again. It downloads the existing asset,
  hashes it and updates `repo.xml` from it, without rebuilding or re-uploading anything.
- **Tag exists without a release**: the workflow stops and asks for a human. Delete the tag in
  GitHub (Code → Tags), then run the workflow again.

## Verifying a release

1. The release exists with the asset:
   `https://github.com/wilsonwaters/SqueezeABCListen/releases/tag/vV` lists `ABCListen-V.zip`,
   and its notes are the `CHANGELOG.md` section for `V`.
2. `repo.xml` on `main` points at it: a commit `Release vV: update repo.xml [skip ci]` by
   Wilson Waters sets `version="V"` and
   `<url>https://github.com/wilsonwaters/SqueezeABCListen/releases/download/vV/ABCListen-V.zip</url>`.
3. The SHA1 of the downloaded asset equals `repo.xml`'s `<sha>`:

   ```bash
   V=0.1.0
   curl -sSLO "https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v$V/ABCListen-$V.zip"
   sha1sum "ABCListen-$V.zip"
   curl -sSL https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml | grep '<sha>'
   ```

4. Optionally, install it on a test LMS: `scripts/lms-repo-install.sh http://<lms>:9000
   https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml`, then restart
   LMS. (raw.githubusercontent.com may serve the old `repo.xml` for a few minutes, and LMS
   caches each repository file for 5 minutes.)

## Prerequisites and troubleshooting

- **Workflow permissions.** The workflow declares `permissions: contents: write`, but a
  repository setting can still make `GITHUB_TOKEN` read-only. A **403** on creating the release
  or on pushing `repo.xml` means: **Settings → Actions → General → Workflow permissions →
  Read and write permissions**, save, then run the workflow again (it repairs `repo.xml` if the
  release was already created).
- **Branch protection.** GitHub Actions (`github-actions[bot]`, the `GITHUB_TOKEN` identity)
  must be allowed to push the `repo.xml` commit straight to `main`; the commit's author doesn't
  matter for this. If `main` is protected,
  allow GitHub Actions to bypass the rule, or the release is created but `repo.xml` stays stale.
- **Before the first release** the committed `repo.xml` has a placeholder `sha` of 40 zeros. A
  user who adds the repository in that window sees ABC listen 0.1.0, but LMS's SHA1 check
  rejects the download and nothing is installed. Run the first release soon after `repo.xml`
  reaches `main`.
- **Non-fast-forward push.** Retried automatically (re-fetch, re-apply, up to 3 times). If it
  still fails, run the workflow again.
- **"version … is lower than …"**: `install.xml` has a version below the last release (its tag,
  or the version in `repo.xml` on `main`). Bump it above the released version.
- **"uploaded asset sha1 … differs"**: the uploaded file isn't the one that was built;
  `repo.xml` was left alone. Bump the version and release again. Don't re-run the workflow
  for the broken version: its repair path would publish the uploaded file's SHA1.

## Rules

- **Never reuse a version number.** LMS only offers an update when the version goes up, and
  it caches downloads by name.
- **Never hand-edit `sha`** (or `version`/`url`) in `repo.xml`. The workflow writes them; the
  committed file starts with a 40-zero placeholder `sha` until the first release.
- **Never replace an uploaded asset.** Installed copies were verified against the old SHA1.
  Fix problems by bumping the version and releasing again.
- **Feature pull requests never touch `<version>`** in `ABCListen/install.xml`. Changing it on
  `main` releases it.
- **Update `CHANGELOG.md` before releasing.** Its section for the version is the release notes;
  without one, GitHub generates notes from the merged pull requests.
