#!/usr/bin/env bash
# abc-endpoints-check.sh - drift probe for every ABC endpoint the plugin relies on at run time
# (ai-state/research/abc-listen-api.md, ABCListen/API.pm and its callers). Each family sends its
# requests the way the plugin does and asserts the JSON paths the plugin's parsers read, not just
# HTTP 200.
# Prints "PASS <family>: <detail>" or "FAIL <family>: <reason>" per family (one line each) and exits
# 1 if any family failed, 2 if a tool is missing.
#
# Families, and the plugin code that depends on them:
#   search page            /listen/search: buildId, and the Algolia app id, key and index
#                          (API::siteConfig; Search, the A-Z, chapters and restricted episodes
#                          need the key)
#   _next/data             a program page and an episode redirect (API::nextData, Programs, Episode)
#   episodesWithSegments   a program's episodes (Programs::episodes)
#   collection             a BFF collection (Collections::items)
#   epgNowPlaying          RN now and next (NowPlaying; Stations' event checks)
#   music                  musicNowPlaying and plays/search.json (Tracks: time-zone versions,
#                          recently played)
#   schedule               a day's schedule (Schedule)
#   Algolia search         the Search menu's programs and episodes queries (Search)
#   pls                    a .pls playlist -> Icecast mount (Stations)
#   non-ASCII path         a %XX page path requested lower-case (API::nextData, F4)
#   legacy 308             a legacy program path's 308 (API::nextData, F4/F6)
#   program aggregations   programAggregationCollection/x for every collection id of Programs.pm's
#                          networks (Programs -> By network; 9317914 is Kids listen -> All programs)
#   section extras         Sections.pm's Kids listen extras: its collection ids and the News Time page
#   recommendations        recommendations/listen/* (Home -> Popular now, Popular in sport)
#   music now              plays/<station>/now.json of every music station (Tracks::now)
#   section pages          componentsContent of the Home, News, Sport, Kids listen, Audiobooks and
#                          Podcasts pages (Collections::page and podcasts; Sections)
#   Algolia program index  the A-Z / By type query (ProgramIndex::programs)
#   Algolia chapters       an audiobook's chapters (Audiobooks; restricted podcasts' Episodes send
#                          the same query) and the objectID lookup (Episode)
#   station collections    the national and state station collections (Stations::enrich)
# PAPI (program.abcradio.net.au) is not probed: the plugin doesn't call it at run time
# (scripts/gen-station-data.py reads it when the station catalogue is regenerated).
# The collection ids, page paths and station names are copies of the plugin's tables (below);
# t/89-endpoints-check.t checks that they still match the modules.
#
# Run by hand, and weekly by .github/workflows/abc-drift.yml, which opens or updates an "ABC
# endpoint drift" issue when it fails. Never run by scripts/check.sh or on pull requests, and don't
# loop it (ABC etiquette): one run sends about 60 requests.
# Needs bash, curl and jq. Uses $HTTPS_PROXY when set, and --max-time 10 per request.
# No Algolia credentials are hard-coded: they are read from /listen/search at run time, like
# API::siteConfig. The key and the app id are never printed: every PASS/FAIL line is redacted, and
# in GitHub Actions (GITHUB_ACTIONS=true) both are first registered with ::add-mask::, so the log
# masks them too (that command line is the only output that holds them; the runner hides it).
#
# Overrides (environment):
#   ABC_PROGRAM_PATH  program page for _next/data   (default /listen/programs/scienceshow)
#   ABC_EPISODE_PATH  any-slug episode page that redirects (default /listen/programs/scienceshow/x/107266790)
#   ABC_COLLECTION_ID collection for the collection family (default 103194120)
#   ABC_NONASCII_ID   episode whose canonical path has a non-ASCII slug (default 107267360, "El Niño")
#   ABC_LEGACY_PATH   legacy program path that 308-redirects to /listen (default /radionational/programs/futuretense)
#   ABC_AUDIOBOOK_ID  audiobook program id for Algolia chapters (default: the first of the program
#                     index's audiobooks, up to 3, that has chapters)
#
# Deliberate breakage, to see a family fail the way it would when ABC drifts:
#   ABC_CHECK_BREAK_PATH=<family>[,<family>...]
#       that family's requests go to a path ABC doesn't serve: "-drift" is added to the BFF
#       endpoint name (core-next/api/collection-drift/x), to a .json page or file name
#       (/listen/news-drift.json, plays/triplej/now-drift.json), else to the last path segment
#       (/listen/search-drift, Algolia's .../query-drift).
#   ABC_CHECK_BREAK_FIELD=<family>:<key>[,<family>:<key>...]
#       in that family's JSON answers (search page: its __NEXT_DATA__), every key named <key> is
#       renamed <key>-drift before the checks, as if ABC had renamed the field.
#
#   ABC_PROGRAM_PATH=/listen/programs/nope scripts/abc-endpoints-check.sh       # FAIL _next/data: ...
#   ABC_CHECK_BREAK_PATH='music now' scripts/abc-endpoints-check.sh              # FAIL music now: HTTP 404 ...
#   ABC_CHECK_BREAK_FIELD='section pages:componentsContent' scripts/abc-endpoints-check.sh
set -uo pipefail

SITE=https://www.abc.net.au
BFF=$SITE/core-next/api
MUSIC_API=https://music.abcradio.net.au/api/v1
PROGRAM_PATH=${ABC_PROGRAM_PATH:-/listen/programs/scienceshow}
EPISODE_PATH=${ABC_EPISODE_PATH:-/listen/programs/scienceshow/x/107266790}
COLLECTION_ID=${ABC_COLLECTION_ID:-103194120}
NONASCII_ID=${ABC_NONASCII_ID:-107267360}
LEGACY_PATH=${ABC_LEGACY_PATH:-/radionational/programs/futuretense}
AUDIOBOOK_ID=${ABC_AUDIOBOOK_ID:-}
FAMILIES=19

# ---- Copies of the plugin's tables (t/89-endpoints-check.t keeps them in step with the modules) ----
# Programs.pm @NETWORKS collectionIds, in table order
AGGREGATION_IDS=(11474038 13910480 8698186 9375554 9104650 8794720 12606644 9317914 106304964 9373518 9412768)
# Sections.pm %SECTIONS: the Kids listen extras, collections (<id>[:<kind>]) and programs (page paths)
SECTION_COLLECTIONS=(9317914:aggregation 104141842 106510880)
SECTION_PROGRAMS=(/kidslisten/programs/news-time)
# <menu name>:<page path>: Collections::home, Sections.pm's four sections, Collections' PODCASTS_PATH
SECTION_PAGES=(Home:/listen News:/listen/news Sport:/listen/sport 'Kids listen:/kidslisten' Audiobooks:/listen/audiobooks Podcasts:/listen/podcasts)
# Discover.pm: Popular now, Popular in sport
RECOMMENDATIONS=(homepagePopularNow homepageSports)
# StationData.pm musicStation of the music networks (Tracks::station)
MUSIC_STATIONS=(kidslisten classic triplej doublej country jazz unearthed classic2 h100)
# Stations.pm @COLLECTIONS, <collectionId>:<rootMetaCollectionId>: national, then NSW ACT NT VIC SA TAS QLD WA
STATION_COLLECTIONS=(12872264:14139428 14126370:14123276 14126436:14123276 14128062:14123276 14128070:14123276 14128508:14123276 14128536:14123276 14128542:14123276 14128996:14123276)
# ProgramIndex::siteFilter (Search uses it too)
SITE_FILTER='(siteSegment:listen OR siteSegment:triplej OR siteSegment:kidslisten OR siteSegment:triplejunearthed OR siteSegment:pacific OR canonicalURI_fragments:listen OR canonicalURI_fragments:triplej OR canonicalURI_fragments:kidslisten OR canonicalURI_fragments:triplejunearthed OR canonicalURI_fragments:pacific)'

MIN_INDEX_PROGRAMS=100   # program pages the A-Z index has at least (743 on 2026-10-25)
MAX_AUDIOBOOK_TRIES=3    # audiobooks asked for chapters before Algolia chapters fails

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "abc-endpoints-check: $tool is required" >&2; exit 2; }
done

curl_opts=(-sS --max-time 10 -A 'SqueezeABCListen endpoint check (curl)')
[[ -n "${HTTPS_PROXY:-}" ]] && curl_opts+=(--proxy "$HTTPS_PROXY")

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

failures=0
started=$SECONDS
build_id='' app_id='' api_key='' index_name='' error=''

# Every result line goes through say, which blanks the Algolia key and app id wherever they occur.
say() {
  local line=$1
  [[ -n "$api_key" ]] && line=${line//"$api_key"/<apiKey>}
  [[ -n "$app_id" ]] && { line=${line//"$app_id"/<appId>}; line=${line//"${app_id,,}"/<appId>}; }
  printf '%s\n' "$line"
}
pass() { say "PASS $1: $2"; }
fail() { say "FAIL $1: $2"; failures=$((failures + 1)); }

# jq definitions shared by the checks; they mirror the plugin's parsers.
#   digits     a number or all-digit string, as a string (Collections::_digits), else null
#   cm_type    a card's coremedia://<type>/<digits> contentUri type (API::coreMediaRef), else null
#   site_path  a URL or path on www.abc.net.au -> its path (API::sitePath), else null
#   leaf       the all-digit last segment of a path (Collections::_leaf), else null
#   card_kind  what Collections::_target makes of a card: program, episode, collection, category,
#              station, or null (not listed). station is any channel or externallink card with a
#              page on the site: Stations->byPageSlug decides which are stations, not copied here.
#   cards      the listed cards of an array; program_cards: those Programs::_programRef keeps (a
#              coremedia card with a title and a path on the site)
#   page_summary  Collections::_parsePage of a _next/data page: collections (StandardCollection,
#              MetaCollection sub-collection, ProgramAggregationCollection), meta (sub-collections),
#              hero, stations (MiniEPG, LiveRadioCarousel), categories (podcast categories collections)
# shellcheck disable=SC2016  # $t, $p, $c ... are jq variables
JQ_DEFS='
def digits: if (type == "string" or type == "number") and (tostring | test("^[0-9]+$")) then tostring else null end;
def cm_type: (.contentUri // null) as $u | if ($u | type) == "string" then ($u | capture("^coremedia://(?<t>[A-Za-z][A-Za-z0-9_]*)/[0-9]+$") | .t | ascii_downcase) // null else null end;
def site_path: if type != "string" then null
  elif test("^\\s*(https?:)?//"; "i") then ((capture("^\\s*(https?:)?//(www\\.)?abc\\.net\\.au(?<p>/[^?#]*)?([?#].*)?$"; "i") | .p // "/") // null)
  elif test("^\\s*/") then (capture("^\\s*(?<p>/[^?#]*)") | .p)
  else null end
  | if . == null then null else (sub("\\s+$"; "") | sub("/+$"; "") | if . == "" then "/" else . end) end;
def leaf: (sub("/+$"; "") | capture("/(?<id>[0-9]+)$") | .id) // null;
def card_kind: cm_type as $t | (.articleLink | site_path) as $p |
  if $t == null then null
  elif $t == "program" then (if $p then "program" else null end)
  elif ($t == "audioepisode" or $t == "audio" or $t == "audiosegment") then "episode"
  elif $t == "collection" then "collection"
  elif $t == "dynamiccollection" then (if $p and ($p | leaf) then "category" else null end)
  elif ($t == "channel" or $t == "externallink") then (if $p then "station" else null end)
  elif ($t == "teaser" or $t == "unknown") then
    (if ($p // "") | test("/programs/") then (if ($p | leaf) then "episode" elif ($p | test("/programs/[^/]+$")) then "program" else null end) else null end)
  else null end;
def cards: [.[]? | objects | select(card_kind)];
def program_cards: [.[]? | objects | select(cm_type and ((.cardTitle // "") | type == "string" and test("\\S")) and (.articleLink | site_path))];
def page_summary: [.pageProps.data.componentsContent[]? | objects] as $c
  | ($c | map(select(.component == "StandardCollection" and ([.componentProps.id?, .key] | map(digits | select(.)) | first) and ((.componentProps.items? | cards) | length > 0)))) as $std
  | ($c | map(select(.component == "MetaCollection") | .componentProps.items[]? | objects | select((.id | digits) and (.itemsCount != 0)))) as $meta
  | ($c | map(select(.component == "ProgramAggregationCollection" and ((.componentProps.items? | cards) | length > 0)))) as $agg
  | { collections: (($std | length) + ($meta | length) + ($agg | length)),
      meta: ($meta | length),
      hero: ($c | map(select(.component == "HeroCarousel") | .componentProps.items[]? | objects | select(.itemUri | type == "string" and test("^coremedia://[A-Za-z][A-Za-z0-9_]*/[0-9]+$"))) | length),
      stations: ($c | map((select(.component == "MiniEPG") | .componentProps), (select(.component == "LiveRadioCarousel") | .componentProps.cards[]?) | objects | select(.papiServiceId | type == "string" and test("^[A-Za-z0-9_]+$"))) | length),
      categories: ($std | map(.componentProps.items | cards | select(all(.[]; card_kind == "category") and ([.[] | .articleLink | site_path | leaf] | unique | length >= 2))) | length) };
'

# fetch <outfile> <url> [curl args...] -> prints the HTTP status ("000" on a transport error)
fetch() {
  local out=$1 url=$2
  shift 2
  curl "${curl_opts[@]}" -o "$out" -w '%{http_code}' "$@" "$url" 2>"$out.err" || true
}

# check <file> <jq expression that must be true>; value <file> <jq expression> -> its raw output
check() { jq -e "$JQ_DEFS $2" "$1" >/dev/null 2>&1; }
value() { jq -r "$JQ_DEFS $2" "$1" 2>/dev/null; }

# in_list <item> <comma-separated list>
in_list() { [[ ",$2," == *",$1,"* ]]; }

# summarize "<key>: <message>"... -> "<key>, <key>: <message>; <key>: <message>", one entry per
# distinct message, in order (so 11 collections failing alike make one entry)
summarize() {
  local entry key message out='' i
  local -a messages=() keys=()
  for entry in "$@"; do
    key=${entry%%: *} message=${entry#*: }
    for i in "${!messages[@]}"; do
      if [[ "${messages[$i]}" == "$message" ]]; then
        keys[i]+=", $key"
        continue 2
      fi
    done
    messages+=("$message")
    keys+=("$key")
  done
  for i in "${!messages[@]}"; do
    out+="${out:+; }${keys[$i]}: ${messages[$i]}"
  done
  printf '%s' "$out"
}

# request_url <family> <url> -> the URL to request: the URL itself, or with ABC_CHECK_BREAK_PATH
# naming the family, a path ABC doesn't serve (see the header)
request_url() {
  local family=$1 url=$2 base query='' rest
  if ! in_list "$family" "${ABC_CHECK_BREAK_PATH:-}"; then
    printf '%s' "$url"
    return
  fi
  base=${url%%\?*}
  [[ "$url" == *\?* ]] && query="?${url#*\?}"
  case "$base" in
    "$BFF"/*) rest=${base#"$BFF"/}; base="$BFF/${rest%%/*}-drift${rest#"${rest%%/*}"}" ;;
    *.json) base="${base%.json}-drift.json" ;;
    *) base="$base-drift" ;;
  esac
  printf '%s%s' "$base" "$query"
}

# break_fields <family> <json file>: ABC_CHECK_BREAK_FIELD's renames for the family (see the header)
break_fields() {
  local family=$1 file=$2 spec specs
  IFS=, read -r -a specs <<<"${ABC_CHECK_BREAK_FIELD:-}"
  for spec in "${specs[@]}"; do
    [[ "$spec" == *:* && "${spec%%:*}" == "$family" ]] || continue
    jq --arg k "${spec#*:}" 'walk(if type == "object" then with_entries(if .key == $k then .key += "-drift" else . end) else . end)' \
      "$file" >"$file.drift" 2>/dev/null && mv "$file.drift" "$file"
  done
}

# request <family> <outfile> <url> [curl args...]: fetch, expect HTTP 200 and JSON; else return 1
# with the reason in $error (nothing printed)
request() {
  local family=$1 out=$2 url status
  url=$(request_url "$family" "$3")
  shift 3
  error=''
  status=$(fetch "$out" "$url" "$@")
  if [[ "$status" != 200 ]]; then
    error="HTTP $status from ${url%%\?*}$( [[ -s "$out.err" ]] && printf ' (%s)' "$(head -c 200 "$out.err" | tr '\n' ' ')" )"
    return 1
  fi
  if ! jq -e . "$out" >/dev/null 2>&1; then
    error="not JSON from ${url%%\?*}"
    return 1
  fi
  break_fields "$family" "$out"
}

# get_json <family> <outfile> <url> [curl args...]: request; FAIL the family if it fails
get_json() { request "$@" || { fail "$1" "$error"; return 1; }; }

# algolia <family> <outfile> <params JSON>: a query with the credentials from the search page, as
# API::algolia sends it (the headers are read from a pipe, so the key isn't on curl's command line)
algolia() {
  request "$1" "$2" "https://$app_id-dsn.algolia.net/1/indexes/$index_name/query" -X POST \
    -H @<(printf 'X-Algolia-Application-Id: %s\nX-Algolia-API-Key: %s\n' "$app_id" "$api_key") \
    -H 'Content-Type: application/json' --data "$3"
}

# 1. search page: buildId and the Algolia config in __NEXT_DATA__ (API::siteConfig)
search_url=$(request_url 'search page' "$SITE/listen/search")
status=$(fetch "$tmp/search.html" "$search_url")
if [[ "$status" != 200 ]]; then
  fail 'search page' "HTTP $status from ${search_url#"$SITE"}"
else
  build_id=$(grep -o '"buildId":"[^"]*"' "$tmp/search.html" | head -n 1 | cut -d '"' -f 4)
  [[ "$build_id" =~ ^[A-Za-z0-9._-]+$ ]] || build_id=''
  grep -o '<script id="__NEXT_DATA__"[^>]*>[^<]*</script>' "$tmp/search.html" | sed -e 's/^<script[^>]*>//' -e 's/<\/script>$//' >"$tmp/next.json"
  break_fields 'search page' "$tmp/next.json"
  # API::_findAlgolia: a hash with client {appId, apiKey} and a sibling indexName, each as
  # API::_algoliaConfig accepts it; the Search component's first, then any index but a
  # query-suggestions one, then any
  if ! read -r app_id api_key index_name < <(jq -r '
      def config: select((.client? | type) == "object"
        and (.client.appId | type) == "string" and (.client.appId | test("^[A-Za-z0-9]+$"))
        and (.client.apiKey | type) == "string" and (.client.apiKey | test("^[\\x21-\\x7E]+$"))
        and (.indexName | type) == "string" and (.indexName | test("^[A-Za-z0-9._-]+$")));
      [ (.. | objects | select(.component? == "Search") | .[] | objects | config),
        (.. | objects | config | select(.indexName | test("suggestion"; "i") | not)),
        (.. | objects | config) ]
      | first // empty | "\(.client.appId) \(.client.apiKey) \(.indexName)"' "$tmp/next.json" 2>/dev/null); then
    app_id='' api_key='' index_name=''
  fi
  if [[ -n "$api_key" && "${GITHUB_ACTIONS:-}" == true ]]; then
    printf '::add-mask::%s\n' "$api_key" "$app_id" "${app_id,,}"
  fi
  if [[ -n "$build_id" && -n "$api_key" ]]; then
    pass 'search page' "buildId $build_id, Algolia index $index_name (app id and key found)"
  else
    fail 'search page' "buildId '${build_id:-none}'; $( [[ -n "$api_key" ]] && echo 'Algolia config found' || echo 'no Algolia appId/apiKey/indexName in __NEXT_DATA__' )"
  fi
fi

# 2. _next/data: program page, then an any-slug episode page that redirects to its canonical path
collection_id=''
if [[ -z "$build_id" ]]; then
  fail '_next/data' 'no buildId (search page failed)'
elif get_json '_next/data' "$tmp/program.json" "$SITE/_next/data/$build_id$PROGRAM_PATH.json"; then
  if ! check "$tmp/program.json" '.pageProps.programCollectionPrepared.id | (type == "number") or (type == "string" and test("^[0-9]+$"))'; then
    fail '_next/data' ".pageProps.programCollectionPrepared.id is not a number in $PROGRAM_PATH"
  else
    collection_id=$(value "$tmp/program.json" '.pageProps.programCollectionPrepared.id')
    if get_json '_next/data' "$tmp/redirect.json" "$SITE/_next/data/$build_id$EPISODE_PATH.json"; then
      target=$(value "$tmp/redirect.json" '.pageProps.__N_REDIRECT // empty | strings')
      target=${target#https://www.abc.net.au}
      if [[ "$target" != /* ]]; then
        fail '_next/data' "no .pageProps.__N_REDIRECT for $EPISODE_PATH"
      elif get_json '_next/data' "$tmp/episode.json" "$SITE/_next/data/$build_id$target.json"; then
        if check "$tmp/episode.json" '.pageProps.data.documentProps.renditions[0].url | type == "string" and length > 0'; then
          pass '_next/data' "programCollectionPrepared.id $collection_id; $EPISODE_PATH -> $target has renditions"
        else
          fail '_next/data' "no .pageProps.data.documentProps.renditions[0].url at $target"
        fi
      fi
    fi
  fi
fi

# 3. episodesWithSegments
if [[ -z "$collection_id" ]]; then
  fail 'episodesWithSegments' 'no collection id (_next/data failed)'
elif get_json 'episodesWithSegments' "$tmp/episodes.json" "$BFF/episodesWithSegments/x?collectionId=$collection_id&offset=0&size=2"; then
  if check "$tmp/episodes.json" '(.collection.items[0].contentUri | type == "string" and startswith("coremedia://")) and (.collection.pagination.total | type == "number")'; then
    pass 'episodesWithSegments' "total $(value "$tmp/episodes.json" '.collection.pagination.total'), first $(value "$tmp/episodes.json" '.collection.items[0].contentUri')"
  else
    fail 'episodesWithSegments' 'expected .collection.items[0].contentUri (coremedia://...) and a numeric .collection.pagination.total'
  fi
fi

# 4. collection
if get_json 'collection' "$tmp/collection.json" "$BFF/collection/x?collectionId=$COLLECTION_ID&offset=0&size=2"; then
  if check "$tmp/collection.json" '.collection.items[0] | (.contentUri | type == "string") and (.cardTitle | type == "string") and (.cardImagePrepared.imgSrc | type == "string")'; then
    pass 'collection' "$(value "$tmp/collection.json" '.collection.title // "untitled"'): first card $(value "$tmp/collection.json" '.collection.items[0].contentUri')"
  else
    fail 'collection' 'expected .collection.items[0].{contentUri,cardTitle,cardImagePrepared.imgSrc}'
  fi
fi

# 5. epgNowPlaying: now and next (NowPlaying::parse needs .title; Stations' event check .sources)
if get_json 'epgNowPlaying' "$tmp/epg.json" "$BFF/epgNowPlaying/RN/now?imageRatio=1x1"; then
  if ! check "$tmp/epg.json" '(.title | type == "string") and (.start | type == "string") and (.sources | type == "array")'; then
    fail 'epgNowPlaying' 'RN now: expected .title, .start and a .sources array'
  elif get_json 'epgNowPlaying' "$tmp/epg-next.json" "$BFF/epgNowPlaying/RN/next?imageRatio=1x1"; then
    if check "$tmp/epg-next.json" '(.title | type == "string") and (.start | type == "string")'; then
      pass 'epgNowPlaying' "RN now: $(value "$tmp/epg.json" '.title'); next: $(value "$tmp/epg-next.json" '.title')"
    else
      fail 'epgNowPlaying' 'RN next: expected .title and .start'
    fi
  fi
fi

# 6. music: BFF musicNowPlaying and the public music API's recently played list
if get_json 'music' "$tmp/music-now.json" "$BFF/musicNowPlaying/TRIPLEJ"; then
  if ! check "$tmp/music-now.json" 'has("mapiNow")'; then
    fail 'music' 'musicNowPlaying/TRIPLEJ has no mapiNow key'
  elif get_json 'music' "$tmp/plays.json" "$MUSIC_API/plays/search.json?station=triplej&order=desc&limit=1"; then
    if check "$tmp/plays.json" '.items[0].recording.title | type == "string"'; then
      pass 'music' "mapiNow present; last triple j play: $(value "$tmp/plays.json" '.items[0].recording.title')"
    else
      fail 'music' 'plays/search.json: no .items[0].recording.title'
    fi
  fi
fi

# 7. schedule (today in Sydney)
today=$(TZ=Australia/Sydney date +%F)
if get_json 'schedule' "$tmp/schedule.json" "$BFF/schedule?service=RN&date=$today&tz=Australia/Sydney&ratio=1x1"; then
  if check "$tmp/schedule.json" '(.formattedScheduleArray[0].items[0].title | type == "string") and (.serviceTimezone | type == "string")'; then
    pass 'schedule' "RN $today ($(value "$tmp/schedule.json" '.serviceTimezone')): $(value "$tmp/schedule.json" '.formattedScheduleArray[0].items[0].title')"
  else
    fail 'schedule' 'expected .formattedScheduleArray[0].items[0].title and .serviceTimezone'
  fi
fi

# 8. Algolia search: Search's two queries for "science" (programs, distinct 0; episodes)
if [[ -z "$api_key" ]]; then
  fail 'Algolia search' 'no credentials (search page failed)'
else
  attributes='["objectID","title","canonicalURL","contentType","defaultThumbnail","programDefaultThumbnail","infoSource","shortTeaserText","description","teaserText","synopsis","programTitle","programID","duration","dates","mediaRenditions","mediaDownloadStatus","mediaStreamingStatus","programType"]'
  programs_query=$(jq -cn --arg f "contentType:program AND $SITE_FILTER" --argjson a "$attributes" \
    '{query: "science", hitsPerPage: 20, filters: $f, attributesToRetrieve: $a, distinct: 0}')
  episodes_query=$(jq -cn --arg f "(contentType:audioepisode OR contentType:audio OR contentType:audiosegment) AND $SITE_FILTER" --argjson a "$attributes" \
    '{query: "science", hitsPerPage: 40, filters: $f, attributesToRetrieve: $a}')
  if ! algolia 'Algolia search' "$tmp/search-programs.json" "$programs_query"; then
    fail 'Algolia search' "programs: $error"
  elif ! check "$tmp/search-programs.json" '[.hits[]? | objects | select((.objectID | type == "string" and test("^coremedia://program/[0-9]+$")) and (.title | type == "string") and (.canonicalURL | site_path))] | length > 0'; then
    fail 'Algolia search' "programs: no hit with a coremedia://program/<id> objectID, a title and a canonicalURL on www.abc.net.au"
  elif ! algolia 'Algolia search' "$tmp/search-episodes.json" "$episodes_query"; then
    fail 'Algolia search' "episodes: $error"
  elif ! check "$tmp/search-episodes.json" '[.hits[]? | objects | select((.objectID | type == "string" and test("^coremedia://(audioepisode|audio|audiosegment)/[0-9]+$")) and (.title | type == "string"))] | length > 0'; then
    fail 'Algolia search' "episodes: no hit with a coremedia://<audio type>/<id> objectID and a title"
  else
    pass 'Algolia search' "'science': $(value "$tmp/search-programs.json" '.nbHits') programs, first $(value "$tmp/search-programs.json" '.hits[0].objectID'); $(value "$tmp/search-episodes.json" '.nbHits') episodes, first $(value "$tmp/search-episodes.json" '.hits[0].objectID')"
  fi
fi

# 9. .pls -> Icecast mount
pls_url=$(request_url 'pls' 'https://streaming.abc-cdn.net.au/audio/ice/triplejnsw.pls')
status=$(fetch "$tmp/pls" "$pls_url")
if [[ "$status" != 200 ]]; then
  fail 'pls' "HTTP $status from ${pls_url##*/}"
elif file1=$(tr -d '\r' <"$tmp/pls" | grep -m 1 '^File1=https://abc\.streamguys1\.com/live/'); then
  pass 'pls' "${file1#File1=}"
else
  fail 'pls' 'no File1=https://abc.streamguys1.com/live/... line in triplejnsw.pls'
fi

# 10. non-ASCII path (F4): the generic path redirects to the canonical path, which ABC spells with
#     upper-case %XX escapes; requested lower-case, as API::nextData does, it must serve the episode
#     document. The spelling as given is probed for the log only: ABC answered it with a 307 that has
#     only an x-nextjs-redirect header (no Location), which LMS can't follow (2026-10-19).
generic_path="/listen/programs/x/x/$NONASCII_ID"
if [[ -z "$build_id" ]]; then
  fail 'non-ASCII path' 'no buildId (search page failed)'
elif get_json 'non-ASCII path' "$tmp/nonascii-redirect.json" "$SITE/_next/data/$build_id$generic_path.json"; then
  target=$(value "$tmp/nonascii-redirect.json" '.pageProps.__N_REDIRECT // empty | strings')
  target=${target#https://www.abc.net.au}
  if [[ "$target" != /* ]]; then
    fail 'non-ASCII path' "no .pageProps.__N_REDIRECT for $generic_path"
  elif [[ "$target" != *%[0-9A-Fa-f][0-9A-Fa-f]* ]]; then
    fail 'non-ASCII path' "$target has no %XX escape (set ABC_NONASCII_ID to another episode)"
  else
    served=${target,,}
    as_given=$(fetch "$tmp/nonascii-as-given.json" "$SITE/_next/data/$build_id$target.json")
    if get_json 'non-ASCII path' "$tmp/nonascii.json" "$SITE/_next/data/$build_id$served.json"; then
      if check "$tmp/nonascii.json" "(.pageProps.data.documentProps.id | tostring) == \"$NONASCII_ID\""; then
        pass 'non-ASCII path' "$generic_path -> $target (HTTP $as_given as given); lower-case: document $NONASCII_ID"
      else
        fail 'non-ASCII path' "no .pageProps.data.documentProps.id $NONASCII_ID at $served"
      fi
    fi
  fi
fi

# 11. legacy program path (F4, F6): the page data of /radionational/programs/futuretense (Algolia's
#     canonicalURL for some programs) answers HTTP 308 with a Location to its /listen page. LMS
#     doesn't follow a 308; API::nextData follows the Location (x-nextjs-redirect only without one).
if [[ -z "$build_id" ]]; then
  fail 'legacy 308' 'no buildId (search page failed)'
else
  legacy_url=$(request_url 'legacy 308' "$SITE/_next/data/$build_id$LEGACY_PATH.json")
  status=$(fetch "$tmp/legacy.body" "$legacy_url" -D "$tmp/legacy.headers")
  location=''
  [[ -s "$tmp/legacy.headers" ]] && location=$(tr -d '\r' <"$tmp/legacy.headers" | sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]: *//p' | head -n 1)
  location=${location#https://www.abc.net.au}
  if [[ "$status" != 308 ]]; then
    fail 'legacy 308' "HTTP $status from ${legacy_url#"$SITE/_next/data/$build_id"} (expected 308)$( [[ -n "$location" ]] && printf ' Location %s' "$location" )"
  elif [[ "$location" != /listen/* ]]; then
    fail 'legacy 308' "308 from $LEGACY_PATH, but its Location '${location:-none}' is not a /listen page"
  else
    pass 'legacy 308' "$LEGACY_PATH -> 308, Location $location"
  fi
fi

# 12. program aggregations: every collection id of Programs.pm's networks, first page as
#     Programs::_collectionPages asks for it; each must list program cards (_programRef: a coremedia
#     card with a cardTitle and an articleLink on the site). No live fallback for these ids.
errors=() cards=0
for id in "${AGGREGATION_IDS[@]}"; do
  if ! request 'program aggregations' "$tmp/aggregation-$id.json" "$BFF/programAggregationCollection/x?collectionId=$id&offset=0&size=50"; then
    errors+=("$id: $error")
  elif ! check "$tmp/aggregation-$id.json" '.collection.items | program_cards | length > 0'; then
    errors+=("$id: no .collection.items[] card with a coremedia contentUri, a cardTitle and an articleLink on the site")
  else
    cards=$((cards + $(value "$tmp/aggregation-$id.json" '.collection.items | program_cards | length')))
  fi
done
if ((${#errors[@]})); then
  fail 'program aggregations' "${#errors[@]} of ${#AGGREGATION_IDS[@]} collections: $(summarize "${errors[@]}")"
else
  pass 'program aggregations' "${#AGGREGATION_IDS[@]} collections, $cards program cards on their first pages"
fi

# 13. section extras: Sections.pm's Kids listen collections (first menu page, as
#     Collections::menuPage asks for it: aggregations 50 cards, others 20) and program pages
#     (Programs::program: a coremedia://program uri and an episode collection). No live fallback.
errors=() found=()
for spec in "${SECTION_COLLECTIONS[@]}"; do
  id=${spec%%:*} kind=''
  [[ "$spec" == *:* ]] && kind=${spec#*:}
  if [[ "$kind" == aggregation ]]; then
    url="$BFF/programAggregationCollection/x?collectionId=$id&offset=0&size=50"
  else
    url="$BFF/collection/x?collectionId=$id&offset=0&size=20"
  fi
  if ! request 'section extras' "$tmp/extra-$id.json" "$url"; then
    errors+=("$id: $error")
  elif ! check "$tmp/extra-$id.json" '.collection.items | cards | length > 0'; then
    errors+=("$id: no .collection.items[] card the menus list")
  else
    found+=("$id $(value "$tmp/extra-$id.json" '.collection.title // .collection.heading // "untitled"')")
  fi
done
for path in "${SECTION_PROGRAMS[@]}"; do
  if [[ -z "$build_id" ]]; then
    errors+=("$path: no buildId (search page failed)")
  elif ! request 'section extras' "$tmp/extra-program.json" "$SITE/_next/data/$build_id$path.json"; then
    errors+=("$path: $error")
  elif ! check "$tmp/extra-program.json" '(.pageProps.heroImageWithCTAPrepared.uri | type == "string" and test("^coremedia://program/[0-9]+$")) and (.pageProps.programCollectionPrepared.id | digits)'; then
    errors+=("$path: expected .pageProps.heroImageWithCTAPrepared.uri coremedia://program/<id> and a .pageProps.programCollectionPrepared.id")
  else
    found+=("$path")
  fi
done
if ((${#errors[@]})); then
  fail 'section extras' "$(summarize "${errors[@]}")"
else
  pass 'section extras' "$(printf '%s, ' "${found[@]}" | sed 's/, $//')"
fi

# 14. recommendations: Home -> Popular now / Popular in sport (Collections::recommendations: cards
#     from .items[])
errors=() found=()
for name in "${RECOMMENDATIONS[@]}"; do
  if ! request 'recommendations' "$tmp/recommendations-$name.json" "$BFF/recommendations/listen/$name"; then
    errors+=("$name: $error")
  elif ! check "$tmp/recommendations-$name.json" '.items | cards | length > 0'; then
    errors+=("$name: no .items[] card the menus list")
  else
    found+=("$name $(value "$tmp/recommendations-$name.json" '.items | cards | length') cards")
  fi
done
if ((${#errors[@]})); then
  fail 'recommendations' "$(summarize "${errors[@]}")"
else
  pass 'recommendations' "$(printf '%s, ' "${found[@]}" | sed 's/, $//')"
fi

# 15. music now: plays/<station>/now.json of every music station (Tracks::parseNow: .now is {}
#     between songs, else .now.recording.title); at least one station must be playing a song
errors=() songs=0 song=''
for station in "${MUSIC_STATIONS[@]}"; do
  if ! request 'music now' "$tmp/now-$station.json" "$MUSIC_API/plays/$station/now.json"; then
    errors+=("$station: $error")
  elif ! check "$tmp/now-$station.json" '(.now | type == "object") and (.now == {} or (.now.recording.title | type == "string" and test("\\S")))'; then
    errors+=("$station: .now is neither {} nor a song with .now.recording.title")
  elif check "$tmp/now-$station.json" '.now != {}'; then
    songs=$((songs + 1))
    [[ -n "$song" ]] || song="$station: $(value "$tmp/now-$station.json" '.now.recording.title')"
  fi
done
if ((${#errors[@]})); then
  fail 'music now' "$(summarize "${errors[@]}")"
elif ((songs == 0)); then
  fail 'music now' "no song (.now.recording.title) on any of the ${#MUSIC_STATIONS[@]} music stations"
else
  pass 'music now' "${#MUSIC_STATIONS[@]} stations, $songs playing a song ($song)"
fi

# 16. section pages: componentsContent as Collections::_parsePage reads it; every page must list a
#     collection, and Podcasts its sub-collections and categories (Collections::podcasts)
if [[ -z "$build_id" ]]; then
  fail 'section pages' 'no buildId (search page failed)'
else
  errors=() found=()
  for entry in "${SECTION_PAGES[@]}"; do
    name=${entry%%:*} path=${entry#*:}
    file="$tmp/page-${path//\//_}.json"
    if ! request 'section pages' "$file" "$SITE/_next/data/$build_id$path.json"; then
      errors+=("$name: $error")
      continue
    fi
    read -r collections meta categories < <(value "$file" 'page_summary | "\(.collections) \(.meta) \(.categories)"')
    if [[ "${collections:-0}" -eq 0 ]]; then
      errors+=("$name ($path): no collection in .pageProps.data.componentsContent")
    elif [[ "$name" == Podcasts ]] && [[ "${meta:-0}" -eq 0 || "${categories:-0}" -eq 0 ]]; then
      errors+=("$name ($path): $meta MetaCollection sub-collections, $categories categories collections (needs both)")
    else
      found+=("$name $collections")
    fi
  done
  if ((${#errors[@]})); then
    fail 'section pages' "$(summarize "${errors[@]}")"
  else
    pass 'section pages' "collections: $(printf '%s, ' "${found[@]}" | sed 's/, $//')"
  fi
fi

# 17. Algolia program index: ProgramIndex's query (one a day per LMS); its hits make the A-Z and
#     By type. Fails if the index outgrows the 1000 hits one query returns (the A-Z would miss
#     programs) or no hit has a programType By type knows.
audiobooks=()
if [[ -z "$api_key" ]]; then
  fail 'Algolia program index' 'no credentials (search page failed)'
else
  index_query=$(jq -cn --arg f "contentType:program AND $SITE_FILTER" \
    '{query: "", hitsPerPage: 1000, distinct: 0, filters: $f, attributesToRetrieve: ["objectID", "title", "canonicalURL", "shortTeaserText", "description", "defaultThumbnail", "infoSource", "programType"]}')
  if ! algolia 'Algolia program index' "$tmp/index.json" "$index_query"; then
    fail 'Algolia program index' "$error"
  elif ! check "$tmp/index.json" '(.hits | type == "array") and (.nbHits | type == "number")'; then
    fail 'Algolia program index' 'expected a .hits array and a numeric .nbHits'
  else
    # shellcheck disable=SC2016  # $h is a jq variable
    read -r hits nb_hits pages typed < <(value "$tmp/index.json" '
      [.hits[] | objects] as $h
      | [ ($h | length), .nbHits,
          ($h | map(select((.objectID | type == "string" and test("^coremedia://program/[0-9]+$")) and (.title | type == "string")
                and ((.canonicalURL | site_path) // "" | test("/(programs|audiobooks)/[^/]+$")))) | length),
          ($h | map(select(.programType | type == "string" and (ascii_downcase | IN("podcast", "catch-up", "music", "music playlists", "news-briefing", "audiobook")))) | length) ]
      | map(tostring) | join(" ")')
    hits=${hits:-0} nb_hits=${nb_hits:-0} pages=${pages:-0} typed=${typed:-0}
    mapfile -t audiobooks < <(value "$tmp/index.json" '.hits[] | objects | select((.programType // "" | ascii_downcase) == "audiobook") | .objectID | strings | capture("^coremedia://program/(?<id>[0-9]+)$").id')
    if ((nb_hits > hits)); then
      fail 'Algolia program index' "$nb_hits programs in the index, only $hits returned (Algolia's 1000-hit cap): the A-Z would miss programs"
    elif ((pages < MIN_INDEX_PROGRAMS)); then
      fail 'Algolia program index' "$pages hits at a program page (coremedia://program objectID, title, canonicalURL .../programs/<slug>), expected at least $MIN_INDEX_PROGRAMS"
    elif ((typed == 0)); then
      fail 'Algolia program index' 'no hit has a programType By type knows (podcast, catch-up, music, news-briefing, audiobook)'
    else
      pass 'Algolia program index' "$hits programs, $pages at a program page, $typed with a known programType, ${#audiobooks[@]} audiobooks"
    fi
  fi
fi

# 18. Algolia chapters: Audiobooks' query for an audiobook (the first, of up to 3, with chapters
#     that can be listed: an audio objectID, its programID, an http(s) mediaRenditions url, a
#     publicationDate, not EXPIRED/NONE for both download and streaming), then Episode's objectID
#     lookup of one chapter
if [[ -n "$AUDIOBOOK_ID" ]]; then
  audiobooks=("$AUDIOBOOK_ID")
fi
if [[ -n "$AUDIOBOOK_ID" && ! "$AUDIOBOOK_ID" =~ ^[0-9]+$ ]]; then
  fail 'Algolia chapters' "ABC_AUDIOBOOK_ID '$AUDIOBOOK_ID' is not a program id (digits)"
elif [[ -z "$api_key" ]]; then
  fail 'Algolia chapters' 'no credentials (search page failed)'
elif ((${#audiobooks[@]} == 0)); then
  fail 'Algolia chapters' 'no audiobook to ask for (Algolia program index failed or lists none; set ABC_AUDIOBOOK_ID)'
else
  book='' chapters=0 chapter='' tried=()
  for id in "${audiobooks[@]:0:$MAX_AUDIOBOOK_TRIES}"; do
    tried+=("$id")
    chapters_query=$(jq -cn --arg f "contentType:audioepisode AND programID=$id" \
      '{query: "", hitsPerPage: 1000, filters: $f, attributesToRetrieve: ["objectID", "title", "canonicalURL", "duration", "dates", "mediaRenditions", "mediaDownloadStatus", "mediaStreamingStatus", "programTitle", "programID"]}')
    algolia 'Algolia chapters' "$tmp/chapters.json" "$chapters_query" || break
    listed=$(value "$tmp/chapters.json" '[.hits[]? | objects
      | select((.objectID | type == "string" and test("^coremedia://(audioepisode|audio|audiosegment)/[0-9]+$"))
        and ((.programID | digits) == "'"$id"'")
        and ([.mediaRenditions[]? | objects | select(.url | type == "string" and test("^https?://"; "i"))] | length > 0)
        and (.dates.publicationDate | type == "string")
        and ([.mediaDownloadStatus, .mediaStreamingStatus] | map(if type == "string" then ascii_upcase else "" end) | all(. == "EXPIRED" or . == "NONE") | not))
      | .objectID]')
    chapters=$(jq -r 'length' <<<"${listed:-[]}" 2>/dev/null || echo 0)
    if ((chapters > 0)); then
      book=$id
      chapter=$(jq -r 'first' <<<"$listed")
      break
    fi
  done
  if [[ -n "$error" ]]; then
    fail 'Algolia chapters' "programID=${tried[-1]}: $error"
  elif [[ -z "$book" ]]; then
    fail 'Algolia chapters' "no listable chapter (audio objectID, programID, mediaRenditions url, publicationDate) for programID $(printf '%s, ' "${tried[@]}" | sed 's/, $//')"
  else
    chapter_id=${chapter##*/}
    lookup_query=$(jq -cn --arg f "objectID:\"coremedia://audioepisode/$chapter_id\" OR objectID:\"coremedia://audio/$chapter_id\" OR objectID:\"coremedia://audiosegment/$chapter_id\"" \
      '{query: "", filters: $f, hitsPerPage: 1, attributesToRetrieve: ["objectID", "canonicalURL", "title", "programTitle", "programID", "duration", "dates", "mediaRenditions", "defaultThumbnail"]}')
    if ! algolia 'Algolia chapters' "$tmp/lookup.json" "$lookup_query"; then
      fail 'Algolia chapters' "objectID lookup of $chapter: $error"
    elif ! check "$tmp/lookup.json" '(.hits[0].objectID == "'"$chapter"'") and (.hits[0].mediaRenditions[0].url | type == "string")'; then
      fail 'Algolia chapters' "objectID lookup of $chapter: expected .hits[0] with that objectID and a mediaRenditions url"
    else
      pass 'Algolia chapters' "programID=$book: $chapters chapters; objectID lookup of $chapter has renditions"
    fi
  fi
fi

# 19. station collections: Stations::enrich's national and state collections (cards with an
#     articleLink to a station page and a cardTitle); the catalogue is the fallback
errors=() cards=0
for spec in "${STATION_COLLECTIONS[@]}"; do
  id=${spec%%:*} root=${spec#*:}
  if ! request 'station collections' "$tmp/stations-$id.json" "$BFF/collection/listen/radio?collectionId=$id&metaInMeta=false&rootMetaCollectionId=$root"; then
    errors+=("$id: $error")
  elif ! check "$tmp/stations-$id.json" '[.collection.items[]? | objects | select((.cardTitle | type == "string") and (.articleLink | type == "string" and test("^(https?:)?//(www\\.)?(abc\\.net\\.au|triplejunearthed\\.com)(/|$)"; "i")))] | length > 0'; then
    errors+=("$id: no .collection.items[] card with a cardTitle and an articleLink to an ABC page")
  else
    cards=$((cards + $(value "$tmp/stations-$id.json" '.collection.items | length')))
  fi
done
if ((${#errors[@]})); then
  fail 'station collections' "${#errors[@]} of ${#STATION_COLLECTIONS[@]} collections: $(summarize "${errors[@]}")"
else
  pass 'station collections' "${#STATION_COLLECTIONS[@]} collections, $cards station cards"
fi

echo
if ((failures)); then
  echo "abc-endpoints-check: $failures of $FAMILIES families FAILED ($((SECONDS - started)) s)"
  exit 1
fi
echo "abc-endpoints-check: all $FAMILIES families passed ($((SECONDS - started)) s)"
