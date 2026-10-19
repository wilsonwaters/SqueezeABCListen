# Master Plan — myabc

## Goal
Users personalise ABC listen in LMS **without any ABC account** (brief capability 4, OPEN-QUESTIONS #1):
1. **M1** — a plugin settings page (Settings → Plugins → ABC listen) with a **home state**, which live radio uses to put
   the user's local stations first and pick their time-zone versions; the page is section-owned so other streams
   (L5's live quality) add settings without conflicts.
2. **M2** — **follow** any program from its menu (or from song info while one of its episodes plays) and get **My ABC
   listen → Latest episodes** (newest episodes across followed programs) and **Followed programs**. Follows are stored
   locally in LMS prefs; nothing is sent to ABC.

ABC-account sync (Gigya login, cross-app follows/history) is stretch **M3**, out of v1 scope.

## Contracts used / provided
- Uses: hook API (`MyABC->init`, `MyABC->menuItems`), `OnDemand->programItem`/`episodeItem` and
  `registerProgramMenuProvider` (O2), `Programs->program`/`episodes` (O2), episode meta cache (program of the playing
  episode), `Slim::Web::Settings`, `Slim::Menu::TrackInfo`.
- Provides: prefs `homeState` (read by L1, L4) and `followed`; the settings page shell with owner sections;
  `Follow->isFollowed/follow/unfollow/list` (for future integrations).

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| M1 | Settings page: `Settings.pm` + `settings/basic.html` (owner sections) + `homeState` pref (init, validation) + `install.xml` `optionsURL` | S | F1 | planned |
| M2 | Followed programs: `Follow.pm` (pref-backed list), Follow/Unfollow in program menus (registry) and song info, **My ABC listen** → Latest episodes / Followed programs | M | O2 (soft O1, M1) | planned |
| _M3_ | _Stretch, out of v1: ABC account sign-in (Gigya) syncing follows/history; token kept outside prefs (0600 file), never the password_ | L | M2 | stretch |

### M1 — settings page + home state
- `ABCListen/Settings.pm`: `use base qw(Slim::Web::Settings)`; `name` → `PLUGIN_ABCLISTEN`; `page` →
  `plugins/ABCListen/settings/basic.html`; `prefs` → `(preferences('plugin.abclisten'), qw(homeState))` (append-only list
  for later owners). Instantiated from `MyABC->init` only `if (main::WEBUI)` (never "WEB_UI"; research ARCH gotcha 15).
- `ABCListen/HTML/EN/plugins/ABCListen/settings/basic.html`: `[% PROCESS settings/header.html %]` … `[% WRAPPER setting
  title="PLUGIN_ABCLISTEN_HOME_STATE" desc="PLUGIN_ABCLISTEN_HOME_STATE_DESC" %]<select name="pref_homeState"
  id="pref_homeState">` with "Not set" + the 8 states (L1's `PLUGIN_ABCLISTEN_STATE_*` tokens) … `[% PROCESS
  settings/footer.html %]`; reserved owner sections `<!-- === L5 === -->` (and further ones added by future owners).
- `MyABC->init`: `$prefs->init({homeState => ''})` and `setValidate` (value in the allowed list).
- `ABCListen/install.xml`: add `<optionsURL>plugins/ABCListen/settings/basic.html</optionsURL>` (the one sanctioned
  non-version edit).
- Accessibility (only custom UI in the plugin): the select has an associated label via the settings WRAPPER title and
  `id`; native control (keyboard operable); no new colour surfaces; axe-core run on the page — no critical/serious
  findings.
- **Tests** `t/50-settings.t` (Settings name/page/prefs via the `Slim::Web::Settings` stub; default ''; validation rejects
  unknown values; template file exists and its tokens are defined — also covered by `lint-strings.pl` once it scans
  templates).
- **Runtime**: Manage Plugins shows a Settings link for ABC listen; settings page screenshot (Default skin; Material via
  its plugin-settings view after P1); choosing WA and saving → `["pref","plugin.abclisten:homeState","?"]` = `WA`;
  invalid value via JSON-RPC is rejected; once L1 is merged, Local radio lists Western Australia first.

### M2 — followed programs
- **`Follow.pm`** (data): pref `followed` = list of `{path, id, title, image, network, followedAt}` (keyed by canonical
  program `path`, deduped, cap 200, oldest dropped with an INFO log); `follow(\%program)`, `unfollow($path)`,
  `isFollowed($path)`, `list()` (A–Z). `MyABC->init` does `$prefs->init({followed => []})`.
- **Program menus**: `OnDemand->registerProgramMenuProvider` adds **Follow this program** / **Unfollow this program**
  at the top of every program menu (Programs, A–Z, Home, Podcasts, sections, Search, schedule links — all via `programItem`). The item
  is an OPML action (`type => 'link'`, coderef url) that toggles and answers with one confirmation text item
  (`showBriefly`, `nextWindow => 'parent'`; MQ2).
- **Song info**: `Slim::Menu::TrackInfo` provider for `abclisten://episode/` tracks → Follow/Unfollow "<program>"
  (program path from the episode meta cache: canonical episode path minus its last two segments, MQ3; hidden when
  unknown).
- **`MyABC.pm`** `menuItems` → link **My ABC listen** (`weight => topWeight('myabc')`, the last top-level entry;
  `MyABC->menuWeights` declared) →
  - **Latest episodes**: for each followed program `Programs->program(path)` → `Programs->episodes(collectionId, 0, 5)`
    (≤ 4 concurrent, per-program failures skipped and logged), merged newest-first, max 50, built with
    `OnDemand->episodeItem` (name prefixed with the program title); cache 15 min.
  - **Followed programs (N)** → `programItem`s A–Z.
  - Empty state: one text item "Open any program and choose 'Follow this program'".
- **Tests** `t/51-follow.t` (follow/unfollow/dedupe/cap/A–Z; persistence through the prefs stub; path derivation from
  episode paths incl. `/triplej/programs/…` and `/kidslisten/programs/…`), `t/52-myabc-menu.t` (latest-episodes merge
  order, concurrency cap with the fake clock, one failing program, empty state, registry item label toggles, song-info
  item only for episode URLs).
- **Runtime**: Default + Material: Programs → … → The Science Show → **Follow this program** → My ABC listen → Followed
  programs (1) → episodes play; follow 2 more programs → Latest episodes in date order; unfollow from the program menu;
  follow from song info while an episode plays; follows persist across `dev/restart-lms.sh`; screenshots;
  `["pref","plugin.abclisten:followed","?"]` holds only program refs (no personal data, no credentials).

## Integration points
- **F1 hook API**: `MyABC` returns the last top-level item (weight 90, contract 1); `MyABC->init` creates the settings page (M1) and inits
  `homeState`/`followed`. myabc never edits `Plugin.pm`.
- **live**: L1/L4 read `homeState` (undef/'' ⇒ NSW behaviour); L5 adds the `liveQuality` section to `basic.html` and
  appends to the `Settings.pm` prefs list (rule 4 in `streams.md`).
- **ondemand**: M2 depends on O2's builders, `Programs` data API and `registerProgramMenuProvider`; it never edits
  `OnDemand.pm`. Programs reached from Home, Podcasts, the News/Sport/Kids listen/Audiobooks sections, Search (D1–D5)
  and schedules (L4) get Follow automatically; audiobook menus show D5's Chapters link before Follow (registration
  order Discover → MyABC).
- **foundation**: `install.xml` `optionsURL` (M1, sanctioned); `Slim::Web::Settings` stub exists from F1.
- **release**: README documents home state, follows (local, server-wide), and that no ABC login exists in v1.
- **Strings** (pre-seeded by F1): M1 `PLUGIN_ABCLISTEN_HOME_STATE`, `PLUGIN_ABCLISTEN_HOME_STATE_DESC`,
  `PLUGIN_ABCLISTEN_HOME_STATE_NONE`; M2 `PLUGIN_ABCLISTEN_MY_ABC`, `PLUGIN_ABCLISTEN_LATEST_EPISODES`,
  `PLUGIN_ABCLISTEN_FOLLOWED_PROGRAMS`, `PLUGIN_ABCLISTEN_FOLLOW`, `PLUGIN_ABCLISTEN_UNFOLLOW`,
  `PLUGIN_ABCLISTEN_FOLLOWED_OK`, `PLUGIN_ABCLISTEN_UNFOLLOWED_OK`, `PLUGIN_ABCLISTEN_NO_FOLLOWED_HELP`.

## Out of scope
- Any ABC account login or sync (stretch M3; OPEN-QUESTIONS #1); listening history / "continue listening".
- Per-player follows; import/export of follows; notifications of new episodes.
- Menu customisation, Radio-vs-My-Apps placement, configurable now-playing lines.
- Radio Favourites plugin handler, Material Home Extras ("Latest episodes" row), Don't Stop The Music ("next episode of
  this program") — cheap candidate follow-ups after v1.
- Managing follows from the settings page (menus and song info only).

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| MQ1 | Follows server-wide or per player? (brief ambiguity 6) | Server-wide (one list per LMS). | M2 |
| MQ2 | How should the Follow action item behave in Default vs Material (refresh vs confirmation)? | Confirmation text item with `showBriefly` + `nextWindow => 'parent'`; M2 verifies both skins and adjusts within OPML conventions. | M2 |
| MQ3 | Program of a playing episode for song-info Follow. | Canonical episode path minus last two segments; hidden when unknown. | M2 |
| MQ4 | Latest-episodes sizing. | 5 per program, 50 total, cache 15 min, ≤ 4 concurrent fetches. | M2 |
| MQ5 | Home state unset: prompt the user, or default silently? | Default silently to NSW behaviour; README explains the setting. | M1 |

## Changelog
- 2026-10-19 — Initial master plan (stream-planning sub-agent).
- 2026-10-19 — Stakeholder: top level mirrors the ABC listen app. My ABC listen uses `topWeight('myabc')` (last) and
  declares `menuWeights`; Follow reaches the new section menus (D4) and audiobook menus (D5) via the registry, no M2
  work. #20 amended.
- 2026-10-19 — M2 review rounds: follow block is always two rows (Follow + hint | ✓ Following + Unfollow) so stale
  LMS item ids never flip state; FOLLOW/UNFOLLOW tokens replaced by FOLLOW_NAMED/FOLLOWING_NAMED/FOLLOW_HINT (line 90's
  token list is superseded). Followed programs listed in follow order with 30-min tombstones for unfollowed programs
  (A–Z ordering dropped: it shifted row ids). Orchestrator decisions after review findings on PR #35.

