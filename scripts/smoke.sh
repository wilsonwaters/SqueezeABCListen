#!/usr/bin/env bash
# smoke.sh - acceptance test for the ABC listen plugin on a running LMS, over JSON-RPC.
#
# Usage: scripts/smoke.sh [LMS_URL] [PLAYER_MAC] [--skip-live] [--station <SERVICE_ID>] [--local <SERVICE_ID>] [-h|--help]
#   LMS_URL     the server; default $LMS_URL, else http://localhost:9000 (https and other ports work)
#   PLAYER_MAC  the player to play on; default $PLAYER, else the only connected player
#   --skip-live          skip the live-stream checks 6, 7 and 15 (servers that can't reach ABC's live streams)
#   --station <ID>       the national station for check 6 (default TRIPLEJ); with a home state, its
#                        row in Radio may play that state's time-zone version, which counts too
#   --local <ID>         the local station for check 7 (default LOCAL_SYDNEY)
#   Station ids are the ABC service ids in abclisten://live/<ID> links: A-Z, 0-9 and _ only.
# Environment: LMS_USER and LMS_PASS for a password-protected server (HTTP basic auth).
#
# WARNING: the test plays audio on the chosen player. It replaces the player's queue; at the end
# (also on failure or Ctrl-C) it stops the player, clears the queue and switches the player off
# again if it was off. A player in a sync group stops with its group, and the group's shared queue
# is cleared. It follows and unfollows one program, then puts that program (and any follow the
# plugin dropped to make room for it) back as it was; other changes to the followed programs, made
# by someone else meanwhile, are kept.
#
# Checks, one line each ("PASS|FAIL|SKIP  <n>. <name> — <detail>"), then
# "SMOKE: <passed>/<run> passed" (", <k> skipped" when checks were skipped):
#    1. Server reachable          2. Player connected            3. Plugin enabled
#    4. Radio lists ABC listen    5. Top level (10 entries)      6. National station plays with metadata
#    7. Local station plays       8. Episode plays and seeks     9. All programs A–Z non-empty
#   10. Home non-empty           11. Search                     12. Follow round trip
#   13. Podcasts non-empty       14. Sections non-empty         15. Kids listen live plays
# Menus are walked by item name, always with the ids from the latest response.
# Exit codes: 0 no check failed (skips allowed), 1 a check failed, 2 usage, dependency or
# connectivity error. Needs bash 4+, curl and jq. Takes about a minute.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "smoke: needs bash 4 or later" >&2
  exit 2
fi
case "$BASH_VERSION" in
  [0-3].*) echo "smoke: needs bash 4 or later (this is bash $BASH_VERSION)" >&2; exit 2 ;;
esac

set -uo pipefail

# Menu item names: the EN values of these ABCListen/strings.txt tokens. "%s" stands for a count
# or a name; such names are matched by the text before it. t/96-smoke-strings.t checks that they
# are equal; change both together.
STR_HOME='Home'                                       # PLUGIN_ABCLISTEN_HOME
STR_RADIO='Radio'                                     # PLUGIN_ABCLISTEN_RADIO
STR_PODCASTS='Podcasts'                               # PLUGIN_ABCLISTEN_PODCASTS
STR_NEWS='News'                                       # PLUGIN_ABCLISTEN_NEWS
STR_SPORT='Sport'                                     # PLUGIN_ABCLISTEN_SPORT
STR_KIDS='Kids listen'                                # PLUGIN_ABCLISTEN_KIDS
STR_AUDIOBOOKS='Audiobooks'                           # PLUGIN_ABCLISTEN_AUDIOBOOKS
STR_PROGRAMS='Programs'                               # PLUGIN_ABCLISTEN_PROGRAMS_AZ
STR_SEARCH='Search'                                   # PLUGIN_ABCLISTEN_SEARCH
STR_MY_ABC='My ABC listen'                            # PLUGIN_ABCLISTEN_MY_ABC
STR_LOCAL_RADIO='Local radio'                         # PLUGIN_ABCLISTEN_LOCAL_RADIO
STR_BY_NETWORK='By network'                           # PLUGIN_ABCLISTEN_BY_NETWORK
STR_AZ='All programs A–Z'                             # PLUGIN_ABCLISTEN_AZ
STR_SEARCH_PROGRAMS='Programs (%s)'                   # PLUGIN_ABCLISTEN_SEARCH_PROGRAMS
STR_SEARCH_EPISODES='Episodes (%s)'                   # PLUGIN_ABCLISTEN_SEARCH_EPISODES
STR_FOLLOWED_PROGRAMS='Followed programs (%s)'        # PLUGIN_ABCLISTEN_FOLLOWED_PROGRAMS
STR_NO_FOLLOWED_HELP='Open any program and choose Follow'  # PLUGIN_ABCLISTEN_NO_FOLLOWED_HELP
STR_FOLLOW='Follow "%s"'                              # PLUGIN_ABCLISTEN_FOLLOW_NAMED
STR_UNFOLLOW='Unfollow "%s"'                          # PLUGIN_ABCLISTEN_UNFOLLOW_NAMED
STR_FOLLOWING='✓ Following "%s"'                      # PLUGIN_ABCLISTEN_FOLLOWING_NAMED
STR_FOLLOWED_OK='Following %s'                        # PLUGIN_ABCLISTEN_FOLLOWED_OK
STR_UNFOLLOWED_OK='No longer following %s'            # PLUGIN_ABCLISTEN_UNFOLLOWED_OK
STR_RATE_LIMITED='ABC listen is busy right now. Please try again in a few minutes.'  # PLUGIN_ABCLISTEN_RATE_LIMITED
STR_LOAD_FAILED="Couldn't load this from ABC listen. Please try again later."         # PLUGIN_ABCLISTEN_LOAD_FAILED
STR_ERROR='Sorry, part of the ABC listen menu could not be loaded. Please try again later.'  # PLUGIN_ABCLISTEN_ERROR
STR_PLUGIN='ABC listen'                               # PLUGIN_ABCLISTEN

# ABC's own collection title (data from ABC, not a plugin string)
ABC_NEW_NOTEWORTHY='New & Noteworthy'

# The top level, in order (check 5)
TOP_LEVEL=("$STR_HOME" "$STR_RADIO" "$STR_PODCASTS" "$STR_NEWS" "$STR_SPORT" "$STR_KIDS" "$STR_AUDIOBOOKS" "$STR_PROGRAMS" "$STR_SEARCH" "$STR_MY_ABC")

# Timing. The SMOKE_* overrides exist for t/97-smoke-cli.t only; don't set them for a real test.
LIVE_START_S="${SMOKE_LIVE_START_S:-20}"        # a live stream must be playing within this
LIVE_WINDOW_S="${SMOKE_LIVE_WINDOW_S:-6}"       # ... and advance at least LIVE_ADVANCE_S over this window
LIVE_ADVANCE_S=5
META_WAIT_S="${SMOKE_META_WAIT_S:-30}"          # program or song metadata within this, from the play
EPISODE_START_S="${SMOKE_EPISODE_START_S:-30}"  # an episode must be playing within this
EPISODE_WINDOW_S="${SMOKE_EPISODE_WINDOW_S:-3}" # ... and advance over this window
SEEK_MAX_S=600                                  # seek target: min(SEEK_MAX_S, duration / 2)
SEEK_WAIT_S="${SMOKE_SEEK_WAIT_S:-15}"          # within this, time must reach the target and play on
STOP_GRACE_S="${SMOKE_STOP_GRACE_S:-5}"         # a player stopped again after this has given up
POLL_S="${SMOKE_POLL_S:-1}"                     # status polling interval
CURL_TIMEOUT_S="${SMOKE_CURL_TIMEOUT_S:-15}"    # per request; a timed-out menu request is tried once more
MAX_PROGRAMS=3      # programs tried for an episode (check 8)
MAX_ATTEMPTS=5      # episodes tried (check 8)
MAX_HOME_LINKS=3    # Home links tried (check 10)
SEARCH_QUERY='science'

usage() { sed -n '4,/^$/p' "$0" | sed '/^$/d; s/^# \{0,1\}//'; }   # the header, from "Usage:"
die() { echo "smoke: $*" >&2; exit 2; }

# ---- arguments ----

skip_live="" station="TRIPLEJ" local_station="LOCAL_SYDNEY"
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --skip-live) skip_live=1 ;;
    --station | --local)
      [[ $# -ge 2 ]] || { usage >&2; die "$1 needs a service id"; }
      [[ "$2" =~ ^[A-Z0-9_]+$ ]] || die "$1: '$2' is not a service id (A-Z, 0-9 and _ only, e.g. TRIPLEJ)"
      if [[ "$1" == --station ]]; then station="$2"; else local_station="$2"; fi
      shift
      ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) positional+=("$1") ;;
  esac
  shift
done
if [[ ${#positional[@]} -gt 2 ]]; then usage >&2; die "too many arguments: ${positional[*]}"; fi

missing=()
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[[ ${#missing[@]} -eq 0 ]] || die "missing: ${missing[*]} (needs bash 4+, curl and jq)"

lms="${positional[0]:-${LMS_URL:-http://localhost:9000}}"
lms="${lms%/}"
[[ "$lms" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || die "LMS_URL must look like http://host:9000, got '$lms'"
player="${positional[1]:-${PLAYER:-}}"
player="${player,,}"

# until the checks start, the temporary directory is all there is to clean up (cleanup, below,
# takes over then)
tmp=""
trap '[[ -z "$tmp" ]] || rm -rf "$tmp"' EXIT
trap 'echo "smoke: interrupted" >&2; exit 130' INT TERM
tmp="$(mktemp -d)" || die "can't create a temporary directory"
curl_opts=(-sS -m "$CURL_TIMEOUT_S" --connect-timeout 10 -H 'Content-Type: application/json')
if [[ -n "${LMS_USER:-}" ]]; then
  # the credentials go in a curl config file only this user can read, never on curl's command line
  auth="$LMS_USER:${LMS_PASS:-}"
  auth="${auth//\\/\\\\}"
  auth="${auth//\"/\\\"}"
  (umask 077 && printf 'user = "%s"\n' "$auth" >"$tmp/auth.conf") || die "can't write $tmp/auth.conf"
  unset auth
  curl_opts+=(-K "$tmp/auth.conf")
fi

touched=""      # set once the player has been changed: cleanup then stops it
was_power=1     # the player's power state before the test
follows_saved=""  # the followed programs before check 12 (JSON), while check 12 may have changed them
follow_sent=""    # set once check 12 has sent a Follow or Unfollow
follow_path="" follow_name="" follow_title="" follow_note="" follow_start=""
passed=0 failed=0 skipped=0

DRIFT_HINT="if this persists, ABC may have changed its data: run scripts/abc-endpoints-check.sh"

# ---- JSON-RPC ----

# rpc PLAYER COMMAND_JSON: R = the result object; on failure returns 1 with rpc_error set
# (rpc_rc = curl's exit code, 0 when LMS answered)
rpc() {
  local body code
  R="" rpc_error="" rpc_rc=0
  body="$(jq -cn --arg p "$1" --argjson c "$2" '{id: 1, method: "slim.request", params: [$p, $c]}' 2>/dev/null)" ||
    { rpc_error="bad command: $2"; return 1; }
  code="$(curl "${curl_opts[@]}" -o "$tmp/body" -w '%{http_code}' -d "$body" "$lms/jsonrpc.js" 2>"$tmp/err")"
  rpc_rc=$?
  if [[ $rpc_rc -ne 0 ]]; then
    rpc_error="no answer to $2 (curl exit $rpc_rc: $(head -n 1 "$tmp/err" | sed 's/^curl: ([0-9]*) //'))"
    return 1
  fi
  case "$code" in
    200) ;;
    401) rpc_error="$lms asks for a password: set LMS_USER and LMS_PASS"; return 1 ;;
    *) rpc_error="HTTP $code for $2"; return 1 ;;
  esac
  if ! R="$(jq -ce 'if type == "object" and has("result") then .result // {} else error end' "$tmp/body" 2>/dev/null)"; then
    rpc_error="unexpected answer to $2: $(head -c 200 "$tmp/body")"
    R=""
    return 1
  fi
}

# items [ITEM_ID [PARAM...]]: R = a plugin menu level (["abclisten","items",0,200,"item_id:<id>",...]).
# A first, uncached open can take longer than curl's timeout; the plugin finishes it in the
# background and caches it, so a timed-out call is tried once more.
items() {
  local cmd='["abclisten","items",0,200' p
  for p in ${1:+"item_id:$1"} "${@:2}"; do cmd+=",$(jq -cn --arg p "$p" '$p')"; done
  cmd+=']'
  rpc "$player" "$cmd" && return 0
  [[ $rpc_rc -eq 28 ]] || return 1
  rpc "$player" "$cmd"
}

# menu_items ITEM_ID: R = the same level in menu mode (menu:1: item_loop, with presetParams)
menu_items() { items "$1" menu:1; }

# find_item JSON NAME: the id of the first item named NAME, else of the first whose name starts
# with NAME
find_item() {
  jq -r --arg p "$2" '[.loop_loop[]? | {id, name: (.name // "" | gsub("\\s+"; " "))}] | ([.[] | select(.name == $p)] + [.[] | select(.name | startswith($p))]) | first | .id // empty' <<<"$1"
}

# item_list JSON FILTER: "<id><US><name>" for each item matching the jq FILTER, one per line
item_list() {
  jq -r ".loop_loop[]? | select($2)"' | [(.id | tostring), (.name // "" | gsub("\\s+"; " "))] | join("\u001f")' <<<"$1"
}

# names JSON: the item names of a level, " | "-separated (for messages)
names() { jq -r '[.loop_loop[]? | .name // "" | gsub("\\s+"; " ") | .[0:60]] | join(" | ")' <<<"$1"; }

# non_text JSON: how many items are not plain text (links, playable items, searches)
non_text() { jq -r '[.loop_loop[]? | select((.type // "") != "text" and (.type // "") != "textarea")] | length' <<<"$1"; }

# prefix TEXT: TEXT up to its first "%s"
prefix() { printf '%s' "${1%%%s*}"; }

# count_of JSON TEMPLATE: N from the first item named like TEMPLATE ("Programs (%s)" -> N), else empty
count_of() {
  local name pre="${2%%%s*}" post="${2#*%s}"
  name="$(jq -r --arg p "$pre" 'first(.loop_loop[]? | select((.name // "") | startswith($p))) | .name // empty' <<<"$1")"
  [[ -n "$name" ]] || return 0
  name="${name#"$pre"}"
  name="${name%"$post"}"
  [[ "$name" =~ ^[0-9]+$ ]] && echo "$name"
  return 0
}

# walk NAME...: from the top level, open each named item in turn, with the ids from the latest
# response. R = the last level, W_ID = its id; on failure returns 1 with walk_error set.
walk() {
  local name id
  W_ID="" walk_error=""
  items || { walk_error="$rpc_error"; return 1; }
  for name in "$@"; do
    id="$(find_item "$R" "$name")"
    if [[ -z "$id" ]]; then
      walk_error="no \"$name\" item (got: $(names "$R"))"
      return 1
    fi
    W_ID="$id"
    items "$id" || { walk_error="$name: $rpc_error"; return 1; }
  done
}

# hint JSON: why a level that should list something didn't, for FAIL details
hint() {
  local got all
  got="$(names "$1")"
  all="$(jq -r '[.loop_loop[]? | .name // ""] | join(" | ")' <<<"$1")"
  case "$all" in
    *"$STR_RATE_LIMITED"*) echo "ABC is limiting requests (\"$STR_RATE_LIMITED\"); try again later" ;;
    *"$STR_LOAD_FAILED"* | *"$STR_ERROR"*) echo "got: $got; ABC didn't answer, try again later; $DRIFT_HINT" ;;
    *) echo "got: ${got:-nothing}; $DRIFT_HINT" ;;
  esac
}

# number: $1 if it is a JSON number, else 0
num() { if [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then echo "$1"; else echo 0; fi; }

# is EXPR: true if the jq expression over numbers is true, e.g. is "3.5 >= 2"
is() { jq -en "$1" >/dev/null 2>&1; }

# secs N: N rounded to 0.1, for messages
secs() { jq -n "$(num "$1") * 10 | round / 10"; }

# status: S_MODE, S_TIME, S_DURATION, S_TITLE (the current track's title) of the player
status() {
  local line
  S_MODE="" S_TIME=0 S_DURATION=0 S_TITLE=""
  rpc "$player" '["status","-",1,"tags:adl"]' || return 1
  line="$(jq -r '[.mode // "", (.time // 0 | tostring), (.duration // 0 | tostring), (.playlist_loop[0].title // "" | gsub("\\s+"; " "))] | join("\u001f")' <<<"$R")"
  IFS=$'\x1f' read -r S_MODE S_TIME S_DURATION S_TITLE <<<"$line"
  S_TIME="$(num "$S_TIME")"
  S_DURATION="$(num "$S_DURATION")"
}

status_text() { echo "mode=${S_MODE:-?} time=$(secs "$S_TIME") title='$S_TITLE'"; }

# power_on: switch the player on (once); cleanup restores its power state
power_on() {
  [[ -n "$touched" ]] && return 0
  touched=1
  rpc "$player" '["power",1]'
}

# play ITEM_ID: play a plugin item, replacing the queue
play() {
  power_on || return 1
  rpc "$player" "$(jq -cn --arg id "item_id:$1" '["abclisten","playlist","play",$id]')"
}

# play_url URL: play a URL, replacing the queue
play_url() {
  power_on || return 1
  rpc "$player" "$(jq -cn --arg u "$1" '["playlist","play",$u]')"
}

# wait_playing TIMEOUT: until mode is play and time > 0. why = the reason on failure. A player
# that has stopped again after STOP_GRACE_S has given up (e.g. an episode that is no longer
# available, or a stream that can't be reached).
wait_playing() {
  local start=$SECONDS
  why=""
  while ((SECONDS - start < $1)); do
    sleep "$POLL_S"
    if ! status; then why="$rpc_error"; continue; fi
    if [[ "$S_MODE" == play ]] && is "$S_TIME > 0"; then return 0; fi
    if [[ "$S_MODE" == stop ]] && ((SECONDS - start >= STOP_GRACE_S)); then
      why="stopped after $((SECONDS - start)) s ($(status_text))"
      return 1
    fi
  done
  why="not playing within $1 s ($(status_text))"
  return 1
}

# advances WINDOW: time advances at least LIVE_ADVANCE_S over WINDOW seconds; why = the detail
advances() {
  local t0="$S_TIME"
  sleep "$1"
  status || { why="$rpc_error"; return 1; }
  why="time $(secs "$t0") → $(secs "$S_TIME") s in $1 s"
  [[ "$S_MODE" == play ]] && is "$S_TIME - $t0 >= $LIVE_ADVANCE_S" && return 0
  why="$why, needs +$LIVE_ADVANCE_S s ($(status_text))"
  return 1
}

# find_station LEVEL_JSON SERVICE_ID [versions]: "<id><US><name><US><service><US><title>" of the
# row whose menu-mode favourite is abclisten://live/<SERVICE_ID>; with "versions", else of a row
# that plays one of its time-zone versions, abclisten://live/<SERVICE_ID>_<state or capital> (with
# a home state, Radio's network rows play that state's version under the network's name).
# service, title = the favourite's service id and title.
find_station() {
  jq -r --arg s "$2" --arg v "${3:-}" '
    def svc: .presetParams.favorites_url? // "" | ltrimstr("abclisten://live/");
    [.item_loop[]? | select(.presetParams.favorites_url? // "" | startswith("abclisten://live/"))] as $rows
    | (first($rows[] | select(svc == $s))
       // (if $v == "" then empty else first($rows[] | select(svc | test("^" + $s + "_(SA|QLD|NT|WA|ADELAIDE|BRISBANE|DARWIN|PERTH)$"))) end))
    | [(.params.item_id // .actions.go.params.item_id // .actions.play.params.item_id // "" | tostring), (.text // "" | split("\n")[0]), svc, (.presetParams.favorites_title // "" | tostring | split("\n")[0] // "")]
    | join("\u001f")' <<<"$1"
}
has_favs() { jq -e 'any(.item_loop[]?; .presetParams.favorites_url? // "" | startswith("abclisten://live/"))' <<<"$1" >/dev/null 2>&1; }

# station_names LEVEL_JSON: the names of a menu-mode level's station rows (rows with a station
# favourite, or playable rows on an LMS without favourite links) and their favourites' titles (a
# time-zone version's own title, under a network's name), one per line
station_names() {
  jq -r '.item_loop[]? | select((.presetParams.favorites_url? // "" | startswith("abclisten://live/")) or .type == "playlist" or .type == "audio") | (.text, .presetParams.favorites_title?) | strings | split("\n")[0] // empty' <<<"$1"
}

# menu_links LEVEL_JSON: "<id><US><name>" of a menu-mode level's links (not station rows)
menu_links() {
  jq -r '.item_loop[]? | select((.actions.go.params.item_id? // "") != "" and .type != "playlist" and .type != "audio" and ((.presetParams.favorites_url? // "") == "")) | [(.actions.go.params.item_id | tostring), (.text // "" | split("\n")[0])] | join("\u001f")' <<<"$1"
}

# search_station LEVEL_ID SERVICE_ID: breadth-first through the menu-mode levels below LEVEL_ID
# (two levels down, at most 20 requests) for the row whose favourite is abclisten://live/SERVICE_ID,
# or, in LEVEL_ID itself, for the row that plays one of its time-zone versions (find_station).
# ST_ID, ST_NAME = that row; ST_SERVICE, ST_TITLE = its favourite's service id and title;
# ST_WHERE = the links that lead to it; ST_NAMES = the names and favourite titles of every station
# row seen (one per line); ST_FAVS set when any row had a station favourite.
search_station() {
  local queue=("$1"$'\x1f'0$'\x1f') entry id depth where child cname versions requests=0
  ST_ID="" ST_NAME="" ST_SERVICE="" ST_TITLE="" ST_WHERE="" ST_NAMES="" ST_FAVS="" ST_ERR=""
  while [[ ${#queue[@]} -gt 0 ]] && ((requests < 20)); do
    entry="${queue[0]}"
    queue=("${queue[@]:1}")
    IFS=$'\x1f' read -r id depth where <<<"$entry"
    requests=$((requests + 1))
    menu_items "$id" || { ST_ERR="${where:-$id}: $rpc_error"; continue; }
    has_favs "$R" && ST_FAVS=1
    ST_NAMES+="$(station_names "$R")"$'\n'
    versions=""
    ((depth > 0)) || versions=versions
    IFS=$'\x1f' read -r ST_ID ST_NAME ST_SERVICE ST_TITLE <<<"$(find_station "$R" "$2" "$versions")"
    if [[ -n "$ST_ID" ]]; then ST_WHERE="$where"; return 0; fi
    ((depth < 2)) || continue
    while IFS=$'\x1f' read -r child cname; do
      [[ -n "$child" ]] && queue+=("$child"$'\x1f'$((depth + 1))$'\x1f'"${where:+$where › }$cname")
    done < <(menu_links "$R")
  done
  ST_ID="" ST_NAME="" ST_SERVICE="" ST_TITLE=""
  return 1
}

# not_a_station_name TITLE: TITLE is neither a station row's name seen by search_station, nor the
# service id, nor the plugin's own name (what Now Playing shows before it has any metadata)
not_a_station_name() {
  local name
  [[ -n "$1" && "$1" != "$station" && "$1" != "$STR_PLUGIN" ]] || return 1
  while IFS= read -r name; do
    [[ -n "$name" && "$name" == "$1" ]] && return 1
  done <<<"$ST_NAMES"
  return 0
}

# play_station ID NAME SERVICE_ID [PLAYS]: play a station row (or its URL when ID is empty); why =
# detail; PLAYS = what the row plays when that is not the station its name says
play_station() {
  local how
  if [[ -n "$1" ]]; then
    how="\"$2\"${4:+, which plays $4}"
    play "$1" || { why="play command failed: $rpc_error"; return 1; }
  else
    how="abclisten://live/$3 (played by URL)"
    play_url "abclisten://live/$3" || { why="play command failed: $rpc_error"; return 1; }
  fi
  play_start=$SECONDS
  wait_playing "$LIVE_START_S" || { why="$how: $why"; return 1; }
  advances "$LIVE_WINDOW_S" || { why="$how: $why"; return 1; }
  why="$how: $why"
}

# ---- output and cleanup ----

result() {
  printf '%s  %s. %s — %s\n' "$1" "$2" "$3" "$4"
  case "$1" in
    PASS) passed=$((passed + 1)) ;;
    FAIL) failed=$((failed + 1)) ;;
    SKIP) skipped=$((skipped + 1)) ;;
  esac
  return 0
}

restore_player() {
  [[ -n "$touched" ]] || return 0
  touched=""
  rpc "$player" '["stop"]'
  rpc "$player" '["playlist","clear"]'
  [[ "$was_power" == 0 ]] && rpc "$player" '["power",0]'
  return 0
}

# followed: R_FOLLOWED = the followed-programs pref (JSON), or returns 1
followed() {
  rpc "" '["pref","plugin.abclisten:followed","?"]' || return 1
  R_FOLLOWED="$(jq -c '._p2 // []' <<<"$R")"
}

# same_json A B: A and B are the same JSON, numbers compared as text (LMS may report a number as a
# string once it has saved its prefs file)
same_json() {
  jq -en --argjson a "$1" --argjson b "$2" '
      def text: if type == "array" then map(text) elif type == "object" then map_values(text) elif type == "number" then tostring else . end;
      ($a | text) == ($b | text)' >/dev/null 2>&1
}

# find_test_path follow|unfollow SAVED: the path of the test program's entry in the followed
# programs (R_FOLLOWED): the program check 12 followed (followed now, not in SAVED) or unfollowed
# (followed in SAVED, not now), told apart by its title from changes someone else made meanwhile.
# Empty when unsure.
find_test_path() {
  jq -r --argjson s "$2" --arg op "$1" --arg t1 "$follow_title" --arg t2 "$follow_name" '
      def act: [.[]? | select(type == "object" and (has("unfollowedAt") | not)) | .path];
      ($s | act) as $sa | act as $ca |
      (if $op == "follow" then $ca - $sa else $sa - $ca end) as $changed |
      ([ .[]?, $s[]? | select(type == "object") | select(.path as $x | $changed | index([$x]) != null)
         | select((.title // "") == $t2 or ($t1 != "" and (.title // "") == $t1)) | .path ] | unique) as $named |
      if ($named | length) == 1 then $named[0]
      elif ($named | length) == 0 and ($changed | length) == 1 then $changed[0]
      else "" end' <<<"$R_FOLLOWED" 2>/dev/null
}

# restore_follows: put back what check 12 changed in the followed programs, and nothing else. The
# test program's entry goes back to what it was before check 12 (taken out if it wasn't there: an
# unfollow leaves it in the list, marked unfollowed, for 30 minutes), and so does the follow the
# plugin dropped to make room for it when 200 were followed. Changes someone else made meanwhile
# are kept. Nothing is written when check 12 never sent a Follow or Unfollow.
restore_follows() {
  local saved="$follows_saved" path merged
  [[ -n "$saved" ]] || return 0
  follows_saved=""
  [[ -n "$follow_sent" ]] || return 0
  followed || { follow_note="couldn't read the followed programs: $rpc_error"; return 1; }
  same_json "$saved" "$R_FOLLOWED" && return 0
  path="$follow_path"
  [[ -n "$path" ]] || path="$(find_test_path follow "$saved")"
  [[ -n "$path" ]] || path="$(find_test_path unfollow "$saved")"
  merged="$(jq -c --argjson s "$saved" --arg p "$path" '
      def obj: [.[]? | select(type == "object" and (.path | type) == "string")];
      def act: [.[] | select(has("unfollowedAt") | not)];
      def num: (tostring | tonumber? // 0);
      ($s | obj) as $s | obj as $c | ($s | act) as $sa |
      (if ($sa | length) >= 200 then ($sa | min_by(.followedAt | num) | .path) else "" end) as $oldest |
      (if $oldest != "" and $oldest != $p and any($c[]; .path == $oldest and has("unfollowedAt")) then $oldest else "" end) as $dropped |
      ([$p, $dropped] | map(select(. != ""))) as $put |
      ($s | map({key: .path, value: .}) | from_entries) as $before |
      [ $c[] | if (.path as $x | $put | index([$x])) != null then ($before[.path] // empty) else . end ]
      + [ $s[] | select(.path as $x | $put | index([$x]) != null) | select(.path as $x | any($c[]; .path == $x) | not) ]
    ' <<<"$R_FOLLOWED" 2>/dev/null)"
  [[ -n "$merged" ]] || { follow_note="couldn't work out which follows to put back"; return 1; }
  if [[ -z "$path" ]]; then
    follow_note="couldn't tell which followed program was the test's ($follow_name): check $STR_MY_ABC"
    same_json "$merged" "$R_FOLLOWED" && return 1
  fi
  same_json "$merged" "$R_FOLLOWED" && return 0
  rpc "" "$(jq -cn --argjson v "$merged" '["pref","plugin.abclisten:followed",$v]')" ||
    { follow_note="couldn't restore the followed programs: $rpc_error"; return 1; }
  [[ -z "$path" ]] && return 1
  return 0
}

# shellcheck disable=SC2317,SC2329  # only called from the EXIT trap
cleanup() {
  local rc=$?
  restore_follows
  restore_player
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT

finish() {
  restore_player
  local run=$((passed + failed))
  if [[ $skipped -gt 0 ]]; then
    echo "SMOKE: $passed/$run passed, $skipped skipped"
  else
    echo "SMOKE: $passed/$run passed"
  fi
  [[ $failed -eq 0 ]] && exit 0
  exit 1
}

echo "smoke: testing the ABC listen plugin on $lms"

# ---- 1. server reachable ----
if rpc "" '["serverstatus",0,0]'; then
  result PASS 1 "Server reachable" "LMS $(jq -r '.version // "?"' <<<"$R") at $lms"
else
  result FAIL 1 "Server reachable" "$rpc_error"
  die "can't talk to LMS at $lms"
fi

# ---- 2. player connected ----
rpc "" '["players",0,99]' || { result FAIL 2 "Player connected" "$rpc_error"; die "can't list the players"; }
players="$R"
list_players() {
  jq -r '.players_loop[]? | "  \(.playerid)  \(.name // "?")  connected=\(.connected // 0)"' <<<"$players" >&2
}
connected="$(jq -r '[.players_loop[]? | select((.connected | tostring) == "1") | .playerid | ascii_downcase] | join(" ")' <<<"$players")"
if [[ -z "$player" ]]; then
  read -r -a ids <<<"$connected"
  if [[ ${#ids[@]} -eq 1 ]]; then
    player="${ids[0]}"
  else
    result FAIL 2 "Player connected" "${#ids[@]} players connected and none chosen"
    echo "smoke: pass the MAC of one of these players (or set PLAYER):" >&2
    list_players
    exit 2
  fi
fi
if [[ " $connected " == *" $player "* ]]; then
  name="$(jq -r --arg p "$player" 'first(.players_loop[]? | select((.playerid | ascii_downcase) == $p)) | .name // "?"' <<<"$players")"
  was_power="$(jq -r --arg p "$player" 'first(.players_loop[]? | select((.playerid | ascii_downcase) == $p)) | .power // 1 | tostring' <<<"$players")"
  result PASS 2 "Player connected" "$name ($player)"
else
  result FAIL 2 "Player connected" "$player is not a connected player"
  echo "smoke: players known to $lms:" >&2
  list_players
  exit 2
fi

# ---- 3. plugin enabled ----
if rpc "" '["pref","plugin.state:ABCListen","?"]'; then
  state="$(jq -r '._p2 // "unset"' <<<"$R")"
  if [[ "$state" == enabled ]]; then
    result PASS 3 "Plugin enabled" "plugin.state:ABCListen = enabled"
  else
    result FAIL 3 "Plugin enabled" "plugin.state:ABCListen = $state (install or enable ABC listen in Settings → Manage Plugins, then restart LMS)"
  fi
else
  result FAIL 3 "Plugin enabled" "$rpc_error"
fi

# ---- 4. Radio lists ABC listen ----
if rpc "$player" '["radios",0,100]'; then
  entry="$(jq -r 'first(.radioss_loop[]? | select(.cmd == "abclisten")) | .name // empty' <<<"$R")"
  if [[ -n "$entry" ]]; then
    result PASS 4 "Radio lists ABC listen" "\"$entry\" (cmd abclisten)"
  else
    result FAIL 4 "Radio lists ABC listen" "no entry with cmd abclisten in the Radio menu (is the plugin loaded? restart LMS)"
  fi
else
  result FAIL 4 "Radio lists ABC listen" "$rpc_error"
fi

# ---- 5. top level ----
top_ok=""
if items; then
  got=()
  while IFS= read -r line; do got+=("$line"); done < <(jq -r '.loop_loop[]? | .name // "" | gsub("\\s+"; " ")' <<<"$R")
  same=1
  [[ ${#got[@]} -eq ${#TOP_LEVEL[@]} ]] || same=""
  for ((i = 0; i < ${#TOP_LEVEL[@]}; i++)); do [[ "${got[i]:-}" == "${TOP_LEVEL[i]}" ]] || same=""; done
  if [[ -n "$same" ]]; then
    top_ok=1
    result PASS 5 "Top level" "${#got[@]} entries: $(names "$R")"
  else
    result FAIL 5 "Top level" "expected: $(printf '%s | ' "${TOP_LEVEL[@]}" | sed 's/ | $//'); got: $(names "$R")"
    # the menus can still be walked if the entries are there at all
    top_ok=1
    for want in "${TOP_LEVEL[@]}"; do [[ -n "$(find_item "$R" "$want")" ]] || top_ok=""; done
  fi
else
  result FAIL 5 "Top level" "$rpc_error"
fi

needs_top() { # needs_top N NAME: FAIL N when the top level can't be walked
  [[ -n "$top_ok" ]] && return 0
  result FAIL "$1" "$2" "skipped: the top level is missing entries"
  return 1
}

# ---- 6. national station plays with metadata ----
if [[ -n "$skip_live" ]]; then
  result SKIP 6 "National station plays with metadata" "--skip-live"
elif needs_top 6 "National station plays with metadata"; then
  if ! walk "$STR_RADIO"; then
    result FAIL 6 "National station plays with metadata" "$walk_error"
  else
    # the station's row: in Radio itself, else in Sport, Local radio (each state) or Time-zone versions
    search_station "$W_ID" "$station"
    st_id="$ST_ID" st_name="$ST_NAME" note="" plays=""
    if [[ -z "$st_id" ]]; then
      if [[ -n "$ST_FAVS" ]]; then note=" ($station is not in $STR_RADIO${ST_ERR:+; $ST_ERR})"; else note=" (no station links in menu mode, older LMS?${ST_ERR:+; $ST_ERR})"; fi
      st_name="$station"
    elif [[ "$ST_SERVICE" != "$station" ]]; then
      plays="${ST_TITLE:-$ST_SERVICE} (your state's version)"
    fi
    if ! play_station "$st_id" "$st_name" "$station" "$plays"; then
      result FAIL 6 "National station plays with metadata" "$why$note"
    else
      # metadata: a title that is not a station's name (the station's own title is all LMS shows
      # without the plugin's program or song information)
      played="${ST_WHERE:+$ST_WHERE › }$why"
      title_ok=""
      while :; do
        if [[ "$S_TITLE" != "$st_name" ]] && not_a_station_name "$S_TITLE"; then title_ok=1; break; fi
        ((SECONDS - play_start < META_WAIT_S)) || break
        sleep "$POLL_S"
        status || break
      done
      if [[ -n "$title_ok" ]]; then
        result PASS 6 "National station plays with metadata" "$played; now playing '$S_TITLE'$note"
      else
        result FAIL 6 "National station plays with metadata" "$played, but no program or song title within $META_WAIT_S s (title '$S_TITLE')$note"
      fi
    fi
  fi
fi

# ---- 7. local station plays ----
if [[ -n "$skip_live" ]]; then
  result SKIP 7 "Local station plays" "--skip-live"
elif needs_top 7 "Local station plays"; then
  if ! walk "$STR_RADIO" "$STR_LOCAL_RADIO"; then
    result FAIL 7 "Local station plays" "$walk_error"
  else
    st_id="" st_name="" st_state="" favs="" last=""
    while IFS=$'\x1f' read -r state_id state_name; do
      [[ -n "$state_id" ]] || continue
      menu_items "$state_id" || { last="$state_name: $rpc_error"; continue; }
      has_favs "$R" && favs=1
      IFS=$'\x1f' read -r st_id st_name _ <<<"$(find_station "$R" "$local_station")"
      if [[ -n "$st_id" ]]; then st_state="$state_name"; break; fi
    done < <(item_list "$R" '.type == "link"')
    note=""
    if [[ -z "$st_id" ]]; then
      if [[ -n "$favs" ]]; then note=" ($local_station is not in $STR_LOCAL_RADIO${last:+; $last})"; else note=" (no station links in menu mode${last:+; $last})"; fi
      st_name="$local_station"
    fi
    if play_station "$st_id" "$st_name" "$local_station"; then
      result PASS 7 "Local station plays" "${st_state:+$st_state › }$why$note"
    else
      result FAIL 7 "Local station plays" "$why$note"
    fi
  fi
fi

# ---- 8. an episode plays and seeks ----
try_episode() { # try_episode ID: plays it, checks progress and a seek; why = the result
  local id="$1" t0 target start landed=""
  play "$id" || { why="play command failed: $rpc_error"; return 1; }
  wait_playing "$EPISODE_START_S" || return 1
  is "$S_DURATION > 0" || { why="playing, but no duration ($(status_text))"; return 1; }
  t0="$S_TIME"
  sleep "$EPISODE_WINDOW_S"
  status || { why="$rpc_error"; return 1; }
  is "$S_TIME > $t0" || { why="time not advancing: $(secs "$t0") → $(secs "$S_TIME") s in $EPISODE_WINDOW_S s ($(status_text))"; return 1; }
  target="$(jq -n "[$SEEK_MAX_S, ($S_DURATION / 2 | floor)] | min")"
  rpc "$player" "[\"time\",$target]" || { why="seek failed: $rpc_error"; return 1; }
  start=$SECONDS
  while ((SECONDS - start < SEEK_WAIT_S)); do
    sleep "$POLL_S"
    status || continue
    if [[ -z "$landed" ]]; then
      is "$S_TIME >= $target" && landed="$S_TIME"
    elif is "$S_TIME > $landed"; then
      why="duration $(secs "$S_DURATION") s, seek to $target s: time $(secs "$landed") → $(secs "$S_TIME") s"
      return 0
    fi
  done
  if [[ -n "$landed" ]]; then
    why="seek to $target s: time reached $(secs "$landed") s but did not advance ($(status_text))"
  else
    why="seek to $target s: not reached within $SEEK_WAIT_S s ($(status_text))"
  fi
  return 1
}

episode_path=()   # the names that lead to the program whose episode played (for check 12)
if needs_top 8 "Episode plays and seeks"; then
  if ! walk "$STR_PROGRAMS" "$STR_BY_NETWORK"; then
    result FAIL 8 "Episode plays and seeks" "$walk_error"
  else
    IFS=$'\x1f' read -r net_id net_name <<<"$(item_list "$R" '.type == "link"' | head -n 1)"
    if [[ -z "$net_id" ]] || ! items "$net_id"; then
      result FAIL 8 "Episode plays and seeks" "no network to open (${rpc_error:-$(hint "$R")})"
    else
      prog_ids=() prog_names=()
      while IFS=$'\x1f' read -r id name; do prog_ids+=("$id"); prog_names+=("$name"); done < <(item_list "$R" '.type == "link"')
      attempts=0 last="" played_prog=-1 played_ep=""
      for ((p = 0; p < ${#prog_ids[@]} && p < MAX_PROGRAMS && attempts < MAX_ATTEMPTS; p++)); do
        items "${prog_ids[p]}" || { last="${prog_names[p]}: $rpc_error"; continue; }
        ep_ids=() ep_names=()
        while IFS=$'\x1f' read -r id name; do ep_ids+=("$id"); ep_names+=("$name"); done \
          < <(item_list "$R" '(.isaudio | tostring) == "1" and (.type == "link" or .type == "audio" or .type == "playlist")')
        [[ ${#ep_ids[@]} -gt 0 ]] || { last="${prog_names[p]}: no episodes ($(hint "$R"))"; continue; }
        for ((e = 0; e < ${#ep_ids[@]} && attempts < MAX_ATTEMPTS; e++)); do
          attempts=$((attempts + 1))
          if try_episode "${ep_ids[e]}"; then
            played_prog=$p played_ep="${ep_names[e]}"
            break 2
          fi
          last="${prog_names[p]} › ${ep_names[e]}: $why"
        done
      done
      if [[ $played_prog -ge 0 ]]; then
        episode_path=("$STR_PROGRAMS" "$STR_BY_NETWORK" "$net_name" "${prog_names[played_prog]}")
        result PASS 8 "Episode plays and seeks" "$net_name › ${prog_names[played_prog]} › $played_ep: $why"
      else
        result FAIL 8 "Episode plays and seeks" "no episode played in $attempts attempt(s) over $p program(s) of $net_name${last:+; last: $last}"
      fi
    fi
  fi
fi
[[ -n "$touched" ]] && rpc "$player" '["stop"]'

# ---- 9. All programs A–Z non-empty ----
az_path=()
if needs_top 9 "All programs A–Z non-empty"; then
  if ! walk "$STR_PROGRAMS" "$STR_AZ"; then
    result FAIL 9 "All programs A–Z non-empty" "$walk_error"
  else
    IFS=$'\x1f' read -r letter_id letter_name <<<"$(item_list "$R" '.type == "link"' | head -n 1)"
    if [[ -z "$letter_id" ]]; then
      result FAIL 9 "All programs A–Z non-empty" "no letters ($(hint "$R"))"
    elif ! items "$letter_id"; then
      result FAIL 9 "All programs A–Z non-empty" "$letter_name: $rpc_error"
    else
      count="$(jq -r '[.loop_loop[]? | select(.type == "link")] | length' <<<"$R")"
      first_prog="$(item_list "$R" '.type == "link"' | head -n 1 | cut -d $'\x1f' -f 2)"
      if [[ "$count" -ge 1 ]]; then
        az_path=("$STR_PROGRAMS" "$STR_AZ" "$letter_name" "$first_prog")
        result PASS 9 "All programs A–Z non-empty" "$letter_name: $count programs, first '$first_prog'"
      else
        result FAIL 9 "All programs A–Z non-empty" "$letter_name lists no programs ($(hint "$R"))"
      fi
    fi
  fi
fi

# ---- 10. Home non-empty ----
if needs_top 10 "Home non-empty"; then
  if ! walk "$STR_HOME"; then
    result FAIL 10 "Home non-empty" "$walk_error"
  else
    home="$R" found="" tried=() last=""
    while IFS=$'\x1f' read -r id name; do
      tried+=("$name")
      if ! items "$id"; then last="$name: $rpc_error"; continue; fi
      n="$(non_text "$R")"
      if [[ "$n" -ge 1 ]]; then found="$name: $n items, first '$(item_list "$R" '(.type // "") != "text" and (.type // "") != "textarea"' | head -n 1 | cut -d $'\x1f' -f 2)'"; break; fi
      last="$name: nothing to open ($(hint "$R"))"
    done < <(item_list "$home" '.type == "link"' | head -n "$MAX_HOME_LINKS")
    if [[ -n "$found" ]]; then
      result PASS 10 "Home non-empty" "$found"
    elif [[ ${#tried[@]} -eq 0 ]]; then
      result FAIL 10 "Home non-empty" "no links under $STR_HOME ($(hint "$home"))"
    else
      result FAIL 10 "Home non-empty" "none of the first ${#tried[@]} links lists anything${last:+; last: $last}"
    fi
  fi
fi

# ---- 11. search ----
if needs_top 11 "Search"; then
  if ! items; then
    result FAIL 11 "Search" "$rpc_error"
  else
    search_id="$(jq -r --arg n "$STR_SEARCH" 'first(.loop_loop[]? | select(.name == $n and .type == "search")) | .id // empty' <<<"$R")"
    [[ -n "$search_id" ]] || search_id="$(find_item "$R" "$STR_SEARCH")"
    if [[ -z "$search_id" ]]; then
      result FAIL 11 "Search" "no \"$STR_SEARCH\" item"
    elif ! items "$search_id" "search:$SEARCH_QUERY"; then
      result FAIL 11 "Search" "search '$SEARCH_QUERY': $rpc_error"
    else
      n_prog="$(count_of "$R" "$STR_SEARCH_PROGRAMS")"
      n_ep="$(count_of "$R" "$STR_SEARCH_EPISODES")"
      if [[ "${n_prog:-0}" -ge 1 && "${n_ep:-0}" -ge 1 ]]; then
        result PASS 11 "Search" "'$SEARCH_QUERY': $(prefix "$STR_SEARCH_PROGRAMS")$n_prog), $(prefix "$STR_SEARCH_EPISODES")$n_ep)"
      else
        result FAIL 11 "Search" "'$SEARCH_QUERY': needs $(prefix "$STR_SEARCH_PROGRAMS")N) and $(prefix "$STR_SEARCH_EPISODES")M) with N, M >= 1; $(hint "$R")"
      fi
    fi
  fi
fi

# ---- 12. follow round trip ----
# followed_count: F_COUNT = N of "Followed programs (N)" (0 when My ABC listen shows the help text),
# F_ID = that item's id; returns 1 with why set when it can't be read
followed_count() {
  F_COUNT="" F_ID=""
  walk "$STR_MY_ABC" || { why="$walk_error"; return 1; }
  F_COUNT="$(count_of "$R" "$STR_FOLLOWED_PROGRAMS")"
  if [[ -n "$F_COUNT" ]]; then
    F_ID="$(find_item "$R" "$(prefix "$STR_FOLLOWED_PROGRAMS")")"
    return 0
  fi
  [[ -n "$(find_item "$R" "$STR_NO_FOLLOWED_HELP")" ]] && { F_COUNT=0; return 0; }
  why="no \"$(prefix "$STR_FOLLOWED_PROGRAMS")N)\" item ($(hint "$R"))"
  return 1
}

# follow_action OP: open the program again and choose Follow (OP=follow) or Unfollow; why = detail
follow_action() {
  local want id answer reply
  if [[ "$1" == follow ]]; then want="$STR_FOLLOW"; answer="$STR_FOLLOWED_OK"; else want="$STR_UNFOLLOW"; answer="$STR_UNFOLLOWED_OK"; fi
  walk "${follow_menu[@]}" || { why="$walk_error"; return 1; }
  id="$(find_item "$R" "$(prefix "$want")")"
  [[ -n "$id" ]] || { why="no \"$(prefix "$want")…\" item in $follow_name (got: $(names "$R"))"; return 1; }
  follow_sent=1
  items "$id" || { why="$(prefix "$want")…: $rpc_error"; return 1; }
  reply="$(jq -r --arg p "$(prefix "$answer")" 'first(.loop_loop[]? | .name // "" | select(startswith($p)))' <<<"$R")"
  [[ -n "$reply" ]] || { why="$(prefix "$want")… answered: $(names "$R")"; return 1; }
  follow_title="${reply#"$(prefix "$answer")"}"   # the title the plugin stored
}

# listed: the program is a row of Followed programs
listed() {
  [[ -n "$F_ID" ]] && items "$F_ID" &&
    jq -e --arg n "$follow_name" 'any(.loop_loop[]?; (.name // "" | gsub("\\s+"; " ")) == $n)' <<<"$R" >/dev/null 2>&1
}

follow_check() {
  local start n already full expect
  follow_menu=("${episode_path[@]}")
  [[ ${#follow_menu[@]} -gt 0 ]] || follow_menu=("${az_path[@]}")
  [[ ${#follow_menu[@]} -gt 0 ]] || { why="skipped: no program from checks 8 or 9"; return 1; }
  follow_name="${follow_menu[${#follow_menu[@]} - 1]}"
  followed || { why="can't read the followed programs: $rpc_error"; return 1; }
  follows_saved="$R_FOLLOWED"
  follow_path="" follow_note="" follow_title="" follow_sent=""
  followed_count || return 1
  start="$F_COUNT"
  follow_start="$start"
  # with 200 followed (the plugin's limit), a follow unfollows the oldest one to make room
  full=""
  [[ "$start" -ge 200 ]] && full=1

  walk "${follow_menu[@]}" || { why="$walk_error"; return 1; }
  if [[ -n "$(find_item "$R" "$(prefix "$STR_FOLLOW")")" ]]; then
    already=""
  elif [[ -n "$(find_item "$R" "$(prefix "$STR_FOLLOWING")")" || -n "$(find_item "$R" "$(prefix "$STR_UNFOLLOW")")" ]]; then
    already=1
  else
    why="$follow_name has no \"$(prefix "$STR_FOLLOW")…\" item (got: $(names "$R"))"
    return 1
  fi

  if [[ -z "$already" ]]; then
    follow_action follow || return 1
    followed && follow_path="$(find_test_path follow "$follows_saved")"
    followed_count || return 1
    n="$F_COUNT"
    listed || { why="followed, but $(prefix "$STR_FOLLOWED_PROGRAMS")$n) doesn't list $follow_name"; return 1; }
    expect=$((full ? start : start + 1))
    [[ "$n" -eq "$expect" ]] || { why="followed: $(prefix "$STR_FOLLOWED_PROGRAMS")$start) → ($n), expected ($expect)"; return 1; }
    follow_action unfollow || return 1
    followed_count || return 1
    expect=$((full ? start - 1 : start))
    [[ "$F_COUNT" -eq "$expect" ]] || { why="unfollowed: $(prefix "$STR_FOLLOWED_PROGRAMS")$n) → ($F_COUNT), expected ($expect)"; return 1; }
    why="$follow_name: $(prefix "$STR_FOLLOWED_PROGRAMS")$start) → followed, listed ($n) → unfollowed ($F_COUNT)"
    [[ -n "$full" ]] && why="$why; the list was full, so the plugin dropped the oldest follow to make room"
  else
    follow_action unfollow || return 1
    followed && follow_path="$(find_test_path unfollow "$follows_saved")"
    followed_count || return 1
    n="$F_COUNT"
    [[ "$n" -eq $((start - 1)) ]] || { why="unfollowed: $(prefix "$STR_FOLLOWED_PROGRAMS")$start) → ($n), expected $((start - 1))"; return 1; }
    follow_action follow || return 1
    followed_count || return 1
    listed || { why="re-followed, but $(prefix "$STR_FOLLOWED_PROGRAMS")$F_COUNT) doesn't list $follow_name"; return 1; }
    [[ "$F_COUNT" -eq "$start" ]] || { why="re-followed: $(prefix "$STR_FOLLOWED_PROGRAMS")$n) → ($F_COUNT), expected ($start)"; return 1; }
    why="$follow_name was already followed: $(prefix "$STR_FOLLOWED_PROGRAMS")$start) → unfollowed ($n) → followed again, listed ($F_COUNT)"
  fi
  return 0
}

if needs_top 12 "Follow round trip"; then
  if follow_check; then
    detail="$why"
    if ! restore_follows; then
      result FAIL 12 "Follow round trip" "$detail; but $follow_note"
    elif ! followed_count; then
      result FAIL 12 "Follow round trip" "$detail; restored, but then $why"
    elif [[ "$F_COUNT" -ne "$follow_start" ]]; then
      result FAIL 12 "Follow round trip" "$detail; restored, but $(prefix "$STR_FOLLOWED_PROGRAMS")$F_COUNT), expected ($follow_start)"
    else
      result PASS 12 "Follow round trip" "$detail; followed programs restored ($F_COUNT)"
    fi
  else
    detail="$why"
    restore_follows || detail="$detail; $follow_note"
    result FAIL 12 "Follow round trip" "$detail"
  fi
fi

# ---- 13. Podcasts non-empty ----
if needs_top 13 "Podcasts non-empty"; then
  if ! walk "$STR_PODCASTS"; then
    result FAIL 13 "Podcasts non-empty" "$walk_error"
  else
    nn_id="$(find_item "$R" "$ABC_NEW_NOTEWORTHY")"
    if [[ -z "$nn_id" ]]; then
      result FAIL 13 "Podcasts non-empty" "no \"$ABC_NEW_NOTEWORTHY\" item ($(hint "$R"))"
    elif ! items "$nn_id"; then
      result FAIL 13 "Podcasts non-empty" "$ABC_NEW_NOTEWORTHY: $rpc_error"
    else
      n="$(jq -r '[.loop_loop[]? | select(.type == "link")] | length' <<<"$R")"
      if [[ "$n" -ge 1 ]]; then
        result PASS 13 "Podcasts non-empty" "$ABC_NEW_NOTEWORTHY: $n programs, first '$(item_list "$R" '.type == "link"' | head -n 1 | cut -d $'\x1f' -f 2)'"
      else
        result FAIL 13 "Podcasts non-empty" "$ABC_NEW_NOTEWORTHY lists no programs ($(hint "$R"))"
      fi
    fi
  fi
fi

# ---- 14. sections non-empty ----
if needs_top 14 "Sections non-empty"; then
  counts=() empty=()
  for section in "$STR_NEWS" "$STR_SPORT" "$STR_KIDS" "$STR_AUDIOBOOKS"; do
    if ! walk "$section"; then empty+=("$section ($walk_error)"); continue; fi
    n="$(non_text "$R")"
    if [[ "$n" -ge 1 ]]; then counts+=("$section $n"); else empty+=("$section ($(hint "$R"))"); fi
  done
  if [[ ${#empty[@]} -eq 0 ]]; then
    list="$(printf '%s, ' "${counts[@]}")"
    result PASS 14 "Sections non-empty" "${list%, } items"
  else
    result FAIL 14 "Sections non-empty" "empty: $(printf '%s; ' "${empty[@]}" | sed 's/; $//')"
  fi
fi

# ---- 15. Kids listen live plays ----
if [[ -n "$skip_live" ]]; then
  result SKIP 15 "Kids listen live plays" "--skip-live"
elif needs_top 15 "Kids listen live plays"; then
  if ! walk "$STR_KIDS" || ! menu_items "$W_ID"; then
    result FAIL 15 "Kids listen live plays" "${walk_error:-$rpc_error}"
  else
    IFS=$'\x1f' read -r st_id st_name _ <<<"$(find_station "$R" KIDSLISTEN)"
    note=""
    if [[ -z "$st_id" ]]; then
      if has_favs "$R"; then note=" (KIDSLISTEN is not in $STR_KIDS)"; else note=" (no station links in menu mode)"; fi
      st_name=KIDSLISTEN
    fi
    if play_station "$st_id" "$st_name" KIDSLISTEN; then
      result PASS 15 "Kids listen live plays" "$why$note"
    else
      result FAIL 15 "Kids listen live plays" "$why$note"
    fi
  fi
fi

finish
