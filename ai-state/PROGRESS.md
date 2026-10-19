# Project Progress

## Phase
Phase 3/4 — task specs being filed; execution started with F1 (2026-10-19).

## Issue map (task ID → GitHub issue)
- foundation: F1 #1 · F2 #3 · F3 #7
- live: L1 #2 · L2 #4 · L3 #8 · L4 #10 · L5 #14
- ondemand: O1 #12 · O2 #16 · O3 #18 · O4 #19
- discovery: D1 #5 · D2 #6 · D3 #13 · D4 #22 · D5 #23
- myabc: M1 #11 · M2 #20
- release: R1 #9 · R2 #15 · R3 #17

## Currently in flight
- #9 R1 → PR #24 (packaging, repo.xml, release.yml) — under review; v0.1.0 to be cut post-merge
- #3 F2 → PR #25 (abclisten:// protocol handler) — under review + runtime verification
- #11 M1 → PR #26 (settings page, homeState) — under review + runtime verification. Re-committed by the
  orchestrator as one clean commit on `feat/M1-settings-page` (the implementer's local branch had an
  old-author commit it was not permitted to rewrite).
- #7 F3 (API.pm) — implementation in progress
- Attribution scrub of issue/PR text in progress (stakeholder rule)

## Last completions
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
- Review + runtime-verify each wave-1 PR as it lands; merge; then wave 2 = L1, O1, O2 (after F2+F3); cut v0.1.0 after R1.

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
