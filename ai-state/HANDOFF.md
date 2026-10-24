# Handoff — ABC listen for Lyrion Music Server, v1.0.0

_Written 2026-10-24 at the end of the orchestrated build. For the stakeholder (Wilson Waters)._

## What was built

An unofficial **ABC listen** plugin for Lyrion Music Server (LMS 8.3+, tested on 9.1.1), in Perl, in
`ABCListen/`. No ABC account or login is needed anywhere. The top level mirrors the ABC listen app:

| Menu | What it does |
|---|---|
| **Home** | ABC listen's Featured items and home collections (Popular now, Popular in sport, …) |
| **Radio** | Every live station: national networks, music stations, local radio by state (your state first), sport, time-zone versions. A station opens **Listen live**, what's **On air**, and **Today / Yesterday / 5 earlier days** of schedule; past programs open their catch-up episodes. The row's play button still plays live. |
| **Podcasts** | New & Noteworthy, Most Popular, Award Winning, **Browse by category** (all 18), **All podcasts A–Z** |
| **News / Sport / Kids listen / Audiobooks** | ABC's section pages with their live stations, programs, collections; Sport's Live & Upcoming Events; Kids listen in full (live, Featured, programs, Kids & Families podcasts, Books for Kids, News Time); every audiobook has **Chapters (N)** in reading order |
| **Programs** | By network, All programs A–Z (736 programs), By type |
| **Search** | Programs and episodes from ABC's search index; also in LMS's global search |
| **My ABC listen** | Follow programs (stored in LMS only), Latest episodes, Followed programs |

Now Playing: the program on air and presenters for talk stations; **song, artist and cover** on the nine
music stations, with **Recently played**; episodes with notes, **segments** (each playable), **tracklists**,
presenters and **More from <program>**. Settings → Advanced → ABC listen: **Home state** and **Live
stream quality** (Standard 56 kbps, or ABC mediahub with automatic fallback).

## Where things are

| | |
|---|---|
| Install URL (LMS → Settings → Manage Plugins → Additional repositories) | `https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml` |
| User docs | `README.md` (install, usage tour with 9 screenshots, limitations, troubleshooting, privacy, self-test) |
| Release notes | `CHANGELOG.md`; GitHub Releases v0.1.0, v0.2.0, v0.3.0, **v1.0.0** |
| Releasing | `RELEASING.md` — bump `<version>` in `ABCListen/install.xml` on `main` (+ CHANGELOG) and the Release workflow does the rest. Zips are also committed to the orphan branch **`release-assets`** and `repo.xml` points there, because LMS 9.1.1 can't read GitHub's release-download redirect (a 9 KB header; #62). Never merge `release-assets`. |
| Self-test | `scripts/smoke.sh <LMS URL> <player MAC>` — 15 checks over JSON-RPC, ~1 min; plays audio on that player and restores its queue and your follows afterwards |
| Developer checks | `scripts/check.sh` (≈810 tests, XML, strings lint, package checks, shellcheck); CI runs it on every push/PR |
| ABC endpoint drift probe | `scripts/abc-endpoints-check.sh` (extend per #77) |
| Getting into the official LMS repository | `docs/official-repository.md` (not submitted — your call) |
| Planning and history | `ai-state/` — brief, streams + master plans, PROGRESS, OPEN-QUESTIONS, RUNBOOK (container testbed), research |

## How it was verified

- Every feature PR had an independent review (code + deliberate breakages + a runtime check on the container
  testbed: LMS 9.1.1 + squeezelite, Default and Material skins). Small fix/test/release PRs (#61, #63, #64, #71,
  #73, #74) were reviewed by the orchestrator (diff read + `check.sh` on the merged tree). GitHub shows no formal
  "reviews" because one account owns the repo.
- v0.3.0 system verification: 12/12 journeys, 85/85 stations, upgrade from v0.2.0.
- v1.0.0 (#17): installed from the public `repo.xml` on a **clean LMS profile** → smoke 15/15; prefs file holds only
  `homeState`, `liveQuality`, `followed` (+ LMS bookkeeping), no credentials; brief criteria 1–6 PASS in Default,
  Material and JSON-RPC (evidence: #17 comment 6380815256). Final review against the brief: delivered.

## Actions for you

1. **Run the pi14 acceptance checklist** — #17 comment 6380828931. It covers what the build container couldn't:
   install/upgrade from 0.3.0 on your server, ABC mediahub (and its bitrate) from Australia, Australia-only audio
   (audiobooks, Bluey Listen Along, *You're Dead To Me*), local schedule times, a hardware Squeezebox (AAC needs
   LMS's `faad`), and whether Material shows the "only available in Australia" message. Report ✓/✗ per item on
   #17; I turn any ✗ into a 1.0.1.
2. **Decide** (`ai-state/OPEN-QUESTIONS.md`):
   - §6 — ABC Classic shows the composer as ABC does ("Liszt, Franz"); want "Composer – Performer" instead?
   - §1 (no ABC login) and §5 (list audiobooks, play where ABC allows) — confirm the defaults.
   - Official LMS repository submission (guide in `docs/official-repository.md`) — after acceptance.
3. **Optional housekeeping**: delete the merged feature branches on GitHub. Two of them
   (`feat/F1-vertical-slice`, `feat/F2-protocol-handler`) still hold commits from before your authorship
   instruction with the old author identity and trailers; `main` has one commit with the old identity after the
   instruction (`71e77b6`, disclosed in OPEN-QUESTIONS; you chose not to rewrite history). Every other commit, PR, issue, release and file is authored
   as Wilson Waters with no attribution.

## Known limitations (also in README)

- Live streams are 56 kbps by default; ABC mediahub may only work from Australia (falls back automatically). No
  HLS: the PlayHLS plugin can't play `abclisten://` stations, so HLS-only services (Sport Rapid, RLWC Rapid, ABC
  Cricket, Kids listen time-zone versions) aren't listed — #80.
- ABC lists only a program's newest 250 episodes; some expired catch-up episodes stay listed until played — #81.
- Australia-only audio (most audiobooks, some podcasts) plays only from an Australian connection.
- Program info, Recently played and Sport event times use the LMS server's time zone.
- An unfollowed program stays in Followed programs / Latest episodes for up to 30 minutes (keeps menus stable).
- Material's own search box doesn't list ABC listen (use ABC listen → Search).
- The plugin uses ABC's website data, not a public API; ABC changes can break menus until updated (drift probe #77).

## Backlog (open issues)

| Priority | Issue |
|---|---|
| P1 (1.0.1) | #75 release tooling "403" match (in progress) · #76 `seenAt` from fetch time · #77 drift probe coverage + weekly run · #79 docs touch-ups · any pi14 ✗ |
| P2 | #80 HLS / higher-quality live (before the cricket season) · #78 log noise and cache writes |
| P3 | #81 episodes beyond 250 / hide expired · #72 Default-skin placeholder icons |
| Won't (proposed) | ABC-account (Gigya) sync of follows — fragile, needs credentials, little gain |

## Process notes

- Built with the project-orchestration methodology: research → brief → 6 streams → master plans → ~40 specified
  tasks (issues) → implementation agents in isolated worktrees → independent review + runtime verification →
  squash merges with clean messages → cluster/system verification → releases.
- The container testbed and its gotchas are documented in `ai-state/RUNBOOK.md`; the session was interrupted four
  times by usage limits/worker restarts (PROGRESS "Interruptions"), each recovered without losing work.
