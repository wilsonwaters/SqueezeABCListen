# Master Plan — release

## Goal
Make ABCListen installable from one URL and ship it properly (brief "Distribution", criteria 6 and 7):
1. **R1** — reproducible packaging (zip + sha1), a GitHub-hosted third-party `repo.xml`, and an automated release
   workflow that creates the tag/Release server-side and updates `repo.xml`; README installation section; cut
   **v0.1.0** right after the vertical slice so the install path is proven early.
2. **R2** — a scripted JSON-RPC acceptance test (`scripts/smoke.sh`) covering every success criterion, user docs with
   Default + Material screenshots, troubleshooting/limitations, and the official-repository guide.
3. **R3** — **v1.0.0** through the workflow, installed on a clean LMS profile from the GitHub `repo.xml`, smoke pass,
   final system verification, and the pi14 acceptance checklist for the stakeholder.

Everything is ported from SqueezeRTRFM v1.0.0 (`research/lms-plugin-guide.md` §9–§10) with the mechanical rename
`RTRFM`→`ABCListen`, `rtrfm`→`abclisten`, `wilsonwaters/SqueezeRTRFM`→`wilsonwaters/SqueezeABCListen`.

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| R1 | Packaging & distribution: `build.sh`, `check-package.sh`, `update-repo-xml.pl`, `changelog-section.sh`, `lms-repo-install.sh`, `repo.xml` (placeholder sha), `release.yml`, CI package checks, README install section, RELEASING.md, CHANGELOG.md; local repo-install test; cut v0.1.0 | M | F1 | planned |
| R2 | `scripts/smoke.sh` acceptance test (+ CLI test with fake JSON-RPC); README usage tour, screenshots, limitations, troubleshooting, compatibility, privacy; `docs/official-repository.md`; CHANGELOG for all shipped tasks | M | all shipping tasks (L1–L5, O1–O4, D1–D3, M1–M2, R1) or their descoping | planned |
| R3 | v1.0.0: version bump → workflow release; clean-profile install from raw GitHub `repo.xml`; `smoke.sh` pass; final system verification (Default + Material); pi14 acceptance checklist | S | R2 | planned |

### R1 — packaging, repo.xml, automated release, v0.1.0
- **Scripts** (port REF, rename): `scripts/build.sh` (version from `ABCListen/install.xml`, `X.Y.Z` only; zips the
  **contents** of `ABCListen/` with `install.xml` at the zip root, `zip -X`, symlinks dereferenced →
  `dist/ABCListen-<ver>.zip` + `.sha1`); `scripts/check-package.sh` (layout; forbidden paths `t/`, `dev/`, `ai-state/`,
  `.github/`, `scripts/`, `docs/`); `scripts/update-repo-xml.pl` (core Perl, idempotent: version, url, sha);
  `scripts/changelog-section.sh` (Keep a Changelog section extractor); `scripts/lms-repo-install.sh` (headless Manage
  Plugins form POST; `PLUGIN` default `ABCListen`).
- **`repo.xml`** (repo root): `<extensions><details><title lang="EN">…</title></details><plugins><plugin
  name="ABCListen" version minTarget="8.3" maxTarget="*">` with `title`, `desc` (consistent with shipped features),
  category `radio`, **absolute** raw.githubusercontent.com `icon`, `url`
  `https://github.com/wilsonwaters/SqueezeABCListen/releases/download/v<ver>/ABCListen-<ver>.zip`, 40-zero placeholder
  `sha`, `link`, `creator`. min/maxTarget mirror `install.xml`. Must stay valid XML forever (the official aggregator
  `die`s on bad XML).
- **`.github/workflows/release.yml`** (port REF): triggers `workflow_dispatch` + push to `main` touching
  `ABCListen/install.xml`; `permissions: contents: write`; CI via `workflow_call`; guards (version format, no downgrade,
  existing tag/release → idempotent repair path, `repo.xml` must contain `name="ABCListen"`); build once and hash that
  exact file; `gh release create v<ver>` with notes from `changelog-section.sh`; download the asset and compare sha1;
  `update-repo-xml.pl` + `xmllint`; commit **only** `repo.xml` to `main` with `[skip ci]`, retry ×3 on non-fast-forward;
  commit identity per RQ1. PRs touching release files get a dry run.
- **CI**: append to `scripts/check.sh`/`ci.yml` (sanctioned foundation edits): build zip, `check-package.sh`, `xmllint`
  `repo.xml`, repo.xml targets == install.xml.
- **Tests** `t/90-plugin-files.t` (install.xml: module, GUID format and not RTRFM's, min 8.3/max `*`, icon exists and is
  512×512), `t/91-repo-xml.t`, `t/92-update-repo-xml.t`, `t/93-release-workflow.t`, `t/94-package.t`,
  `t/95-changelog-section.t` (expects the `0.1.0` section).
- **Docs**: README (what it is, unofficial/not-affiliated disclaimer, status, **Installation**: Settings → Manage Plugins
  → Additional Repositories → add `https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml` →
  Apply → confirm the third-party prompt → tick ABC listen → Apply → restart; updating; uninstalling); `RELEASING.md`
  (bump version on `main` or dispatch; what the workflow does; prerequisites: Actions read/write permission, `main`
  pushable by Actions); `CHANGELOG.md` (Unreleased + 0.1.0).
- **Verification**: (a) local repo install on the testbed — unlink the dev link, `scripts/build.sh`, serve `dist/` + a
  localhost `repo.xml` (`python3 -m http.server --bind 127.0.0.1`), `scripts/lms-repo-install.sh`, restart → plugin loads
  from `/opt/lms-dev/cache/InstalledPlugins/Plugins/ABCListen`, Radio lists ABC listen, a station plays; uninstall
  cleanly; restore the dev link; (b) after merge the orchestrator dispatches the workflow → Release `v0.1.0` with the
  zip; `repo.xml` on `main` matches the downloaded asset's sha1; (c) if the container can fetch GitHub release assets
  (RQ7), install v0.1.0 from the raw GitHub URL.

### R2 — acceptance smoke test + user docs
- **`scripts/smoke.sh <lms-url> <player-mac> [--skip-live] [--station <SERVICE_ID>] [--local <SERVICE_ID>]`** (bash +
  curl + jq; walks menus **by name**; prints PASS/FAIL/SKIP per check; non-zero exit on FAIL):
  1. server up; 2. player connected; 3. plugin enabled; 4. Radio lists "ABC listen"; 5. top level is Live radio,
  Programs, Discover, Search ABC listen, My ABC listen; 6. a national station plays (`time` advances ≥ 5 s) and `status`
  shows program/song metadata ≠ the station name (default `TRIPLEJ`); 7. a local station plays (default
  `LOCAL_SYDNEY`); 8. Programs → By network → first program → first episode plays and seeks (`time 600` → ≥ 600);
  9. All programs A–Z non-empty; 10. Discover → first collection non-empty; 11. search "science" returns ≥ 1 program
  and ≥ 1 episode; 12. follow a program → listed under My ABC listen → unfollow (state restored). Live checks `SKIP`
  with `--skip-live`.
- **Tests** `t/96-smoke-strings.t` (menu names in smoke.sh equal strings.txt values), `t/97-smoke-cli.t` (smoke.sh
  against a fake JSON-RPC server: pass, fail and skip paths; port REF `t/19`).
- **README**: usage tour (Live radio incl. local/time-zone versions and schedules; Programs by network/A–Z/type;
  Discover; Search incl. LMS global search; My ABC listen and settings); screenshots (Default + Material) in
  `docs/images/` (small PNGs); now-playing behaviour; limitations (56 kbps default live and the quality setting,
  HLS-only/event-only stations, newest-250 episodes, catch-up AAC ~28-day expiry, Australia-only audio, unofficial ABC
  endpoints may change); troubleshooting (`faad` for older players, Radio Now Playing coexistence, raising
  `plugin.abclisten` log level, Algolia "busy" message, "not available" messages); compatibility (tested on 9.1.x;
  claims 8.3+); privacy (no ABC login; follows stored locally in LMS prefs); self-test with `smoke.sh`; disclaimer.
- `docs/official-repository.md` (port REF; re-check `ABCListen` is unused in the official `extensions.xml`;
  prerequisites: unique name, valid XML, stable URL, versioned zip names; PR adding our raw `repo.xml` URL to
  `LMS-Community/lms-plugin-repository` `include.json`); `CHANGELOG.md` entries for every shipped task (from PR bodies);
  `t/98-docs.t` (README/RELEASING required sections; install URL correct).
- **Verification**: `scripts/smoke.sh http://localhost:9000 00:00:00:00:00:01` all PASS on the testbed (live via
  StreamGuys); screenshots regenerated from the final build; `scripts/check.sh` green.

### R3 — v1.0.0 release and final acceptance
- Bump `ABCListen/install.xml` to `1.0.0` and close the CHANGELOG section (the only version-changing commit) → workflow
  publishes `v1.0.0` and updates `repo.xml`.
- Clean LMS profile (fresh prefs/cache, dev link removed) installs v1.0.0 from the raw GitHub `repo.xml` (UI or
  `lms-repo-install.sh`); `scripts/smoke.sh` passes; plugin prefs contain only defaults/follows — no credentials
  (criterion 5); restore the dev setup afterwards.
- Final system verification by the runtime-verification agent: every success criterion walked in Default + Material and
  via `menu:1` JSON-RPC; `server.log` clean.
- Draft the **pi14 acceptance checklist** for the orchestrator's handoff: add the repo URL and install; run `smoke.sh`
  against pi14; `liveQuality` = mediahub; ABC Wide Bay; a `/geo-001/` episode; an AU schedule/EPG spot check; a hardware
  player (AAC/`faad`); optional PlayHLS.

## Integration points
- **foundation**: R1 appends package checks to F1's `scripts/check.sh` and `ci.yml`; `install.xml` is
  foundation-owned except `<version>`, which only R1 (0.1.0 notes), the IC-3 bump (0.2.0) and R3 (1.0.0) change.
- **All feature streams**: describe user-visible changes and new limitations in PR bodies; R2 folds them into README
  and CHANGELOG. Menu names used by `smoke.sh` come from strings pre-seeded by F1 (L1, O2, O3, D1, D3, M2 sections).
- **Testbed**: repo-install tests remove the dev link first and restore it after (RUNBOOK "Testing the install from
  repository flow"); hold the testbed lock.
- **Orchestrator**: dispatches the release workflow (GitHub MCP) for v0.1.0 (after R1), v0.2.0 (IC-3), optional
  v0.3.0, v1.0.0 (R3).
- **Strings**: release adds no runtime strings; R2 may add `PLUGIN_ABCLISTEN_DESC` wording changes in F1's section
  (orchestrator-sanctioned).

## Out of scope
- Actually submitting the official-repository PR (document only; stakeholder decides after pi14 acceptance — RQ4).
- Non-EN translations; gh-pages/dev-build channels; LMS 8.x test bed; signing.
- Hosting the plugin under the LMS-Community org; forum announcement (stakeholder's choice).

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| RQ1 | Commit identity for the workflow's `repo.xml` commit (OPEN-QUESTIONS #2; REF hard-coded "Wilson Waters"). | `github-actions[bot]` until the stakeholder says otherwise; a one-line `COMMIT_NAME/EMAIL` change. | R1 |
| RQ2 | Install URL: raw `main` or `releases/latest/download/repo.xml`? | Raw `main` (REF). | R1 |
| RQ3 | `GITHUB_TOKEN` may be read-only / `main` protected. | Workflow declares `contents: write`; on 403 the stakeholder enables read/write in Settings → Actions (RELEASING.md). | R1 (release step) |
| RQ4 | Submit to the official LMS plugin repository now? | Document only (R2); stakeholder decides after pi14 acceptance. | R2/R3 |
| RQ5 | Release cadence. | v0.1.0 (R1) → v0.2.0 (IC-3) → optional v0.3.0 after wave 4 → v1.0.0 (R3). | R1, R3 |
| RQ6 | Commit README screenshots? | Yes, small PNGs in `docs/images/` (not large binaries per sandbox rules); never commit `dev/logs`. | R2 |
| RQ7 | Can the container download GitHub release assets through the egress proxy? | Check in R1; if not, IC-3/R3 GitHub-URL installs are stakeholder-verified and the container uses a locally served zip with the same sha1. | R1, R3 |

## Changelog
- 2026-10-19 — Initial master plan (stream-planning sub-agent).
