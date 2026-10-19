# Project Progress

## Phase
Phase 3/4 — task specs being filed; execution started with F1 (2026-10-19).

## Issue map (task ID → GitHub issue)
- foundation: F1 #1 · F2 #3 · F3 #7
- live: L1 #2 · L2 #4 · L3 #8 · L4 #10 · L5 #14
- ondemand: O1 #12 · O2 #16 · O3 #18 · O4 #19 · O6 #30
- discovery: D1 #5 · D2 #6 · D3 #13 · D4 #22 · D5 #23
- myabc: M1 #11 · M2 #20
- release: R1 #9 · R2 #15 · R3 #17

## Currently in flight
- Implementation (worktrees, parallel): #2 L1 all live stations · #30 O6 AAC seek · #18 O3 A–Z/by type ·
  #5 D1 collection engine + Home · #13 D3 search + global search · #20 M2 followed programs
- IC-1 integration check: Programs → episode → play end to end (O1 + O2), plus Radio/Settings regression

## Interruptions
- 2026-10-19 ~12:30–17:23 UTC: account usage limit stopped all agents, then the session worker restarted (LMS +
  squeezelite stopped). 17:24: testbed restarted (`dev/start.sh`), stale O3 lock broken, link restored to main; all
  in-flight agents (L1, O3, D1, D3, M2, O6 review, IC-1) resumed from their saved state. Lesson: ≤5 concurrent agents.

## Last completions
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
