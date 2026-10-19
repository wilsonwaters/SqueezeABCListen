# Master Plan — discovery

## Goal
Users explore ABC listen the way the **ABC listen app** presents it (stakeholder direction 2026-10-19), without knowing a
program name. The discovery stream owns six of the ten top-level entries:
- **Home** — the home page's featured carousel and curated collections (Today's Top Picks, Most Popular Podcasts, True
  Crime & Investigations, Relax & Sleep, …) plus **Popular now** (This Week's Most Listened) and Popular in sport.
- **Podcasts** — the podcasts page collections, the 8 **podcast categories** and All podcasts A–Z (prominent, per the
  stakeholder).
- **News, Sport, Kids listen, Audiobooks** — the ABC section pages: each section's live station(s), curated collections
  and programs. **Kids listen is a full section**: the Kids listen live station, the Kids listen page's collections, all
  Kids listen programs with episodes, Kids & Families podcasts, Books for Kids and News Time.
- **Search** — programs and directly playable episodes, also inside LMS's global search.

Audiobook programs, which ABC's website shows without chapters, get a **Chapters** list (D5) wherever they appear. Every
card becomes the same program/episode/station item the rest of the plugin uses (ondemand builders, live `stationItem`),
so playback, favourites and follows behave identically everywhere.

Top level (contract 1, ordered by `Util::topWeight`): Home 10 · Radio 20 (live) · Podcasts 30 · News 40 · Sport 50 ·
Kids listen 60 · Audiobooks 70 · Programs 75 (ondemand) · Search 80 · My ABC listen 90 (myabc).

## Contracts used / provided
- Uses: hook API (`Discover` and `Search` hooks; `weight`, `Util::topWeight`, `menuWeights`), `API.pm` (`nextData`,
  `bff`, `algolia`, `cardRef` with `cardId` ids, `imageUrl`, `sitePath`), ondemand builders `programItem`/`episodeItem`
  and `registerProgramMenuProvider` (O2), `programsByType` (O3, soft), live `Live->stationItem` +
  `Stations->byPageSlug` (L1, soft), episode meta cache (D3 and D5 seed `renditions` for O1).
- Provides: `Collections->page($path, $cb)`, `Collections->items($collectionId, $offset, $size, $cb)` and
  `Collections->itemFor($client, $cardRef)` (card → OPML item dispatcher); `Sections->topItems`/`menuWeights` (D4);
  `Audiobooks->chapters($programId, $cb)` (D5) — reusable by M2 or later features.

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| D1 | Collection engine (`Collections.pm`: generic `page($path)` Next data → collections → paged cards → typed items) + top-level **Home**: Featured (hero) and every home collection | M | F3, O2 (soft L1, O1) | planned (#5) |
| D2 | Top-level **Podcasts** menu (podcast collections, **Browse by category** → 8 categories, **All podcasts A–Z** via O3) + **Popular now** / Popular in sport in Home | M | D1 (soft O3) | planned (#6) |
| D3 | Top-level **Search** (`Search.pm`, Algolia programs + playable episodes, cached, budget-aware) + `Slim::Menu::GlobalSearch` provider | M | F3, O2 (soft O1) | planned (#13) |
| D4 | Section menus **News, Sport, Kids listen** (full section), **Audiobooks**: four top-level items rendered from the ABC section pages by D1's engine (+ MetaCollection, program aggregation and live-station components) plus static extras | M (upper) | D1 (soft L1, O1, O3, D5) | planned (#22) |
| D5 | **Audiobook chapters**: `Audiobooks.pm` lists a book's chapters from Algolia (reading order, seeded renditions) as a **Chapters** link in every audiobook program menu via O2's registry; Play all | M (lower) | O2 (soft O1; a route via D3/O3/D4) | planned (#23) |

D1 and D3 run in parallel (separate hooks/modules); D2 and D4 follow D1 (wave 4; both append to `Discover.pm`'s
`menuItems`/`menuWeights`, so the second to merge rebases); D5 needs only O2 plus any merged route to a book (wave 4).

### D1 — collection engine + Home → Featured / home collections
- **`Collections.pm`** (data + dispatcher, no top-level menu code):
  - `page($path, $cb)` → `API::nextData($path)` → `pageProps.data.componentsContent[]` in page order → `{hero =>
    [cards], collections => [{id, title, image}]}` from `HeroCarousel` and `StandardCollection` blocks; unknown
    components skipped (DEBUG once). Cache 1 h per path, `stale_ok`. `home($cb)` = `page('/listen', $cb)` (ids like
    103194114 Today's Top Picks, 103194120 Most Popular Podcasts, 103194124 True Crime, 106728212 Relax & Sleep);
    `LiveRadioCarousel` and `RecommendationsExperiment` skipped (Radio and D2 cover them); video-only collections
    skipped (DQ1). D4 extends `page()` with more component types; Home ignores keys it doesn't know.
  - `items($id, $offset, $size, $cb)` → `API::bff('collection/x', {collectionId, offset, size})` → `{title, total,
    cards}`; cache 30 min.
  - `itemFor($client, $card)` (cards normalised by `API::cardRef`; **ids are `cardId`**, never teaser `contentUri` ids):
    program → `OnDemand->programItem` (name per FQ4 + lazy program-name lookup, tagline as description);
    `audioepisode`/`audio`/`audiosegment` → `OnDemand->episodeItem`; `collection` → nested link; `dynamiccollection` →
    nested link by `articleLink` leaf id (max depth 3); `channel` and `externallink` cards to `/live/` → `Live->stationItem`
    via `Stations->byPageSlug` (skip if live API absent; `abc.net.au` without `www` accepted); teaser → by `articleLink`
    shape (`/programs/<slug>/` → program, `/<id>` leaf → episode); `article`/`video`/`person`/unknown → skipped (DEBUG).
- **`Discover.pm`** (rewrite of the F1 stub): `menuItems` → one link **Home** (`PLUGIN_ABCLISTEN_HOME`, `weight =>
  topWeight('home')`), no network I/O; `menuWeights` → `(topWeight('home'))`. Home → **Featured** (hero cards) then one
  link per home collection (title, first card's image) → items (20 per page, **More…** while `total` exceeds loaded).
  Empty collection → "Nothing here right now"; errors → `PLUGIN_ABCLISTEN_LOAD_FAILED`; exactly one callback.
- **Tests** `t/40-collections.t` (fresh `/listen` capture, `bff-collection-home-most-popular-podcasts`,
  `nextdata-listen-radio.metacollections.trimmed` for channel cards, a `cardId` ≠ `contentUri` card from
  `nextdata-section-news.trimmed` + synthetic: unknown component types, teaser cards, video cards, empty/oversized
  pagination; `page('/listen')` == `home()`; dispatcher calls the right builder with the right args),
  `t/41-discover-menu.t` (Home item keys incl. `weight`, `menuWeights`, menu shapes, More… paging, depth limit, failure
  isolation).
- **Runtime**: Default + Material: Home → Most Popular Podcasts → a program → episodes → play (O1); Today's Top Picks →
  an episode plays directly; Featured lists the hero items; `menu:1` shapes; clean `server.log`. **pi14**: collections
  as seen from Australia (`ABC_LD`) may differ — note only.

### D2 — Podcasts top-level menu, Popular now in Home
- **Popular now**: `API::bff('recommendations/listen/homepagePopularNow')` (title "This Week's Most Listened", ~24
  cards) → `Collections->itemFor`; cache 1 h. **Popular in sport** (`homepageSports`, 20 audio cards on 2026-10-19; DQ5).
- **Categories**: `API::nextData('/listen/podcasts')` → Categories collection (14123152) → 8 category cards (News &
  Analysis 104142082, True Crime 104142226, Sport 104142200, Kids & Families 104141842, History 104141924, Society &
  Culture 104142164, Music 104142058, Conversations & Storytelling 104141814; static fallback) → `Collections->items(<page
  id>)` paging → programs (category-page `nextData` fallback).
- **Podcasts collections**: podcasts page MetaCollection 106118844 → sub-collections (New & Noteworthy 105492374, Most
  Popular Podcasts 103470928, Award Winning Podcasts 11511926) via `collection/x` (works with or without
  `rootMetaCollectionId`).
- **Top-level "Podcasts" menu** (stakeholder: podcasts prominent and browsable): `name => PLUGIN_ABCLISTEN_PODCASTS`,
  `weight => topWeight('podcasts')`. Contains, in order: New & Noteworthy, Most Popular Podcasts, Award Winning Podcasts,
  **Browse by category** (the 8 categories), **All podcasts A–Z** (O3's `programsByType(…, 'podcast')`; omitted if O3's
  function is absent). Every podcast program opens O2's program → episodes menu.
- **Home root** (owned from now on): Featured, **Popular now**, **Popular in sport**, then D1's home collections minus
  the home "Categories" collection. `Discover->menuItems` returns Home and Podcasts; `menuWeights` adds `podcasts`.
- **Tests** `t/42-categories.t` (podcasts-page and category-page fixtures recorded by D2; static-id fallback),
  `t/43-recommendations.t` (fixture `bff-recommendations-homepagePopularNow`; card dispatch; empty response), `t/41`
  additions (both top-level items, weights, Home root order).
- **Runtime**: Podcasts → Browse by category → True Crime → program → episode plays; Home → Popular now lists ~24 items
  with durations and plays one; Podcasts → New & Noteworthy non-empty; Default + Material screenshots.

### D3 — Search + LMS global search
- **`Search.pm`** hook (rewrite of F1 stub): `menuItems` → `{name => PLUGIN_ABCLISTEN_SEARCH ("Search"), type =>
  'search', url => \&_search, weight => topWeight('search')}`; `menuWeights` → `(topWeight('search'))`;
  `_search($client, $cb, $args)` reads `$args->{search}`; empty → no request.
- Query: two parallel `API::algolia` calls (20 programs + 40 episodes; see #13) with site segments listen, triplej,
  kidslisten, triplejunearthed, pacific (DQ3); result cache 1 h per normalised query.
- Results: **Programs (N)** → `programItem`; **Episodes (N)** → `episodeItem`, seeding the meta cache with `renditions`,
  `availableTo`/`downloadAvailableTo` and `seenAt` so O1 can skip the page fetch; hide hits whose download **and**
  streaming status are `EXPIRED`/`NONE` (keep `PENDING`). No results → "No results for '<q>'"; budget exhausted →
  `PLUGIN_ABCLISTEN_RATE_LIMITED` text. Audiobook chapters appear as episode hits (`/geo-001/`).
- **Global search**: in `Search->init`, `Slim::Menu::GlobalSearch->registerInfoProvider(abclisten => …)` returning an
  "ABC listen" link that runs the same search for `$tags->{search}` (shares the result cache; no query until opened).
- **Tests** `t/44-search.t`, `t/45-global-search.t` (as #13).
- **Runtime**: JSON-RPC search returns programs and episodes; Default skin plugin search and Material global search show
  ABC listen results; playing an episode result makes no page fetch (egress log shows only the media host).

### D4 — section menus: News, Sport, Kids listen, Audiobooks
Probe 2026-10-19 (research §6.1; fixtures `abc-samples/nextdata-section-*.trimmed.json`): every section page is
`componentsContent[]` like Home, so D1's engine renders them with four extra component types; Radio's page holds only
station collections, so the Radio menu needs nothing from D4.
- **`Collections->page()` extensions** (additive): `MetaCollection` → its non-empty sub-collections (`itemsCount` > 0)
  as collections, paged by `items()` (no `rootMetaCollectionId` needed); `ProgramAggregationCollection` → collection with
  `kind => 'aggregation'` paged by `bff('programAggregationCollection/x')`; `MiniEPG` and `LiveRadioCarousel` (cards in
  `componentProps.cards[]`) → `stations => [{serviceId => uc(papiServiceId), title, start, end}]`; skip `Promo`,
  `AppStoreCTA`, `AppOnwardJourney`, `TeaserNavigator`, `Tracklist`; an untitled StandardCollection is named "Featured".
- **`Sections.pm`** (new): `topItems($client)` → News (`PLUGIN_ABCLISTEN_NEWS`, 40), Sport (`PLUGIN_ABCLISTEN_SPORT`,
  50), Kids listen (`PLUGIN_ABCLISTEN_KIDS`, 60), Audiobooks (`PLUGIN_ABCLISTEN_AUDIOBOOKS`, 70); `menuWeights`; appended
  by `Discover->menuItems`/`menuWeights`. Each section menu = live stations (`Live->stationItem`, undef → omitted) →
  page collections in page order → static extras; page failure → stations + extras + `LOAD_FAILED`.

  | Section | Page | Live | Extras |
  |---|---|---|---|
  | News | `/listen/news` (MiniEPG + 9 collections) | ABC NewsRadio (`NEWS`) | – |
  | Sport | `/listen/sport` ("Radio Stations" inline as station rows, Live & Upcoming Events link, 5 collections) | ABC SPORT, SPORT EXTRA, World Cup, AFLW (HLS-only ones hidden unless L5 `hls`) | – |
  | Kids listen | `/kidslisten` (untitled hero → Featured, Latest Programs) | ABC KIDS listen (`KIDSLISTEN`, Icecast `abcextra`); variants only if `stationItem` defined | All Kids listen programs (aggregation 9317914, 34), Kids & Families podcasts (104141842, 52), Books for Kids (106510880), News Time |
  | Audiobooks | `/listen/audiobooks` (MetaCollection 105894152: 9 non-empty sub-collections) | – | All audiobooks A–Z (O3 `programsByType(…, 'audiobook')`, soft), "Audiobooks play only in Australia." note |

- **Tests** `t/46-sections.t` (page parsing of the five section fixtures; Home unchanged), `t/47-section-menus.t` (top
  items + weights; row order; stationItem undef; Kids variants; Sport events; O3 absent; failure path; one callback).
- **Runtime**: top-level order; News: NewsRadio plays, a `/news/…` audio item plays; Sport: ABC SPORT plays, Programs →
  ABC Cricket Podcast; Kids listen: ABC KIDS listen plays, Latest Programs episode plays, all programs (~34), Kids &
  Families podcasts (52), Books for Kids, News Time; Audiobooks: sub-collections + A–Z + note; Default + Material
  screenshots of the top level and the four sections.

### D5 — audiobook chapters
Probe 2026-10-19: ABC's website lists **no chapters** for audiobooks — book pages have `programTemplate: audiobook` (or
`default`), `webDistributionRestricted: true`, `programCollectionPrepared: null`; chapter pages 308 to the book. Chapters
are in Algolia (`contentType:audioepisode AND programID=<id>`, numeric filter), `/geo-001/` MP3, 1-year window, reading
order = ascending id (30 chapters for *The Dictionary of Lost Words*; 20 audiobooks).
- **`Audiobooks.pm`** (new): `isAudiobook($program)` (template audiobook, or restricted with no episode collection, or
  `/listen/audiobooks/` path); `chapters($programId, $cb)` → one Algolia query per book per day (`ttl` 24 h, `stale_ok`)
  → contract-3 refs with seeded `renditions`/availability/`seenAt`, expired-status filter, ascending id.
- Registered in `Audiobooks->init` (called from `Discover->init`) as an O2 program-menu provider: for audiobooks one
  **Chapters** link (`Chapters (N)` when cached; no network in the provider), `type => 'playlist'` (Play all / Add all)
  → rows via `episodeItem`, named `"<n>. <title>"`. O2 hides "No episodes available" for restricted programs without a
  collection; O1 re-resolves chapters via Algolia after the 6 h seeded window.
- **Tests** `t/48-audiobooks.t`. **Runtime**: a book shows Chapters; count = Algolia `nbHits`; reading order; `playlist
  add` queues N in order; chapter play → O1 geo message with no `_next/data` fetch; non-book has no Chapters; second
  open within 24 h makes no Algolia request. **pi14**: a chapter plays, seeks, Play all continues.

## Integration points
- **F1 hook API**: `Discover` and `Search` are separate hooks. `Discover->menuItems` returns Home (D1), Podcasts (D2),
  News, Sport, Kids listen, Audiobooks (D4); `Search->menuItems` returns Search (D3); each declares `menuWeights`.
  `Search->init` registers the global-search provider; `Discover->init` calls `Audiobooks->init` (D5). Discovery never
  edits `Plugin.pm`.
- **F3 `API.pm`**: `nextData` (home, podcasts, category and section pages), `bff` (collections, program aggregations,
  recommendations), `algolia` (D3; D5 ≤ 1 query/book/day; shares the 300/h budget with O3's ≤ 1/day), `cardRef` (FQ4
  naming; `cardId` ids), `sitePath` (`abc.net.au` host variants).
- **ondemand (hard)**: all program/episode items via `programItem`/`episodeItem`; never builds `abclisten://` URLs
  itself; D3's and D5's seeded `renditions` are honoured by O1 (contract 3); D5 plugs into the program-menu registry
  (provider input incl. `template`/`restricted`/`id`, O2 #16 amendment); O3's `programsByType` feeds Podcasts → All
  podcasts A–Z (D2) and Audiobooks → All audiobooks A–Z (D4).
- **live (soft)**: station cards and section stations via `Stations->byPageSlug` + `Live->stationItem` (contract 7);
  skipped gracefully if absent; D4 may override `line2`/`description` on copies (Sport events).
- **myabc**: programs reached from Home/Podcasts/sections/Search show M2's Follow item automatically (program-menu
  registry); audiobook menus show Chapters (D5) before Follow.
- **Release**: R2's `smoke.sh` checks the 10-entry top level, Home has ≥ 1 non-empty collection, Podcasts and the four
  sections are non-empty, the Kids listen live station plays, and search returns ≥ 1 program and episode.
- **Strings** (pre-seeded by F1): F1 top-level names `PLUGIN_ABCLISTEN_HOME`, `_NEWS`, `_KIDS`, `_AUDIOBOOKS` (and L1's
  `_SPORT`, D2's `_PODCASTS`, D3's `_SEARCH` = "Search"); D1 `PLUGIN_ABCLISTEN_DISCOVER` (unused), `_FEATURED`,
  `_MORE`, `_EMPTY_COLLECTION`; D2 `_POPULAR_NOW`, `_CATEGORIES`, `_PODCASTS` (+ `_POPULAR_SPORT`); D3 `_SEARCH`,
  `_SEARCH_PROGRAMS`, `_SEARCH_EPISODES`, `_NO_RESULTS`, `_GLOBAL_SEARCH_TITLE`. New sections appended by later tasks:
  D4 `PLUGIN_ABCLISTEN_KIDS_PROGRAMS`, `_KIDS_PODCASTS`, `_AUDIOBOOKS_AZ`, `_AUDIOBOOKS_AU_ONLY`; D5
  `PLUGIN_ABCLISTEN_CHAPTERS`, `_CHAPTERS_N`.

## Out of scope
- Personalised recommendations (need `ABCAccountID` cookies / login), "Continue listening".
- Query suggestions (`listen_prod_all_query_suggestions`), recent searches, Material CLI extras.
- Video podcasts, news articles, non-audio cards; Terminus/Algolia app-index keys from the mobile app.
- Material Skin Home Extras rows and Don't Stop The Music handlers — candidate follow-ups.
- Network home pages (`/listen/radionational`, `/listen/classic`, …) as separate sections — candidate follow-up (the
  engine supports it). Sport's `/listen/sport/epg` schedule, the Kids listen Tracklist/About/FAQ pages.
- Working around `/geo-001/` (audiobooks play only in Australia).

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| DQ1 | Which home components to show? | HeroCarousel → Featured; every `StandardCollection` in page order except video-only ones (D2 drops the home "Categories" duplicate); LiveRadioCarousel and RecommendationsExperiment omitted from Home's collection list (Radio, D2 cover them). | D1 |
| DQ2 | Card naming (taglines vs program names). | FQ4 rule from F3 (`cardImagePrepared.alt` for program cards); tagline shown as description; D1 lazy name lookup. | D1 |
| DQ3 | Search scope beyond ABC listen proper? | Include triple j, Kids listen, Unearthed, Pacific site segments (same as A–Z). | D3 |
| DQ4 | Show search hits whose audio has expired? | Hide when both download and streaming statuses are EXPIRED/NONE; keep PENDING (index lag). | D3, D5 |
| DQ5 | Add "Popular in sport" (`homepageSports`)? | Yes (endpoint returned 20 audio cards on 2026-10-19); in Home. | D2 |
| DQ6 | Result page size. | 20 programs + 40 episodes, no paging (each extra page costs Algolia budget). | D3 |
| DQ7 | Audiobooks: ABC's web marks them `webDistributionRestricted` (AU-only rights, app-only). List and play them? | Yes: list (D4) and play where the `/geo-001/` CDN allows (Australia); container shows O1's geo message. Stakeholder to confirm (OPEN-QUESTIONS #5). | D4, D5 |
| DQ8 | What makes Kids listen a "full section"? | Live station + the `/kidslisten` page collections + All Kids listen programs (aggregation 9317914) + Kids & Families podcasts + Books for Kids + News Time (the site nav's program links); Tracklist/About/FAQ skipped. | D4 |
| DQ9 | Should Radio show `/listen/radio`'s program collections? | Resolved: the page has none (only national/local station MetaCollections), so Radio stays L1's station tree; no section-extras registry. | – |

## Changelog
- 2026-10-19 — Initial master plan (stream-planning sub-agent).
- 2026-10-19 — D2: Podcasts promoted to a top-level menu (collections, categories, A–Z via O3) at stakeholder request;
  Discover keeps Featured, Popular now and home collections.
- 2026-10-19 — Stakeholder: top level mirrors the ABC listen app. Discover → **Home** (D1, `topWeight('home')`, generic
  `page($path)` parser); D2 = top-level Podcasts + Popular now/Popular in sport in Home; D3 = top-level **Search**
  (`topWeight('search')`); every hook declares `menuWeights`. Section pages probed live (research §6.1): new **D4** (#22)
  section menus News/Sport/Kids listen (full section)/Audiobooks; split out **D5** (#23) audiobook chapters because ABC's
  web has no chapter list (Algolia only). `cardRef` ids now `cardId` (teaser ids, some dynamic). Plan-revision sub-agent.
