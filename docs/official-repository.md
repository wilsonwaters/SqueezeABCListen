# Getting ABC listen into the official LMS plugin repository

**Status: not submitted. The stakeholder decides whether and when to submit after accepting
v1.0.0 on their own server (RQ4).**

Today users install ABC listen by adding this repository's `repo.xml` URL under **Settings →
Manage Plugins → Additional Repositories** (see the [README](../README.md#installation)). Plugins
in the official repository need no extra URL: they are listed in **Manage Plugins** on every LMS
out of the box. This guide describes how to get there.

## How the official repository works

LMS reads its default plugin list from
<https://lms-community.github.io/lms-plugin-repository/extensions.xml>. That file is built by
the [LMS-Community/lms-plugin-repository](https://github.com/LMS-Community/lms-plugin-repository)
project from `include.json`, a list of repository XML URLs, one per plugin author. The project's
README says: "If a plugin author wants his plugins to be included in the default list of
extensions in LMS, just add the URL to his repository XML file to this list". So ABC listen keeps
its own `repo.xml` and release process ([RELEASING.md](../RELEASING.md)); the official repository
only copies from it.

The build script, `buildrepo.pl`, reads `include.json`, fetches every repository file listed
there and merges them into `extensions.xml`. A scheduled workflow runs it every 6 hours. It dies
on a repository file that isn't well-formed XML, which stops the update for every plugin, not
just the broken one.

## Prerequisites

Check each of these before opening the pull request:

- [ ] **The plugin name `ABCListen` is globally unique.** The aggregator merges every repository
  by plugin name, so a second `ABCListen` would clash with ours (or ours with it). Search the
  current `extensions.xml` for `name="ABCListen"`:

  ```bash
  curl -sSL https://raw.githubusercontent.com/LMS-Community/lms-plugin-repository/master/extensions.xml | grep -c 'name="ABCListen"'
  ```

  This should print `0`. It printed `0` on 2026-10-24, when the file listed 221 plugins and none
  of them had "ABC" in its name. Check again just before submitting.
- [ ] **`repo.xml` is valid XML.** `buildrepo.pl` dies on a repository file that isn't
  well-formed, which stops the update for everyone. CI runs `xmllint --noout repo.xml` on every
  change (`scripts/check.sh`, and `t/91-repo-xml.t` checks every element LMS reads), and the
  release workflow checks it again before committing.
- [ ] **The repository URL is stable:** the raw file on `main`,
  `https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml`. Don't rename
  the repository, the branch or the file afterwards.
- [ ] **Zip names are versioned** (`ABCListen-<version>.zip`), because LMS caches downloads by
  name. `scripts/build.sh` and the release workflow already do this, and the zips on the
  `release-assets` branch are never replaced.
- [ ] **`minTarget` and `maxTarget` are both present** on the `<plugin>` element (LMS only
  filters by version when both are there), and equal `install.xml`'s `minVersion`/`maxVersion`
  (`8.3` / `*`). `t/91-repo-xml.t` checks this.
- [ ] **The category is valid:** `radio`. The aggregator turns unknown categories into `misc`.
- [ ] **The icon URL is absolute** (a `https://raw.githubusercontent.com/…` URL), not the
  relative path used in `install.xml`.
- [ ] **The `sha` is correct:** the SHA1 of the zip that `<url>` points at. The release workflow
  writes it from the uploaded file and downloads the zip again to check it; check it yourself
  with the commands in [RELEASING.md, Verifying a release](../RELEASING.md#verifying-a-release).

## Pre-submission checklist

- [ ] The stakeholder has accepted v1.0.0 on their own LMS and players.
- [ ] v1.0.0 installs from the repository URL on a clean LMS (Settings → Manage Plugins →
  Additional Repositories, or `scripts/lms-repo-install.sh`).
- [ ] `scripts/smoke.sh http://<your-lms>:9000 <player-mac>` passes on that LMS
  (`SMOKE: 15/15 passed`).
- [ ] All the prerequisites above are ticked.

## Steps

1. Fork <https://github.com/LMS-Community/lms-plugin-repository> on GitHub.
2. In the fork, edit `include.json` and add our URL to the `"repositories"` list, in
   alphabetical order (or at the end), keeping the file's formatting (a comma between entries,
   none after the last one, so the file stays valid JSON):

   ```json
   "https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml",
   ```

3. Commit, and open a pull request against `LMS-Community/lms-plugin-repository`. Say what the
   plugin does and that it is unofficial, and link this repository. For example:

   > Add ABC listen (SqueezeABCListen): an unofficial plugin for ABC listen, the radio and
   > podcast service of the Australian Broadcasting Corporation. It plays every ABC live radio
   > station with what's on air, ABC's podcasts, programs, episodes and audiobooks, and has
   > search and followed programs. It is not affiliated with or endorsed by the ABC, needs no
   > ABC account, and streams straight from ABC's servers.
   > <https://github.com/wilsonwaters/SqueezeABCListen>

4. Wait for the maintainers to review and merge it.

## What happens after the merge

- The scheduled workflow in the official repository rebuilds `extensions.xml` every 6 hours
  (maintainers can also run it by hand). ABC listen appears in **Manage Plugins** on every LMS
  after the next rebuild (and after LMS refreshes its copy).
- The aggregator rewrites our entry on the way in:
  - it removes any `installations` value and fills in the real install count from the LMS
    usage statistics;
  - an unknown category becomes `misc` (ours, `radio`, is known).
- If a rebuild would remove 3 or more lines from `extensions.xml`, the workflow opens a pull
  request for a human to check instead of pushing the change. So a release that drops or
  renames things in our entry may take longer to appear.
- New releases need nothing extra: the workflow in this repository updates `repo.xml`, and
  the next rebuild picks up the new version, URL and `sha`.
- Users who had added our URL under Additional Repositories can remove it; keeping it is
  harmless.

## Maintenance rules once listed

- **Keep `repo.xml` valid XML**, always. A broken file breaks the official rebuild for
  everyone. Change it only through the release workflow and pull requests that pass CI.
- **Never reuse a version number**, and never replace a published zip. LMS only offers updates
  when the version goes up, and installed copies were checked against the old `sha`. Fix
  mistakes by releasing a new version.
- Keep the plugin name, the repository URL, the category and `minTarget`/`maxTarget` stable.
- Keep the README's disclaimer: the plugin is unofficial and not affiliated with or endorsed by
  the ABC.
- To withdraw the plugin, open a pull request that removes our URL from `include.json`.
