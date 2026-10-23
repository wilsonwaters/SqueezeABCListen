# Project Progress

## Phase
Phase 3/4 — task specs being filed; execution started with F1 (2026-10-19).

## Issue map (task ID → GitHub issue)
- foundation: F1 #1 · F2 #3 · F3 #7 · F4 #34 (bug) · F5 #37 (cardRef names) · F6 #41 (F4 follow-ups)
- live: L1 #2 · L2 #4 · L3 #8 · L4 #10 · L5 #14
- ondemand: O1 #12 · O2 #16 · O3 #18 · O4 #19 · O6 #30 · O7 #40 · O8 #48 (O7 follow-ups)
- discovery: D1 #5 · D2 #6 · D3 #13 · D4 #22 · D5 #23 · D6 #44 (podcast A–Z groups) · D7 #51 (all categories) · D8 #56 (D7 follow-ups)
- myabc: M1 #11 · M2 #20 · M3 #52 (settings/L5 follow-ups) · M4 #59 (Latest stale-id unfollow)
- release: R1 #9 · R2 #15 · R3 #17

## Currently in flight
- #4 L2 program on air — PR #47 in review + runtime check
- **v0.3.0 system verification** on ff1be94 (journeys J1–J12 incl. upgrade from v0.2.0). Hold O4/D5 merges until v0.3.0 is cut.
- #19 O4 episode extras — PR #57 APPROVED + review fixes verified (head e6b6886); merge after v0.3.0
- #59 M4 Latest episodes stable after unfollow — implementation
- #23 D5 audiobook chapters — PR #58 in review + runtime check (merge after v0.3.0 is cut)
- Queued (cap 3): F6, O8, M3, D8, then v0.3.0 (system verification → release), R2, R3

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

## Last completions
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
