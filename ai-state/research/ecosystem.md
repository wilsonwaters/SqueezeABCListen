# Ecosystem research: ABC listen on LMS and elsewhere

Researched 2026-10-19 by a research sub-agent. Cloned code was read, never run. Clones are in the scratchpad (`/tmp/claude-0/-home-user/ae9985bf-990f-54ab-8efa-9c020108380c/scratchpad/ecosystem/`).

## Summary

- **No LMS plugin for ABC exists today.** The official LMS repository list has 221 plugin entries gathered from the 75 repos named in `include.json`. None of them is for ABC or Australia. The only historical one was **AlienBBC**, from the SqueezeCenter 7.x era (around 2008–2011). It carried some ABC streams and ABC podcasts and has been dead for years.
- **The strongest existing LMS option is Paul Webster's Radio Now Playing (RNP).** It is GPL-3, at v0.0.56, with about 2.8k installs. It ships an ABC broadcaster config (`init-stationdata-abcaustralia.json`) and adds now-playing data to any ABC live stream, whatever plugin it is played from (TuneIn, Radio Browser, favourites). That data covers track, artist, album, cover, programme name and synopsis. It reads ABC's public `music.abcradio.net.au` and `program.abcradio.net.au` APIs. **It has no on-demand, catch-up, programme browsing or podcasts.**
- **The generic routes leave gaps:**
  - The built-in **Podcasts** plugin (PodcastIndex/GPodder) handles ABC shows that have RSS feeds well. Those feeds have 3000px art, descriptions and MP3s.
  - **TuneIn**, **Radio Browser** and **RadioNet** give live streams.
  - None of them offers catch-up of broadcast programmes, programmes without RSS (Kids listen, many music shows, local radio), schedules, or browsing by network.
  - Most Radio Browser ABC entries (146 checked) are **HLS**. LMS 9.2 core cannot play HLS without bpa's PlayHLS + ffmpeg.
- **Elsewhere, the closest analogue is Music Assistant's ABC Radio Network provider.** It is Apache-2.0, beta, added 2026-08-05 by @OzGav. It covers **only the 9 music stations**, live only, with now-playing from `music.abcradio.net.au`. Its maintainers deliberately cut a PR that would have added talk stations. Kodi has only small stream-list add-ons. Nothing was found for Home Assistant, Mopidy, Volumio, Sonos, Plex or Jellyfin.
- **ABC is well documented in others' code.** Useful sources are rrradio's broadcaster research, wryun/abcradio (talk-station fallback), aerial-registry (`__NEXT_DATA__` scraping), and two scripts that call the ABC listen app's **Terminus GraphQL** API for on-demand programmes and episodes. A keyless station-list endpoint (`services.json`, 95 live services) exists, although one project wrongly says there is none.
- **Best-in-class analogue: expectingtofly's BBC Sounds plugin.** It is GPL-3, v2.54.8, has 2.1k installs and was last committed 2026-09-01. Its patterns to copy include:
  - a station menu of Live, then day-by-day schedules, then Highlights
  - a custom URL scheme so favourites stay stable
  - configurable now-playing lines and images
  - Track Info, Global Search, Radio Favourites, Material Home Extras and Don't Stop The Music integrations
  - live rewind
- **Differentiators for our plugin:**
  - the first ABC-specific LMS plugin
  - all networks, including talk, local and regional stations, with state/timezone variants
  - on-demand programmes and episodes beyond RSS, with art, descriptions and dates
  - schedules and catch-up
  - now-playing that falls back from track to programme
  - native playback without PlayHLS
  - no login or app keys needed for the core features

## Method: what was searched

| Where | What | Result |
|---|---|---|
| `LMS-Community/lms-plugin-repository` `extensions.xml` (raw, 221 `<plugin>` entries) | case-insensitive `abc`, `austral`, `triple j`, `radio national`, `aussie`, `ozradio`/`oz radio`; also listed every `radio`/`musicservices` entry and anything matching radio/podcast/bbc/broadcast | **No ABC/Australia plugin.** The only `abc` hits were inside SHA hashes (ArchiveOrg, VolumeLock). The only AU mention is bpa's iHeartRadio ("Live US,CA,AU,NZ and MX stations"). |
| `include.json` (75 active third-party repo URLs + 16 disabled) | `abc`, `austral` in the URLs; spot-checked bossanova808 (an Australian dev) and the radionowplaying.com repo | No ABC repo. bossanova808 ships only XSqueezeDisplay. radionowplaying.com holds RNP, RadioFrance, CBC FR and PlanetRadio. |
| Radio Now Playing 0.0.56 zip | grep for ABC hosts | **Match:** `stationdata/init-stationdata-abcaustralia.json` (ABC broadcaster definition, Feb 2026) plus an older `stationdata-abcaustralia.disabledobf` |
| lyrion.org/plugins/directory | any ABC/AU/triple j | None |
| forums.lyrion.org | direct search returned **HTTP 403** to both WebFetch and curl; tried web search with `site:` and free-text variants | No forum threads surfaced. One cannot rule out discussion threads, but no plugin is announced anywhere indexed. |
| wiki.lyrion.org | AlienBBC page | Historic ABC support ("Australia's ABC… podcasts from ABC & BBC"). SqueezeCenter 7.x / AlienBBC 2.x era. Dead. |
| LMS core (`LMS-Community/slimserver` public/9.2) | `Slim/Plugin/Podcast`, `Slim/Plugin/InternetRadio`, `Slim/Player/Protocols` | Podcast providers are pluggable (`registerProvider`, PodcastIndex/GPodder built in). **No native HLS** protocol handler; protocols are HTTP/HTTPS/MMS/File only. |
| GitHub (repo + code search) | `abc listen`, `triple j`, `plugin.audio abc`, `music.abcradio.net.au`, `program.abcradio.net.au`, `api.abc.net.au/terminus`, `abc.net.au/listen` | About 30 relevant repos (below) |
| Kodi official repos (Matrix/Nexus/Omega/Piers `addons.xml.gz`) | id/name/description matching abc/triple j/Australian Broadcasting | **None in current repos.** Gotham-era `plugin.audio.abcradionational` and the third-party teeedubb repo exist. |
| Music Assistant, Home Assistant, Mopidy, Volumio, Sonos, Plex/Jellyfin | web + GitHub search | See per-ecosystem notes |

## Existing LMS options for ABC

| Name | Link | What it does for ABC | Gaps |
|---|---|---|---|
| **Radio Now Playing** (Paul Webster, GPL-3, v0.0.56, ~2.8k installs) | http://www.radionowplaying.com (repo `http://radionowplaying.com/slimserver-rep/repo.xml`) | Auto-registers ABC stations from `services.json`. Matches ABC stream URLs by regex (shout-aac/mp3 `.pls`, `mediaserviceslive.akamaized.net`, `*.mediahubaustralia.com`, `abc.streamguys1.com`, `streaming.abc-cdn.net.au`). Shows track/artist/album/label/year/cover from `music.abcradio.net.au/.../now.json` and the programme title/synopsis from `program.abcradio.net.au/.../programitems/live.json`. Has an optional menu in Radio or My Apps. | Live only, and a metadata layer rather than an ABC browser: no programmes, episodes, catch-up, schedules, search of ABC content or podcasts. Generic multi-broadcaster UX. **Interaction risk:** its regexes will also match our plugin's stream URLs. A custom protocol (`abclisten://`) or coordination avoids double or competing metadata. |
| **TuneIn** (built-in InternetRadio) | built-in | Search "triple j", "ABC Classic" and so on to get live streams. TuneIn also lists some ABC programme "shows". | No ABC-specific metadata (RNP fills that in), no catch-up, inconsistent station coverage and names, stream URLs proxied by TuneIn. |
| **Radio Browser** (hjelev, v0.3.10) | https://github.com/hjelev/lyr-radio-browser | Community directory. A query for `name=ABC&countrycode=AU` returned 146 entries, including regional locals, with favicons. | **Almost all ABC entries are HLS** (`streaming.abc-cdn.net.au/...m3u8`, `mediaserviceslive.akamaized.net/.../masterhq.m3u8`), which LMS cannot play without PlayHLS. Names are noisy ("ABC 702kHz AM Sydney NSW Local Radio 20220701"). No on-demand. |
| **RadioNet** (bpa, v3.4) / **iHeartRadio** (bpa; lists AU stations) | bpa-code.github.io/bpaplugins | Directory access to live streams | Same gaps. ABC coverage unverified. |
| **Podcasts** (built-in, PodcastIndex/GPodder providers) + **Podcast Extensions** (philippe44, v0.23.1) | built-in / https://github.com/philippe44/LMS-PodcastExt | Search for and subscribe to any ABC podcast with an RSS feed (`https://www.abc.net.au/feeds/<id>/podcast.xml`). Feeds are good quality: `itunes:image` at 3000×3000, full descriptions, MP3 enclosures on `mediacore-live-production.akamaized.net`. | You must know and search each show. No browsing by network or category. **No broadcast programmes without RSS** (e.g. Kids listen Story Time and Bedtime Stories, which is why schmttc/abc-kidslisten-rss exists; many triple j, Double J and Classic music shows; local radio). No live, schedules or now-playing. |
| **PlayHLS** (bpa, v1.01) | sourceforge bpaplugins | Lets LMS play HLS URLs via ffmpeg custom-convert, so Radio Browser's ABC HLS entries become playable | Extra install and ffmpeg dependency. No metadata. |
| **Manual favourites** of `.pls` or Icecast URLs | e.g. `https://www.abc.net.au/res/streaming/audio-live/shout-aac/abcjazz.pls` (Volumio thread) | Works natively (AAC/MP3) | URLs change over time (forum users report hidden characters and broken URLs). Bitrate is low (shout-aac is about 63 kbps). |
| **AlienBBC** (historic) | https://wiki.lyrion.org/index.php/AlienBBC | Once had ABC streams and ABC/BBC podcasts | Defunct, SqueezeCenter 7 era |

## Integrations in other systems

| Ecosystem | Project | Licence / last activity | What it does | Found? |
|---|---|---|---|---|
| **Music Assistant** | `music-assistant/server` → `music_assistant/providers/abc_radio_network` (docs: https://music-assistant.io/music-providers/abc-radio-network/) | Apache-2.0. Added 2026-08-05 (#5321). Last ABC change 2026-09-09 (#6140). Stage "beta". | 9 live music stations (triple j, triple j Hottest, Double J, Unearthed, Classic, Classic 2, Jazz, Country, Kids listen). HLS from `streaming.abc-cdn.net.au`. Polls now-playing every 30 s. Search by station name. | **Found**, music-only |
| **Home Assistant** | No integration. HA users go through Music Assistant or Radio Browser media source. Personal YAML exists (e.g. bjeanes/ha-config REST sensors). | n/a | REST sensors on `program.abcradio.net.au/api/v1/programitems/{triplej,doublej,jazz}/live.json` | **Not found** (only personal configs) |
| **Kodi** | `teeedubb/teeedubb-xbmc-repo`: `plugin.audio.triple.j` 1.0.5 and `plugin.audio.abc.kids.listen` 1.0.1 | GPL-2.0. Repo last commit 2025-03-03. | Hard-coded stream lists | Found (trivial) |
| Kodi (historic) | `DamonToumbourou/plugin.audio.abcradionational` 1.1.0 (Gotham repo) | MIT, 2015 | Scraped RN podcasts pages and the RN live page | Found, dead |
| Kodi (historic) | `techyteach-s/plugin.audio.abcradioaustralia`, `eathernet/plugin.audio.triplej` | 2013–2015 | Stream lists | Dead |
| **Mopidy** | none (Mopidy-Podcast or Mopidy-RadioNet only generically) | n/a | n/a | **Not found** |
| **Volumio** | none. Community thread on ABC Jazz HLS problems: https://community.volumio.com/t/how-to-add-radio-station-to-volumio/69234 | n/a | Lesson: the browser page plays but Volumio needs direct `.pls` or HLS URLs | **Not found** |
| **Sonos** | none (no SMAPI service). ABC is reachable via TuneIn, Sonos Radio or manual URL. A Sept 2026 thread reports RN failing on S1. | n/a | n/a | **Not found** |
| **Plex / Jellyfin** | none | n/a | n/a | **Not found** |
| Android radio app registry | `shapeshed/aerial-registry` (`docs/providers/abc.md`) | 2026-10-10 | Scrapes `abc.net.au/listen/live/{slug}` `__NEXT_DATA__` for `papiServiceId`, `config.sources[]` and logo. 11 national + 9 capital-city locals. | Found (useful notes) |
| Web radio app | `MarkusSteinbrecher/rrradio` (`docs/broadcaster-research.md#abc`) | MIT, 2026-10-19 | The best write-up of ABC's metadata APIs: service-ID taxonomy, response shapes, cache headers, CORS | Found (**key reference**) |
| ICY metadata proxy | `wryun/abcradio` (Pony) | No licence file, 2026-08-25 | Relays every ABC service with injected ICY metadata. Tries music now-playing first, then falls back to programme EPG ("Presenter – Show"). Station list from `services.json`. | Found (**key reference**) |
| yt-dlp | core `yt_dlp/extractor/abc.py` (ABCIE handles `abc.net.au/listen/...` episode pages via embedded `renditions` JSON) + `ClosedPort22/yt-dlp-plugins` `abclisten.py` (Unlicense, 2026-08-10) | | The plugin uses ABC listen **Terminus GraphQL** persisted queries `GetProgramDetails` and `GetEpisodeById` for audiobooks | Found |
| Downloader | `brinlyau/abc_listen_downloader` | Unlicense, 2026-03-16 | Algolia program search plus Terminus GraphQL (ad-hoc query) to list and download a program's episodes | Found |
| Tracklist scrobbler | `obobed/abc-listener` | AGPL-3.0, 2026-07-16 | Parses `__NEXT_DATA__` on programme pages (episode list) and episode pages (`tracklistPrepared`) to scrobble to Last.fm | Found |
| RSS generator | `schmttc/abc-kidslisten-rss` | No licence, 2026-10-18 (active) | GitHub Action scrapes Kids listen programme HTML into MP3 podcast RSS (for Yoto players) | Found |
| Catch-up downloader | `ehoppmann/abc_dl` | MIT, 2025-08-15 | Builds catch-up HLS URLs on `abcradiomodhls.abc-cdn.net.au` (old scheme) | Found (dated) |
| CLI player | `uncleLukie/jaybird` (C#) | MIT, 2025-11-15 | triple j / Double J / Unearthed CLI with Discord presence. Per-state Icecast streams. | Found |
| Python library | `MatthewBurke1995/ABC-Radio-Wrapper` (PyPI, readthedocs) | MIT, 2023-02-17 | Wraps `music.abcradio.net.au/api/v1/plays/search.json` (paged play history) | Found |
| ABC's own OSS | `abcnews/terminus-fetch` (npm `@abcnews/terminus-fetch`) | MIT, 2026-08-20 | Official ABC client for the Terminus REST v2 content API (**needs an API key**) | Found |
| Misc | tidbyt `apps/abcradio`, i3pystatus `abc_radio.py`, etoxin/triplej, JamesBLewis/triplej-playlist-generator, jono-hayward/j-bots, Michael-Howes/tripleJ_api (R) | various | Now-playing and play-history consumers | Found |

### Per-item notes and lessons

- **Music Assistant ABC Radio Network.**
  - Implementation:
    - Station table is hard-coded (id, name, description, HLS URL, logo hash on `live-production.wcms.abc-cdn.net.au`).
    - `parse_now_playing` prefers `now.summary.artist`, because `recording.artists` mixes performer and composer entries for classical.
    - Falls back from `now.release` to `recording.releases[0]`.
    - Appends the release year to the album.
    - Clears stale metadata when talk programming starts.
  - Lessons:
    - The station ids double as music-API service ids.
    - The API sometimes briefly returns nothing; keep the last value.
    - Upstream maintainers want to keep it music-only. **Talk, local, on-demand and podcasts are open territory.**
- **wryun/abcradio.**
  - Lessons:
    - The music endpoint answers **400** for stations without music (e.g. Grandstand) and **200 with empty `now`** between songs.
    - The programme endpoint answers bare `null` for stations without a schedule. Ask music first, then programme, and keep the last title if both are empty.
    - Display format: "Artist – Title" for music, "Presenter – Show" for talk.
    - "icy-br: 56" in ABC AAC headers is wrong; the real bitrate is higher.
    - `services.json` lists every station with its AAC/HLS outlets in a single call.
- **aerial-registry.**
  - On `/listen/live/{slug}` pages, `__NEXT_DATA__` has an object with `papiServiceId` and `config.sources[]`. `sources[0]` is HLS, followed by AAC and MP3 on `live-radio01.mediahubaustralia.com/<CODE>/{aac,mp3}/`.
  - `title` there is the **current programme, not the station name**.
  - It claims "no station-list endpoint". That is wrong: `services.json` returned 95 services, including about 50 regional locals, when probed 2026-10-19.
- **rrradio.**
  - Service-ID taxonomy: player `papiServiceId` → API slug, e.g. `TRIPLEJ`→`triplej`, `LOCAL_SYDNEY`→`local_sydney`, **`RN`→`RN` (uppercase)**, `NEWS`→`news`, `KIDS_LISTEN`→`kidslisten`, `RA`→`ra`. Use a lookup table, not a transform.
  - **An unknown `service` passed to `programitems/search.json` silently returns unfiltered results.** Validate `creating_service.service_id`.
  - Respect `Cache-Control` max-age (60–163 s). CORS is `*`. No auth.
  - Use `primary_publication_event.defining_timezone` (Australia/Sydney) for day boundaries.
- **Terminus GraphQL (ABC listen app back end).**
  - `https://api.abc.net.au/terminus/graphql/query` takes both GET persisted queries (Apollo `persistedQuery` sha256 hashes for `GetProgramDetails` and `GetEpisodeById`) and POSTed ad-hoc queries, e.g. `CoremediaProgram(id){ title contextSettings{ document(name:"program.content.collection"){ ... on CoremediaCollection{ items(limit:N){ ... on CoremediaAudio{ id title duration publicationDate renditions{contentType url} } ... on CoremediaTeaser{ target{...} } } } } } }`.
  - It requires an `X-Api-Key` header and app-like headers. The values in those repos come from the **decompiled ABC listen Android app**. They appear in `ClosedPort22/yt-dlp-plugins/yt_dlp_plugins/extractor/abclisten.py` and `brinlyau/abc_listen_downloader/download_program.py` and are deliberately not copied here.
  - The yt-dlp plugin notes **"API is not geo-blocked, but media URLs are"** (for audiobooks).
  - Episode ids are CoreMedia ids (`coremedia://program/<id>` appears in page HTML).
  - **Risk:** using app keys is fragile and arguably outside ABC's terms. Prefer the keyless public endpoints and page JSON where possible.
- **Algolia search (ABC listen app).** Index `ABC_production_listenapp` with filter `docType:Program`, at `https://<APP_ID>-dsn.algolia.net/1/indexes/*/queries`. The app id and search key also come from the decompiled app (same caveat).
- **`__NEXT_DATA__` scraping** (obobed, aerial).
  - Programme pages expose `props.pageProps.programCollectionPrepared.items[]` (`cardTitle`, `articleLink`, which can be relative or absolute, and `cardAttributionPrepared.publishedDate`).
  - Episode pages expose `props.pageProps.data.documentProps.tracklistPrepared.items[]` (tracklists with `timestampRelative`).
  - The pages also expose `papiServiceId` and a Gigya profiles key (ABC account login; not needed).
  - schmttc's scraper depends on hashed CSS class names (`CardLayout_content__zgsBr`), which is very fragile. Prefer the JSON blob.
- **Old or dead endpoints:** `http://www.abc.net.au/radio/data/stations_apps_v3.xml` (i3pystatus) and `streaming.c3.abc.net.au/hottest100_a_aac` (teeedubb). The `abcradiomodhls.abc-cdn.net.au/i/triplej/audio/...` catch-up scheme (abc_dl) is likely superseded.

### ABC endpoints found in others' code

Status: "200" means probed from this sandbox on 2026-10-19. Probe responses are in the scratchpad (`.../ecosystem/probe/`).

**Station list and live streams**
- `https://program.abcradio.net.au/api/v1/services.json?filter=has_live_stream&include=outlets%2Coutlet_audio` (wryun). RNP adds `primary_image,primary_webpage,social_media,resized_images,colours,images&image_role=background&client_version=1.30.0`. **200: 95 services.** Each service carries `outlets[].audio_streams[]` with `type` HLS/AAC/HDS. Service ids include `RN`, `RN_wa|sa|qld|nt`, `classic`, `classic2`, `classic_perth|adelaide|brisbane|darwin`, `doublej`, `doublej_*`, `h100`, `jazz`, `country`, `kidslisten`, `kidslisten_*`, `grandstand`, `abc_afl_rapid`, `itinerant_one…four`, and about 50 `local_*` stations.
- `https://www.abc.net.au/core-next/api/collection/listen/radio?collectionId=<id>&rootMetaCollectionId=<id>&metaInMeta=false` (wryun): station "cards" with images, grouped by network/state.
- `https://www.abc.net.au/listen/live/{slug}`: `__NEXT_DATA__` with `papiServiceId`, `config.sources[]` (aerial).
- Stream hosts seen:
  - `https://streaming.abc-cdn.net.au/audio/hls/<name>.m3u8` (e.g. `triplejnsw`, `doublejnsw`, `classicnsw`, `classic2`, `abcjazz`, `abccountry`, `abckids`, `triplejunearthed`, `triplejhottest`, `localsydney`). HLS, about 115–246 kbps AAC.
  - `https://mediaserviceslive.akamaized.net/hls/live/<n>/<name>/masterhq.m3u8` (HLS).
  - `http(s)://live-radio01.mediahubaustralia.com/<CODE>/{aac,mp3}/`. Codes: `2TJW` triple j, `DJDW` Double J, `UNEW` Unearthed, `XTDW` Kids listen, `PBW`. Also `live-radio03…` and `hot100.mediahubaustralia.com/H100W/aac/`. Plain Icecast, **LMS-native**.
  - `http(s)://abc.streamguys1.com/live/<name>/icecast.audio`, with per-state variants (`triplejnsw|qld|sa|wa|nt`, `doublejnsw|…`, `abcextra`, `triplejhottest`). Plain Icecast, **LMS-native**.
  - `abc-hls.streamguys1.com` (HLS).
  - `.pls` playlists: `https://www.abc.net.au/res/streaming/audio/aac/{triplej,unearthed,dig_music}.pls`, `https://www.abc.net.au/res/streaming/audio-live/shout-aac/abcjazz.pls`.
  - Legacy HDS: `abcradiolivehds-lh.akamaihd.net`.

**Now playing and EPG**
- `https://music.abcradio.net.au/api/v1/plays/{service}/now.json` (MA, wryun, RNP, rrradio, jaybird, tidbyt). **200.** Returns `now/next/prev`, each with `summary{artist,title}`, `recording{title,duration,artists[],releases[].artwork[].sizes[]}`, plus `played_time`.
- `https://music.abcradio.net.au/api/v1/plays/search.json?station={service}&order=desc&limit=N[&from=&to=&offset=]` (rrradio, etoxin, ABC-Radio-Wrapper): recent-tracks history. Usable for a "recently played" list in a Track Info menu.
- `https://program.abcradio.net.au/api/v1/programitems/{service}/live.json[?include=now]` (bjeanes HA, i3pystatus). **200.** Returns `now{title, short_synopsis, presenters[].display_name, series, program{arid}, primary_webpage, categories, live[{start,duration_seconds}]}`.
- `https://program.abcradio.net.au/api/v1/programitems/live.json?service={id}&limit=80&include=with_images%2Cresized_images` (RNP).
- `https://program.abcradio.net.au/api/v1/programitems/search.json?service={id}&from=<ISO>&to=<ISO>&include=next,with_images,resized_images&limit=N` (rrradio). **200.** Schedules and day guides.
- `https://www.abc.net.au/core-next/api/epgNowPlaying/{SERVICE_ID_UPPER}/now` (wryun; e.g. `LOCAL_SYDNEY`, `RN`). **200**, with `preparedImage.srcSet` and `preparedPresenters`. rrradio found the `/listen/core-next/...` variant 404s when called cold. The `/core-next/...` path without `/listen` worked here.

**On-demand programmes, episodes and podcasts**
- `https://api.abc.net.au/terminus/graphql/query` (yt-dlp plugin, brinlyau): program details and episode lists with `renditions[]{contentType,url}`, `duration`, `publicationDate`, `caption.plainText`, and thumbnails via `cropInfo`. Needs the app key.
- `https://api.abc.net.au/terminus/api/v2/content/coremedia/{type}/{id}` and `/api/v2/search/coremedia` (abcnews/terminus-fetch; needs an API key). Search supports `source: 'mapi', service: 'triplej'`.
- Algolia `ABC_production_listenapp` index (brinlyau; app keys).
- `https://www.abc.net.au/feeds/{id}/podcast.xml`: podcast RSS. **200**, rich metadata.
- `https://www.abc.net.au/sitemaps/sitemap-listen-0.xml.gz` (craigamcc/podcast-catalogue): enumerates `/listen/programs/...` pages.
- `https://www.abc.net.au/listen/listenapp/most-listened-podcasts/103470928`: editorial collection page (podcast-catalogue).
- Media: `https://mediacore-live-production.akamaized.net/audio/...{mp3,m4a}`. Legacy catch-up HLS: `http://abcradiomodhls.abc-cdn.net.au/i/<network>/audio/...`.
- Images: `https://live-production.wcms.abc-cdn.net.au/<hash>?impolicy=wcms_crop_resize&cropH=&cropW=&xPos=&yPos=&width=&height=` and `https://resize.abcradio.net.au/<sig>=/<WxH>/center/middle/<urlencoded src>`.

## Best-in-class analogue plugins

### BBC Sounds for LMS (expectingtofly)

https://github.com/expectingtofly/LMS_BBC_Sounds_Plugin. GPL-3, v2.54.8, 2,130 installs, last commit 2026-09-01. Same author also publishes Global Player UK, Virgin Radio, Times Radio and Radio Favourites.

- **Top menu.** User-configurable and re-orderable in settings. Some items cannot be removed.
  - Search, My Sounds, Stations & Schedules
  - Discover Podcasts, Music You'll Love, Promoted Editorial, Explore All
  - Recommended For You, Local To Me, Browse Categories
  - Continue Listening, Listen Live (live stations only), All News, Collections
  - The plugin can sit in **My Apps or Radio** (`is_radio` pref).
- **Station menu** (`getStationMenu`): `<Station> LIVE` (playable, favouritable as `sounds://_LIVE_<id>`), then **Today, Yesterday (Weekday), and the 5 earlier days by date**, then `<Station> Highlights`, then **Full 30 Day Schedule**.
- **Playable item menu:** Play, All Episodes, Bookmark, Subscribe, Tracklist, Synopsis. A setting can make items play directly from browsing.
- **Now playing:**
  - A live programme is shown as a "track".
  - Three configurable display lines for programme mode (programme title, description, station, blank) and track mode (track, artist, programme title).
  - Configurable image (programme image or track cover); option for short descriptions.
  - Polling can be throttled.
  - Spotify link for the current track via Spotty.
  - Thumbs-up/heart buttons on the now-playing screen bookmark and subscribe.
- **Live pause and rewind.** A custom `sounds://` ProtocolHandler fetches DASH segments and demuxes M4A itself. `<<` restarts the programme, and a second press goes to the previous programme, up to 6 hours back. `>>` returns to live. "Rewind to time" menu.
- **Integrations:**
  - `Slim::Menu::TrackInfo` (Tracklist, Next Episodes, Bookmark, Station Schedule, Live Tracklist, Rewind to time)
  - `Slim::Menu::GlobalSearch` (search results inside LMS global search)
  - CLI dispatches for Material Skin (`recentsearches`, `containerMenu`, `bookmark`, `subscribe`)
  - **Material Skin Home Extras** (scrollable home-screen rows)
  - **Don't Stop The Music** handlers ("Continue Listening", "Recommendations")
  - **Radio Favourites** handler (`addHandler({handlerFunctionKey, handlerSub})`, returning now-on title, description, image, start and end)
  - BBC account sync (continue listening; heartbeat about once a minute)
- **Robustness:**
  - `$prefs->migrate` steps for menu-schema changes
  - caches with explicit `flushCache`
  - menu cache
  - "UK listener abroad" pref, with region-dependent bitrate (320 kbps UK, 96 kbps abroad)

### ARD Audiothek for LMS (mzedd)

https://github.com/mzedd/LMS-ARD-Audiothek-Plugin. GPL-3, v1.3.2, about 1,000 installs, last commit 2024-01. This is the nearest on-demand-first analogue: a public-broadcaster audio library over GraphQL, like ABC's Terminus.

- **Menus:** Search (split into Program Sets, Editorial Categories, Editorial Collections, Items), Start/Discover (editorial sections), Radio (Organizations, then Publication Services, then permanent live streams), Podcasts (editorial categories, then program sets, then episodes).
- **Custom `ardaudiothek://` protocol** with `getMetadataFor`/`explodePlaylist`. Episodes are favouritable and show title, artwork and duration in now-playing.
- The code is small (about 1.2k lines) with GraphQL queries in a separate module. It is a good structural model for an MVP.

### Radio Now Playing (Paul Webster)

The metadata engine, rather than a UX model.

- Its declarative per-broadcaster JSON maps stream-URL regexes to now-playing and programme APIs (see `init-stationdata-abcaustralia.json`).
- It shows that ABC's public APIs are stable enough for a long-lived plugin. RNP has used them for years.
- **Our plugin must coexist with it.** Use a custom protocol, or document disabling RNP's ABC entries, so the two plugins do not fight over metadata.

### UX patterns worth copying

1. **Station page layout:** `LIVE` first, then Today, Yesterday and day-by-day catch-up (7 days), then Highlights, then the full schedule. Use the station's local timezone for day boundaries.
2. **Stable custom URLs** such as `abclisten://live/<service_id>` and `abclisten://episode/<coremedia_id>`. Resolve the real stream at play time so favourites and presets survive ABC changing stream hosts. Implement `getMetadataFor` so favourites show art and title.
3. **Two now-playing modes:** track mode (song, artist, cover) when music plays; programme mode (programme, presenter or synopsis, programme image) otherwise. Make the lines and image configurable.
4. **Track Info menu items:** Recently played tracks, Programme synopsis, Station schedule, All episodes of this programme, Follow/unfollow.
5. **Global Search provider**, and recent searches.
6. **Configurable home menu** and Radio vs My Apps placement.
7. **Radio Favourites handler**, **Material Home Extras** and **Don't Stop The Music**. These are cheap wins that make the plugin feel native.
8. **Throttled polling** that respects `Cache-Control` max-age. Keep the last good metadata on transient empties.
9. **Prefs migration** from day one, so menu changes don't break user settings.

## Differentiation for an ABC listen–specific LMS plugin

- **First and only ABC-dedicated LMS plugin.** Nothing in the LMS repository covers ABC browsing, on-demand or catch-up.
- **Whole network, not just music.** Cover national talk and music networks, all ~50 regional locals, and state/timezone variants (`RN_wa`, `classic_perth`, triple j state streams), driven by `services.json` rather than a hard-coded list. Music Assistant covers only 9 music stations. RNP gives metadata but no ABC browsing UX.
- **On-demand beyond RSS:** programmes and episodes for shows that have no podcast feed (Kids listen, music shows, local programmes), with artwork, descriptions, dates and durations. The built-in Podcasts plugin cannot do this.
- **Browse like the ABC listen app:** by network, by category or collection (e.g. "most listened podcasts"), A–Z programmes, and search. No per-show RSS hunting.
- **Schedules and catch-up** per station (Today, Yesterday, 7 days), using the EPG.
- **Rich now-playing for talk stations too:** music API first, then programme EPG with presenter and image. Existing options are either music-only (MA) or generic (RNP).
- **Plays natively on any LMS:** prefer the AAC/MP3 Icecast outlets (mediahubaustralia, streamguys), with optional HLS support later. Most Radio Browser ABC entries need PlayHLS.
- **No account or app keys needed for core features.** Use public keyless endpoints and page JSON. Treat Terminus or Algolia app keys as an optional, isolated adapter, if used at all.
- **Australian-first defaults:** a home-state setting for local station, state stream variants and schedule timezone. Australian English strings.
- **Plays well with others:** a custom protocol to avoid RNP conflicts, plus Radio Favourites, Material and DSTM integrations.

## Feature ideas ranked

**Must**
1. Live stations from `services.json`, grouped by Networks (triple j, Double J, Unearthed, Classic, Classic 2, Jazz, Country, Kids listen, RN, News, Grandstand/Sport, Radio Australia) and Local stations by state. Station logos.
2. Native-playable live streams (AAC/MP3 outlet preferred, HLS fallback only if a handler exists). Stable `abclisten://live/<id>` URLs for favourites.
3. Now-playing metadata: track mode from `music.abcradio.net.au/.../now.json`; programme mode from `programitems/{id}/live.json` or `epgNowPlaying`. Keep the last good value on empty or 400 responses. Polling at about 30–90 s, respecting max-age.
4. On-demand programmes: browse by network and A–Z. Episode lists with artwork, description, publish date and duration. Paging.
5. Play episodes (MP3/AAC renditions). Seekable, with title, art and duration in now-playing via `getMetadataFor`.
6. Search across programmes and episodes.
7. Caching and polite HTTP: a User-Agent, timeouts, graceful degradation when ABC changes page JSON.

**Should**
1. Station schedule: Today, Yesterday and the past 7 days, with catch-up episodes where ABC publishes them. Timezone-correct.
2. Track Info menu: recently played tracks (`plays/search.json`), synopsis, schedule, all episodes, follow.
3. Local "Followed programmes" list, with a "Latest from followed" feed.
4. Home-state preference for the default local station, state stream variants and schedule timezone.
5. Configurable now-playing lines and image, and home-menu items. Radio vs My Apps placement.
6. Global Search provider. Radio Favourites handler. Material Skin Home Extras rows (Live now, Latest episodes, Featured).
7. Featured and editorial collections, e.g. "Most listened podcasts" and Kids listen collections.
8. Resume position for long episodes (or rely on LMS's built-in podcast-style resume, if available for remote tracks).

**Could**
1. Own HLS protocol handler for higher-bitrate live audio and live pause/rewind (BBC-style), if the ABC HLS window allows it.
2. Don't Stop The Music handler (e.g. continue with the next episode of the same programme).
3. Register as a provider for the built-in Podcasts plugin (`Slim::Plugin::Podcast::Plugin::registerProvider`), so ABC search appears there too.
4. Spotify or Spotty link for the current track (as BBC Sounds does).
5. triple j extras: Hottest 100 station, Unearthed, play history.
6. Episode tracklists (`tracklistPrepared`) shown as a submenu.
7. Optional Terminus/Algolia adapter for richer on-demand data (behind a setting; key risk noted).
8. Geo-aware messaging if some media (e.g. audiobooks) is geo-blocked outside Australia.

## Risks and lessons from others

- **Page-JSON shapes change.** aerial and obobed both note inconsistent `articleLink` and deep paths, and schmttc relies on hashed CSS classes. Search JSON by shape, not by fixed path, and fail soft.
- **Service-ID quirks.** `RN` is uppercase. Unknown `service` values return unfiltered EPG results. The music API returns 400 for talk-only stations and an empty `now` between songs.
- **HLS is not native in LMS.** Default to Icecast AAC/MP3 outlets.
- **App keys (Terminus/Algolia) came from a decompiled app.** They are a legal and ToS risk and could be rotated. Keep them out of the critical path.
- **Some media URLs are geo-blocked** (audiobooks, per the yt-dlp plugin). The BBC plugin's "listener abroad" setting is precedent for handling this.
- **RNP coexistence** (see above).

## References

- LMS plugin repository: https://github.com/LMS-Community/lms-plugin-repository (`extensions.xml`, `include.json`)
- Lyrion plugin directory: https://lyrion.org/plugins/directory/
- AlienBBC: https://wiki.lyrion.org/index.php/AlienBBC
- Radio Now Playing: http://www.radionowplaying.com (zip `http://radionowplaying.com/slimserver-rep/RadioNowPlaying-0.0.56.zip`)
- BBC Sounds LMS plugin: https://github.com/expectingtofly/LMS_BBC_Sounds_Plugin (wiki: https://github.com/expectingtofly/LMS_BBC_Sounds_Plugin/wiki)
- ARD Audiothek LMS plugin: https://github.com/mzedd/LMS-ARD-Audiothek-Plugin
- Radio Browser LMS plugin: https://github.com/hjelev/lyr-radio-browser
- Podcast Extensions: https://github.com/philippe44/LMS-PodcastExt
- LMS core (Podcast plugin, protocols): https://github.com/LMS-Community/slimserver (branch public/9.2)
- Music Assistant ABC provider: https://github.com/music-assistant/server/tree/dev/music_assistant/providers/abc_radio_network and https://music-assistant.io/music-providers/abc-radio-network/ (PR #5321, #6140)
- rrradio broadcaster research: https://github.com/MarkusSteinbrecher/rrradio/blob/main/docs/broadcaster-research.md
- wryun/abcradio: https://github.com/wryun/abcradio
- aerial-registry ABC provider: https://github.com/shapeshed/aerial-registry/blob/main/docs/providers/abc.md
- yt-dlp ABC extractor: https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/abc.py
- ABC listen yt-dlp plugin: https://github.com/ClosedPort22/yt-dlp-plugins
- ABC listen downloader: https://github.com/brinlyau/abc_listen_downloader
- abc-listener (tracklist scrobbler): https://github.com/obobed/abc-listener
- abc-kidslisten-rss: https://github.com/schmttc/abc-kidslisten-rss
- abc_dl: https://github.com/ehoppmann/abc_dl
- jaybird: https://github.com/uncleLukie/jaybird
- ABC-Radio-Wrapper: https://github.com/MatthewBurke1995/ABC-Radio-Wrapper (docs: https://abc-radio-wrapper.readthedocs.io)
- abcnews/terminus-fetch: https://github.com/abcnews/terminus-fetch
- podcast-catalogue (sitemap use): https://github.com/craigamcc/podcast-catalogue
- Kodi: https://github.com/teeedubb/teeedubb-xbmc-repo, https://github.com/DamonToumbourou/plugin.audio.abcradionational, https://kodi.wiki/view/Add-on:ABC_Radio_National, https://forum.kodi.tv/printthread.php?tid=184488
- Home Assistant example config: https://github.com/bjeanes/ha-config (config/packages/media_centre.yaml)
- Volumio ABC stream thread: https://community.volumio.com/t/how-to-add-radio-station-to-volumio/69234
- Sonos ABC thread: https://en.community.sonos.com/controllers-and-music-services-229131/abc-radio-stations-not-playing-on-sonos-1-sill-playing-on-sonos-2-other-stations-still-playing-ok-on-both-6934761
- ABC direct-stream help article (403 to fetchers): https://help.abc.net.au/hc/en-us/articles/4402927208079-Where-can-I-find-direct-stream-URLs-for-ABC-Radio-stations
