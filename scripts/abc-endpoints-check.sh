#!/usr/bin/env bash
# abc-endpoints-check.sh - manual drift probe for the ABC endpoints the plugin relies on
# (ai-state/research/abc-listen-api.md, ABCListen/API.pm). One live request per endpoint family
# (the _next/data and music families need a few), asserting the JSON paths our parsers use.
# Prints "PASS <family>: <detail>" or "FAIL <family>: <reason>" per family and exits 1 if any
# family failed.
#
# Manual only: never run by CI or scripts/check.sh, and don't loop it (ABC etiquette).
# Needs bash, curl and jq. Uses $HTTPS_PROXY when set, and --max-time 10 per request.
# No Algolia credentials are hard-coded: they are read from /listen/search at run time, like
# API::siteConfig, and never printed.
#
# Overrides (environment), e.g. to check a probe failure:
#   ABC_PROGRAM_PATH  program page for _next/data   (default /listen/programs/scienceshow)
#   ABC_EPISODE_PATH  any-slug episode page that redirects (default /listen/programs/scienceshow/x/107266790)
#   ABC_COLLECTION_ID collection for the collection family (default 103194120)
#
#   ABC_PROGRAM_PATH=/listen/programs/nope scripts/abc-endpoints-check.sh   # FAIL _next/data: ...
set -uo pipefail

SITE=https://www.abc.net.au
PROGRAM_PATH=${ABC_PROGRAM_PATH:-/listen/programs/scienceshow}
EPISODE_PATH=${ABC_EPISODE_PATH:-/listen/programs/scienceshow/x/107266790}
COLLECTION_ID=${ABC_COLLECTION_ID:-103194120}

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "abc-endpoints-check: $tool is required" >&2; exit 2; }
done

curl_opts=(-sS --max-time 10 -A 'SqueezeABCListen endpoint check (curl)')
[[ -n "${HTTPS_PROXY:-}" ]] && curl_opts+=(--proxy "$HTTPS_PROXY")

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

failures=0
started=$SECONDS

pass() { printf 'PASS %s: %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }

# fetch <outfile> <url> [curl args...] -> prints the HTTP status ("000" on a transport error)
fetch() {
  local out=$1 url=$2
  shift 2
  curl "${curl_opts[@]}" -o "$out" -w '%{http_code}' "$@" "$url" 2>"$out.err" || true
}

# check <file> <jq expression that must be true>
check() { jq -e "$2" "$1" >/dev/null 2>&1; }

# get_json <family> <outfile> <url> [curl args...]: fetch, expect HTTP 200 and JSON; FAIL otherwise
get_json() {
  local family=$1 out=$2 url=$3 status
  shift 3
  status=$(fetch "$out" "$url" "$@")
  if [[ "$status" != 200 ]]; then
    fail "$family" "HTTP $status from ${url%%\?*}$( [[ -s "$out.err" ]] && printf ' (%s)' "$(head -c 200 "$out.err")" )"
    return 1
  fi
  if ! jq -e . "$out" >/dev/null 2>&1; then
    fail "$family" "not JSON from ${url%%\?*}"
    return 1
  fi
}

# 1. search page: buildId and the Algolia config in __NEXT_DATA__
build_id='' app_id='' api_key='' index_name=''
status=$(fetch "$tmp/search.html" "$SITE/listen/search")
if [[ "$status" != 200 ]]; then
  fail 'search page' "HTTP $status from /listen/search"
else
  build_id=$(grep -o '"buildId":"[^"]*"' "$tmp/search.html" | head -n 1 | cut -d '"' -f 4)
  grep -o '<script id="__NEXT_DATA__"[^>]*>[^<]*</script>' "$tmp/search.html" | sed -e 's/^<script[^>]*>//' -e 's/<\/script>$//' >"$tmp/next.json"
  # the Search component's config first, then any non-suggestions index (as API::siteConfig)
  if read -r app_id api_key index_name < <(jq -r '
      [ (.. | objects | select(.component? == "Search") | .componentProps | objects),
        (.. | objects | select((.indexName? | type) == "string" and (.indexName | test("suggestion") | not))),
        (.. | objects | select((.indexName? | type) == "string")) ]
      | map(select((.client? | type) == "object" and (.client.appId | type) == "string" and (.client.apiKey | type) == "string"))
      | first | "\(.client.appId) \(.client.apiKey) \(.indexName)"' "$tmp/next.json" 2>/dev/null) \
    && [[ -n "$build_id" && -n "$app_id" && -n "$api_key" && -n "$index_name" && "$app_id" != null ]]; then
    pass 'search page' "buildId $build_id, Algolia index $index_name (app id and key found)"
  else
    fail 'search page' "buildId '${build_id:-none}'; Algolia appId/apiKey/indexName not found in __NEXT_DATA__"
    [[ "$app_id" == null ]] && app_id=''
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
    collection_id=$(jq -r '.pageProps.programCollectionPrepared.id' "$tmp/program.json")
    if get_json '_next/data' "$tmp/redirect.json" "$SITE/_next/data/$build_id$EPISODE_PATH.json"; then
      target=$(jq -r '.pageProps.__N_REDIRECT // empty | strings' "$tmp/redirect.json")
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
elif get_json 'episodesWithSegments' "$tmp/episodes.json" "$SITE/core-next/api/episodesWithSegments/x?collectionId=$collection_id&offset=0&size=2"; then
  if check "$tmp/episodes.json" '(.collection.items[0].contentUri | type == "string" and startswith("coremedia://")) and (.collection.pagination.total | type == "number")'; then
    pass 'episodesWithSegments' "total $(jq -r '.collection.pagination.total' "$tmp/episodes.json"), first $(jq -r '.collection.items[0].contentUri' "$tmp/episodes.json")"
  else
    fail 'episodesWithSegments' 'expected .collection.items[0].contentUri (coremedia://...) and a numeric .collection.pagination.total'
  fi
fi

# 4. collection
if get_json 'collection' "$tmp/collection.json" "$SITE/core-next/api/collection/x?collectionId=$COLLECTION_ID&offset=0&size=2"; then
  if check "$tmp/collection.json" '.collection.items[0] | (.contentUri | type == "string") and (.cardTitle | type == "string") and (.cardImagePrepared.imgSrc | type == "string")'; then
    pass 'collection' "$(jq -r '.collection.title // "untitled"' "$tmp/collection.json"): first card $(jq -r '.collection.items[0].contentUri' "$tmp/collection.json")"
  else
    fail 'collection' 'expected .collection.items[0].{contentUri,cardTitle,cardImagePrepared.imgSrc}'
  fi
fi

# 5. epgNowPlaying
if get_json 'epgNowPlaying' "$tmp/epg.json" "$SITE/core-next/api/epgNowPlaying/RN/now?imageRatio=1x1"; then
  if check "$tmp/epg.json" '(.title | type == "string") and (.start | type == "string") and (.sources | type == "array")'; then
    pass 'epgNowPlaying' "RN now: $(jq -r '.title' "$tmp/epg.json")"
  else
    fail 'epgNowPlaying' 'expected .title, .start and a .sources array'
  fi
fi

# 6. music: BFF musicNowPlaying and the public music API
if get_json 'music' "$tmp/music-now.json" "$SITE/core-next/api/musicNowPlaying/TRIPLEJ"; then
  if ! check "$tmp/music-now.json" 'has("mapiNow")'; then
    fail 'music' 'musicNowPlaying/TRIPLEJ has no mapiNow key'
  elif get_json 'music' "$tmp/plays.json" 'https://music.abcradio.net.au/api/v1/plays/search.json?station=triplej&order=desc&limit=1'; then
    if check "$tmp/plays.json" '.items[0].recording.title | type == "string"'; then
      pass 'music' "mapiNow present; last triple j play: $(jq -r '.items[0].recording.title' "$tmp/plays.json")"
    else
      fail 'music' 'plays/search.json: no .items[0].recording.title'
    fi
  fi
fi

# 7. schedule (today in Sydney)
today=$(TZ=Australia/Sydney date +%F)
if get_json 'schedule' "$tmp/schedule.json" "$SITE/core-next/api/schedule?service=RN&date=$today&tz=Australia/Sydney&ratio=1x1"; then
  if check "$tmp/schedule.json" '(.formattedScheduleArray[0].items[0].title | type == "string") and (.serviceTimezone | type == "string")'; then
    pass 'schedule' "RN $today ($(jq -r '.serviceTimezone' "$tmp/schedule.json")): $(jq -r '.formattedScheduleArray[0].items[0].title' "$tmp/schedule.json")"
  else
    fail 'schedule' 'expected .formattedScheduleArray[0].items[0].title and .serviceTimezone'
  fi
fi

# 8. PAPI
if get_json 'PAPI' "$tmp/papi.json" 'https://program.abcradio.net.au/api/v1/services.json'; then
  if check "$tmp/papi.json" '(.items[0].service_id | type == "string") and (.total | type == "number" and . >= 100)'; then
    pass 'PAPI' "$(jq -r '.total' "$tmp/papi.json") services"
  else
    fail 'PAPI' 'expected .items[0].service_id and .total >= 100'
  fi
fi

# 9. Algolia (credentials from family 1; the key is sent in a header and never printed)
if [[ -z "$app_id" || -z "$api_key" || -z "$index_name" ]]; then
  fail 'Algolia' 'no credentials (search page failed)'
else
  query='{"query":"science","hitsPerPage":1,"filters":"siteTitle:\"Listen\" AND (contentType:program OR contentType:audioepisode)"}'
  if get_json 'Algolia' "$tmp/algolia.json" "https://$app_id-dsn.algolia.net/1/indexes/$index_name/query" \
      -X POST -H "X-Algolia-Application-Id: $app_id" -H "X-Algolia-API-Key: $api_key" \
      -H 'Content-Type: application/json' --data "$query"; then
    if check "$tmp/algolia.json" '(.nbHits | type == "number" and . > 0) and (.hits[0].objectID | type == "string")'; then
      pass 'Algolia' "$(jq -r '.nbHits' "$tmp/algolia.json") hits for 'science', first $(jq -r '.hits[0].objectID' "$tmp/algolia.json")"
    else
      fail 'Algolia' 'expected .nbHits > 0 and .hits[0].objectID'
    fi
  fi
fi

# 10. .pls -> Icecast mount
status=$(fetch "$tmp/pls" 'https://streaming.abc-cdn.net.au/audio/ice/triplejnsw.pls')
if [[ "$status" != 200 ]]; then
  fail 'pls' "HTTP $status from triplejnsw.pls"
elif file1=$(tr -d '\r' <"$tmp/pls" | grep -m 1 '^File1=https://abc\.streamguys1\.com/live/'); then
  pass 'pls' "${file1#File1=}"
else
  fail 'pls' 'no File1=https://abc.streamguys1.com/live/... line in triplejnsw.pls'
fi

echo
if ((failures)); then
  echo "abc-endpoints-check: $failures of 10 families FAILED ($((SECONDS - started)) s)"
  exit 1
fi
echo "abc-endpoints-check: all 10 families passed ($((SECONDS - started)) s)"
