# Open Questions

Unresolved product/technical decisions and what they block. Resolved items move to the bottom with the answer.

## Open

1. **ABC account login — worth building?** Research: ABC accounts use Gigya (SAP Customer Data Cloud); no audio
   is gated behind login; login only syncs followed programs / listening history / favourite stations across
   ABC apps. **Default decision (pending stakeholder confirmation):** no ABC login in v1 — offer local,
   per-LMS "followed programs" instead, which needs no credentials. ABC-account sync would mean driving an
   undocumented Gigya login flow (fragile, credential handling) for little gain. The stakeholder never needs
   to share credentials with the agents.
   _Blocks: nothing in v1._
2. _(resolved — see Resolved: commit authorship)_
3. **mediahubaustralia live streams unreachable from the dev container.** `live-radio0N.mediahubaustralia.com`
   returns a Cloudflare 403 to this container's (non-Australian datacenter) egress. ABC's `.pls` files also
   point at `abc.streamguys1.com` HE-AAC Icecast streams, which DO play in the container testbed (verified),
   as do ABC JSON APIs and on-demand MP3s. Whichever live URL family the plugin uses, the stakeholder
   confirms live playback on pi14 (in Australia) at acceptance.
   _Blocks: nothing (streamguys URLs give a container-verifiable live path)._

4. **Live stream quality.** The only live streams LMS can play natively that are reachable from the container
   are ABC's Icecast streams (`abc.streamguys1.com`, HE-AAC 56 kbps). ABC's HLS streams carry 221–246 kbps AAC
   for music stations but LMS 9.x can't play HLS without the third-party PlayHLS plugin. `mediahubaustralia.com`
   streams may be higher quality but are untestable here. **Default decision:** v1 plays the Icecast streams;
   higher-quality live options (HLS via PlayHLS when installed, mediahub when reachable) are planned as an
   optional setting in the live stream and confirmed by the stakeholder on pi14.
   **Update 2026-10-19 (L5, PR #49):** PlayHLS 1.01 cannot play `abclisten://` stations: it has no protocol handler
   and hands ffmpeg `$FILE$`, which F2 rewrites back to `abclisten://…` (verified on the testbed). Orchestrator
   decision: L5 ships **Standard (56 kbps Icecast, default)** and **ABC mediahub (may be Australia-only; automatic
   Icecast fallback)**; the HLS option is not shown until L6 (stretch: own HLS handler, or a small F2 change so a
   convert rule gets the real URL). Stakeholder: confirm mediahub plays on pi14 and note its bitrate.
   _Blocks: nothing in v1._

5. **Audiobooks — list and play them?** ABC's website plays no audiobooks: book pages are `webDistributionRestricted`
   and its FAQ says audiobooks are Australia-only and streamed only in the ABC listen app (Australian app stores). The
   chapters are in ABC's public search index with `/geo-001/` MP3 URLs that the CDN serves only to Australian IPs
   (`research/abc-listen-api.md` §6.1). **Default decision (pending stakeholder confirmation):** list audiobooks under
   the Audiobooks section (D4 #22) and play chapters where the CDN allows, i.e. on pi14 in Australia (D5 #23); outside
   Australia the plugin shows "only available in Australia". Alternative: list them with an Australia-only note but
   never play them (drop D5).
   _Blocks: nothing (D5 is Should; dropping it only removes chapter lists)._

6. **Classical music: which artist does Now Playing show?** ABC's music API gives `summary.artist` = the composer in
   "Last, First" form (e.g. "Liszt, Franz"); performers ("Yundi Li (piano)") are separate. **Default (L3, PR #54):**
   composer only, as ABC's own summary does. Alternative: "Composer – Performer" (one-line change in
   `Tracks::_artist`). Asked the stakeholder 2026-10-20.
   _Blocks: nothing._

## Resolved

- **ABC account login** (§1; stakeholder 2026-10-25 after pi14 testing): **no login** — "No login by default works well".
  Follows stay local to LMS. ABC-account (Gigya) sync is not planned.
- **Classical music artist** (§6; stakeholder 2026-10-25): show the artist **as ABC does itself** (the composer, "Last,
  First"). No change.
- **Official LMS repository** (RQ4; stakeholder 2026-10-25): the stakeholder will submit it (guide in
  `docs/official-repository.md`) and delete the old remote feature branches.

- **Commit authorship / attribution** (2026-10-19, stakeholder instruction): **never attribute any AI tool or vendor**
  anywhere — commits, PRs, issues, comments, docs or code. All commits are authored and committed as
  `Wilson Waters <wilsonwaters@users.noreply.github.com>` (including the release workflow's `repo.xml` commit); no
  attribution trailers or generated-by footers. PRs are squash-merged with an explicit clean commit message.
  Commits made before this instruction carry the old author/trailers; the stakeholder chose to **leave existing
  history as is** (no force-push).
  **Mechanics for every agent:** the GitHub MCP connector appends a generated-by footer to anything it *creates*
  (PR bodies, issues, comments) but not on *updates* — so every create must be followed by a re-read and an edit that
  removes the footer. Squash-merge with an explicit clean commit message (GitHub then adds no co-author lines).
  Feature-branch commits that can't be rewritten (permission-denied) are handled by re-committing the tree as one
  clean commit on a fresh branch — never by rewriting pushed history.
  **Identity persistence:** a session-worker restart reset the global git identity to the tool default, and one
  orchestrator commit (71e77b6, progress log) went to `main` with the wrong author before it was noticed. The identity
  is now also set in each repo's own `.git/config` (survives global resets); verify with `git var GIT_AUTHOR_IDENT`
  after any restart.

- **Top-level Programs label** (2026-10-19, orchestrator decision): the entry is labelled **"Programs"** (its submenu
  offers By network / A–Z / By type). F1 seeded the text "Programs (A–Z)"; O2 (#16) changes that token's EN text to
  "Programs" rather than adding a new token.

_(none yet)_
