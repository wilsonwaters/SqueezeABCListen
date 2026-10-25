# Project Progress

## Phase
v1.0.0 accepted by the stakeholder on pi14 (2026-10-25; #17 closed). Now: v1.1.0 — stakeholder feedback + HLS + backlog.

## Issue map (task ID → GitHub issue)
- foundation: F1 #1 · F2 #3 · F3 #7 · F4 #34 (bug) · F5 #37 (cardRef names) · F6 #41 (F4 follow-ups)
- live: L1 #2 · L2 #4 · L3 #8 · L4 #10 · L5 #14
- ondemand: O1 #12 · O2 #16 · O3 #18 · O4 #19 · O6 #30 · O7 #40 · O8 #48 (O7 follow-ups) · O9 #72 (Default-skin placeholder icons, after 1.0)
- discovery: D1 #5 · D2 #6 · D3 #13 · D4 #22 · D5 #23 · D6 #44 (podcast A–Z groups) · D7 #51 (all categories) · D8 #56 (D7 follow-ups) · D9 #66 (search segments)
- myabc: M1 #11 · M2 #20 · M3 #52 (settings/L5 follow-ups) · M4 #59 (Latest stale-id unfollow)
- release: R1 #9 · R2 #15 · R3 #17 · R4 #62 (raw-hosted zips: LMS can't read GitHub's download redirect) · R5 #75 (push-refusal match)

## Currently in flight
- v1.1.0 (stakeholder feedback 2026-10-25): all feature PRs merged (main 7b64242).
  - System verification SYS-1.1.0 — running (J1–J12: top level, stations std/HLS, HLS plays + CPU + fallback,
    U1/U2/U3/O9 incl. Jive DB.lua sim, no leftover "More", podcasts, search, My ABC, sections, upgrade from 1.0.0,
    hygiene, smoke).
  - Then: CHANGELOG [1.1.0] + version bump → release → install check from repo.xml → pi14 re-check (CPU in top,
    Cricket / Grandstand, 30+ min HLS play, Squeezer header, long lists on Jive/piCorePlayer if available).
  - P3 after 1.1.0: #91 L7 HLS title offset, #81 O5.

## Interruptions
- 2026-10-19 ~12:30–17:23 UTC: account usage limit stopped all agents, then the session worker restarted (LMS +
  squeezelite stopped). 17:24: testbed restarted (`dev/start.sh`), stale O3 lock broken, link restored to main; all
  in-flight agents (L1, O3, D1, D3, M2, O6 review, IC-1) resumed from their saved state. Lesson: ≤5 concurrent agents.
- 2026-10-19 ~21:50–23:07 UTC: usage limit again (5 agents) + worker restart. Global git identity reset again (repo
  .git/config kept Wilson Waters, so no wrong-author commits). Testbed restarted, stale L5 lock cleared. Resumed L2,
  F5, O7; L5 and D6 held until those finish. New cap: ≤3 concurrent agents.
- 2026-10-20 ~03:00 UTC: usage limit again (SYS, D5 review, M4) + worker restart; stakeholder paused all work
  ("hold off"). 2026-10-23 22:59 UTC: resumed — global git identity reset to Wilson Waters again, testbed restarted,
  stale D5-review lock broken, main re-linked; SYS, D5 review and M4 resumed from saved state.
- 2026-10-24 ~03:00–04:30 UTC: usage limit (R2 final fix round) + worker restart; global git identity reset again
  (fixed), testbed restarted, R2 resumed.
- 2026-10-25 ~03:45–05:56 UTC: usage limit (U2 round-2 fixes, R7) + worker restart; global git identity reset again
  (fixed), testbed restarted, main re-linked, lock free; U2 and R7 resumed from saved state.

## Last completions
- #95 U3 merged (PR #96, squash f48f7ab): 7 s load deadline after page 0, 429 stops a page's split, P5/P9 tests.
  #72 O9 merged (PR #97, squash 7b64242): images on text rows for the web UI only (isWeb; Material turns image-only
  menus into grids), program/episode menus + Program info, README screenshot refreshed. Both orchestrator-reviewed:
  diff read, merged-tree check.sh (937 / 941 tests), screenshots checked.
- #84 U2 merged (PR #90, squash 9a4fcb1): continuous lists (partial feeds), rows numbered by audio episode over all
  pages, no leading textarea above 200 rows (Jive count fix), bounded 10-page retries + 60 s failure cache. Reviews:
  R1 REQUEST_CHANGES (Jive endless reload, HIGH) → R2 REQUEST_CHANGES (placeholders for video cards, retry storm) →
  R3 APPROVE (5 low → #95). Live sample 71 programs: 0 placeholders; DB.lua sim clean.
- #79 R7 merged (PR #94, squash 65399e0): README/CHANGELOG [Unreleased]/RELEASING for 1.1.0; t/98 updated for HLS
  docs. Orchestrator added U2's Play all/Add all, no-repeat collections, About on ≥100-row lists; merged-tree check.sh
  933 tests.
- #89 F9 merged (PR #93, squash 62e98b3): Programs quiet opts; Latest 404 → 1 WARN/day; F7/F8 test gaps (13/13 caught);
  Tracks log line. Orchestrator review: diff read, merged-tree check.sh 895 tests (+U2 trial merge 931 tests).
- #83 U1 merged (PR #86, squash f6abcd1): short description headers + About row. Review REQUEST_CHANGES (pos() bug,
  R3 gap) → fixes → re-review APPROVE; merged-tree check.sh 913 tests.
- #77 R6 merged (PR #92, squash 0980036): drift probe 12 → 19 families (all hard-coded collection ids, recommendations,
  music now.json ×9, section pages, Algolia program index + chapters, station collections; PAPI dropped), breakage
  switches + offline t/89; weekly workflow abc-drift.yml (Sun 19:17 UTC, retry after 5 min, abc-drift issue,
  GITHUB_TOKEN only). Orchestrator review: diff read, merged-tree check.sh 883 tests, live run 19/19 with 0 key/app-id
  occurrences in output; first workflow_dispatch run on main triggered. Also: research notes no longer hold ABC's
  Algolia key/app id or the Gigya site key (f939933; still in git history — public site keys, history not rewritten).
- #80 L6 merged (PR #88, squash b95ad87): liveQuality `hls` — own HLS reader (HLS.pm), 192 kbps AAC on music
  stations, fallback to Icecast, HLS-only services listed in hls mode; gated F2 hook (orchestrator sign-off). Review
  REQUEST_CHANGES ×2 (failure counters, mid-play bad 200, truncation, trun bound, deadline; then master-fetch reset
  loop) → fixes; round 2 verified by orchestrator: diff read, check.sh 874 tests, reviewer probes (hls/r2/framer)
  pass. streams.md contracts 4 and 8 updated. Pending pi14: CPU in top, Cricket/Grandstand, 30+ min play.
- #76 F7 merged (PR #85, squash c884ebf): seenAt = fetch time in Search + episode resolver; newer-meta guard; D5's
  rule shared in Util. #78 F8 merged (PR #87, squash 5c613b6; orchestrator merged main into the stacked branch, t/11
  conflict = F8 side): warnings rate-limited, unchanged meta not rewritten (re-walk 50 → 0 writes). One reviewer, both
  APPROVE (no defects; 3 test gaps + 1 log nit → #89); merged-tree check.sh 830 tests.
- Historical (v0.3.0 → v1.0.0): v0.3.0 released via R4 raw-hosted zips; v1.0.0 released (PR #73) and verified on a
  clean profile (#17); stakeholder accepted on pi14 2026-10-25; #75 R5 merged (PR #82).
- #15 R2 merged (PR #68, squash 47d2099): smoke.sh (15 checks; follows restored by merge), README (16 sections, 9
  screenshots), official-repository guide, CHANGELOG Unreleased, desc sync. REQUEST_CHANGES → fixes → re-review APPROVE.
- O8/D9 review test gaps merged (PR #71, squash 4eeb267): tests only + one comment.
- #48 O8 merged (PR #69, squash 286f338): Hottest 100 follow row + More from; page checks resilient (10-min unconfirmed
  cache, 403 = no answer, dying check listed). #66 D9 merged (PR #70, squash 965d7d0): Search finds AM / same-title
  programs (siteFilter + mergeTwins, distinct 0); A–Z byte-identical. One reviewer, both APPROVE; merged-tree check.sh
  767 tests. Test gaps → small follow-up PR.
- #41 F6 merged (PR #67, squash e979a24): HTTP.pm response to error callbacks, x-nextjs-redirect follow, stale renditions
  fallback, drift probe 12. Review APPROVE; fixes verified (diff read + merged-tree check.sh 752 tests).
- #56 D8 merged (PR #65, squash 9be5881): A–Z 709 → 736 (AM via URL site segment; distinct 0 + strict twin merge),
  Audiobooks A–Z 20, last-good categories at the deadline, A–Z buckets for modifier/compat letters. Review APPROVE;
  fixes verified (diff read + merged-tree check.sh 746 tests).
- #52 M3 merged (PR #64, squash 5ff5484): partial-POST warning fixed, redirect family in log, aria-describedby.
- #23 D5 merged (PR #58, squash da61cf4; orchestrator merged main into the branch to resolve t/10): audiobook Chapters,
  restricted-podcast Episodes (Bluey Listen Along), seenAt = fetch time (API info `at`), /radio/geo/ geo message.
  Review REQUEST_CHANGES → fixes → re-review APPROVE.
- #59 M4 merged (PR #60, squash f2727e2): Latest episodes stable after an unfollow (tombstones kept 30 min).
- #19 O4 merged (PR #57, squash 92d6b51): episode extras — segments, tracklist (stable rows, 90 s failure cache),
  presenters, More from, episode song info.
- v0.3.0 Material D-1 fix merged (PR #61, squash 1e40eb3): station rows type playlist.
- #10 L4 merged (PR #55, squash ff1be94): station rows link + play; station menu (Listen live, on air, Today,
  Yesterday, 5 days); day lists with "<date> · <City> time" heading; past programs → catch-up. Review + runtime APPROVE;
  review fixes verified (diff read + merged-tree check.sh 668 tests). **Live stream L1–L5 complete.**
- #8 L3 merged (PR #54, squash f49749a): song, artist and cover in Now Playing for the 9 music stations; Recently
  played; L2 follow-ups; Live onStream isolation. Review + runtime APPROVE; review fixes (cover originals, variant null
  body, song-end poll, 4 test gaps) verified by orchestrator diff read + merged-tree check.sh (639 tests).
- #51 D7 merged (PR #53, squash 26b21cd): Browse by category lists all 18 categories (collection paged; fallbacks);
  strict categories detection; A–Z "Other" row for non-Latin titles. Review APPROVE; follow-ups D8 (#56).
- #14 L5 merged (PR #49, squash 5cb5289): live quality Standard / ABC mediahub with automatic Icecast fallback; no
  HLS (PlayHLS incompatible, deferred to L6). Review + runtime APPROVE. Follow-ups: M3 (#52); Live.pm onStream
  isolation folded into L3.
- #44 D6 merged (PR #50, squash 892e0bd): Podcasts → All podcasts A–Z by letter (24 rows = 238 podcasts); Home hides
  Categories by detected id. Review found 10 of 18 podcast categories unreachable (podcasts page shows only 8) →
  new D7 (#51).
- #4 L2 merged (PR #47, squash 3b5d5ee): program on air in Radio menus, Now Playing (poll/push per master player via
  the live kind hook) and Program info. Review + runtime APPROVE (3 stations played). Low findings folded into L3 (#8).
- #40 O7 merged (PR #46, squash 7004fc0): network-relative program paths (Hottest 100) kept in A–Z / By type after a
  page check. Review APPROVE; follow-ups filed as O8 (#48: Follow row for Hottest 100 episodes, outage resilience).
- #37 F5 merged (PR #45, squash 1adab5b): cardRef uses image alt text as a name only when it spells the card's slug
  (430 fixture cards diffed in review: only the intended 16 names change). check.sh passes on main.
- #22 D4 merged (PR #43, squash 990f709): News, Sport, Kids listen (full section), Audiobooks. Integrated with D2/M2
  by an integration agent; review fixes applied. **Top level now mirrors the ABC listen app.**
- #6 D2 merged (PR #42, squash e7e058d): top-level Podcasts + Popular now (integration agent merged main/M2 first).
- v0.2.0 install from GitHub verified on the testbed (PASS).
- #20 M2 merged (PR #35, squash 2911dbf): followed programs + My ABC listen (3 review rounds; stale-id safe).
- **v0.2.0 released** (8a13cb4 bump → workflow a5f85cc; asset sha1 64527ef7…). System verification PASS_WITH_NOTES:
  8/8 journeys, 85/85 stations, no regressions, no plugin errors.
- #34 F4 merged (PR #39, squash 834f446): lower-case nextData paths, 308 follow, cached-path fallback. Follow-ups F6 (#41).
- #13 D3 merged (PR #38, squash 137af39): Search + LMS global search (nested results per LMS 9.1.1).
- #18 O3 merged (PR #36, squash e427302): A–Z (708 programs) + By type + public programsByType. Orchestrator
  resolved the t/10 module-list conflict. Follow-up O7 (#40, Hottest 100 redirect paths).
- #2 L1 merged (PR #32, squash 5d262e2): all live stations (101 services, generated StationData.pm with committed
  generator `scripts/gen-station-data.py`), Radio menus, live resolver with bitrate. 85/85 playable swept.
- #5 D1 merged (PR #33, squash 4d9b90d): collection engine + top-level Home. Review APPROVE; runtime PASS.
  Follow-ups: D4 (#22) amendment (byPageSlug by path, checkOnAir, %FETCHERS, header fix, dying-callback test);
  new F5 (#37) cardRef alt-text naming.
- IC-2 (O1+O2 browse→play, run as "IC-1"): journeys pass in JSON-RPC, Default and Material (play, seek, add,
  favourite after restart, regression). DEFECT: non-ASCII episode paths fail (ABC 307 with only x-nextjs-redirect;
  resolver has no fallback from a cached path) → F4 #34 (bug, dispatched).
- #30 O6 merged (PR #31, squash 9207314): AAC catch-up seek (fill-only bitrate/duration via onStream).
- #16 O2 merged (PR #29, squash fd465d0): Programs → network → program → episodes, public builders, program-menu
  registry. Review APPROVE + fixes; runtime PASS (5 networks/5 programs, both skins). LMS menu rules recorded.
- #12 O1 merged (PR #28, squash 95690b7): episode playback (MP3/AAC renditions, expired/not-found/geo messages,
  favourites). Review APPROVE; runtime PASS with independent ids. AAC seek gap → new O6 (#30).
- #7 F3 merged (PR #27, squash a8d2488): API.pm data client + drift probe (10/10 live). Review fix: cardRef
  naming no longer uses image alt text when the card title matches the article slug. **Wave 1 complete.**
- **v0.1.0 released** (Release workflow; asset sha1 cacbeb99…; repo.xml commit ad751ff by Wilson Waters). Install
  from the GitHub repo.xml URL verified on the testbed (InstalledPlugins, 5 stations, play, settings, uninstall).
  #9 closed.
- #3 F2 merged (PR #25, squash 6791521): `abclisten://` protocol handler, kind registry; stations on stable URLs.
  Runtime PASS; review fixes (resolve eval scoped to kind code, rate-limited metadata warnings, contract notes).
- R1 merged (PR #24, squash fb010bc): packaging, repo.xml, release.yml (review fixes: no dropped version bumps).
  #9 stays open until v0.1.0 is cut (after F3 merges; CHANGELOG [0.1.0] to include F2/F3/M1).
- #11 M1 merged (PR #26, squash 9f041ce, first commit fully under the new authorship rule): settings page,
  homeState pref. Review: code APPROVE (blocker was a connector-appended footer, removed); runtime PASS (Default +
  Material, keyboard, axe on the select = 0 violations).
- #1 F1 merged (PR #21, squash 161ae6a): installable slice — ABC listen → Radio → 5 national stations play; weighted
  top-level hook API (`Util::topWeight`, optional `menuWeights()`); HTTP/Util; harness (833 assertions); check.sh; CI.
  Review APPROVE (10 deliberate breakages all caught); runtime verification PASS in Default + Material skins.

## Process notes (deviations from the orchestrator manual, adapted to this session)
- Plan approval for M tasks is folded into PR review: implementers put their plan at the top of the PR body.
- Streams were not held for explicit stakeholder sign-off (stakeholder asked for an end-to-end run); they are
  summarised to the stakeholder and can be redirected at any time.
- Screenshots/evidence live in the session scratchpad (`evidence/<ID>/`), cited by path in PRs, not committed.

## Last completions
- Research committed: `research/abc-listen-api.md` (+ 31 fixtures), `research/ecosystem.md`, `research/lms-plugin-guide.md`.
- Dev testbed committed (`dev/`, `RUNBOOK.md`): local LMS 9.1.1 + squeezelite "DevPlayer" running in the container.
- Brief updated with findings: no ABC audio requires login; Icecast (streamguys) live streams + MP3/AAC
  episodes play in the testbed; mediahub + /geo-001/ blocked from the container's US egress.

## Key findings
- No existing LMS plugin for ABC listen (official repo list checked). Closest: Radio Now Playing (metadata only),
  built-in Podcasts (RSS shows only), Music Assistant ABC provider (9 music stations, live only).
- Data: ABC website's internal `core-next/api` JSON + Next.js `_next/data/<buildId>` + Algolia public search key.
  ABC's official terminus API needs a private key (not usable).

- Streams + master plans committed (6 streams, 20 v1 tasks + 3 stretch). Material Skin 6.4.14 added to testbed.

## Next
- v0.2.0 = all live stations + Programs browse/play + Home + AAC seek: after F4 (#34) merges → system verification on
  main → version bump + CHANGELOG → release → install-from-GitHub check.
- Unblocked queue (≤5 agents at once): D4 (#22, News/Sport/Kids listen/Audiobooks), L2 (#4), F5 (#37), L5 (#14).
- As wave 2 PRs land: review + runtime-verify + merge. Then wave 3: L2, L5, O3, D1, D3, M2 (deps per streams.md).
- Integration checkpoint IC-1 after L1/O1/O2 (cluster integration agent); system verification after ~10 merges.

## Plan revisions
- 2026-10-19 — Stakeholder: podcasts prominent → D2 makes "Podcasts" top-level (#6 comment).
- 2026-10-19 — Stakeholder: top-level menu mirrors the ABC listen app (Home, Radio, Podcasts, News, Sport, Kids listen,
  Audiobooks, + Programs, Search, My ABC listen). F1 amended in flight (weighted top-level ordering via
  `Util::topWeight`, "Live radio" → "Radio"). Plan-revision + backlog-reconciliation agent to follow once the last
  spec batch is filed (new section-menus task for News/Sport/Kids listen/Audiobooks; Discover → Home).
- 2026-10-19 — Plan revision + backlog reconciliation done (sub-agent): section pages probed live (research §6.1, 7 new
  fixtures); contract 1 rewritten to F1's implemented hook API (`weight`, `topWeight`, `menuWeights`); Discover → Home,
  Live radio → Radio, Search ABC listen → Search; new **D4 #22** (News/Sport/Kids listen/Audiobooks section menus, M)
  and **D5 #23** (audiobook chapters from Algolia — ABC's web lists none; Should); Radio gets no section extras
  (`/listen/radio` holds only station collections); `cardRef` ids = `cardId` (curated teaser ids, some dynamic). All six
  master plans + `streams.md` changelogged; amendment comments on #2–#7, #9, #10, #12–#20; titles of #2, #5, #6, #13
  renamed. 22 v1 tasks; wave 4 = L3, L4, O4, D2, D4, D5. New stakeholder question: OPEN-QUESTIONS #5 (audiobooks).

## Active blockers
- None. Stakeholder decisions with defaults in OPEN-QUESTIONS §1 (login), §2 (authorship), §4 (live quality).
