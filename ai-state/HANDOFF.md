# Handoff — ABC listen for Lyrion Music Server, v1.1.0

_v1.0.0 written 2026-10-24 at the end of the orchestrated build; updated 2026-10-25 for v1.1.0. For the stakeholder
(Wilson Waters)._

## What's new in 1.1.0 (your feedback after accepting 1.0.0 on pi14)

| Change | PR |
|---|---|
| **High quality (HLS)** live option: 192 kbps AAC on music stations (64 kbps talk), plugin's own HLS reader, falls back to the standard stream; HLS-only services (Sport Rapid, RLWC Rapid, ABC Cricket, Kids listen time-zone versions) listed in this mode | #88 |
| **Short description headers** (Squeezer) with the full text under **About this program / episode** | #86 |
| **One continuous list** instead of "More…" / "More episodes…" (all clients page it themselves; long lists don't reload on Squeezebox/piCorePlayer); Play all / Add all up to 250; 7 s load deadline | #90, #96 |
| Default-skin artwork instead of grey placeholder icons | #97 |
| Fresher episode audio data, fewer repeated warnings and cache writes, no Algolia app id in logs | #85, #87, #93, #100 |
| Weekly ABC drift check (GitHub Actions, opens an `abc-drift` issue) | #92 |

Verified: every PR independently reviewed (U2 three rounds, L6 two) or orchestrator-reviewed; system verification
PASS_WITH_NOTES (J1–J12; 85/85 standard, HLS 96/100 with geo 403s, 1107 lists walked with no "More" rows, upgrade
from 1.0.0 keeps prefs/follows/favourites); release installed from the public `repo.xml` on the testbed (SHA1 OK,
v1.1.0, 10 top-level items, triple j 56 kbps, Double J HLS 192 kbps).

### Please check on pi14 (only your server can)
1. Update via Settings → Manage Plugins (1.0.0 → 1.1.0); settings, follows and favourites kept.
2. Settings → Advanced → ABC listen → Live stream quality → **High quality (HLS)**; play a music station for 30+
   minutes; LMS CPU in `top` while it plays (test machine: 4–5% of an x86 core).
3. ABC Cricket / Grandstand / Sport Rapid during a live event (blocked from the test machine).
4. Squeezer: a program's header is short; **About this program** shows the full text; RN Breakfast scrolls to the end
   without "More".
5. If you have one: a Squeezebox/piCorePlayer scrolling RN Breakfast past row 200 (simulated here only).

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
| Release notes | `CHANGELOG.md`; GitHub Releases v0.1.0, v0.2.0, v0.3.0, v1.0.0, **v1.1.0** |
| Releasing | `RELEASING.md` — bump `<version>` in `ABCListen/install.xml` on `main` (+ CHANGELOG) and the Release workflow does the rest. Zips are also committed to the orphan branch **`release-assets`** and `repo.xml` points there, because LMS 9.1.1 can't read GitHub's release-download redirect (a 9 KB header; #62). Never merge `release-assets`. |
| Self-test | `scripts/smoke.sh <LMS URL> <player MAC>` — 15 checks over JSON-RPC, ~1 min; plays audio on that player and restores its queue and your follows afterwards |
| Developer checks | `scripts/check.sh` (≈940 tests, XML, strings lint, package checks, shellcheck); CI runs it on every push/PR |
| ABC endpoint drift probe | `scripts/abc-endpoints-check.sh` (19 families); weekly in `.github/workflows/abc-drift.yml` → `abc-drift` issue |
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

- Live streams are 56 kbps by default; High quality (HLS) gives 192 kbps but uses more LMS CPU and runs 30–40 s
  behind live, so song titles change early (#91). ABC mediahub may only work from Australia (falls back
  automatically). HLS-only services are listed only in HLS mode; Cricket may be Australia-only.
- ABC lists only a program's newest 250 episodes; some expired catch-up episodes stay listed until played — #81.
- Australia-only audio (most audiobooks, some podcasts) plays only from an Australian connection.
- Program info, Recently played and Sport event times use the LMS server's time zone.
- An unfollowed program stays in Followed programs / Latest episodes for up to 30 minutes (keeps menus stable).
- Material's own search box doesn't list ABC listen (use ABC listen → Search).
- The plugin uses ABC's website data, not a public API; ABC changes can break menus until updated (drift probe #77).

## Backlog (open issues)

| Priority | Issue |
|---|---|
| Done in 1.1.0 | #76 #77 #78 #79 #80 #72 #83 #84 #89 #95 |
| P3 | #91 HLS song titles change 30–40 s early · #98 The J Files listed twice · #99 install script can't apply updates · #81 episodes beyond 250 / hide expired |
| Won't (proposed) | ABC-account (Gigya) sync of follows — fragile, needs credentials, little gain |

## Process notes

- Built with the project-orchestration methodology: research → brief → 6 streams → master plans → ~40 specified
  tasks (issues) → implementation agents in isolated worktrees → independent review + runtime verification →
  squash merges with clean messages → cluster/system verification → releases.
- The container testbed and its gotchas are documented in `ai-state/RUNBOOK.md`; the session was interrupted four
  times by usage limits/worker restarts (PROGRESS "Interruptions"), each recovered without losing work.
