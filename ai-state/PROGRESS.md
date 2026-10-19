# Project Progress

## Phase
Phase 3/4 — task specs being filed; execution started with F1 (2026-10-19).

## Issue map (task ID → GitHub issue)
- foundation: F1 #1 · F2 #3 · F3 #7
- live: L1 #2 · L2 #4 · L3 #8 · L4 #10 · L5 #14
- ondemand: O1 #12 · O2 #16 · O3 #18 · O4 #19
- discovery: D1 #5 · D2 #6 · D3 #13 (D4 section menus: pending)
- myabc: M1 #11 · M2 #20
- release: R1 #9 · R2 #15 · R3 #17

## Currently in flight
- Wave 1 implementation agents (worktrees, in parallel): #3 F2 protocol handler (`feat/F2-protocol-handler`),
  #7 F3 API client (`feat/F3-api-client`), #9 R1 packaging/release (`feat/R1-packaging-release`), #11 M1 settings (`feat/M1-settings`)
- Plan-revision + backlog-reconciliation agent: app-style navigation, new D4 section menus, contract 1 update

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

## Active blockers
- None. Stakeholder decisions with defaults in OPEN-QUESTIONS §1 (login), §2 (authorship), §4 (live quality).
