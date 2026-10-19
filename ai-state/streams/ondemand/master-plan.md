# Master Plan — ondemand

## Goal
From **ABC listen → Programs** users browse ABC listen programs **by network**, **A–Z** and **by type**, open a program
(artwork, description, presenters, network) and its episodes (artwork, synopsis, broadcast date, duration — newest
first, up to ABC's 250), and play any available episode. Playback goes through `abclisten://episode/<id>`, resolved at
play time from ABC's episode data with the right rendition for its availability window, so episodes are seekable,
favouritable and show title/program/artwork/duration in Now Playing. Unavailable audio (expired catch-up AAC,
`webDistributionRestricted`, Australia-only `/geo-001/` outside Australia) gives a clear message instead of silence.
Extras: playable segments and tracklists. The stream also supplies the **program/episode item builders** that live
(L4), discovery (D1–D3) and myabc (M2) use, so every route into an episode behaves the same.

## Contracts used / provided
- Uses: hook API (`OnDemand->init`, `OnDemand->menuItems`), PH kind registry (`episode` kind, `failToken`), `API.pm`
  (`nextData`, `bff`, `algolia`, `cardRef`, `richText`, `imageUrl`, `sitePath`), `Util` URL contract, episode meta
  cache, date/duration helpers.
- Provides (O2, `streams.md` contract 6): `programItem($client, \%program)`, `episodeItem($client, \%episode)`,
  `registerProgramMenuProvider($sub)`; `Programs->program($path, $cb)` (program detail) for M2/L4.
- **`Episode.pm` registration**: F1 creates a stub `Episode.pm` whose `init` `OnDemand->init` already calls; O1 fills
  `Episode.pm` only and never edits `OnDemand.pm` (so O1 and O2 run in parallel without conflicts).

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| O1 | Episode playback engine: `Episode.pm` resolver (meta cache / Next data / Algolia → renditions), MP3-vs-AAC choice by availability windows, restricted/expired/geo/not-found errors, `episode` kind metadata; seekable; favourites replay | M (upper; highest technical risk) | F2, F3 | planned |
| O2 | Programs → By network → program → episodes: `Programs.pm` (program aggregation collections, program Next data, `episodesWithSegments` paging) + `OnDemand.pm` menus, public builders, program-menu registry, episode meta-cache writes; empty/error states | M (upper) | F3 (integrates with O1 at IC-2) | planned |
| O3 | All programs A–Z and by type: `ProgramIndex.pm` (Algolia program list, 24 h cache, last-good, fallback to network lists) + Programs root entries | M | O2 | planned |
| O4 | Episode extras: playable segments, tracklist (lazy episode Next data), "More from <program>", presenters, episode song info during playback | M | O1, O2 | planned |
| _O5_ | _Stretch: episodes older than the newest 250 via Algolia (by program, date-ranged); hide expired catch-up AAC before listing using Algolia availability statuses_ | M | O2, O3 | stretch |

### O1 — episode playback engine
- **`Episode.pm`** `resolve($id, $cb)` → `{url, alternates, meta, failToken}` | `{error => TOKEN}`:
  1. Fresh meta-cache entry with `renditions` (seeded by D3 from Algolia, `seenAt` < 6 h) → choose directly.
  2. Else episode document via `API::nextData(<path>)` → `pageProps.data.documentProps` (`path` from the meta cache;
     without one, see OQ1) → `{id, docType, title, synopsis, programTitle, programId, image, date
     (datelinePrepared.publishedDate), duration, renditions[{url, MIMEType, bitrate}], availableFrom/To,
     downloadAvailableFrom/To, webDistributionRestricted}`; cached 1 h; meta cache updated (merge).
  3. Rendition choice (research §4.3): MP3 (`audio/mpeg`, `audio/mp3`) while now ∈ `downloadAvailable*` → primary;
     AAC (`audio/aac`) while now ∈ `available*` → primary if no MP3, else alternate (OQ2); ignore `.m3u8`, `.f4m`, and
     the duplicate `application/vnd.apple.mpegurl` entry pointing at the `.aac`; `webDistributionRestricted` →
     `PLUGIN_ABCLISTEN_EPISODE_RESTRICTED`; nothing in window → `PLUGIN_ABCLISTEN_EPISODE_EXPIRED`; unknown id →
     `PLUGIN_ABCLISTEN_EPISODE_NOT_FOUND`; URL containing `/geo-001/` → `failToken => 'PLUGIN_ABCLISTEN_EPISODE_GEO'`
     ("only available in Australia") so a 403 at scan time reads correctly.
- **`episode` kind** (registered from `Episode->init`): `metadata` → `{title => episode title, artist => program title,
  album => network or program, cover => episode image (600 px) || program image || icon, duration}` from the meta cache;
  URL fallback "ABC listen episode". Never touches `$song->duration`/`startOffset`.
- **Tests** `t/30-episode.t` (fixtures `nextdata-episode-scienceshow-mp3`, `-classic-drive-aac`, `-old-2024`: rendition
  matrix at fixed "now" values — MP3 permanent, AAC inside/after window, MP3+AAC both present, restricted, only
  m3u8/f4m, `abcmedia.akamaized.net` legacy MP3, geo-001; seeded-renditions shortcut; stale buildId path delegated to
  API), `t/31-episode-kind.t` (resolve → PH result shape; error tokens; metadata + fallback).
- **Runtime** (before O2; JSON-RPC): `["playlist","play","abclisten://episode/107266790"]` after seeding the meta cache
  path (or via OQ1) plays on DevPlayer; `["time",600]` → `time` ≈ 600 and advancing; `status` title/artist/
  `artwork_url`/`duration`; a fresh catch-up AAC episode (e.g. ABC Classic Drive) plays — record whether AAC seeks; an
  expired AAC-only episode shows the expired message; favourite replay after `dev/restart-lms.sh`; direct and proxied
  streaming. **pi14**: a `/geo-001/` episode (e.g. *You're Dead To Me*) plays; in the container it shows the geo message.

### O2 — Programs → network → program → episodes
- **`Programs.pm`** (data):
  - Networks (static, CoreMedia collection ids from research §3): Radio National 11474038 (+ Featured 13910480),
    triple j 8698186, Double J 9375554, ABC Classic 9104650, ABC Jazz 8794720, ABC Country 12606644, ABC Kids listen
    9317914, triple j Unearthed 106304964; others (NewsRadio, Classic 2, Radio Australia/Pacific) via OQ4.
    `networkPrograms($net, $cb)` → `bff('programAggregationCollection/x', {collectionId, offset, size})` paged to
    `total` → program refs via `API::cardRef` (`coremedia://teaser/<id>` tolerated); cache 6 h, `stale_ok`.
  - `program($path, $cb)` → `API::nextData($path)` → `{id, title (heroImageWithCTAPrepared.heading), description
    (richText(heroDescriptionPrepared)), presenters, image, network (attributionLinksPrepared), episodeCollectionId
    (programCollectionPrepared.id), total, firstEpisodes}`; cache 6 h.
  - `episodes($collectionId, $offset, $size, $cb)` → `bff('episodesWithSegments/x', {collectionId, offset, size})` →
    episode refs `{id (contentUri), docType, title (cardTitle), description, path (articleLink), date
    (cardAttributionPrepared.publishedDate), duration (cardMediaIndicatorPrepared.duration), image, presenters,
    segments[]}`; cache 15 min; `total` capped at 250.
- **`OnDemand.pm`** (rewrite of the F1 stub; keeps `init` calling `Episode->init`):
  - `menuItems` → one link **Programs** → `_programsRoot`: **By network** → networks → programs (A–Z within network).
  - `programItem` → `type link`, name = title, `image`, line2 = network, `description`, `url => \&_programMenu`.
  - `_programMenu`: description (`textarea`), "Presented by …", network; then registry extras (M2 Follow); then
    episodes newest first: first 50 + **More episodes…** link loading the next 50 (to ABC's 250).
  - `episodeItem` → `type link` + `play => abclisten://episode/<id>` (no `on_select`), name "Mon 19 Oct – <title>" (date
    in name for the Default skin), line2 "<date> · <duration>", `image` (episode, else program), `duration`; writes the
    episode meta cache. `_episodeMenu`: "Play episode" (`type audio`, `on_select play`, `favorites_title`), synopsis
    (`textarea`), "Broadcast <date> · <duration>" text.
  - Empty/error: "No episodes available" / `PLUGIN_ABCLISTEN_LOAD_FAILED` text items; every feed answers exactly once
    (REF `_respond`/`_textFeed` pattern).
- **Tests** `t/32-programs.t` (fixtures `bff-programAggregationCollection-rn`, `nextdata-program-scienceshow`,
  `bff-episodesWithSegments-scienceshow` + synthetic: missing images/presenters, teaser cards, rich-text edge cases,
  empty collection, 250 cap), `t/33-ondemand-menus.t` (exact item keys for program/episode rows and submenus; paging;
  meta-cache writes; registry extras ordering and failure isolation; exactly-one callback on every path).
- **Runtime**: Default + Material: ABC listen → Programs → By network → Radio National → The Science Show → episode list
  (artwork, date in name) → episode submenu (synopsis, date · duration) — screenshots; `menu:1` shape; after O1 (IC-2)
  playing from the row play control and from "Play episode" works; More episodes loads; clean `server.log`.

### O3 — All programs A–Z and by type
- **`ProgramIndex.pm`**: `API::algolia({query => '', hitsPerPage => 1000, filters => 'contentType:program AND
  (siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten OR siteSegment:triplejunearthed OR
  siteSegment:pacific)', attributesToRetrieve => [...]})` → program refs `{id (objectID), title, path (canonicalURL),
  description (shortTeaserText/description), image (defaultThumbnail 1x1), network (infoSource), programType}`; cache
  24 h with last-good (one Algolia query per day per LMS). Algolia unavailable / rate-limited → union of O2 network
  lists, flagged with a text note.
- **Menus** (`_programsRoot`, owned from now on): **All programs A–Z** → letters A–Z and "0–9" with counts → programs
  (`programItem`; sorting ignores a leading "The"); **By type** → Podcasts, Catch-up radio, Music, News briefings,
  Audiobooks, Other (from `programType`).
- **Tests** `t/34-program-index.t` (fixture `algolia-programs-list`; grouping, "The" sorting, digits, missing types,
  fallback path, cache/last-good).
- **Runtime**: Programs → All programs A–Z → S → The Science Show → episodes → play; By type → Audiobooks lists programs
  (geo note for audiobooks); counts ≈ ABC's ~720 programs; Default + Material screenshots.

### O4 — episode extras
- Segments: episodes whose card has `segments[]` show **Segments (N)** in `_episodeMenu`; each segment is an
  `episodeItem` (`abclisten://episode/<segmentId>`, docType `audiosegment`, resolved by O1).
- Tracklist: on opening an episode menu, lazily `API::nextData(<episode path>)` → `tracklistPrepared` → **Tracklist (N)**
  text rows "Artist – Title" (with relative time when `timestampRelative` exists); none → "No tracklist".
- "More from <program>" (`programItem`) in the episode menu — for episodes reached from Discover/Search/My ABC.
- Episode song info (TrackInfo provider, registered in `Episode->init`): synopsis, program link, tracklist while an
  `abclisten://episode/` track plays.
- **Tests** `t/35-episode-extras.t` (segment rows; tracklist parse incl. missing timestamps; "More from" present only
  when program path known; song-info items).
- **Runtime**: an RN Breakfast/Science Show episode with segments plays a single segment; a Double J/Classic music
  episode shows a tracklist; song info during playback; Default + Material screenshots.

## Integration points
- **F1/F2**: `OnDemand->menuItems` is the second top-level hook; `Episode->init` (called from `OnDemand->init`, stub
  created by F1) registers the `episode` kind and song-info provider; ondemand never edits `Plugin.pm` or
  `ProtocolHandler.pm`.
- **F3**: `nextData` (program/episode documents, buildId refresh), `bff` (aggregation collections, episodes),
  `algolia` (O3), `cardRef`/`richText`/`imageUrl`/`sitePath`.
- **Episode meta cache**: written by `episodeItem` (all callers), O1 resolver, D3 (seeded renditions); read by O1, O4.
- **Builders for other streams**: L4 (schedule → `programItem`), D1/D2 (collection cards), D3 (search results), M2
  (followed programs, latest episodes; Follow item via `registerProgramMenuProvider`). Consumers never construct episode
  URLs or OPML shapes themselves.
- **Builder ownership** (`OnDemand.pm`): O2 creates all; O3 then owns `_programsRoot`; O4 owns `episodeItem` and
  `_episodeMenu`; `programItem`/`_programMenu`/registry stay O2's.
- **Release**: R2 smoke plays and seeks an episode; README documents availability windows, geo restriction, 250 cap.
- **Strings** (pre-seeded by F1): O1 `PLUGIN_ABCLISTEN_EPISODE_EXPIRED`, `PLUGIN_ABCLISTEN_EPISODE_RESTRICTED`,
  `PLUGIN_ABCLISTEN_EPISODE_GEO`, `PLUGIN_ABCLISTEN_EPISODE_NOT_FOUND`; O2 `PLUGIN_ABCLISTEN_PROGRAMS`,
  `PLUGIN_ABCLISTEN_BY_NETWORK`, `PLUGIN_ABCLISTEN_EPISODES`, `PLUGIN_ABCLISTEN_PLAY_EPISODE`,
  `PLUGIN_ABCLISTEN_NO_EPISODES`, `PLUGIN_ABCLISTEN_MORE_EPISODES`, `PLUGIN_ABCLISTEN_PRESENTED_BY`,
  `PLUGIN_ABCLISTEN_BROADCAST`; O3 `PLUGIN_ABCLISTEN_AZ`, `PLUGIN_ABCLISTEN_BY_TYPE`, `PLUGIN_ABCLISTEN_TYPE_PODCAST`,
  `PLUGIN_ABCLISTEN_TYPE_CATCHUP`, `PLUGIN_ABCLISTEN_TYPE_MUSIC`, `PLUGIN_ABCLISTEN_TYPE_NEWS`,
  `PLUGIN_ABCLISTEN_TYPE_AUDIOBOOK`, `PLUGIN_ABCLISTEN_TYPE_OTHER`, `PLUGIN_ABCLISTEN_INDEX_FALLBACK`; O4
  `PLUGIN_ABCLISTEN_SEGMENTS`, `PLUGIN_ABCLISTEN_TRACKLIST`, `PLUGIN_ABCLISTEN_NO_TRACKLIST`,
  `PLUGIN_ABCLISTEN_MORE_FROM`.

## Out of scope
- Episodes beyond the newest 250 per program (stretch O5); podcast RSS feeds (feed id not derivable).
- Downloading/caching audio; transcoding; resume-from-position bookkeeping beyond what LMS does natively.
- Favouriting program menus (coderef menus can't be favourites — M2 "Follow" covers this); per-player program prefs.
- Video podcasts and non-audio docTypes (article, video); Terminus GraphQL/app keys.
- Local-station program lists by network (local programs are reachable via A–Z, By type, search and L4 schedules).

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| OQ1 | Resolving an episode id with no cached path (e.g. favourite after cache expiry, typed URL). | Try `nextData('/listen/programs/x/x/<id>')` (`__N_REDIRECT` to canonical — verify generic slugs work), then Algolia `objectID:"coremedia://<docType>/<id>"` for the three audio docTypes; else `EPISODE_NOT_FOUND`. Meta-cache TTL 30 days keeps this rare. | O1 |
| OQ2 | MP3 (192 kbps, permanent, seekable) vs AAC (~260 kbps, 28-day) when both are available — expose a preference? | Prefer MP3, AAC as alternate; no pref in v1. | O1 |
| OQ3 | Does LMS seek in remote ADTS AAC episodes? | O1 records it; if not, README documents "catch-up AAC episodes can't seek". | O1 |
| OQ4 | Collection ids for NewsRadio, Classic 2, Radio Australia/Pacific program lists. | O2 discovers via `nextData('/<network>/programs')` if cheap; else those networks are reachable via A–Z/By type only. | O2 |
| OQ5 | Episode row text: duration in the Default-skin `name` too? | No — date in name; duration in line2 and the episode submenu (meets criterion 2 via the submenu). | O2 |
| OQ6 | Hide likely-expired catch-up episodes (AAC-only programs > 28 days) at list time? | No (needs per-episode data); play-time message instead; stretch O5. | O2 |
| OQ7 | Audiobooks and BBC co-productions are often `/geo-001/` — label them in lists? | No list label (needs per-episode data); geo message at play time; README note. | O1, O3 |

## Changelog
- 2026-10-19 — Initial master plan (stream-planning sub-agent).
