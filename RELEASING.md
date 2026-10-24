# Releasing SqueezeABCListen

Releases are made only by the **Release** workflow (`.github/workflows/release.yml`). It builds
`ABCListen-<version>.zip`, creates the tag and GitHub Release `v<version>` with the zip attached,
commits the same zip to the `release-assets` branch, and then points `repo.xml` on `main` at that
copy. `repo.xml` is what LMS users install from:

```
https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml
```

Its `<url>` is the zip on the `release-assets` branch, served by raw.githubusercontent.com:

```
https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-<version>.zip
```

It is not the GitHub Release asset, because LMS 9.1.1 can't download that. GitHub's
`releases/download/…` redirect carries a `Content-Security-Policy` header line of about 9,200
characters, and the `Net::HTTP` bundled with LMS rejects any header line over 8,192 (`Header
line too long (limit is 8192)` in `server.log`; issue #62). raw.githubusercontent.com sends short
headers. The GitHub Release stays as it is, with the same zip, for people and for the changelog.

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
   `install.xml` without changing `<version>`, for example a new `optionsURL`, does nothing
   if `repo.xml` on `main` already has that version; if it doesn't, the version was never
   released, and that push releases it.)
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

Real releases only run from `main`; a real run dispatched on another branch fails at once
(without holding up or cancelling a release from `main`).

## What the workflow does

0. **Version.** Reads `V` from `ABCListen/install.xml` and fails unless it is `X.Y.Z`. On a
   push, it compares `V` with the version before the push; if it is unchanged **and**
   `repo.xml` on the latest `main` already has `version="V"`, the run ends here (a green no-op;
   the other jobs show as skipped). Otherwise it goes on, so a version whose own run never
   released it is released now.
1. **Checks.** Runs the same checks as CI (`ci.yml`, i.e. `scripts/check.sh`); a failure stops
   the run.
2. **Guards.** Fails if `V` is lower than the highest `vX.Y.Z` tag or than the version in
   `repo.xml` on the latest `main` (no downgrades), if `repo.xml` on `main` has no
   `name="ABCListen"` entry to update, or if tag `vV` exists without a release.
3. **Existing release.** If release `vV` already exists, it downloads its `ABCListen-V.zip` and
   hashes it. If `repo.xml` on `main` already has `version="V"`, the raw `release-assets` URL of
   `ABCListen-V.zip` and the asset's SHA1, **and** `release-assets` has that same file, the run
   logs `nothing to do` and ends green. Otherwise it logs what is stale and skips to step 7 with
   the downloaded asset (the repair path). That includes a release made before `release-assets`
   existed (0.3.0 and earlier), whose `repo.xml` url is still the GitHub Release asset. If
   `release-assets` has a *different* `ABCListen-V.zip`, the run fails. An existing release is
   never rebuilt and its asset is never replaced.
4. **Build.** Runs `scripts/build.sh` once and takes the SHA1 from `dist/ABCListen-V.zip.sha1`.
   The zip is never rebuilt after it has been hashed.
5. **Release.** Creates tag and release `vV` server-side with `gh release create`, on the commit
   that was built, titled `ABC listen V`, with `ABCListen-V.zip` attached. The release notes are
   the body of `CHANGELOG.md`'s `## [V]` section (`scripts/changelog-section.sh V`); if there is
   no such section, or it is empty, GitHub generates notes from the merged pull requests instead.
6. **Verify.** Downloads the uploaded asset and compares its SHA1 with step 4's. On a mismatch
   the run fails before anything else is published.
7. **release-assets.** `scripts/publish-release-asset.sh --branch release-assets <zip>` commits
   the zip (step 4's, or the downloaded asset on the repair path) to the `release-assets`
   branch as `ABCListen-V.zip`: one commit, `Add ABCListen-V.zip`, authored and committed as
   `COMMIT_NAME` / `COMMIT_EMAIL` (see step 9) and pushed with `GITHUB_TOKEN`.
   - The first publish creates the branch as an orphan, with no history in common with `main`.
     It holds the zips and a short README that says what the branch is for and not to merge it.
   - A zip that is already there with the same content is left alone. One with different content
     is never replaced: the run fails.
   - The commit is made with `git commit-tree`, so the checkout isn't touched.
   - A rejected push (the branch moved) is retried on the new tip up to 3 times. A refusal (403,
     GH006, GH013) is not.
8. **Verify the download URL.** `scripts/verify-download.sh` downloads
   `https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-V.zip`
   the way LMS will (following redirects) and compares its SHA1 with the zip's.
   - raw.githubusercontent.com can take a moment to serve a new file, and caches every answer
     (a 404 included) for 5 minutes, so it retries every 15 s for up to 6 minutes.
   - It fails at once if a response header line is longer than 8,192 bytes, LMS 9.1.1's limit.
   - On a failure the run stops before `repo.xml` is touched.
9. **repo.xml.** On top of the latest `main`: runs
   `scripts/update-repo-xml.pl --version V --sha <sha1> --url <raw URL> --install-xml <file>`,
   where `<raw URL>` is step 8's URL and `<file>` is the `install.xml` inside the zip being
   released (so `minTarget` / `maxTarget` are the released commit's, not those of a later
   `main`). It checks the result with `xmllint`, and commits **only** `repo.xml` with the message
   `Release vV: update repo.xml [skip ci]`, authored and committed as
   `Wilson Waters <wilsonwaters@users.noreply.github.com>` (the repository owner). That identity
   (also used in step 7) is set once, at the top of the workflow (`COMMIT_NAME` /
   `COMMIT_EMAIL`); change those two lines to commit as someone else. The push itself is made
   with `GITHUB_TOKEN`, i.e. by GitHub Actions (`github-actions[bot]`). If it is rejected because
   `main` moved, the workflow re-fetches `main`, re-applies the change and retries, up to 3
   times, then fails.

The release and the `release-assets` copy are created, and the copy is downloaded and checked,
before `repo.xml` is changed. So `repo.xml` never points at a file that doesn't exist or doesn't
match its `sha`. If a run stops in between, `repo.xml` is stale (still the previous release) but
not broken, and the next run repairs it (step 3).

Pushes made with `GITHUB_TOKEN` don't start workflows, so the `repo.xml` commit doesn't
trigger another release; `[skip ci]` and the `paths` filter are extra guards. `release-assets`
has no workflow files, so no workflow ever runs on it.

## Dry runs

A dry run goes through steps 0–4, step 7 without the push (the `release-assets` commit is made
in the runner's checkout and shown) and step 9 up to, but not including, the commit. It skips
step 8, since nothing was pushed. It creates no release, tag, branch or commit on GitHub. It
prints the version, the zip name, its SHA1 and URL, the `unzip -l` listing, the release notes a
release of that version would get (and where they come from), the `release-assets` commit and
the `git diff` of `repo.xml`, and repeats the notes and the diff in the run summary. The notes
are shown even when release `vV` already exists.

- Every pull request that changes `.github/workflows/release.yml`, `ABCListen/install.xml`,
  `repo.xml`, `CHANGELOG.md`, `scripts/build.sh`, `scripts/check-package.sh`,
  `scripts/update-repo-xml.pl`, `scripts/changelog-section.sh`,
  `scripts/publish-release-asset.sh` or `scripts/verify-download.sh` gets a dry run (the
  **Build and release** job of the **Release** workflow). On a pull request the change is
  applied to the pull request's merge commit.
- **Actions → Release → Run workflow** with *Dry run* ticked (or `"inputs":{"dry_run":"true"}`
  in the REST call) does a dry run on the chosen branch.

Dry runs don't wait for real releases, and real releases don't wait for dry runs. If release
`vV` already exists, a dry run shows the no-op or repair path instead of a build; CI builds
and checks the zip on every pull request anyway.

## Idempotency and repair

- Real runs share one concurrency group and a running release is never cancelled, so two
  runs for the same version (a dispatch plus a push, or a re-run) run one after the other, and
  the second one finds the release and ends with `nothing to do`.
- GitHub keeps only the newest *waiting* run of the group and cancels an older waiting one, so
  a version bump's run can be cancelled before it starts. The newest version is still
  released: the run that replaced it is for a later commit on `main`, and it releases the
  version in that commit's `install.xml` unless `repo.xml` on `main` already has it (step 0).
  That holds even when the later push leaves `<version>` alone (say a bump to 0.3.0 waits
  behind another release, then a new `optionsURL` is pushed: the 0.3.0 run is cancelled and
  the `optionsURL` run releases 0.3.0). Only when the version is bumped several times in quick
  succession (0.2.0, then 0.3.0 while the 0.2.0 run is still waiting) is the middle version
  superseded: it never gets a tag or a release. This is harmless for LMS users, who only ever
  see the version in `repo.xml`; to release every version, wait for each release run to
  finish before the next bump.
- A push that touches `install.xml` without changing the version releases nothing once
  `repo.xml` on `main` has that version (step 0); a dispatch for an already released version
  finds the existing release and does nothing.
- **Release exists but `repo.xml` is stale** (a run failed after creating the release, for
  example on a rejected push, or raw.githubusercontent.com was slow): run the workflow again. It
  downloads the existing asset, hashes it, publishes it to `release-assets` if it isn't there
  yet, checks the raw URL and updates `repo.xml` from it, without rebuilding or re-uploading
  anything.
- **Releases made before `release-assets` (0.3.0 and earlier).** Their `repo.xml` url is the
  GitHub Release asset, which LMS 9.1.1 can't download. Run the workflow on `main` (*Dry run*
  unticked) while `install.xml` still has that version. It takes the repair path: it publishes
  the existing asset to `release-assets` and moves `repo.xml`'s url there. `version` and `sha`
  stay the same, and no new version is needed. This is how v0.3.0 is moved over.
- **Tag exists without a release**: the workflow stops and asks for a human. Delete the tag in
  GitHub (Code → Tags), then run the workflow again.

## Verifying a release

1. The release exists with the asset:
   `https://github.com/wilsonwaters/SqueezeABCListen/releases/tag/vV` lists `ABCListen-V.zip`,
   and its notes are the `CHANGELOG.md` section for `V`.
2. `release-assets` has the same zip:
   `https://github.com/wilsonwaters/SqueezeABCListen/tree/release-assets` lists
   `ABCListen-V.zip`, added by a commit `Add ABCListen-V.zip` by Wilson Waters.
3. `repo.xml` on `main` points at it: a commit `Release vV: update repo.xml [skip ci]` by
   Wilson Waters sets `version="V"` and
   `<url>https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-V.zip</url>`.
4. The SHA1 of the file LMS downloads equals `repo.xml`'s `<sha>` and the release asset's:

   ```bash
   V=0.3.0
   curl -sSL https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml | grep -E '<url>|<sha>'
   curl -sSL -o "raw-$V.zip" "https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/release-assets/ABCListen-$V.zip"
   curl -sSL -o "release-$V.zip" "https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v$V/ABCListen-$V.zip"
   sha1sum "raw-$V.zip" "release-$V.zip"
   ```

   `scripts/verify-download.sh --timeout 0 <url> <sha>` does the same check as the workflow,
   including LMS's header line limit.

5. Optionally, install it on a test LMS: `scripts/lms-repo-install.sh http://<lms>:9000
   https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml`, then restart
   LMS. (raw.githubusercontent.com may serve the old `repo.xml` for a few minutes, and LMS
   caches each repository file for 5 minutes.)

## Prerequisites and troubleshooting

- **Workflow permissions.** The workflow's release job declares `permissions: contents: write`
  (the other jobs only read), but a repository setting can still make `GITHUB_TOKEN`
  read-only. A **403** on creating the release or on pushing `release-assets` or `repo.xml`
  means: **Settings → Actions → General → Workflow permissions → Read and write permissions**,
  save, then run the workflow again (it repairs `release-assets` and `repo.xml` if the release
  was already created).
- **Branch protection.** GitHub Actions (`github-actions[bot]`, the `GITHUB_TOKEN` identity)
  must be allowed to push the `repo.xml` commit straight to `main`, and to create and push
  `release-assets`; the commits' author doesn't matter for this. If `main` is protected,
  allow GitHub Actions to bypass the rule, or the release is created but `repo.xml` stays stale.
  Protecting `release-assets` against deletion and force pushes is fine (the workflow only adds
  commits), but not against pushes by GitHub Actions.
  A refused push (`GH006: Protected branch update failed` for branch protection, `GH013:
  Repository rule violations found` for rulesets, or a 403) fails the run at once instead of
  being retried.
- **Before the first release** the committed `repo.xml` has a placeholder `sha` of 40 zeros. A
  user who adds the repository in that window sees ABC listen 0.1.0, but LMS's SHA1 check
  rejects the download and nothing is installed. Run the first release soon after `repo.xml`
  reaches `main`.
- **Non-fast-forward push.** Retried automatically (re-fetch, re-apply, up to 3 times). If it
  still fails, run the workflow again.
- **"version … is lower than …"**: `install.xml` has a version below the last release (its tag,
  or the version in `repo.xml` on `main`). Bump it above the released version.
- **"uploaded asset sha1 … differs"**: the uploaded file isn't the one that was built;
  `release-assets` and `repo.xml` were left alone. Bump the version and release again. Don't
  re-run the workflow for the broken version: its repair path would publish the uploaded file.
- **"… did not verify after … tries"** (Verify download URL): raw.githubusercontent.com didn't
  serve the zip with the right SHA1 within 6 minutes; `repo.xml` was left alone. The zip is on
  `release-assets`, so run the workflow again later: the repair path finds it there, checks the
  URL again and updates `repo.xml`.
- **"… sends a response header line longer than 8192 bytes"**: the download URL now answers with
  headers LMS 9.1.1 can't read, the problem of issue #62; `repo.xml` was left alone. The zip
  needs another host.
- **"… a published zip is never replaced"**: `release-assets` already has a different
  `ABCListen-V.zip`. Don't change it (LMS may have installed it); bump the version and release
  again.

## Rules

- **Never reuse a version number.** LMS only offers an update when the version goes up, and
  it caches downloads by name.
- **Never hand-edit `sha`** (or `version`/`url`) in `repo.xml`. The workflow writes them; the
  committed file starts with a 40-zero placeholder `sha` until the first release.
- **Never replace an uploaded asset, or a zip on `release-assets`.** Installed copies were
  verified against the old SHA1. Fix problems by bumping the version and releasing again.
- **Never merge `release-assets`** into `main` (or anything into it), and never delete it:
  `repo.xml`'s url points into it. Only the workflow commits to it.
- **Feature pull requests never touch `<version>`** in `ABCListen/install.xml`. Changing it on
  `main` releases it.
- **Update `CHANGELOG.md` before releasing.** Its section for the version is the release notes;
  without one, GitHub generates notes from the merged pull requests.
