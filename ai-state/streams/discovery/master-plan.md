# Master Plan — discovery

## Goal
Users explore ABC listen the way abc.net.au/listen presents it, without knowing a program name: **Discover** shows the
home page's featured carousel and curated collections (Today's Top Picks, Most Popular Podcasts, True Crime &
Investigations, Relax & Sleep, …), **Popular now** (This Week's Most Listened), the 8 **podcast categories** and the
podcasts page collections; **Search ABC listen** finds programs and directly playable episodes, and ABC listen results
also appear in LMS's global search. Every card becomes the same program/episode/station item the rest of the plugin
uses (ondemand builders, live `stationItem`), so playback, favourites and follows behave identically everywhere.

## Contracts used / provided
- Uses: hook API (`Discover` and `Search` hooks), `API.pm` (`nextData`, `bff`, `algolia`, `cardRef`, `imageUrl`),
  ondemand builders `programItem`/`episodeItem` (O2), live `Live->stationItem` + `Stations->byPageSlug` (L1, soft),
  episode meta cache (D3 seeds `renditions` for O1).
- Provides: `Collections->items($collectionId, $offset, $size, $cb)` and `Collections->itemFor($client, $cardRef)` (card
  → OPML item dispatcher) — reusable by M2 or later features.

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| D1 | Collection engine (`Collections.pm`: home Next data → collections → paged cards → typed items) + **Discover** menu: Featured (hero) and every home collection | M | F3, O2 (soft L1, O1) | planned |
| D2 | **Popular now** (recommendations), **Categories** (8 podcast categories → programs), **Podcasts** collections (New & Noteworthy, Most Popular, Award Winning) in Discover | M | D1 | planned |
| D3 | **Search ABC listen** (`Search.pm`, Algolia programs + playable episodes, cached, budget-aware) + `Slim::Menu::GlobalSearch` provider | M | F3, O2 (soft O1) | planned |

D1 and D3 run in parallel (separate hooks/modules); D2 follows D1.

### D1 — collection engine + Discover → Featured / home collections
- **`Collections.pm`** (data + dispatcher, no top-level menu code):
  - `home($cb)` → `API::nextData('/listen')` → `pageProps.data.componentsContent[]` in page order → `{hero => [cards],
    collections => [{id, title}]}` from `HeroCarousel` and `StandardCollection` blocks (ids like 103194114 Today's Top
    Picks, 103194120 Most Popular Podcasts, 103194124 True Crime, 106728212 Relax & Sleep); `LiveRadioCarousel` and
    `RecommendationsExperiment` skipped (Live radio and D2 cover them); video-only collections skipped (DQ1). Cache 1 h,
    `stale_ok`.
  - `items($id, $offset, $size, $cb)` → `API::bff('collection/x', {collectionId, offset, size})` → `{title, total,
    cards}`; cache 30 min.
  - `itemFor($client, $card)` (cards normalised by `API::cardRef`): program → `OnDemand->programItem` (name per FQ4,
    tagline as description); `audioepisode`/`audio`/`audiosegment` → `OnDemand->episodeItem`; `collection`/
    `dynamiccollection` → nested collection link (max depth 3); `channel` → `Live->stationItem` via
    `Stations->byPageSlug` (skip if live API absent); teaser → by `articleLink` shape (`/programs/<slug>/` → program,
    `/<id>` leaf → episode); `article`/`video`/unknown → skipped (DEBUG log).
- **`Discover.pm`** (rewrite of the F1 stub): `menuItems` → one link **Discover** → **Featured** (hero cards) then one
  link per home collection (title, first card's image) → items (20 per page, **More…** while `total` exceeds loaded).
  Empty collection → "Nothing here right now"; errors → `PLUGIN_ABCLISTEN_LOAD_FAILED`; exactly one callback.
- **Tests** `t/40-collections.t` (fixtures `nextdata-listen-home.components.trimmed`, `bff-collection-home-most-popular-
  podcasts`, `nextdata-listen-radio.metacollections.trimmed` for channel cards + synthetic: unknown component types,
  teaser cards, video cards, empty/oversized pagination; dispatcher calls the right builder with the right args),
  `t/41-discover-menu.t` (menu shapes, More… paging, depth limit, failure isolation).
- **Runtime**: Default + Material: Discover → Most Popular Podcasts → a program → episodes → play (O1); Today's Top
  Picks → an episode plays directly; Featured lists the hero items; `menu:1` shapes; clean `server.log`. **pi14**:
  collections as seen from Australia (`ABC_LD`) may differ — note only.

### D2 — Popular now, Categories, Podcasts
- **Popular now**: `API::bff('recommendations/listen/homepagePopularNow')` (title "This Week's Most Listened", ~24
  cards) → `Collections->itemFor`; cache 1 h. (`homepageSports` optionally as "Popular in sport" — DQ5.)
- **Categories**: `API::nextData('/listen/podcasts')` → Categories collection (14123152) → 8 category cards (News &
  Analysis 104142082, True Crime 104142226, Sport 104142200, Kids & Families 104141842, History 104141924, Society &
  Culture 104142164, Music 104142058, Conversations & Storytelling 104141814; static fallback) → category page
  `nextData(<category path>)` → its `StandardCollection` (subaggregation) id → `Collections->items` paging → programs.
- **Podcasts**: podcasts page MetaCollection 106118844 → sub-collections (New & Noteworthy 105492374, Most Popular
  Podcasts, Award Winning Podcasts) via `bff('collection/x', {collectionId, rootMetaCollectionId => 106118844,
  metaInMeta => 'false'})`.
- **Discover root** (owned from now on): Featured, **Popular now**, **Categories**, **Podcasts**, then home collections.
- **Tests** `t/42-categories.t` (podcasts-page and category-page fixtures recorded by D2; static-id fallback),
  `t/43-recommendations.t` (fixture `bff-recommendations-homepagePopularNow`; card dispatch; empty response).
- **Runtime**: Discover → Categories → True Crime → program → episode plays; Popular now lists ~24 items with durations
  and plays one; Podcasts → New & Noteworthy non-empty; Default + Material screenshots.

### D3 — Search + LMS global search
- **`Search.pm`** hook (rewrite of F1 stub): `menuItems` → `{name => 'Search ABC listen', type => 'search', url =>
  \&_search}`; `_search($client, $cb, $args)` reads `$args->{search}`; empty → no request.
- Query: `API::algolia({query, hitsPerPage => 60, filters => '(contentType:program OR contentType:audioepisode OR
  contentType:audio OR contentType:audiosegment) AND (siteSegment:listen OR siteSegment:triplej OR
  siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific)'})`; result cache 1 h per normalised
  query (lower-cased, trimmed).
- Results: **Programs (N)** → `programItem` (title, canonical path, `defaultThumbnail` 1x1, network); **Episodes (N)** →
  `episodeItem` (relevance order; name with date; duration) and seed the meta cache with `renditions`
  (`mediaRenditions`), `availableTo`/`downloadAvailableTo` (`dates.*`) and `seenAt` so O1 can skip the page fetch;
  hide hits whose download **and** streaming status are `EXPIRED`/`NONE` (keep `PENDING`). No results → "No results
  for '<q>'"; budget exhausted → `PLUGIN_ABCLISTEN_RATE_LIMITED` text.
- **Global search**: in `Search->init`, `Slim::Menu::GlobalSearch->registerInfoProvider(abclisten => …)` returning an
  "ABC listen" link that runs the same search for `$tags->{search}` (shares the result cache).
- **Tests** `t/44-search.t` (fixture `algolia-listen_prod_all-query` + synthetic: no hits, only programs, expired/pending
  statuses, missing thumbnails; filters/body sent; cache hit avoids a second Algolia call; meta-cache seeding shape),
  `t/45-global-search.t` (provider registered; returns link; empty query).
- **Runtime**: JSON-RPC `["abclisten","items",0,20,"item_id:<search id>","search:science show"]` returns programs and
  episodes; Default skin plugin search box and LMS home search show ABC listen results (screenshots); Material search
  (global) shows the "ABC listen" section; playing an episode result works and its first play makes no page fetch
  (egress log shows only the media host).

## Integration points
- **F1 hook API**: `Discover` and `Search` are separate hooks (3rd and 4th top-level items); `Search->init` registers the
  global-search provider; discovery never edits `Plugin.pm`.
- **F3 `API.pm`**: `nextData` (home, podcasts, category pages), `bff` (collections, recommendations), `algolia` (D3,
  shares the 300/h budget with O3 — O3 uses ≤ 1 query/day), `cardRef` (FQ4 naming rule).
- **ondemand (hard)**: all program/episode items via `programItem`/`episodeItem`; never builds `abclisten://` URLs
  itself; D3's seeded `renditions` are honoured by O1 (contract 3).
- **live (soft)**: channel cards via `Stations->byPageSlug` + `Live->stationItem`; skipped gracefully if absent.
- **myabc**: programs reached from Discover/Search show M2's Follow item automatically (program-menu registry).
- **Release**: R2's `smoke.sh` checks Discover has ≥ 1 non-empty collection and search returns ≥ 1 program and episode.
- **Strings** (pre-seeded by F1): D1 `PLUGIN_ABCLISTEN_DISCOVER`, `PLUGIN_ABCLISTEN_FEATURED`, `PLUGIN_ABCLISTEN_MORE`,
  `PLUGIN_ABCLISTEN_EMPTY_COLLECTION`; D2 `PLUGIN_ABCLISTEN_POPULAR_NOW`, `PLUGIN_ABCLISTEN_CATEGORIES`,
  `PLUGIN_ABCLISTEN_PODCASTS`; D3 `PLUGIN_ABCLISTEN_SEARCH`, `PLUGIN_ABCLISTEN_SEARCH_PROGRAMS`,
  `PLUGIN_ABCLISTEN_SEARCH_EPISODES`, `PLUGIN_ABCLISTEN_NO_RESULTS`, `PLUGIN_ABCLISTEN_GLOBAL_SEARCH_TITLE`.

## Out of scope
- Personalised recommendations (need `ABCAccountID` cookies / login), "Continue listening".
- Query suggestions (`listen_prod_all_query_suggestions`), recent searches, Material CLI extras.
- Video podcasts, news articles, non-audio cards; Terminus/Algolia app-index keys from the mobile app.
- Material Skin Home Extras rows and Don't Stop The Music handlers — candidate follow-ups.
- Network home pages (`/listen/radionational`, `/kidslisten`, …) as separate Discover sections — candidate follow-up
  (the collection engine supports it).

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| DQ1 | Which home components to show? | HeroCarousel → Featured; every `StandardCollection` in page order except video-only ones; LiveRadioCarousel and RecommendationsExperiment omitted (Live radio, D2 cover them). | D1 |
| DQ2 | Card naming (taglines vs program names). | FQ4 rule from F3 (`cardImagePrepared.alt` for program cards); tagline shown as description. | D1 |
| DQ3 | Search scope beyond ABC listen proper? | Include triple j, Kids listen, Unearthed, Pacific site segments (same as A–Z). | D3 |
| DQ4 | Show search hits whose audio has expired? | Hide when both download and streaming statuses are EXPIRED/NONE; keep PENDING (index lag). | D3 |
| DQ5 | Add "Popular in sport" (`homepageSports`)? | Only if the endpoint returns audio cards at implementation time; otherwise skip. | D2 |
| DQ6 | Result page size. | ≤ 20 programs + ≤ 40 episodes, no paging (each extra page costs Algolia budget). | D3 |

## Changelog
- 2026-10-19 — Initial master plan (stream-planning sub-agent).
