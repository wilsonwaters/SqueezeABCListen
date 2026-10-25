# ABC listen: data sources for a Lyrion (LMS) plugin

Research date: 2026-10-19. Everything below was tested live from a cloud container unless marked otherwise. That container's egress geolocates to the **USA** (Cloudflare trace `loc=US`, Akamai edges in Chicago and Chantilly, ABC sets the cookie `ABC_LD=int` = "international"). It is **not** Hong Kong as first assumed. Anything marked "geo" was blocked from the US and should work from Australia, but that is untested.

Fixtures are in `ai-state/research/abc-samples/`. They are trimmed: arrays are cut to 2–4 items and each file is under 30 KB. Helper scripts are in the session scratchpad, not in the repo.

---

## 1. Summary: recommended data-source strategy

1. **No login is needed for any audio.** ABC accounts (Gigya / SAP Customer Data Cloud) only sync follows and history and unlock app features (§10). Build the plugin anonymously.
2. **Stations.** Use two sources and join them:
   - **PAPI** `https://program.abcradio.net.au/api/v1/services.json` is the machine-readable list of 108 services, with timezones and parent/child (timezone variant) links.
   - The listen **BFF** `https://www.abc.net.au/core-next/api/collection/listen/radio?...` gives the curated national and per-state lists with logos.
   - Get stream URLs from `https://www.abc.net.au/core-next/api/epgNowPlaying/<SERVICE_ID>/now` (`sources[]`: HLS + "aac").
3. **Live playback in LMS.** Use the progressive **Icecast AAC** streams (`https://abc.streamguys1.com/live/<mount>/icecast.audio`, ADTS AAC, `audio/aacp`, 56 kbps). Resolve them from `https://streaming.abc-cdn.net.au/audio/ice/<hls-slug>.pls`. Every station has one except ABC Cricket, ABC Sport Rapid / RLWC Rapid, and the Kids listen timezone variants, which are **HLS-only**. Ship a static fallback table: `derived-station-streams-*.json`.
4. **Programs.** For an A–Z list, query **Algolia** `listen_prod_all` with `contentType:program` (724 audio programs). For per-network lists, use the `programAggregationCollection` BFF plus the network `/programs` pages.
5. **Episodes.**
   - The program page's Next data `/_next/data/<buildId>/<program path>.json` gives `programCollectionPrepared.id`.
   - Page through `https://www.abc.net.au/core-next/api/episodesWithSegments/x?collectionId=<id>&offset=N&size=M`. It returns at most the newest 250 items.
   - Audio URLs come from the episode's Next data `documentProps.renditions`, or from Algolia `mediaRenditions`.
6. **On-demand audio is always progressive.** In more than 3,000 sampled items, every rendition was MP3 (192 kbps) or ADTS AAC (about 260 kbps) on `mediacore-live-production.akamaized.net` or the older `abcmedia.akamaized.net`. Range requests work. No HLS-only on-demand content was found: the "HLS" rendition points at the same `.aac` file.
7. **Availability windows.**
   - MP3 is governed by `downloadAvailableFrom/To`, which is usually 2200, so effectively permanent.
   - AAC and HLS are governed by `availableFrom/To`, usually about 28 days. After that the file returns **404**.
   - URLs containing `/geo-001/` are **AU-only**.
8. **Now playing.**
   - Program: BFF `epgNowPlaying/<ID>/now|next`.
   - Song: `https://music.abcradio.net.au/api/v1/plays/<station>/now.json`, or BFF `musicNowPlaying/<ID>`.
   - Schedule: BFF `/core-next/api/schedule?service=..&date=..&tz=..` or PAPI `programitems/search.json`.
9. **Home and categories.** Read the listen home Next data `/_next/data/<buildId>/listen.json` to get collection ids, then load each with BFF `/core-next/api/collection?collectionId=...`. Category ("dynamiccollection") pages work the same way.
10. **Biggest fragilities.**
    - The `/core-next/api/*` BFF and `_next/data` routes are internal and undocumented.
    - The `buildId` changes on every deploy, so re-scrape it on a 404.
    - The Algolia key is limited to 400 queries per hour per IP.
    - The Terminus API (`api.abc.net.au/terminus`) needs a private API key (401) and is not usable.

---

## 2. Stations and live streams

### 2.1 Machine-readable station lists

| Source | URL | Notes |
|---|---|---|
| **PAPI services** (best canonical list) | `https://program.abcradio.net.au/api/v1/services.json` (`?offset=100` for page 2; total 108) | Fields include `service_id` (e.g. `triplej`, `local_sydney`, `RN`, `triplej_perth`), `title`, `mini_synopsis`, `service_timezone`, `service_location`, `exclude_from_display`, `has_track_data`, `service_group`/`service_sort_order`, `linked_services[]` (`type: child` = timezone variants), and `properties[]` (`livestream_url`, `station_collection_id` for the listen app, GfK ids). **No stream URLs.** Single service: `/api/v1/services/<service_id>.json`. Fixture: `papi-services.trimmed.json`; full list: `derived-papi-services.tsv`. |
| BFF: national networks | `https://www.abc.net.au/core-next/api/collection/listen/radio?collectionId=12872264&rootMetaCollectionId=14139428&metaInMeta=false` | 19 curated cards (`cardTitle`, `articleLink`, logo in `cardImagePrepared`, `contentUri` such as `coremedia://channel/12872318`). Fixture: `bff-collection-national-networks.json`. |
| BFF: local stations by state | same URL with `rootMetaCollectionId=14123276` and `collectionId` = NSW 14126370, ACT 14126436, NT 14128062, VIC 14128070, SA 14128508, TAS 14128536, QLD 14128542, WA 14128996 | 53 local stations. The state collection ids come from the `/listen/radio` page (MetaCollection 14123276). Fixture: `bff-collection-local-stations-nsw.json`, `nextdata-listen-radio.metacollections.trimmed.json`. |
| BFF: live player config per station | `https://www.abc.net.au/_next/data/<buildId>/listen/live/<slug>.json` → `pageProps.data.componentsContent[0].componentProps` (`LiveAudioPlayerUpdate`) | `papiServiceId`, `config.sources[]` ({`type`: `hls`/`aac`/`hds`, `file`}), current program `title`/`start`/`end`, `preparedImage`, `preparedPresenters`, `timezoneInfo`, station logo (`radioHeadingPrepared.logoPrepared`). Fixture: `nextdata-live-radionational.player.json`. |
| **BFF: now playing + sources (no buildId)** | `https://www.abc.net.au/core-next/api/epgNowPlaying/<SERVICE_ID>/now?imageRatio=1x1` (also `/next`) | Same `sources[]` plus current program. SERVICE_ID is the PAPI `service_id` upper-cased (`RN`, `TRIPLEJ_PERTH`, `LOCAL_SYDNEY`). Returns `{}`/no sources for event-only services that are off air. Fixture: `bff-epgNowPlaying-*.json`. |

Service id enum (from the JS bundle). The live-page slug is in the table below.

`ABC_AFL_RAPID ABCSPORTSYNC CLASSIC CLASSIC2 CLASSIC_{ADELAIDE,BRISBANE,DARWIN,PERTH} COUNTRY DOUBLEJ DOUBLEJ_{ADELAIDE,BRISBANE,DARWIN,PERTH} GRANDSTAND GRANDSTAND_EXTRA H100 ITINERANT_{ONE,TWO,THREE,FOUR} JAZZ KIDSLISTEN KIDSLISTEN_{NT,QLD,SA,WA} LOCAL_* (53 + KATHERINE, SOUTHCOAST) NEWS NEWS_BULLETIN RA RA_ML RN RN_{NT,QLD,SA,TAS,VIC,WA} SPORT_{AFL,AFLW,AFL_EXTRA,BBL,CRICKET,TENNIS,WBBL,WORLDCUP} TRIPLEJ TRIPLEJ_{ADELAIDE,BRISBANE,DARWIN,PERTH} UNEARTHED`

### 2.2 Stream URL families

| Family | Pattern | Format | Tested from US |
|---|---|---|---|
| **HLS (what the website plays)** | `https://streaming.abc-cdn.net.au/audio/hls/<slug>.m3u8?source=web` → master playlist → `https://mediaserviceslive.akamaized.net/hls/live/<n>/<name>/v0-221.m3u8` (AAC-LC `mp4a.40.2`, 221–246 kbps for music, about 112 kbps for talk) and `v0-222.m3u8` (HE-AACv2 `mp4a.40.29`, 80–112 kbps) | MPEG-TS segments of about 10 s, `video/mp2t`, live window, `#EXT-X-PROGRAM-DATE-TIME` | ✅ `200`, segment starts `47 40 00` (TS sync). Fixtures: `live-hls-master-triplejnsw.m3u8`, `live-hls-media-triplejnsw-v0-221.m3u8` |
| **Icecast (best for LMS)** | `https://streaming.abc-cdn.net.au/audio/ice/<slug>.pls` → `File1=https://abc.streamguys1.com/live/<mount>/icecast.audio` | Progressive ADTS AAC, `Content-Type: audio/aacp`, `icy-br: 56`, server Nimble. **No `icy-metaint`** even when `Icy-MetaData: 1` is sent, so there is no in-band title metadata; poll the APIs. `http://` also works. | ✅ `200 audio/aacp`, bytes `ff f1 50 80` (ADTS). Fixtures: `live-ice-triplejnsw.pls`, `stream-response-headers.txt`, probe of all 88 slugs: `derived-icecast-probe.tsv` |
| Legacy `.pls` | `https://www.abc.net.au/res/streaming/audio-live/shout-aac/<x>.pls` and `/res/streaming/audio/{mp3,aac,shout-aac}/<x>.pls` | 302 to the `streaming.abc-cdn.net.au/audio/ice/*.pls` above. Several station pages still list these as the `aac` source. | ✅ |
| MediaHub Icecast | `https://live-radio01.mediahubaustralia.com/<CALLSIGN>W/aac/` (also `live-radio03`, `hot100.`; historically `/mp3/`). Some URLs have `;*.mp3` or `http://` | AAC (and historically MP3 128k) | ❌ **Cloudflare "Sorry, you have been blocked" 403** from the test host, likely a datacenter/ASN or non-AU WAF rule. Unknown from an Australian home IP. Treat as optional. |
| Akamai HDS (`abcradiolivehds-lh.akamaihd.net/z/...f4m`) | still listed for some services | Flash HDS | Legacy; ignore |
| StreamGuys HLS | `https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8`, `.../sport-sync-afl/playlist.m3u8` | HLS (fMP4/AAC) | ✅ (Sport Rapid / RLWC Rapid only) |

The `?source=web` query is just a tag the website appends; streams work without it.

**HLS-only live services**, where no Icecast mount was found:
- ABC CRICKET (`ITINERANT_FOUR`, slug `itinerantfour`). It is also **geo-blocked**: Akamai 403 outside AU.
- ABC SPORT RAPID (`ABCSPORTSYNC`) and ABC RLWC RAPID (`ABC_AFL_RAPID`), on StreamGuys HLS.
- Kids listen timezone variants (`abckidsnt/qld/sa/wa`). The main Kids listen stream does have Icecast, mount `abcextra`.

Event-only services (`SPORT_BBL`, `SPORT_WBBL`, `SPORT_TENNIS`, `GRANDSTAND_EXTRA`, `SPORT_AFL*`) had no sources at capture time.

### 2.3 Full station list (captured 2026-10-19)

Expand the slugs into URLs as follows:
- HLS: `https://streaming.abc-cdn.net.au/audio/hls/<HLS slug>.m3u8`
- Icecast: `https://abc.streamguys1.com/live/<mount>/icecast.audio`
- PLS: `https://streaming.abc-cdn.net.au/audio/ice/<HLS slug>.pls`

Machine-readable copies: `abc-samples/derived-station-streams-national.json` and `abc-samples/derived-station-streams-local.json`. They include logos and timezones.

| Station | PAPI/BFF service id | listen page | HLS slug | icecast mount | page `aac` source | note |
|---|---|---|---|---|---|---|
| Radio National | `RN` | /listen/live/radionational | rnnsw | rnnsw | live-radio01.mediahubaustralia.com/2RNW/aac/ |  |
| NewsRadio | `NEWS` | /listen/live/news | newsradio | newsradio | live-radio01.mediahubaustralia.com/PBW/aac/ |  |
| ABC SPORT | `GRANDSTAND` | /listen/live/sport | sport | sport | www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls |  |
| ABC SPORT EXTRA | `ITINERANT_THREE` | /listen/live/sportextra | itinerantthree | sportextra | live-radio01.mediahubaustralia.com/IT3W/aac/ |  |
| ABC SPORT RAPID | `ABCSPORTSYNC` | /listen/live/sportrapid | `https://abc-hls.streamguys1.com/hls/sport-sync/playlist.m3u8` | **none (HLS only)** | www.abc.net.au/res/streaming/audio-live/shout-aac/grandstand.pls |  |
| ABC CRICKET | `ITINERANT_FOUR` | /listen/live/cricket | itinerantfour | **none (HLS only)** | - |  |
| ABC Rugby League World Cup | `ITINERANT_ONE` | /listen/live/afl | itinerantone | afl | http:live-radio01.mediahubaustralia.com/IT1W/aac/ |  |
| ABC AFLW | `ITINERANT_TWO` | /listen/live/aflextra | itineranttwo | aflextra | live-radio01.mediahubaustralia.com/IT2W/aac/ |  |
| ABC AFLW | `SPORT_AFLW` | /listen/live/aflw | itineranttwo | aflextra | live-radio01.mediahubaustralia.com/IT2W/aac/ |  |
| ABC BBL | `SPORT_BBL` | /listen/live/bbl | - | - | - | event-only, no sources at capture |
| ABC WBBL | `SPORT_WBBL` | /listen/live/wbbl | - | - | - | event-only, no sources at capture |
| ABC Tennis | `SPORT_TENNIS` | /listen/live/tennis | - | - | - | event-only, no sources at capture |
| ABC Rugby League World Cup | `SPORT_WORLDCUP` | /listen/live/worldcup | itinerantone | afl | http:live-radio01.mediahubaustralia.com/IT1W/aac/ |  |
| ABC RLWC RAPID | `ABC_AFL_RAPID` | /listen/live/worldcuprapid | `https://abc-hls.streamguys1.com/hls/sport-sync-afl/playlist.m3u8` | **none (HLS only)** | - |  |
| ABC Classic | `CLASSIC` | /listen/live/classic | classicnsw | classicfmnsw | www.abc.net.au/res/streaming/audio-live/shout-aac/classicfm-nswvictas.pls |  |
| Classic 2 | `CLASSIC2` | /listen/live/classic2 | `https://mediaserviceslive.akamaized.net/hls/live/2038317/classic2/index.m3u8` | classic2 (pls name `classic2`) | live-radio01.mediahubaustralia.com/FM2W/aac/;*.mp3 |  |
| ABC Jazz | `JAZZ` | /listen/live/jazz | abcjazz | abcjazz | www.abc.net.au/res/streaming/audio-live/shout-aac/abcjazz.pls |  |
| ABC Country | `COUNTRY` | /listen/live/country | abccountry | abccountry | www.abc.net.au/res/streaming/audio/shout-aac/abc_country.pls |  |
| ABC KIDS listen | `KIDSLISTEN` | /listen/live/kidslisten | abckids | abcextra | - |  |
| Radio Australia | `RA_ML` | /listen/live/radioaustralia | ramulti | ramulti | live-radio01.mediahubaustralia.com/RAMW/aac/ |  |
| triple j | `TRIPLEJ` | /triplej/live/triplej | triplejnsw | triplejnsw | live-radio01.mediahubaustralia.com/2TJW/aac/ |  |
| triple j Hottest | `H100` | /triplej/live/triplejhottest | triplejhottest | triplejhottest | http:hot100.mediahubaustralia.com/TJHW/aac/ |  |
| triple j Unearthed | `UNEARTHED` | /triplej/live/unearthed | triplejunearthed | triplejunearthed | www.abc.net.au/res/streaming/audio-live/shout-aac/unearthed.pls |  |
| Double J | `DOUBLEJ` | /listen/doublej/live | doublejnsw | doublejnsw | www.abc.net.au/res/streaming/audio-live/shout-aac/doublej-nswvictas.pls |  |
| Radio National NT | `RN_NT` | - | rnnt | rnnt | - | tz variant |
| Radio National Qld | `RN_QLD` | - | rnqld | rnqld | - | tz variant |
| Radio National SA | `RN_SA` | - | rnsa | rnsa | - | tz variant |
| Radio National WA | `RN_WA` | - | rnwa | rnwa | - | tz variant |
| triple j Adelaide | `TRIPLEJ_ADELAIDE` | - | triplejsa | triplejsa | - | tz variant |
| triple j Brisbane | `TRIPLEJ_BRISBANE` | - | triplejqld | triplejqld | - | tz variant |
| triple j Darwin | `TRIPLEJ_DARWIN` | - | triplejnt | triplejnt | - | tz variant |
| triple j Perth | `TRIPLEJ_PERTH` | - | triplejwa | triplejwa | - | tz variant |
| Double J Adelaide | `DOUBLEJ_ADELAIDE` | - | doublejsa | doublejsa | - | tz variant |
| Double J Brisbane | `DOUBLEJ_BRISBANE` | - | doublejqld | doublejqld | - | tz variant |
| Double J Darwin | `DOUBLEJ_DARWIN` | - | doublejnt | doublejnt | - | tz variant |
| Double J Perth | `DOUBLEJ_PERTH` | - | doublejwa | doublejwa | - | tz variant |
| ABC Classic Adelaide | `CLASSIC_ADELAIDE` | - | classicsa | classicfmsa | - | tz variant |
| ABC Classic Brisbane | `CLASSIC_BRISBANE` | - | classicqld | classicfmqld | - | tz variant |
| ABC Classic Darwin | `CLASSIC_DARWIN` | - | classicnt | classicfmnt | - | tz variant |
| ABC Classic Perth | `CLASSIC_PERTH` | - | classicwa | classicfmwa | - | tz variant |
| Kids Listen Northern Territory | `KIDSLISTEN_NT` | - | abckidsnt | **none (HLS only)** | - | tz variant |
| Kids Listen Queensland | `KIDSLISTEN_QLD` | - | abckidsqld | **none (HLS only)** | - | tz variant |
| Kids Listen South Australia | `KIDSLISTEN_SA` | - | abckidssa | **none (HLS only)** | - | tz variant |
| Kids Listen Western Australia | `KIDSLISTEN_WA` | - | abckidswa | **none (HLS only)** | - | tz variant |
| Radio Australia | `RA` | - | raeng | raeng | - | tz variant |
| 702 ABC Sydney | `LOCAL_SYDNEY` | /listen/live/sydney | localsydney | localsydney | live-radio01.mediahubaustralia.com/2LRW/aac/ |  |
| ABC Broken Hill | `LOCAL_BROKENHILL` | /listen/live/brokenhill | localbrokenhill | localbrokenhill | live-radio01.mediahubaustralia.com/5BRHW/aac/ |  |
| ABC Central Coast | `LOCAL_CENTRALCOAST` | /listen/live/centralcoast | localcentralcoast | localcentralcoast | live-radio03.mediahubaustralia.com/2GOSW/aac/; |  |
| ABC Central West | `LOCAL_CENTRALWEST` | /listen/live/centralwest | localcentralwest | localcentralwest | live-radio03.mediahubaustralia.com/2ORAW/aac/ |  |
| ABC Coffs Coast | `LOCAL_COFFSCOAST` | /listen/live/coffscoast | localcoffscoast | localcoffscoast | live-radio03.mediahubaustralia.com/2CFHW/aac/ |  |
| ABC Illawarra | `LOCAL_ILLAWARRA` | /listen/live/illawarra | localillawarra | localillawarra | live-radio03.mediahubaustralia.com/2WOLW/aac/ |  |
| ABC Mid North Coast | `LOCAL_MIDNORTHCOAST` | /listen/live/midnorthcoast | localmidnorthcoast | localmidnorthcoast | live-radio01.mediahubaustralia.com/2MAQW/aac/ |  |
| ABC New England North West | `LOCAL_NEWENGLAND` | /listen/live/newengland | localnewengland | localnewengland | live-radio03.mediahubaustralia.com/2TAMW/aac/ |  |
| ABC Newcastle | `LOCAL_NEWCASTLE` | /listen/live/newcastle | localnewcastle | localnewcastle | live-radio01.mediahubaustralia.com/2NEWW/aac/ |  |
| ABC North Coast | `LOCAL_NORTHCOAST` | /listen/live/northcoast | localnorthcoast | localnorthcoast | live-radio03.mediahubaustralia.com/2LISW/aac/ |  |
| ABC Riverina | `LOCAL_RIVERINA` | /listen/live/riverina | localriverina | localriverina | live-radio03.mediahubaustralia.com/2WAGW/aac/ |  |
| ABC South East NSW | `LOCAL_SOUTHEASTNSW` | /listen/live/southeastnsw | localsoutheastnsw | localsoutheastnsw | live-radio03.mediahubaustralia.com/2BGAW/aac/ |  |
| ABC Upper Hunter | `LOCAL_UPPERHUNTER` | /listen/live/upperhunter | localupperhunter | localupperhunter | live-radio03.mediahubaustralia.com/2MUSW/aac/;*.mp3 |  |
| ABC Western Plains | `LOCAL_WESTERNPLAINS` | /listen/live/westernplains | localwesternplains | localwesternplains | live-radio01.mediahubaustralia.com/2DUBW/aac/ |  |
| 666 ABC Canberra | `LOCAL_CANBERRA` | /listen/live/canberra | localcanberra | localcanberra | live-radio01.mediahubaustralia.com/1LRW/aac/ |  |
| 105.7 ABC Darwin | `LOCAL_DARWIN` | /listen/live/darwin | localdarwin | localdarwin | live-radio01.mediahubaustralia.com/8LRW/aac/ |  |
| ABC Alice Springs | `LOCAL_ALICESPRINGS` | /listen/live/alicesprings | localalicesprings | localalicesprings | http:live-radio01.mediahubaustralia.com/8ALIW/aac/ |  |
| 105.7 ABC Darwin | `LOCAL_DARWIN` | /listen/live/katherine | localdarwin | localdarwin | live-radio01.mediahubaustralia.com/8LRW/aac/ |  |
| 774 ABC Melbourne | `LOCAL_MELBOURNE` | /listen/live/melbourne | localmelbourne | localmelbourne | live-radio01.mediahubaustralia.com/3LRW/aac/ |  |
| ABC Ballarat | `LOCAL_BALLARAT` | /listen/live/ballarat | localballarat | localballarat | live-radio01.mediahubaustralia.com/3BALLW/aac/ |  |
| ABC Central Victoria | `LOCAL_CENTRALVIC` | /listen/live/centralvic | localcentralvic | localcentralvic | live-radio01.mediahubaustralia.com/3BENW/aac/ |  |
| ABC Gippsland | `LOCAL_GIPPSLAND` | /listen/live/gippsland | localgippsland | localgippsland | http:live-radio01.mediahubaustralia.com/3SALE/aac/ |  |
| ABC Goulburn Murray | `LOCAL_GOULBURNMURRAY` | /listen/live/goulburnmurray | localgoulburnmurray | localgoulburnmurray | live-radio01.mediahubaustralia.com/3WOD/aac/ |  |
| ABC Mildura-Swan Hill | `LOCAL_MILDURASWANHILL` | /listen/live/milduraswanhill | localmilduraswanhill | localmilduraswanhill | live-radio01.mediahubaustralia.com/3MILW/aac/ |  |
| ABC Shepparton | `LOCAL_SHEPPARTON` | /listen/live/shepparton | localshepparton | localshepparton | live-radio03.mediahubaustralia.com/3SHPW/aac/ |  |
| ABC South West Victoria | `LOCAL_SOUTHWESTVIC` | /listen/live/southwestvic | localsouthwestvic | localsouthwestvic | live-radio01.mediahubaustralia.com/3WARRW/aac/ |  |
| ABC Wimmera | `LOCAL_WESTERNVIC` | /listen/live/wimmera | localwimmera | localwimmera | live-radio01.mediahubaustralia.com/3HORW/aac/ |  |
| 891 ABC Adelaide | `LOCAL_ADELAIDE` | /listen/live/adelaide | localadelaide | localadelaide | live-radio01.mediahubaustralia.com/5LRW/aac/ |  |
| ABC Eyre Peninsula | `LOCAL_EYRE` | /listen/live/eyre | localeyre | localeyre | live-radio03.mediahubaustralia.com/5LINW/aac/ |  |
| ABC North and West SA | `LOCAL_NORTHANDWEST` | /listen/live/northandwest | localnorthandwest | localnorthandwest | live-radio01.mediahubaustralia.com/5PIRW/aac/ |  |
| ABC Riverland | `LOCAL_RIVERLAND` | /listen/live/riverland | localriverland | localriverland | live-radio03.mediahubaustralia.com/5RENW/aac/ |  |
| ABC South East SA | `LOCAL_SOUTHEASTSA` | /listen/live/southeastsa | localsoutheastsa | localsoutheastsa | live-radio03.mediahubaustralia.com/5MTGW/aac/ |  |
| 936 ABC Hobart | `LOCAL_HOBART` | /listen/live/hobart | localhobart | localhobart | live-radio01.mediahubaustralia.com/7LRW/aac/ |  |
| ABC Northern Tasmania | `LOCAL_NORTHTAS` | /listen/live/northtas | localnorthtas | localnorthtas | live-radio01.mediahubaustralia.com/7LAUW/aac/ |  |
| 612 ABC Brisbane | `LOCAL_BRISBANE` | /listen/live/brisbane | localbrisbane | localbrisbane | live-radio01.mediahubaustralia.com/4LRW/aac/ |  |
| ABC Capricornia | `LOCAL_CAPRICORNIA` | /listen/live/capricornia | localcapricornia | localcapricornia | live-radio03.mediahubaustralia.com/4ROCW/aac/ |  |
| ABC Far North | `LOCAL_FARNORTH` | /listen/live/farnorth | localfarnorth | localfarnorth | http:live-radio01.mediahubaustralia.com/4CRNW/aac/ |  |
| ABC Gold Coast | `LOCAL_GOLDCOAST` | /listen/live/goldcoast | localgoldcoast | localgoldcoast | live-radio01.mediahubaustralia.com/4GLDW/aac/ |  |
| ABC North Queensland | `LOCAL_NORTHQLD` | /listen/live/northqld | localnorthqld | localnorthqld | live-radio03.mediahubaustralia.com/4TOWW/aac/ |  |
| ABC North West Queensland | `LOCAL_NORTHWEST` | /listen/live/northwest | localnorthwest | localnorthwest | live-radio01.mediahubaustralia.com/4ISAW/aac/ |  |
| ABC Southern Queensland | `LOCAL_SOUTHQLD` | /listen/live/southqld | localsouthqld | localsouthqld | http:live-radio01.mediahubaustralia.com/4TOOW/aac/ |  |
| ABC Sunshine Coast | `LOCAL_SUNSHINE` | /listen/live/sunshine | localsunshine | localsunshine | live-radio03.mediahubaustralia.com/4SUNW/aac/ |  |
| ABC Tropical North | `LOCAL_TROPIC` | /listen/live/tropic | localtropic | localtropic | live-radio03.mediahubaustralia.com/4MACW/aac/ |  |
| ABC Western Queensland | `LOCAL_WESTQLD` | /listen/live/westqld | localwestqld | localwestqld | live-radio01.mediahubaustralia.com/4LONW/aac/ |  |
| ABC Wide Bay | `LOCAL_WIDEBAY` | /listen/live/widebay | `https://mediaserviceslive.akamaized.net/hls/live/2038240/localwidebay/index.m3u8` | **none (HLS only)** | live-radio03.mediahubaustralia.com/4BBGW/aac/ |  |
| 102.5 ABC Perth | `LOCAL_PERTH` | /listen/live/perth | localperth | localperth | live-radio01.mediahubaustralia.com/6LRW/aac/ |  |
| ABC Esperance | `LOCAL_ESPERANCE` | /listen/live/esperance | localesperance | localesperance | live-radio03.mediahubaustralia.com/6ESPW/aac/ |  |
| ABC Goldfields | `LOCAL_GOLDFIELDS` | /listen/live/goldfields | localgoldfields | localgoldfields | live-radio01.mediahubaustralia.com/6KLGW/aac/ |  |
| ABC Great Southern | `LOCAL_GREATSOUTHERN` | /listen/live/greatsouthern | localgreatsouthern | localgreatsouthern | live-radio03.mediahubaustralia.com/6ALBW/aac/ |  |
| ABC Kimberley | `LOCAL_KIMBERLEY` | /listen/live/kimberley | localkimberley | localkimberley | live-radio01.mediahubaustralia.com/6BRMW/aac/ |  |
| ABC Midwest & Wheatbelt | `LOCAL_WHEATBELT` | /listen/live/wheatbelt | localwheatbelt | localwheatbelt | live-radio03.mediahubaustralia.com/6GERW/aac/ |  |
| ABC Pilbara | `LOCAL_NORTHWESTWA` | /listen/live/pilbara | localpilbara | localpilbara | live-radio01.mediahubaustralia.com/6KARW/aac/ |  |
| ABC South West WA | `LOCAL_SOUTHWESTWA` | /listen/live/southwestwa | localsouthwestwa | localsouthwestwa | live-radio01.mediahubaustralia.com/6BUNW/aac/ |  |

Also verified but not linked from listen pages: `rnvic`, `rntas` Icecast mounts (PAPI marks `RN_vic`/`RN_tas` `exclude_from_display`), `raeng` (Radio Australia English, service `RA`).

Timezone variants:
- RN, triple j, Double J, Classic and Kids listen have NT/QLD/SA/WA variants. RN also has VIC and TAS; those are hidden.
- The listen site offers a timezone switch for these (help article "Can I change the live radio stream so it matches my local timezone?").
- PAPI `linked_services[type=child]` gives the mapping.

Station logos: wcms URL in `cardImagePrepared.imgSrc` / `radioHeadingPrepared.logoPrepared.imgSrc` (1x1, see §8). PAPI has `https://www.abc.net.au/radio/images/service/...png` logos inside schedule `stationsInfo[].primaryImage`.

### 2.4 Working curl examples

```sh
# Station sources + what's on now
curl -s 'https://www.abc.net.au/core-next/api/epgNowPlaying/TRIPLEJ/now?imageRatio=1x1' | jq '{title,start,end,sources}'
# Resolve the icecast mount for an HLS slug
curl -s https://streaming.abc-cdn.net.au/audio/ice/triplejnsw.pls     # File1=https://abc.streamguys1.com/live/triplejnsw/icecast.audio
# Verify audio bytes (stream: cap the read)
curl -s -m 5 https://abc.streamguys1.com/live/triplejnsw/icecast.audio | head -c 4 | od -An -tx1   # ff f1 50 80
# HLS master
curl -s 'https://streaming.abc-cdn.net.au/audio/hls/triplejnsw.m3u8?source=web'
# PAPI service list
curl -s https://program.abcradio.net.au/api/v1/services.json | jq '.items[]|{service_id,title,service_timezone}'
```

---

## 3. Programs (listing, categories, A–Z)

| Need | Endpoint | Notes |
|---|---|---|
| **A–Z of all audio programs** | Algolia `POST https://<appId>-dsn.algolia.net/1/indexes/listen_prod_all/query` body `{"query":"","hitsPerPage":1000,"filters":"contentType:program AND (siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific)"}` with headers `X-Algolia-Application-Id: <appId>`, `X-Algolia-API-Key: <search-only key, discovered at runtime from /listen/search>` | 724 hits in one call (Algolia's 1000-hit pagination cap is not exceeded). Fields: `objectID` (`coremedia://program/2885500`), `title`, `canonicalURL`, `description`/`synopsis`/`shortTeaserText`, `programType` (`podcast` 240, `catch-up` 197, `music` 121, `news-briefing` 49, `audiobook` 19, `Music Playlists` 6, null 92), `infoSource` (network, e.g. "ABC Radio National"), `contributors[]` (presenters), `defaultThumbnail{1x1,16x9,3x2,3x4,4x3,9x16}`, `dates`. Sort client-side. Fixture: `algolia-programs-list.json`. |
| Per network "All Programs" | Next data `/_next/data/<buildId>/<network>/programs.json` gives the `ProgramAggregationCollection` id. Page with `https://www.abc.net.au/core-next/api/programAggregationCollection/x?collectionId=<id>&offset=N&size=M` | Network pages (collection id / total): `/listen/radionational/programs` (11474038 / 56, plus Featured 13910480), `/triplej/programs` (8698186 / 37), `/listen/doublej/programs` (9375554 / 17), `/listen/classic/programs` (9104650 / 35), `/listen/jazz/programs` (8794720 / 10), `/listen/country/programs` (Featured 12606644 / 7), `/kidslisten/programs` (9317914 / 34), `/triplejunearthed/programs` (106304964 / 13), local e.g. `/sydney/programs` (8132676 / 19). Items: `cardTitle`, `articleLink`, `contentUri` (`coremedia://program/<id>`; sometimes `coremedia://teaser/<id>`), `cardImagePrepared`, `description`, `presentersPrepared`. Fixture: `bff-programAggregationCollection-rn.json`. |
| Podcast categories | `/listen/podcasts` page → `Categories` collection 14123152 → 8 category pages `/listen/listenapp/<slug>/<id>` (News & Analysis 104142082, True Crime 104142226, Sport 104142200, Kids & Families 104141842, History 104141924, Society & Culture 104142164, Music 104142058, Conversations & Storytelling 104141814) | Each category page has a `StandardCollection` (`subaggregation`). Load more with `/core-next/api/collection/x?collectionId=<id>&offset=&size=`. Podcasts page MetaCollection 106118844: New & Noteworthy, Most Popular Podcasts, Award Winning Podcasts. |
| Program details | Next data `/_next/data/<buildId><program path>.json` (e.g. `/listen/programs/scienceshow`) | `heroImageWithCTAPrepared` {`heading`, `uri`: `coremedia://program/<id>`, `heroImagePrepared`, `channelLogoPrepared`, `attributionLinksPrepared` (network)}, `heroDescriptionPrepared` (rich-text descriptor tree: collect `type:"text"` nodes), `presentersPrepared[]`, `programCollectionPrepared` {`id` = **episode collection id**, `programId`, `pagination{total}`, `items[]`}, `programTemplate`, `webDistributionRestricted`. Fixture: `nextdata-program-scienceshow.trimmed.json`. |
| Program by id | `https://www.abc.net.au/news/<programId>` → **308** to the canonical URL (works for any CoreMedia id, including episodes) | Lets the plugin store numeric ids only. |

Program paths vary (`/listen/programs/<slug>`, `/triplej/programs/<slug>`, `/kidslisten/programs/<slug>`, `/listen/audiobooks/<slug>`). Always take them from `canonicalURL`/`articleLink`.

---

## 4. Episodes

### 4.1 Listing per program

```
GET https://www.abc.net.au/core-next/api/episodesWithSegments/x?collectionId=2885458&offset=0&size=50
```

- `collectionId` (from `programCollectionPrepared.id`) is **required**. The path after `episodesWithSegments` is ignored. `size` can be up to 250 in one call.
- Response: `collection.pagination{offset,size,total}`. `total` is **capped at 250** (the newest 250). `offset>=250` returns 0 items.
- Items have `cardTitle`, `description`, `contentUri` (`coremedia://audioepisode/<id>`, `coremedia://audio/<id>`, or `coremedia://audiosegment/<id>`), `articleLink`, `cardAttributionPrepared.publishedDate`, `cardMediaIndicatorPrepared.duration` (seconds), `cardImagePrepared`, `presentersPrepared`, `docType`, and `segments[]` (segment cards labelled "1 of 5"…).
- **No audio URLs.**
- Fixture: `bff-episodesWithSegments-scienceshow.json`.

Older episodes have two alternatives:
- Algolia: `filters: programTitle:"The Science Show" AND contentType:audioepisode` returns 1,529 hits, newest first, with `mediaRenditions`.
- The program RSS feed (§4.4).

### 4.2 Episode detail and audio

```
GET https://www.abc.net.au/_next/data/<buildId><articleLink>.json      # e.g. /listen/programs/scienceshow/trees-potatoes-brendan-may-step/107266790
→ pageProps.data.documentProps
```

Any slug works: `/listen/programs/scienceshow/x/107266790.json` returns `pageProps.__N_REDIRECT` to the canonical path.

Key fields:
- Identity and text: `id`, `docType` (`audioepisode`, `audio`, `audiosegment`), `title`, `synopsis`, `canonicalURL`, `duration` (s), `programID`, `contributors`, `datelinePrepared.publishedDate`, `heroImageWithCTAPrepared` / `thumbnailLink` (images).
- `tracklistPrepared` (music shows), `transcript` (rich text), `playlistPrepared` (segments).
- Availability: `availableFrom`, `availableTo`, `downloadAvailableFrom`, `downloadAvailableTo`, `allowMediaDownload`, `webDistributionRestricted`.
- **`renditions[]`**: `{url, MIMEType, bitrate, codec, fileSize}`.

Fixtures: `nextdata-episode-scienceshow-mp3.trimmed.json`, `nextdata-episode-classic-drive-aac.trimmed.json`, `nextdata-episode-old-2024.trimmed.json`.

Rendition types seen (in 3,000+ items sampled via Algolia, plus episode pages):

| MIME | Host / example | Typical use | Verified bytes |
|---|---|---|---|
| `audio/mpeg` (192 kbps, 48 kHz, MP3, ID3) | `https://mediacore-live-production.akamaized.net/audio/02/pg/Z/ai.mp3` | podcasts, talk programs, segments | ✅ `206`, `ID3`, `accept-ranges: bytes`, origin S3 |
| `audio/mp3` | `https://abcmedia.akamaized.net/radio/local_darwin/audio/202204/acl-2022-04-14.mp3` | older content (pre-2023) | ✅ `206 audio/mpeg` |
| `audio/aac` (ADTS, about 260 kbps, Lavc) **plus** a duplicate entry `application/vnd.apple.mpegurl` with **the same `.aac` URL** | `https://mediacore-live-production.akamaized.net/audio/02/pj/Z/2j.aac` | "catch-up" / music / local programs (streaming-only rights) | ✅ `206 audio/aac`, `ff f1` |
| `application/vnd.apple.mpegurl` `.m3u8` + `application/f4m+xml` | `abcradiomodhls-vh.akamaihd.net/i/.../master.m3u8` | legacy (≤2022), always alongside an MP3 | ❌ dead (400); use the MP3 |

**No HLS-only on-demand content was found.** Prefer MP3, then `audio/aac`. Ignore `.m3u8` and `.f4m`.

### 4.3 Availability rules

From the site's JS (`r={downloadable:["audio/mp3","audio/mpeg","video/mp4"], streamable:["audio/mp4","application/vnd.apple.mpegurl","video/mpeg","audio/vnd.wave","audio/aac"]}`; downloadable uses `downloadAvailable*`, streamable uses `available*`):
- MP3 renditions are playable while now is within `downloadAvailableFrom`…`downloadAvailableTo`. That end date is usually `2200-01-01`, i.e. permanent. Verified: a January 2024 MP3 whose `availableTo` passed in February 2024 still returns 206.
- AAC/HLS ("streamable") renditions are playable within `availableFrom`…`availableTo`, typically **28 days**. After that the file is **deleted (404)**. Verified on three expired items.
- `webDistributionRestricted: true` means the website won't play it; honour this.
- Algolia mirrors these as `mediaDownloadStatus`/`mediaStreamingStatus` (`AVAILABLE`, `EXPIRED`, `NONE`, `PENDING`) and `dates.mediaDownloadAvailable*` / `mediaStreamingAvailable*`. The index can lag: the newest episode was still `PENDING`.
- **Geo-restricted audio**: URLs with a `/geo-001/` path prefix (e.g. `https://mediacore-live-production.akamaized.net/geo-001/audio/02/ka/Z/q3.mp3`) return Akamai `403 Access Denied` outside Australia. About 0.8% of 3,000 recent items were affected: BBC co-productions such as *Uncanny* and *You're Dead To Me*, and audiobooks.

### 4.4 Podcast RSS (optional)

`https://www.abc.net.au/feeds/<feedId>/podcast.xml` is standard iTunes RSS with `enclosure` MP3 URLs, `itunes:duration`, images and 250 items. Example: `https://www.abc.net.au/feeds/2885480/podcast.xml` (Science Show). Old `/radionational/feed/<id>/podcast.xml` URLs 308 here.

The **feed id is not the program id**: `/feeds/2885500/podcast.xml` returns a 500 parser error, and the collection id says "No content items". It is not exposed on the new listen pages. You could discover it via Apple Podcasts lookup, which is untested. Fixture: `podcast-rss-2885480-scienceshow.trimmed.xml`.

---

## 5. Now playing and schedules

| Need | Endpoint | Notes |
|---|---|---|
| Current/next program per station | `https://www.abc.net.au/core-next/api/epgNowPlaying/<ID>/now?imageRatio=1x1` (`/next`; `imageRatio` 1x1 or 16x9) | `title`, `start`/`end` (UTC ISO), `programLink`, `preparedPresenters[].names.full`, `preparedImage{imgSrc,srcSet}`, `sources[]`. The site polls every 60 s. |
| Current song (BFF) | `https://www.abc.net.au/core-next/api/musicNowPlaying/<ID>?tz=Australia%2FSydney` (ID upper-case, e.g. `TRIPLEJ`; lower-case returns `{}`) | `mapiNow{title,artist,primaryImage,...}`, `mapiPrev`, `nextUpdated`, `lastUpdated`, `serverTime`. Fixture: `bff-musicNowPlaying-TRIPLEJ.json`. |
| Current song (music API, public) | `https://music.abcradio.net.au/api/v1/plays/<station>/now.json` | Station names that work: `triplej doublej unearthed jazz country classic classic2 h100 kidslisten`. `rn`, `local_sydney`, `hottest` return 400. Shape: `now.recording{title, artists[].name, releases[].artwork[].sizes[]}`, `played_time`, `prev`, `next`, `next_updated`. Use `has_track_data` in PAPI to know which services have tracks. Fixture: `music-abcradio-plays-triplej-now.json`. |
| Recently played | `https://music.abcradio.net.au/api/v1/plays/search.json?station=triplej&order=desc&limit=10` (`offset`, `from`, `to`) | `total` 10000, `items[]{played_time, recording, release, summary}`. BFF equivalent: `/core-next/api/tracklist?station=..&offset=0&size=..&from=..&to=..&tz=..`. Fixture: `music-abcradio-plays-search-triplej.json`. |
| Day schedule | `https://www.abc.net.au/core-next/api/schedule?service=RN&date=2026-10-19&tz=Australia/Sydney&ratio=1x1` (`services=A,B` for several) | `serviceTimezone`, `formattedScheduleArray[{timeBlockTitle: Early/Morning/Afternoon/Evening, items[{id, rawStartTime, rawEndTime, title, synopsis, url (program page), presenters, cardImagePrepared, onNow, start/end local strings, stationsInfo}]}]`. Fixture: `bff-schedule-RN-day.json`. |
| Schedule (raw PAPI) | `https://program.abcradio.net.au/api/v1/programitems/search.json?service=triplej&from=<ISO>&to=<ISO>&include=next,with_images,resized_images&limit=N` | Episode entities with `live[]` (start, end, `outlets[].partof_service.service_id` for each timezone variant), `program{arid,title}`, `presenters`, `primary_image` with sizes, `mini/short/medium_synopsis`. Fixture: `papi-programitems-search-triplej.json`. |

Note: `program.abc.net.au` (a different host) was refused by this sandbox's egress proxy (CONNECT 502). `program.abcradio.net.au` works.

---

## 6. Home page collections and categories

`GET https://www.abc.net.au/_next/data/<buildId>/listen.json` → `pageProps.data.componentsContent[]` (36 KB). Fixture: `nextdata-listen-home.components.trimmed.json`. The components are:

- `HeroCarousel` (editorial items).
- `LiveRadioCarousel`: 11 cards {`papiServiceId`, `stationLink`, `title`, `start`/`end`, image}.
- Several `StandardCollection` blocks {`id`, `title`, `contentUri: coremedia://collection/<id>`, `items[]`}: Today's Top Picks 103194114, Top 100 Australian Books 103194116, Radio Stations 102833294, Latest News 104903746, Explore Video Podcasts 106944162, Most Popular Podcasts 103194120, True Crime & Investigations 103194124, Health & Wellbeing 14123148, Society & Culture 103194150, Music For Every Mood 104223142, Looking For Something New? 103207758, Relax & Sleep 106728212, Categories 14123152.
- `RecommendationsExperiment` blocks (popular now, sport).

Endpoints:
- Paginate any collection with `https://www.abc.net.au/core-next/api/collection/x?collectionId=103194120&offset=0&size=10`, which returns `collection{title,pagination,items}`. Items are cards: `cardTitle` is often an **editorial tagline**, not the program name, `contentUri` gives the type and id, plus `articleLink` and `cardImagePrepared`. Fixture: `bff-collection-home-most-popular-podcasts.json`.
- MetaCollections, such as podcasts page 106118844 or the radio page's 14139428/14123276, already list their sub-collection ids in the page data (`componentProps.items[].id`). Load each one with `/core-next/api/collection/x?collectionId=<subId>&rootMetaCollectionId=<metaId>&metaInMeta=false`. Tested: New & Noteworthy 105492374 returns 7 items. The JS also calls `/core-next/api/metaCollection`, but `...?collectionId=106118844&rootMetaCollectionId=106118844&metaInMeta=true` returned `{}`. The correct parameters for it are unknown, and it isn't needed.
- Recommendations: `https://www.abc.net.au/core-next/api/recommendations/listen/<pageRecs>`, where `pageRecs` is `homepagePopularNow`, `thisWeeksMostListenedRex` or `homepageSports`. Returns `{title:"This Week's Most Listened", items[24]}`; no login needed. Fixture: `bff-recommendations-homepagePopularNow.json`.
- Other nav sections are built the same way: `/listen/radio`, `/listen/podcasts`, `/listen/news`, `/listen/sport`, `/kidslisten`, `/listen/audiobooks`, and network homes `/listen/radionational`, `/listen/classic`, `/listen/doublej`, `/listen/jazz`.

### 6.1 Section pages (probed 2026-10-19, buildId `build-3afcd04f`)

The site nav is Home, Radio (`/listen/radio`), Podcasts, News (`/listen/news`), Sport (`/listen/sport`), Kids listen (**`/kidslisten`**; `/listen/kidslisten` is 404) and Audiobooks (`/listen/audiobooks`). Each page is `/_next/data/<buildId><path>.json` → `pageProps.data.componentsContent[]`. Fixtures: `abc-samples/nextdata-section-{radio,news,sport,kidslisten,kidslisten-programs,audiobooks}.trimmed.json` (they keep the real `pageProps.data` path).

| Page | Components, in order | Cards | Live stations |
|---|---|---|---|
| Radio | MetaCollection 14139428 (→ National Networks 12872264, 19 cards), MetaCollection 14123276 (→ 8 state collections), AppOnwardJourney | `channel` + `externallink` station cards only. **No program collections.** | all (L1's catalogue) |
| News | MiniEPG "Continuous News" (`papiServiceId` NEWS, `sources` HLS + mediahub; Icecast `newsradio` plays), 9 × StandardCollection (Latest News, Daily Programs, Beyond The Headlines, ABC News Daily, Latest Current Affairs, Featured Podcasts, News from Radio National, Latest from NewsRadio, Regional & Rural News), AppStoreCTA | `audio` 18, `audioepisode` 27, `audiosegment` 15, `program` 20. Some `audio` cards link to `/news/<date>/<slug>/<id>`; that path's `_next/data` returns a normal `documentProps` with MP3 renditions. | NEWS |
| Sport | Promo, StandardCollection "Radio Stations" (7 `externallink` cards → `/listen/live/{sport,sportrapid,sportextra,cricket,worldcup,worldcuprapid,aflw}`, some on host `abc.net.au` without `www`), "Best of ABC Sport", **LiveRadioCarousel** "Live & Upcoming Events" (cards in `componentProps.cards[]` with `papiServiceId` (may be lower-case: `itinerant_four`), event `title`, `start`/`end`, `stationLink`), "Latest Cricket", "Rugby League World Cup", "Programs", "Off Season", AppStoreCTA | `audioepisode`, `audio`, `audiosegment`, `program` (some `/pacific/programs/<slug>`, normal program pages) | Icecast plays: `sport`, `sportextra`, `afl` (World Cup / ITINERANT_ONE), `aflextra` (AFLW). HLS-only: Sport Rapid, RLWC Rapid, Cricket (also geo). |
| Kids listen | StandardCollection 9317798 (**untitled** hero: 2 `audioepisode` + 1 `article`), AppOnwardJourney, StandardCollection 9317620 "Latest Programs" (4 `audioepisode`). The Kids listen masthead nav (in `templatePrepared`) is Home, Programs (`/kidslisten/programs`), News Time, Tracklist, About, FAQs; its CTA "Play Live Radio" is `KIDSLISTEN`. `/kidslisten/programs`: **ProgramAggregationCollection** 9317914 (34 programs; page with `programAggregationCollection/x`) + "People" (`person` cards). Podcast category "Kids & Families" 104141842: 52 programs via `collection/x`. | episodes are MP3 (permanent) or AAC+MP3; no geo | `KIDSLISTEN`: `abckids.pls` → `abcextra` Icecast (56 kbps ADTS, plays). `KIDSLISTEN_NT/QLD/SA/WA`: no `.pls` (404), HLS-only. Music API station `kidslisten` works. |
| Audiobooks | Promo, **MetaCollection** 105894152 (11 sub-collections: Live Events [0], Most Popular, Top 100 Australian Books, Crime & Thriller, Audio Dramas, '' [0], Popular Fiction, Timeless Audiobooks, Books for Kids, Beyond The Book, Programs For Book Lovers), TeaserNavigator (FAQ), AppStoreCTA | sub-collections hold `program` cards (books, audio dramas), `audioepisode`/`audiosegment` (book-show features) | – |

Findings that affect the plan:
- **`cardId` vs `contentUri`.** On curated collections the `contentUri` id is often a *teaser* id; `cardId` (also the `articleLink` leaf) is the document id. 22/80 cards on News and 9/45 on Sport differ; program cards too (home `coremedia://program/104252122` → `cardId` 9593170). `coremedia://audioepisode/103186434` ("Full episode: …", `cardId` 107232996) is a **dynamic** "latest full episode" teaser: `/news/103186434` 308s to whichever episode is newest. Use `cardId` for ids.
- **MetaCollection sub-collections** page with `collection/x?collectionId=<sub>` **without** `rootMetaCollectionId` (verified for 105672994, 106510880, 12872264).
- **Audiobooks have no episode list on the web.** A book page (`/listen/audiobooks/<slug>-page`, some `/listen/programs/<slug>` books such as *Octonauts*) has `programTemplate: "audiobook"` (or `"default"`), `webDistributionRestricted: true`, `programCollectionPrepared: null`; chapter pages 308 back to the book page. The FAQ says audiobooks are AU-only and app-only ("Our publishing rights only allow audiobooks to be accessed from within Australia … can only be streamed via the ABC listen app"). Chapters exist in **Algolia**: `filters: contentType:audioepisode AND programID=<book id>` (numeric filter; `programID:<id>` returns 0) → e.g. 30 chapters for *The Dictionary of Lost Words* (106353766), MP3 at `/geo-001/` (403 from the container), `mediaDownloadAvailableTo` = publish + 1 year; all chapters share one publication date, so **reading order = ascending numeric id**. `contentType:program AND programType:audiobook` → 20 books. Fixtures: `nextdata-program-audiobook.trimmed.json`, `algolia-audiobook-chapters.trimmed.json`, `bff-collection-audiobooks-most-popular.json`.
- Components to skip in a plugin: `Promo`, `AppStoreCTA`, `AppOnwardJourney`, `TeaserNavigator`, `Tracklist`, `ExperimentEnroller`; card types `article`, `person`, `video`.

---

## 7. Search

Search uses Algolia. Config comes from `/listen/search` page props (component `Search`) and the masthead:

- App id `<appId>`, search-only key (not recorded here; read at runtime).
- Indexes `listen_prod_all` and `listen_prod_all_query_suggestions`.
- Key ACL (`GET /1/keys/<key>`): `acl:["search"]`, `indexes:["listen_prod_all","listen_prod_all_query_suggestions"]`, **`maxQueriesPerIPPerHour: 400`**. Replica (sorted) indexes are not allowed.
- The site scopes to listen with filter `siteTitle:"Listen"`. A useful plugin filter: `siteTitle:"Listen" AND (contentType:program OR contentType:audioepisode)`. Add triple j, Kids listen and Pacific `siteTitle`s if wanted.
- Facets usable in filters: `contentType` (program, audioepisode, audiosegment, audio, article, video, channel), `siteTitle`, `siteSegment`, `programTitle`, `programType`, `mediaDownloadStatus`, `mediaStreamingStatus`, `unixDates.publicationDate` (numeric), `subject.name`, `tags`, `objectID`.
- Hits include `mediaRenditions[]{url, contentType, bitrate, fileSize, fileName, audioSampleRate}`, `dates{publicationDate, mediaDownloadAvailableFrom/To, mediaStreamingAvailableFrom/To}`, `duration`, `programID`, `programTitle`, `defaultThumbnail{ratios}`, `programDefaultThumbnail`, `title`, `teaserText`, `synopsis` and `canonicalURL`. So Algolia alone can serve search results that are directly playable.

```sh
curl -s -X POST 'https://<appId>-dsn.algolia.net/1/indexes/listen_prod_all/query' \
  -H 'X-Algolia-Application-Id: <appId>' -H 'X-Algolia-API-Key: <search-only key, discovered at runtime from /listen/search>' \
  -d '{"query":"science","hitsPerPage":20,"filters":"siteTitle:\"Listen\" AND (contentType:program OR contentType:audioepisode)"}'
# suggestions
curl -s -X POST 'https://<appId>-dsn.algolia.net/1/indexes/listen_prod_all_query_suggestions/query' -H 'X-Algolia-Application-Id: <appId>' -H 'X-Algolia-API-Key: <search-only key, discovered at runtime from /listen/search>' -d '{"query":"scien"}'
```

Fixture: `algolia-listen_prod_all-query.json`. The key is public and embedded in the page. If it rotates, re-read it from `/listen/search` `__NEXT_DATA__` (`componentProps.client.{appId,apiKey}`, `indexName`).

---

## 8. Images

1. **WCMS (CoreMedia) images**: `https://live-production.wcms.abc-cdn.net.au/<32-hex>?impolicy=wcms_crop_resize&cropH=<h>&cropW=<w>&xPos=<x>&yPos=<y>&width=<W>&height=<H>`
   - Keep the crop params from the API and change `width`/`height` freely. Tested: 300×300 at 28 KB and 1400×1400 at 443 KB, both JPEG.
   - Without params you get the original (e.g. 3000×3000, about 2 MB). `<hash>.jpg?src` is also the original.
   - `impolicy` without the crop params returns a 1×1 pixel, so don't drop the crop.
   - The API supplies `srcSet` widths of 160 and 862. Algolia supplies ready-made `defaultThumbnail` for ratios 1x1, 16x9, 3x2, 3x4, 4x3 and 9x16.
2. **Radio resizer (Thumbor, HMAC-signed)**: `https://resize.abcradio.net.au/<sig>=/<W>x<H>/center/middle/<url-encoded source>`
   - Used by EPG, schedule and music artwork.
   - Changing the size invalidates the signature (400). Use one of the supplied `srcSet` sizes (100, 160, 340, 580, 940, 1300) or URL-decode the embedded source (e.g. `https://www.abc.net.au/radio/images/program/AllInTheMind2000x1125.jpg`, fetched OK) and use the original.
3. Music artwork: `now.recording.releases[].artwork[].sizes[]` (100/160/340/580/940/1300…) and the original `url`.
4. Station logos: wcms 1x1 (see §2). PAPI uses `https://www.abc.net.au/radio/images/service/<x>.png`.

For LMS, use 1x1 program art from `cardImagePrepared.imgSrc` (wcms) and swap `width`/`height` to the size you want.

---

## 9. Text fields (where to find them)

| Item | Title | Short / long text | Presenters | Dates | Duration |
|---|---|---|---|---|---|
| Station (BFF/PAPI) | `cardTitle` / PAPI `title` | PAPI `mini_synopsis` | from `epgNowPlaying.preparedPresenters` | - | - |
| Program (Algolia) | `title` | `shortTeaserText` / `description` | `contributors[].contributorItems[]{firstName,lastName}` | `dates.lastUpdated` | - |
| Program (Next data) | `heroImageWithCTAPrepared.heading` | `heroDescriptionPrepared` (rich text) | `presentersPrepared[].label.full` | - | - |
| Episode card (BFF) | `cardTitle` | `description` | `presentersPrepared[].names.full` | `cardAttributionPrepared.publishedDate` | `cardMediaIndicatorPrepared.duration` |
| Episode doc | `title` | `synopsis`, `transcript` | `contributors` / `embedded.contributors` | `datelinePrepared.{publishedDate,updatedDate}` | `duration` |
| Schedule item | `title` | `synopsis` | `presenters[]` | `rawStartTime/rawEndTime` | - |

Rich-text fields are a `descriptor` tree. Flatten the `type:"text"` nodes in order.

---

## 10. Authentication and what login unlocks

- The mechanism is **Gigya (SAP Customer Data Cloud)**.
  - `https://login.abc.net.au/js/gigya.js?apikey=<site key>` is a CNAME to Gigya data centre `au1` (`x-server: gator-au1-prod`).
  - Web code calls `gigya.accounts.getJWT`, `accounts.logout` and `sso.getContext`.
  - Profile/preferences backend: `https://mylogin-api.abc.net.au/latest/{verify-login,update-user,update-preferences}` with a Gigya `id_token`. Account UI at `https://account.abc.net.au`.
  - Personalised recommendations use `ABCAccountID`/`ABCGuestID` cookies. A Firebase auth-key endpoint (`/core-next/api/firebase/auth-key`) is used only for polls and quizzes.
  - Not attempted: no logins were made and no accounts created.
- **What login unlocks.** Source: ABC Help Centre articles 360001722636, 360001508795, 360001690155 and 360001963636, read via `https://help.abc.net.au/api/v2/help_center/articles/search.json?query=listen%20account`. These are all app-side:
  - followed programs synced across devices (following itself works without login),
  - listening history / "continue listening",
  - favourite stations order on the app home,
  - Call-In / Text-In,
  - Kids profiles and parental controls.
  - "Having an account is optional and not required on the ABC listen app." Downloads, playlists and follows work without an account.
- On the **website**, login only adds the profile menu, location preference sync and personalised recommendations.
- **No audio is gated behind login.** Restrictions are by **geography** (AU-only rights) and **time windows**, not by account.
- The listen **mobile app** API (follows, history sync) was not discoverable from public web code. No public code was found calling it. Not needed for v1.

---

## 11. Geo-blocking and licensing notes

| Resource | From US test host | Expected in AU |
|---|---|---|
| `www.abc.net.au` pages, `/_next/data`, `/core-next/api/*` | ✅ (cookie `ABC_LD=int`) | ✅ (`ABC_LD=nsw` etc.) |
| `program.abcradio.net.au`, `music.abcradio.net.au`, Algolia | ✅ | ✅ |
| HLS `streaming.abc-cdn.net.au` / `mediaserviceslive.akamaized.net` | ✅ for most | ✅ |
| HLS **ABC Cricket** (`itinerantfour` → `.../2118991/sportitinerant/`) | ❌ Akamai 403 | ✅ presumably (sports rights) |
| Icecast `abc.streamguys1.com` | ✅ (incl. `sport`) | ✅ |
| `live-radio0x.mediahubaustralia.com` | ❌ Cloudflare WAF block | ? (may be a datacenter-IP block; test from the LMS host) |
| On-demand `mediacore-live-production.akamaized.net/audio/...` | ✅ | ✅ |
| On-demand `.../geo-001/...` | ❌ Akamai 403 | ✅ |

The ABC help article "How can I access ABC services overseas?" says radio is generally worldwide, but some sport and music performances are not. In those cases "alternative programs are broadcast or the program will simply not be made visible in the schedule to listeners who aren't in Australia". So schedule and EPG content may differ by `ABC_LD`. Ranking and visibility of AU-only items could also differ from what was seen here.

Licensing: these are unauthenticated endpoints used by ABC's own player. ABC content is © ABC; the plugin should only stream, not re-host, and should keep request rates modest. Help pages and terms were not reviewed in depth.

---

## 12. Risks and fragility

1. **`buildId`** (`build-3afcd04f`, also `data-dpl-id="3afcd04f"`, header `x-nextjs-deployment-id`) changes with every deploy. A stale id makes `/_next/data/...` return **404 HTML**. Mitigation: on 404, GET any HTML page (e.g. `/listen/search`, about 28 KB), regex `"buildId":"([^"]+)"`, then retry. The HTML `__NEXT_DATA__` fallback works but pages are 200–500 KB.
2. **`/core-next/api/*` BFF routes** are internal Next.js API routes (rewritten from `/api/*`). They are undocumented and may change shape. A public Music Assistant provider (`jwilliams99/MusicAssistant_ABC_Australia_programs`) and `wryun/abcradio` already depend on them, which is some evidence of stability.
3. **Algolia**: 400 queries per hour per IP on the public key. The key or index may rotate. The index can be stale (`PENDING`) and lacks some brand-new items. Cache aggressively; LMS sits behind a single home IP.
4. **Episode listing is capped at 250 per program** via the BFF. Deeper history needs Algolia (also capped at 1000 hits per query; filter by date range) or RSS.
5. **Icecast quality is 56 kbps** AAC. Better quality (221–246 kbps AAC-LC) exists only on HLS, which LMS can't play natively. Options:
   - Accept 56k.
   - Implement a Perl HLS ProtocolHandler that fetches `.ts` segments and demuxes AAC (complex; the BBC Sounds LMS plugin does similar work).
   - Try MediaHub from AU.
6. ADTS AAC/HE-AAC playback in LMS depends on player decoder or server transcoding (faad). Most modern players (squeezelite, SB Touch/Radio) handle AAC. Classic/SB3 need server-side transcoding.
7. Stream slugs are not derivable from service ids (`RN`→`rnnsw`, `CLASSIC`→`classicnsw`→Icecast `classicfmnsw`, `KIDSLISTEN`→`abckids`→`abcextra`, `ITINERANT_ONE`→`itinerantone`→`afl`). Resolve via `epgNowPlaying` plus `.pls` at runtime and keep the static fallback table.
8. AAC catch-up files disappear exactly at `availableTo` (404). Filter before listing and handle 404 at play time.
9. Terminus (`https://api.abc.net.au/terminus/api/v2/...`) returns **401** without an API key. ABC's own `terminus-fetch` library needs a private key. Not usable.

---

## 13. Open questions

1. Is `live-radio01.mediahubaustralia.com` reachable from an Australian residential IP? Does `/<CALLSIGN>/mp3/` still serve MP3 (better LMS compatibility, higher bitrate)? Test from the user's LMS host.
2. Are there higher-bitrate Icecast mounts on `abc.streamguys1.com` beyond `icecast.audio`? Not found by guessing.
3. Is the sandbox block of `program.abc.net.au` just this environment's proxy? `program.abcradio.net.au` is the working PAPI host anyway.
4. How can a podcast RSS feed id be mapped from a program id without third-party lookups?
5. What does `webDistributionRestricted: true` content look like, and how common is it? No sample was found.
6. Do EPG and schedule responses differ for AU visitors (`ABC_LD` cookie) in ways that matter? For example, are hidden international-restricted programs present?
7. Is `docType: "audio"` (e.g. triple j ICYMI, sport clips) structurally identical to `audioepisode`? It appears so but only lightly checked.

---

## Appendix: endpoint cheat-sheet

```
# buildId
curl -s https://www.abc.net.au/listen/search | grep -o '"buildId":"[^"]*"'

# stations
curl -s https://program.abcradio.net.au/api/v1/services.json
curl -s 'https://www.abc.net.au/core-next/api/collection/listen/radio?collectionId=12872264&rootMetaCollectionId=14139428&metaInMeta=false'
curl -s 'https://www.abc.net.au/core-next/api/epgNowPlaying/LOCAL_SYDNEY/now?imageRatio=1x1'
curl -s https://streaming.abc-cdn.net.au/audio/ice/localsydney.pls

# programs / episodes
curl -s "https://www.abc.net.au/_next/data/$BUILD/listen/programs/scienceshow.json" | jq .pageProps.programCollectionPrepared.id
curl -s 'https://www.abc.net.au/core-next/api/episodesWithSegments/x?collectionId=2885458&offset=0&size=20'
curl -s "https://www.abc.net.au/_next/data/$BUILD/listen/programs/scienceshow/x/107266790.json"   # -> __N_REDIRECT to canonical, then .pageProps.data.documentProps.renditions
curl -s -r 0-1023 -D - -o /dev/null https://mediacore-live-production.akamaized.net/audio/02/pg/Z/ai.mp3   # 206 audio/mpeg

# now playing / schedule
curl -s 'https://www.abc.net.au/core-next/api/musicNowPlaying/TRIPLEJ'
curl -s https://music.abcradio.net.au/api/v1/plays/doublej/now.json
curl -s 'https://www.abc.net.au/core-next/api/schedule?service=RN&date=2026-10-19&tz=Australia/Sydney&ratio=1x1'

# home / collections / recs
curl -s "https://www.abc.net.au/_next/data/$BUILD/listen.json"
curl -s 'https://www.abc.net.au/core-next/api/collection/x?collectionId=103194120&offset=0&size=20'
curl -s 'https://www.abc.net.au/core-next/api/recommendations/listen/homepagePopularNow'
```

Public prior art consulted:
- `jwilliams99/MusicAssistant_ABC_Australia_programs` (Music Assistant provider using Next data and the BFF; it enforces `availableTo` for all renditions, which is stricter than the site for MP3).
- `wryun/abcradio` (station list via the same BFF collection URLs; now-playing via `epgNowPlaying` and `music.abcradio.net.au`).
- `MarkusSteinbrecher/rrradio` `docs/broadcaster-research.md` (PAPI `program.abcradio.net.au` and the music API).
- `junguler/m3u-radio-music-playlists` (lists `abc.streamguys1.com` Icecast mounts).
