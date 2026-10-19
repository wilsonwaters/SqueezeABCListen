# Master Plan — foundation

## Goal
Deliver the small, frozen platform every ABC listen feature builds on:
1. **F1** — the first merge is a thin vertical slice: an installable plugin that puts **"ABC listen"** in the LMS Radio
   menu with **5 national live stations that play** on DevPlayer (under ABC listen → **Radio**), plus the frozen 5-hook
   menu API with weighted top-level ordering, shared HTTP/time
   helpers and the ported LMS-free test harness + `scripts/check.sh` + CI.
2. **F2** — stable `abclisten://` playback URLs through one thin protocol handler with a per-kind resolver registry, so
   live (L*) and on-demand (O*) plug in playback without ever editing the handler; favourites survive restarts.
3. **F3** — one robust ABC data client (`API.pm`) hiding the fragile parts of ABC's undocumented endpoints: Next.js
   `buildId` discovery/refresh, Algolia key discovery and rate budget, caching, coalescing, card/image/rich-text
   helpers.

Packaging, `repo.xml`, the release workflow and user docs are the **release** stream (R1–R3).

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| F1 | Installable vertical slice: Radio → "ABC listen" → "Radio" with 5 playable national stations; frozen hook API (weighted top level, `menuWeights`) + module stubs; `HTTP.pm`, `Util.pm` contracts (incl. `topWeight`); ported test harness; `scripts/check.sh`; CI | M (upper; review plan like an L) | – | in progress (PR #21) |
| F2 | `abclisten://` protocol handler framework: kind registry (resolve/metadata/onStream/onStop), alternates + failure tokens, scan-callback wrapping, `getMetadataFor` dispatch; slice stations move to `abclisten://live/<ID>`; favourites replay | M | F1 | planned |
| F3 | ABC data client `API.pm` (BFF, `_next/data` with buildId, Algolia with runtime key discovery + hourly budget, PAPI, music API, text) + caching/coalescing/last-good + pure helpers; `scripts/abc-endpoints-check.sh` drift probe | M | F1 | planned |

F2 and F3 are independent (wave 1, in parallel with R1 and M1).

### F1 — installable vertical slice, hook API, helpers, harness

**Plugin files** (identifiers from `research/lms-plugin-guide.md` §3)
- `ABCListen/install.xml`: module `Plugins::ABCListen::Plugin`; `name`/`description` string tokens; version `0.1.0`
  (unreleased); **new GUID** (`uuidgen`, never RTRFM's); `targetApplication` minVersion `8.3` (FQ2), maxVersion `*`;
  category `radio`; defaultState `enabled`; icon `plugins/ABCListen/html/images/icon.png`; homepageURL = GitHub repo;
  creator. No `optionsURL` (added by M1).
- `ABCListen/Plugin.pm`: `Slim::Plugin::OPMLBased`, `tag => 'abclisten'`, `menu => 'radios'`, `is_app => 0`;
  `getDisplayName` → `PLUGIN_ABCLISTEN` ("ABC listen"); `playerMenu` → `RADIO`; log category `plugin.abclisten`
  (default WARN). Hook engine ported verbatim from REF `RTRFM/Plugin.pm:42-157`, generalised to the ordered list
  `qw(Live OnDemand Discover Search MyABC)` (each `init` in `eval`; async join; exactly-once; `HOOK_TIMEOUT` 25 s;
  failing hook → one error text item). Registers `abclisten` → `Plugins::ABCListen::ProtocolHandler` (so F2 never
  touches `Plugin.pm`).
  **Amended in flight (2026-10-19, stakeholder: app-style top level; as implemented in PR #21):** top-level items may
  carry `weight`; `Plugin.pm` merges all hooks' items and stable-sorts on it (missing/non-numeric = 100, ties keep hook
  order then item order) and strips the key from shallow copies; a hook may return several top-level items and may
  implement optional `menuWeights()` — a failing hook's error item sorts at its lowest declared weight, else 100.
  `Util::topWeight($name)`: home 10, radio 20, podcasts 30, news 40, sport 50, kids 60, audiobooks 70, programs 75,
  search 80, myabc 90 (`DEFAULT_TOP_WEIGHT` 100). Every hook that returns top-level items declares `menuWeights()`.
- Hook stubs: `Live.pm` → `menuItems` returns one link **"Radio"** (`PLUGIN_ABCLISTEN_RADIO`, `weight =>
  topWeight('radio')`, plus `Live->menuWeights`; renamed from "Live radio" in flight) containing triple j, Double J, Radio National,
  ABC Classic, ABC Jazz as `type audio`, `on_select play` items with plain StreamGuys URLs
  (`https://abc.streamguys1.com/live/<mount>/icecast.audio`, mounts `triplejnsw`, `doublejnsw`, `rnnsw`, `classicfmnsw`,
  `abcjazz`), `favorites_url`/`favorites_icon`, station logo if a crop-param wcms URL is at hand else the plugin icon.
  `OnDemand.pm` → `init` calls `Plugins::ABCListen::Episode->init` (stub `Episode.pm`, `init` no-op — O1 fills it so O1
  never edits `OnDemand.pm`), `menuItems` → `[]`. `Discover.pm`, `Search.pm`, `MyABC.pm` → `init` no-op, `menuItems` →
  `[]`. `ProtocolHandler.pm` → empty package, base `Slim::Player::Protocols::HTTPS`.
- `HTTP.pm`: port REF as-is (rename; explicit LMS User-Agent, never `libwww-perl/*`; JSON decode in `eval` regardless of
  content type; `get` raw; `quiet` option; exactly one callback; default timeout 15 s). Append `postJSON($url, \%body,
  $cb, $ecb, \%opts)` and an `headers => [...]` option (needed by F3's Algolia calls). Never logs header values.
- `Util.pm`:
  - Constants: plugin/display names, icon path, cache namespace `abclisten`, `www.abc.net.au` base.
  - `parseISO8601` handling `Z`, `+10:00`, `+1000` and fractional seconds (REF implementation) → epoch; display helpers
    in **server local time** (`localtime`): `friendlyDate` ("Mon 19 Oct", adds year when not this year), `friendlyTime`
    ("6:30am"), `friendlyDuration` ("54 min", "1 h 05 min"). Drop REF's fixed-UTC+8 Perth helpers.
  - `decodeEntities` (REF).
  - URL contract: `liveUrl($serviceId)`, `episodeUrl($id)`, `parseUrl($url)` → `{kind => 'live'|'episode', id}` or
    undef (service id `[A-Z0-9_]+`; episode id digits).
  - Episode-metadata cache contract `setEpisodeMeta`/`getEpisodeMeta` (shape in `streams.md` contract 3; TTL 30 days;
    merging writes keep existing non-empty fields).
- `strings.txt`: EN only; header comment as REF; `# === <ID> ===` sections for the 20 original tasks (F1…R3; later
  tasks such as D4/D5 append their own section) pre-seeded with
  every token listed in the master plans' integration points.
- Icon: 512×512 PNG at `ABCListen/HTML/EN/plugins/ABCListen/html/images/icon.png` (FQ1).

**Test harness** (port REF, rename `RTRFM`→`ABCListen`, `RTRFMTest`→`ABCListenTest`, `RTRFM_TEST_LOG`→`ABCLISTEN_TEST_LOG`)
- `t/lib` stubs (16 `Slim::` stubs incl. OPMLBased, Log, Prefs, Strings [loads `ABCListen/strings.txt`], Cache, Timers,
  Misc, SimpleAsyncHTTP [routes URLs to fixtures, synchronous, records requests incl. method/headers/body],
  RemoteMetadata, ProtocolHandlers, Protocols::HTTP(S), Playlist, Source, Scanner::Remote, Music::Info,
  Control::Request, Menu::TrackInfo); add `Slim::Menu::GlobalSearch` and `Slim::Web::Settings` stubs now (used by D3,
  M1) so later tasks only add files. `JSON::XS::VersionOneAndTwo` shim; `t/lib/ABCListenTest.pm` (constants, fake clock,
  `route()`/`fixture()`, `collector()`), `t/lib/ABCListenTest/FakeClient.pm`; symlink
  `t/lib/Plugins/ABCListen -> ../../../ABCListen`.
- Tests: `t/10-compile.t` (every `ABCListen/**/*.pm` compiles against the stubs); `t/11-util.t` (ISO-8601 offsets incl.
  DST-boundary dates in AEDT/ACST/AWST; display helpers with a fixed `TZ`; URL contract round-trip + invalid inputs;
  meta cache merge); `t/12-http.t` (UA set, never libwww; bad JSON / HTTP errors → error callback; `postJSON` body and
  headers; quiet); `t/13-plugin-feed.t` (all 5 hooks initialised; order Live, OnDemand, Discover, Search, MyABC; dying
  / non-calling hook → error item; timeout path with the fake clock).

**Quality gates**: `scripts/check.sh` (single middle-loop command, as REF): compile check; `prove -lr -It/lib t`;
`xmllint --noout` on `ABCListen/install.xml` (and `repo.xml` when present); `scripts/lint-strings.pl` (tab format, every
`PLUGIN_ABCLISTEN*` token used in code/templates is defined, no duplicates); shellcheck on `scripts/*.sh` (skip with a
notice if missing locally). `.github/workflows/ci.yml` installs `libxml2-utils liburi-perl libhtml-parser-perl zip unzip
shellcheck curl jq` and runs check.sh on PRs and `main`.

**Runtime demo** (testbed lock): `dev/link-plugin.sh --restart`; `["pref","plugin.state:ABCListen","?"]` → `enabled`;
`["radios",0,50]` lists "ABC listen"; `["abclisten","items",0,50]` → "Radio"; drill in → 5 stations; play triple j →
`mode=play`, `time` advancing over 10 s; Default skin screenshot of Radio → ABC listen → Radio (icon visible);
`server.log` has no `plugin.abclisten` errors. JSON-RPC with `menu:1` shows the same items.

### F2 — `abclisten://` protocol handler framework
- `ProtocolHandler.pm` (base `Slim::Player::Protocols::HTTPS`; model REF `RTRFM/ProtocolHandler.pm` and core
  `Slim::Plugin::Podcast::ProtocolHandler`, rules in `DEVELOPERS.txt:75-104`):
  - `registerKind($kind, \%impl)` per `streams.md` contract 4; unknown kind / unparseable URL → error
    `PLUGIN_ABCLISTEN_BAD_URL`; unregistered kind (e.g. `episode` before O1) → `PLUGIN_ABCLISTEN_UNAVAILABLE`.
  - `scanUrl`: parse → `resolve` → wrapped callback (never captures `$args`): `$song->streamUrl($real)`, title from
    `getMetadataFor`, `$track->cover(0)`, restore `$track->url($ourUrl)`, bump `currentPlaylistUpdateTime`; then
    `SUPER::scanUrl($real, $args)`. If the scan fails, retry with each `alternates` URL in order; if all fail, report
    `failToken` (or `PLUGIN_ABCLISTEN_STREAM_FAILED`). Never hand LMS an `.m3u8` (assert in code: skip candidates
    matching `\.m3u8(\?|$)` unless the kind marks the candidate `hls => 1`, which only L5 does).
  - `new`: `$args->{url} = $song->streamUrl unless $args->{redir}` (avoids the proxied-streaming redirect loop).
  - `getMetadataFor($class, $client, $url, $forceCurrent)`: dispatch to the kind's `metadata`; fallback
    `{title => <display name>, cover => ICON}`; synchronous, no network, never dies. `getCurrentTitle` returns the same
    title. `isRemote` 1; `getIcon` → ICON.
  - `onStream`/`onStop` → dispatch to the kind's optional hooks (used by L2/L3 polling, O4); kind hooks run in `eval`.
  - Never calls `$song->duration`, `$song->startOffset` or `setCurrentTitle($url,$t,$client)` itself.
- Slice update: `Live.pm` stub switches its 5 items to `Util::liveUrl(<ID>)` and registers a `live` kind backed by its
  mini table (resolve → Icecast URL; metadata → station name + logo). L1 replaces both.
- Tests `t/14-protocol-handler.t`: URL parsing; resolve success → `SUPER::scanUrl` called with real URL and the wrapped
  callback restores our URL; resolve error → error token; alternates tried in order; all failing → `failToken`;
  `.m3u8` candidate rejected; metadata dispatch + fallback; `new` with/without `redir`; exceptions in kind code never
  escape.
- Runtime: the 5 stations now play via `abclisten://live/<ID>`; `status` shows station title and `artwork_url`; save one
  as a favourite in the Default skin, `dev/restart-lms.sh`, replay from Favourites; proxied mode
  (`["playerpref","mp3StreamingMethod","1"]`) also plays; `["playlist","play","abclisten://episode/1"]` and
  `abclisten://live/NOPE` give a clean message, no crash, clean `server.log`.

### F3 — ABC data client
- `API.pm` (data layer, no menu code), all async via `HTTP.pm`, exactly one callback, contract 5 in `streams.md`:
  - `bff($path, \%query, $cb, $ecb, \%opts)` → `https://www.abc.net.au/core-next/api/<path>`.
  - `siteConfig($cb, $ecb)` → `{buildId, algolia => {appId, apiKey, indexName}}` scraped from
    `https://www.abc.net.au/listen/search` (`"buildId":"…"`, `__NEXT_DATA__` Search component `client.{appId,apiKey}`,
    `indexName`); cached 6 h; coalesced.
  - `nextData($pagePath, $cb, $ecb, \%opts)` → `/_next/data/<buildId><path>.json` → `pageProps`; on 404/HTML →
    re-discover buildId **once** and retry; follow `pageProps.__N_REDIRECT` (≤ 2 hops).
  - `algolia(\%params, $cb, $ecb, \%opts)` → POST `https://<appId>-dsn.algolia.net/1/indexes/<index>/query` with
    `X-Algolia-Application-Id`/`X-Algolia-API-Key` headers; result cache keyed by canonical params (default TTL 1 h);
    rolling hourly budget (300/h) → `{error => 'PLUGIN_ABCLISTEN_RATE_LIMITED'}` without a request; 401/403 →
    re-discover key once.
  - `papi($path, \%query, …)` → `https://program.abcradio.net.au/api/v1/…`; `music($path, \%query, …)` →
    `https://music.abcradio.net.au/api/v1/…`; `text($url, …)` (for `.pls`).
  - Caching via `Slim::Utils::Cache` namespace `abclisten` with caller TTLs; identical in-flight requests coalesced;
    `stale_ok` returns last-good data on error (logged once at WARN, then DEBUG).
  - Pure helpers: `imageUrl($preparedOrUrl, $px)` (wcms: keep crop params, set `width`/`height`; never strip crop
    params; `resize.abcradio.net.au`: pick nearest `srcSet` size; other URLs unchanged); `richText($descriptor)`
    (flatten `type:"text"` nodes, paragraph breaks); `coreMediaRef('coremedia://program/123')` → `('program', 123)`;
    `cardRef($card)` → `{type, id, uriId, title, tagline, path, image, date, duration, programId, docType, description}`
    (`id` = `cardId` when numeric, else the `articleLink` leaf, else the `contentUri` id — curated `contentUri` ids are
    often teaser ids, some dynamic; program cards: name from `cardImagePrepared.alt` when `cardTitle` is an editorial
    tagline — FQ4); `sitePath($absOrRelUrl)` (accepts `www.abc.net.au` and `abc.net.au`).
- `scripts/abc-endpoints-check.sh` (bash + curl + jq; manual, never in CI): one request per endpoint family (listen
  search page/buildId, a `_next/data` program page, `episodesWithSegments`, `collection`, `epgNowPlaying`,
  `musicNowPlaying`/music API, `schedule`, PAPI services, Algolia query, one `.pls`) asserting the JSON paths our
  parsers rely on; prints PASS/FAIL per family. Used by the orchestrator to detect ABC drift.
- Fixtures `t/data/foundation/`: copied from `research/abc-samples/` + a trimmed recorded `/listen/search` HTML +
  synthetic (stale-buildId 404 HTML, `__N_REDIRECT`, bad JSON, Algolia 403/429, empty collections).
- Tests `t/15-api.t` (buildId discovery and exactly-one retry; redirect follow; Algolia headers, cache, budget, key
  re-discovery; coalescing; `stale_ok`; one-callback on every path), `t/16-api-helpers.t` (image rewriting incl.
  "crop params kept", srcSet pick; rich text; card normalisation for program, audioepisode, audio, audiosegment,
  collection, dynamiccollection, channel and teaser cards).
- Runtime: no user-visible change. Verification = `scripts/abc-endpoints-check.sh` all PASS from the container (through
  `$HTTPS_PROXY`) + `scripts/check.sh` green; L1/O2 exercise `API.pm` in LMS.

## Integration points
- **Hook API (frozen in F1)**: Live (L1–L5; top-level Radio), OnDemand (O1–O4; Programs), Discover (D1, D2, D4, D5;
  Home, Podcasts, News, Sport, Kids listen, Audiobooks), Search (D3; Search), MyABC (M1–M2; My ABC listen). Each
  declares `menuWeights()` for its `Util::topWeight` names.
- **PH registry (frozen in F2)**: `live` kind from `Live->init` (F2 stub → L1/L2/L3/L5), `episode` kind from
  `Episode->init` (called by `OnDemand->init`; O1, O4). L5 relies on `alternates` + `hls` candidate flag; O1 relies on `failToken` for the geo
  message.
- **`API.pm` (F3)**: every data module (Stations, NowPlaying, Tracks, Schedule, Programs, Episode, ProgramIndex,
  Collections, Search, Follow). `cardRef` is the shared card normaliser for O2, D1, D2, M2.
- **`Util.pm`**: URL contract (all), episode meta cache (O1–O4, D1–D3, M2), date helpers (L2, L4, O2, M2).
- **Test harness**: shared by every stream; new stub files allowed, existing stubs additive only.
- **Release**: R1 appends package checks to `scripts/check.sh`/`ci.yml`; R2 documents behaviour. Feature tasks never
  bump `<version>`.
- **Strings** (pre-seeded by F1): F1 `PLUGIN_ABCLISTEN`, `PLUGIN_ABCLISTEN_DESC`, `PLUGIN_ABCLISTEN_ERROR`; F2
  `PLUGIN_ABCLISTEN_BAD_URL`, `PLUGIN_ABCLISTEN_UNAVAILABLE`, `PLUGIN_ABCLISTEN_STREAM_FAILED`; F3
  `PLUGIN_ABCLISTEN_RATE_LIMITED`, `PLUGIN_ABCLISTEN_LOAD_FAILED`. F1 also uses L1's pre-seeded
  `PLUGIN_ABCLISTEN_LIVE_RADIO`.

## Out of scope
- Packaging, `repo.xml`, release workflow, README/docs (release stream).
- Settings page and prefs UI (M1); any ABC login/credential handling (OPEN-QUESTIONS #1).
- Non-EN languages; Radio-vs-My-Apps placement toggle; menu customisation.
- CI tests against live ABC endpoints (fixtures only; the drift probe is manual); runtime testing on LMS 8.x.
- HLS playback of any kind (L5 hands HLS to PlayHLS only; own handler is stretch L6).

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| FQ1 | Icon: ABC/ABC listen logo (trademark) or a neutral self-made icon? | Neutral self-made 512×512 icon evoking radio/"listen" (no ABC lissajous); README says unofficial; stakeholder may swap. | F1 (non-blocking) |
| FQ2 | `minVersion` 8.3 or 8.0? ABC on-demand is MP3/ADTS only (no M4A), so 8.0 may work. | 8.3 (research guide), README says "tested on 9.1.x"; lower later if a user confirms 8.x. | F1 |
| FQ3 | Commit ABC's public search-only Algolia key as a fallback constant? | No — runtime discovery from `/listen/search` only (brief: no credentials committed); search shows `LOAD_FAILED` if discovery breaks. | F3 |
| FQ4 | Program cards: `cardTitle` is often an editorial tagline. Use `cardImagePrepared.alt` as the program name? | Yes when type is program and alt is non-empty and not a generic "logo" phrase; otherwise use `cardTitle`; tagline kept as `tagline`. Consumers may resolve the real name lazily via program Next data. | F3, D1 |
| FQ5 | Where do slice station logos come from before L1? | Crop-param wcms URLs from `bff-collection-national-networks.json`; else plugin icon. | F1 |

## Changelog
- 2026-10-19 — Initial master plan (stream-planning sub-agent).
- 2026-10-19 — F1 amended in flight (stakeholder: top level mirrors the ABC listen app): weighted top-level ordering
  (`weight`, `Util::topWeight`, optional `menuWeights()` for failing-hook placement, several items per hook), "Live radio"
  → "Radio", top-level strings seeded (Home, Radio, News, Kids listen, Audiobooks, Programs (A–Z); `_SEARCH` now
  "Search"; 95 tokens); contract 1 in `streams.md` updated to match PR #21. F3: `cardRef` id = `cardId` (curated teaser
  ids, some dynamic) + `uriId`; `sitePath` accepts `abc.net.au` without `www` (section-page probe, research §6.1; #7
  amended). Plan-revision sub-agent.
