# Master Plan — live

## Goal
From **ABC listen → Live radio** users find every ABC listen live station — national and music networks, sport, local
radio by state (home state first) and the time-zone versions ABC offers — each with its logo, and play it natively
(Icecast AAC via `abclisten://live/<SERVICE_ID>`, never HLS). While a station plays, LMS shows the **program on air**
(title, presenters, image) and, on music stations, the **current song** (artist, title, cover), plus song-info extras
(program synopsis, recently played). Each station opens a menu with **Listen live** and a **Today / Yesterday / 7-day
schedule** whose past programs lead to catch-up episodes. An optional setting chooses higher-quality live sources
where the user's network allows (mediahub, or HLS via the PlayHLS plugin) with automatic fallback.

Ceilings (research): StreamGuys Icecast is 56 kbps HE-AAC with no ICY titles, so all metadata comes from ABC APIs;
HLS-only services need PlayHLS (L5) or an own HLS handler (stretch L6); mediahub streams are untestable in the
container (stakeholder-verified on pi14).

## Contracts used / provided
- Uses: hook API (`Live->init`, `Live->menuItems`), PH kind registry (`live` kind, alternates, `failToken`,
  `onStream`/`onStop`), `API.pm` (`bff`, `text`, `music`, `imageUrl`), `Util` URL contract and date helpers, prefs
  `homeState` (M1) and `liveQuality` (own, L5).
- Provides: `Live->stationItem($client, $serviceId)`, `Stations->byPageSlug($slug)`, `Stations->get($serviceId)`
  (for D1 channel cards and L4); station records `{id, name, group, network, state, tz, slug, hlsSlug, mount,
  mediahub, logo, musicStation, hlsOnly, eventOnly, synopsis}`.

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| L1 | All live stations: `Stations.pm` catalogue + runtime `.pls` resolution (Icecast; mediahub alternate; HLS-only/off-air handling); Live radio menus (networks, sport, local by state, time-zone versions; home state first / home-state variants); `live` kind resolver | M (upper) | F2, F3 | planned |
| L2 | Program on air: `NowPlaying.pm` (`epgNowPlaying` now/next), on-air line2/description in menus, `LiveMetadata.pm` per-player poll/push engine (program mode), song-info "On air" | M | L1 | planned |
| L3 | Now-playing songs on music stations: `Tracks.pm` (music API now + recent plays), LiveMetadata track mode with program fallback and last-good, song-info "Recently played" | M | L2 | planned |
| L4 | Station submenu: `Schedule.pm` (BFF schedule per service/date/tz); station rows become link+play → Listen live, on air, Today, Yesterday, 5 earlier days; past programs link to catch-up via `OnDemand->programItem` | M | L2, O2 | planned |
| L5 | Higher-quality live setting `liveQuality` (`standard` / `mediahub` / `hls` when PlayHLS is enabled), ordered candidates with automatic Icecast fallback, settings section; HLS-only stations playable with PlayHLS | M | L1, M1 | planned |
| _L6_ | _Stretch, out of v1: own HLS protocol handler (fetch media playlist, demux MPEG-TS → ADTS AAC) for 221–246 kbps live, HLS-only stations, live pause/rewind_ | L | L1, L5 | stretch |

### L1 — all live stations
- **`Stations.pm`** (data, no menu code):
  - Static catalogue (Perl data in `Stations.pm` or `StationData.pm`) built from `research/abc-samples/derived-station-
    streams-{national,local}.json`, `derived-icecast-probe.tsv`, `derived-papi-services.tsv`, and fresh BFF captures of
    the national collection (12872264) and all 8 state collections (NSW 14126370, ACT 14126436, NT 14128062, VIC
    14128070, SA 14128508, TAS 14128536, QLD 14128542, WA 14128996; root 14123276). Logos are **wcms URLs with crop
    params** (from `cardImagePrepared.imgSrc`), never bare hashes (a bare hash with `impolicy` returns 1×1).
  - Groups: **networks** (RN, NEWS, TRIPLEJ, DOUBLEJ, UNEARTHED, H100, CLASSIC, CLASSIC2, JAZZ, COUNTRY, KIDSLISTEN,
    RA_ML); **sport** (GRANDSTAND, ITINERANT_THREE, ITINERANT_ONE/SPORT_WORLDCUP and ITINERANT_TWO/SPORT_AFLW deduped
    by stream, event-only SPORT_BBL/WBBL/TENNIS/GRANDSTAND_EXTRA/SPORT_AFL*, HLS-only ABCSPORTSYNC/ABC_AFL_RAPID/
    ITINERANT_FOUR); **local** (53 `LOCAL_*` by state; `/listen/live/katherine` maps to LOCAL_DARWIN); **variants**
    (RN_NT/QLD/SA/WA, TRIPLEJ_*, DOUBLEJ_*, CLASSIC_*, RA; KIDSLISTEN_* hidden — HLS-only, main Kids listen covers it).
  - `streamCandidates($id)` → ordered list: StreamGuys Icecast for `mount` (refreshed from
    `https://streaming.abc-cdn.net.au/audio/ice/<hlsSlug>.pls` `File1=`, cached 24 h, static mount on failure); then
    the page `aac` mediahub URL as an alternate (normalised: https, strip `;*.mp3`/`?source=web`). HLS-only with a
    mediahub URL (LOCAL_WIDEBAY) → mediahub only; HLS-only without one → unplayable (`PLUGIN_ABCLISTEN_LIVE_HLS_ONLY`).
  - Event-only services: one `epgNowPlaying/<ID>/now` check (cached 5 min) decides "on air"; off air →
    `PLUGIN_ABCLISTEN_LIVE_OFF_AIR` and hidden from menus.
  - Optional runtime enrichment: BFF national/state collections (cached 24 h, `stale_ok`) override titles/logos/order
    for known ids; unknown ids are logged at INFO and ignored (catalogue stays authoritative).
  - `byPageSlug`, `get`, `playable($id)` (L5 extends for `hls`).
- **`live` kind** (registered in `Live->init`, replaces F2's stub): `resolve` → `{url => first candidate, alternates =>
  rest, failToken => 'PLUGIN_ABCLISTEN_LIVE_FAILED'}`; `metadata` → `{title => station name, artist => 'ABC listen',
  cover => logo}` (L2 replaces with program data).
- **`Live.pm` menus** (`menuItems` → one link **Live radio**):
  - Networks (catalogue order) first, then links **Sport**, **Local radio**, **Time-zone versions**.
  - Local radio → 8 states (home state first, labelled "(your state)"; `homeState` '' behaves as NSW) → stations
    sorted with the capital-city station first, then A–Z.
  - Home-state variants: when `homeState` ∈ {SA, QLD, NT, WA}, network items for RN/triple j/Double J/Classic use that
    state's variant id (name unchanged, description "<City> time"); Time-zone versions always lists every variant.
  - Station item (`_stationItem`): `name` = station name, `type => 'audio'`, `on_select => 'play'`, `url`/
    `favorites_url` = `abclisten://live/<ID>`, `image`/`favorites_icon` = logo (via `API::imageUrl` at 300 px),
    `favorites_title`, `description` = PAPI `mini_synopsis` where known.
  - Menu answers within ~3 s on every path (catalogue is local; enrichment only from cache).
- **Tests** `t/20-stations.t` (catalogue integrity vs fixtures: every BFF national/state card and every listed variant has
  an entry; unique ids; every non-HLS-only entry has a mount; logos keep crop params; `.pls` parsing incl. CRLF, missing
  `File1`, 404; candidate ordering, mediahub normalisation, never `.m3u8`; event-only on/off air), `t/21-live-menu.t`
  (group shapes and exact item keys; home-state ordering and variant substitution for each state; hidden HLS-only/off-air
  entries; exactly-one callback).
- **Runtime**: Default + Material screenshots of Live radio, Local radio → Queensland, Time-zone versions (logos visible);
  `menu:1` JSON-RPC shapes; **sweep script** (agent scratchpad, not committed) plays every listed station through
  `["playlist","play","abclisten://live/<ID>"]` for ≥ 5 s and records `mode`/`time` → all Icecast stations PASS; Wide Bay
  and off-air/HLS-only behave as specified; set `homeState` WA via JSON-RPC → WA first and triple j resolves to
  TRIPLEJ_PERTH; favourite of a local station replays after restart. **pi14**: Wide Bay (mediahub) plays.

### L2 — program on air
- **`NowPlaying.pm`**: `programNow($id, $cb)` → `bff('epgNowPlaying/<ID>/now', {imageRatio => '1x1'})` → `{title, start,
  end (epoch), presenters (joined `names.full`), image (`preparedImage` srcSet ~580), programPath (`programLink`),
  serviceId}`; `programNext` lazily; cache until `end` (clamp 60 s–15 min); negative cache 60 s; `{}`/no data → undef
  (off air or event service); coalesced; last-good kept for menus.
- **Menus** (`_stationItem` text, owned from now on): line2 "On air: <program> · <presenters>" (Material / `menu:1`), and
  `description` "<program> (<6:00am–9:00am>) — <presenters>" for the Default skin detail view. Fetch for the stations
  in the list being built with a 3 s deadline and ≤ 6 concurrent requests; after the deadline use whatever is cached.
- **`LiveMetadata.pm`** (port REF engine `RTRFM/LiveMetadata.pm`): the `live` kind's `metadata` returns program mode
  `{title => program, artist => presenters || station, album => station name, cover => program image || logo}`;
  `onStream` starts one poll per **master** player (sync groups) for the playing service, next poll at program `end` +
  30 s (clamp 60–900 s, 30 s after errors); `onStop` / URL change kills timers; push sequence
  `setCurrentTitle($url,$title)` (no client) → `$song->pluginData(wmaMeta => …)` → `currentPlaylistUpdateTime` →
  `notifyFromArray($master, ['newmetadata'])`; never polls services nobody plays; never sets `$song->duration`.
- **Song info**: `Slim::Menu::TrackInfo` provider (registered in `Live->init`) for `abclisten://live/` tracks: "On air"
  program title, time slot, presenters, synopsis (from `/next` too: "Next: <program> <time>").
- **Tests** `t/22-nowplaying.t` (parse RN and TRIPLEJ_PERTH fixtures; empty/off-air; TTL clamp; coalescing; last-good),
  `t/23-live-metadata.t` (fake clock: first metadata call triggers fetch; program end re-fetch + `newmetadata`; error
  back-off; stop/URL change stops polling; sync-group master; no leaked timers).
- **Runtime**: play RN → `status` `current_title`/`playlist_loop[0].title` = current program (matches abc.net.au) and
  `artwork_url` = program image; Default + Material Now Playing screenshots; Live radio list via `menu:1` shows on-air
  lines; song info shows synopsis; clean `server.log`. Program-change transition covered by unit tests.

### L3 — now-playing songs on music stations
- **`Tracks.pm`**: music-API station map (TRIPLEJ→`triplej`, DOUBLEJ→`doublej`, UNEARTHED→`unearthed`, JAZZ→`jazz`,
  COUNTRY→`country`, CLASSIC→`classic`, CLASSIC2→`classic2`, H100→`h100`, KIDSLISTEN→`kidslisten`; variants per LQ5);
  `now($id, $cb)` → `music('plays/<station>/now.json')` → `{title, artist (prefer `summary.artist`, else primary
  artists — classical lists composers too), album (release title [+ year]), cover (release artwork ~580 px, else
  recording artwork), playedTime, duration, nextUpdated}`; empty `now` between songs → undef; HTTP 400 (no music) →
  undef + long negative cache; `recent($id, $n)` → `plays/search.json?station=…&order=desc&limit=10`.
- **LiveMetadata track mode** (extends L2): for services with a music station, poll at `next_updated` (clamp 20–120 s);
  while a song is current (`playedTime + duration > now`) metadata = `{title => song, artist => artist, album =>
  "<program> · <station>" (or release), cover => song cover || program image}`; otherwise program mode; keep the last
  good song on one transient empty/error, then fall back to program mode; single shared upstream fetch per station.
- **Song info**: "Recently played" (10 rows "9:41pm · Artist – Title") for music stations, beside L2's "On air".
- **RNP coexistence**: verify (if Radio Now Playing is installed in the testbed) that our `abclisten://` metadata wins and
  there is no double push; document either way for R2.
- **Tests** `t/24-tracks.t` (now/empty/400/classical artists; recent list), `t/25-live-tracks-metadata.t` (mode switch
  song ↔ program; `next_updated` scheduling; last-good on one empty; talk stations never call the music API).
- **Runtime**: play triple j → `status` title/artist match `music.abcradio.net.au/api/v1/plays/triplej/now.json` within one
  poll and change at the next song (observe ≥ 2 songs); `artwork_url` = cover; RN stays in program mode; song info shows
  recently played; Default + Material Now Playing screenshots.

### L4 — station submenu, schedule and catch-up entry points
- **`Schedule.pm`**: `day($id, $date, $cb)` → `bff('schedule', {service => <ID>, date => YYYY-MM-DD, tz => <station tz>,
  ratio => '1x1'})` → items `{start, end (epoch from rawStartTime/rawEndTime), title, synopsis, image, presenters,
  programPath (`sitePath(url)`), onNow}`; cache today 10 min, past days 24 h; station-local "today" per LQ3.
- **Station rows** (`_stationItem`, owned from now on): `type => 'link'`, `play => abclisten://live/<ID>` (no
  `on_select`), `url` → `_stationMenu`; favourites keep the live URL (`favorites_url`, `favorites_type audio`).
- **`_stationMenu`**: "Listen live" (`type audio`, `on_select play`); on-air text (from L2); **Today**, **Yesterday**, then
  5 earlier days by date ("Sat 17 Oct"). Day list rows: name "6:00am · <program>" (time in name for the Default skin),
  line2 presenters, image, description = synopsis; rows that have started link to the program via
  `OnDemand->programItem($client, {title, path => programPath, image})` (catch-up = that program's episodes); future
  rows are text; current row marked "(on air)".
- **Tests** `t/26-schedule.t` (RN day fixture; day boundaries across AEST/AEDT/ACST/AWST with a UTC server clock; empty
  day; old-style program URLs), `t/27-station-menu.t` (station row is link+play; submenu shape; programItem called with
  the right path; future rows not links).
- **Runtime**: Default + Material: Live radio → Radio National → Today lists the schedule; open a past program →
  episodes (O2) → play one (O1); the station row's play control still plays live; a station favourite saved before L4
  still plays; Yesterday for a WA local station uses Perth dates. **pi14**: AU-only schedule differences (if any).

### L5 — higher-quality live setting
- Pref `liveQuality` (`standard` default | `mediahub` | `hls`), initialised in `Live->init`; section `<!-- === L5 === -->`
  in M1's `basic.html` (select + explanation: standard = 56 kbps, works everywhere; mediahub = ABC's own AAC streams,
  may be Australia-only; HLS = up to ~246 kbps, needs the PlayHLS plugin and ffmpeg — option disabled with a note when
  PlayHLS isn't enabled); `Settings.pm` prefs list append.
- `Stations->streamCandidates` honours the pref: `mediahub` → mediahub first, Icecast alternate; `hls` (only when
  `Slim::Utils::PluginManager->isEnabled('Plugins::PlayHLS::Plugin')`) → HLS master URL first marked `hls => 1`, then
  Icecast/mediahub alternates. HLS-only stations (Sport Rapid, RLWC Rapid, Cricket, Wide Bay) become listed and
  playable only in `hls` mode (`playable` extended). Fallback is automatic within a play (F2 alternates) and logged once
  at INFO.
- **Tests** `t/28-stream-quality.t` (candidate order per pref; PlayHLS absent ⇒ `hls` behaves as `standard`; HLS-only
  listing rules; `.m3u8` only ever with `hls => 1`).
- **Runtime**: settings page screenshot with the new section; `mediahub` in the container → 403 → falls back to Icecast
  and plays (`server.log` shows one INFO); `hls` option disabled without PlayHLS; if P3 (PlayHLS + ffmpeg) is installed,
  triple j plays via HLS with a higher reported bitrate. **pi14**: `mediahub` plays (bitrate noted); `hls` with PlayHLS
  if the stakeholder installs it; Cricket during a match.

## Integration points
- **F1/F2**: `Live->init` registers the `live` kind (replacing F2's stub), TrackInfo provider, and prefs init;
  `Live->menuItems` is the first top-level hook. Live never edits `Plugin.pm` or `ProtocolHandler.pm`.
- **F3**: `API::bff` (collections, epgNowPlaying, schedule), `API::text` (`.pls`), `API::music`, `API::imageUrl`.
- **myabc**: reads `homeState` (M1); L5 adds its section to M1's settings page.
- **ondemand**: L4 links schedule rows through `OnDemand->programItem` (O2 contract); live never touches episode URLs.
- **discovery**: D1 maps `coremedia://channel` cards via `Stations->byPageSlug` + `Live->stationItem`.
- **release**: R2's `smoke.sh` plays a national and a local station and checks program/song metadata; README documents
  56 kbps, HLS-only stations, mediahub, PlayHLS, RNP coexistence, `faad` on old players.
- **Strings** (pre-seeded by F1): L1 `PLUGIN_ABCLISTEN_LIVE_RADIO`, `PLUGIN_ABCLISTEN_SPORT`,
  `PLUGIN_ABCLISTEN_LOCAL_RADIO`, `PLUGIN_ABCLISTEN_TIMEZONE_VERSIONS`, `PLUGIN_ABCLISTEN_STATE_{ACT,NSW,NT,QLD,SA,TAS,VIC,WA}`,
  `PLUGIN_ABCLISTEN_YOUR_STATE`, `PLUGIN_ABCLISTEN_CITY_TIME`, `PLUGIN_ABCLISTEN_LIVE_FAILED`,
  `PLUGIN_ABCLISTEN_LIVE_HLS_ONLY`, `PLUGIN_ABCLISTEN_LIVE_OFF_AIR`; L2 `PLUGIN_ABCLISTEN_ON_AIR`,
  `PLUGIN_ABCLISTEN_NEXT`, `PLUGIN_ABCLISTEN_PROGRAM_INFO`; L3 `PLUGIN_ABCLISTEN_RECENTLY_PLAYED`,
  `PLUGIN_ABCLISTEN_NO_RECENT_TRACKS`; L4 `PLUGIN_ABCLISTEN_LISTEN_LIVE`, `PLUGIN_ABCLISTEN_TODAY`,
  `PLUGIN_ABCLISTEN_YESTERDAY`, `PLUGIN_ABCLISTEN_NO_SCHEDULE`, `PLUGIN_ABCLISTEN_ON_AIR_MARK`; L5
  `PLUGIN_ABCLISTEN_LIVE_QUALITY`, `PLUGIN_ABCLISTEN_LIVE_QUALITY_DESC`, `PLUGIN_ABCLISTEN_LIVE_QUALITY_STANDARD`,
  `PLUGIN_ABCLISTEN_LIVE_QUALITY_MEDIAHUB`, `PLUGIN_ABCLISTEN_LIVE_QUALITY_HLS`, `PLUGIN_ABCLISTEN_LIVE_QUALITY_NO_PLAYHLS`.

## Out of scope
- HLS playback by our own code (stretch L6); live pause/rewind; HDS/legacy `.pls` families.
- Configurable now-playing lines/images (BBC-style) and polling throttle prefs — candidate follow-ups.
- Exact schedule-slot → episode matching ("play this broadcast"); future-day schedules; 30-day schedule.
- Radio Favourites plugin handler, Material Home Extras "Live now" row, Don't Stop The Music — candidate follow-ups.
- Hidden PAPI services (`RN_vic`, `RN_tas`, `firstrun`, `dig`) and Kids listen time-zone variants.
- Spotify/Spotty links for the current song.

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| LQ1 | List HLS-only/event-only services? (brief ambiguity 1) | Event-only: only while ABC reports a stream. HLS-only: hidden except Wide Bay (mediahub); all shown in L5 `hls` mode. Kids variants hidden. | L1, L5 |
| LQ2 | Should home state silently switch network streams to the state's time-zone version? | Yes for RN/triple j/Double J/Classic when `homeState` ∈ SA/QLD/NT/WA (description says "<City> time"); all variants remain under Time-zone versions. | L1 |
| LQ3 | Station-local "today" without `DateTime::TimeZone` (not guaranteed in LMS). | `POSIX::tzset` with a localised `$ENV{TZ}` = station tz, falling back to a fixed table (Sydney/Melbourne/Hobart/Canberra +10/+11 DST, Brisbane +10, Adelaide +9:30/+10:30, Darwin +9:30, Perth +8) with AU DST rule (first Sun Oct – first Sun Apr). | L4 |
| LQ4 | Live metadata fields (program mode / track mode). | As in L2/L3. | L2, L3 (non-blocking) |
| LQ5 | Song data for time-zone variants (music API is per network, time-shifted variants unknown). | Try BFF `musicNowPlaying/<VARIANT_ID>`; if empty, variants use program mode only. | L3 |
| LQ6 | Schedule rows with old-style program URLs (`/radionational/programs/<slug>/`). | `API::nextData` follows `__N_REDIRECT`; if the program page still fails, the row is text. | L4 |
| LQ7 | Old Squeezebox players without AAC decode need LMS `faad` transcoding — acceptable? | Yes; README troubleshooting (R2). | L1 (non-blocking) |
| LQ8 | Does Radio Now Playing (installed by many users) double-push metadata for our streams? | Our `abclisten://` PH metadata should win; L3 verifies if RNP can be installed in the testbed, else documents. | L3 |

## Changelog
- 2026-10-19 — Initial master plan (stream-planning sub-agent).
