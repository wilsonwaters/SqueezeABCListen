#!/usr/bin/env bash
# lms-repo-install.sh - install or uninstall the plugin on an LMS from a third-party repository
# without a browser, by posting the same form as Settings > Manage Plugins (LMS 9.1
# Slim/Web/Settings/Server/Plugins.pm). No JSON-RPC command installs plugins.
#
# Usage: scripts/lms-repo-install.sh [--uninstall] LMS_URL REPO_XML_URL
#   LMS_URL       the server, e.g. http://127.0.0.1:9000
#   REPO_XML_URL  the repository file, e.g. https://raw.githubusercontent.com/wilsonwaters/SqueezeABCListen/main/repo.xml
#   --uninstall   untick the plugin and remove REPO_XML_URL from the repository list
# Environment: PLUGIN (default ABCListen); LMS_USER and LMS_PASS for HTTP basic auth.
#
# Install: adds REPO_XML_URL to the repository list, checks that LMS now offers the plugin,
# ticks it, then waits (up to 60 s) until LMS has downloaded and SHA1-checked the zip, i.e.
# plugin.state:<PLUGIN> is needs-install. Uninstall: waits for needs-uninstall instead. Saving
# the form replaces the repository list and the "automatic updates" and "unsupported plugins"
# settings, so every post repeats their current values. LMS finishes the job on its next
# restart; this script does not restart it.
# Exit codes: 0 success, 1 LMS-side failure, 2 usage or connectivity error. Needs curl and jq.
set -uo pipefail

PLUGIN="${PLUGIN:-ABCListen}"
WAIT_S=60

usage() {
  sed -n '6,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
say() { echo "lms-repo-install: $*"; }
fail() { echo "lms-repo-install: $*" >&2; exit 1; }
die_usage() { echo "lms-repo-install: $*" >&2; exit 2; }

uninstall=0
if [[ "${1:-}" == --uninstall ]]; then uninstall=1; shift; fi
[[ $# -eq 2 ]] || usage
lms="${1%/}"
repo="$2"

for tool in curl jq; do
  command -v "$tool" >/dev/null || die_usage "'$tool' is not installed"
done
[[ "$PLUGIN" =~ ^[A-Za-z0-9_]+$ ]] || die_usage "PLUGIN must be a plugin name like ABCListen, got '$PLUGIN'"
[[ "$lms" =~ ^https?://[^[:space:]]+$ ]] || die_usage "LMS_URL must look like http://host:9000, got '$1'"
# LMS keeps only repository URLs matching ^https?://.*\.xml and strips trailing non-word characters
[[ "$repo" =~ ^https?://.*\.xml ]] || die_usage "REPO_XML_URL must be an http(s) URL of an .xml file, got '$repo'"
while [[ "$repo" =~ [^[:alnum:]_]$ ]]; do repo="${repo%?}"; done

page="$lms/settings/server/plugins.html"
curl_opts=(-sS --max-time 90)
[[ -n "${LMS_USER:-}" ]] && curl_opts+=(-u "$LMS_USER:${LMS_PASS:-}")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# request <outfile> <curl args...> : exits 2 if LMS can't be reached, 1 on an HTTP error
request() {
  local out="$1" code rc
  shift
  code="$(curl "${curl_opts[@]}" -o "$out" -w '%{http_code}' "$@")"
  rc=$?
  [[ $rc -eq 0 ]] || die_usage "no response from $lms (curl exit $rc)"
  case "$code" in
    2??) ;;
    401) die_usage "$lms asks for a password: set LMS_USER and LMS_PASS" ;;
    *) fail "$lms answered HTTP $code for $page" ;;
  esac
}

html_unescape() { sed 's/&quot;/"/g; s/&#39;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'; }

# the value of the first <input name="$1" ...> on the page
input_value() {
  grep -o "<input[^>]*name=\"$1\"[^>]*>" "$tmp/page.html" | head -n 1 | sed -n 's/.*value="\([^"]*\)".*/\1/p'
}

checkbox_state() {
  if grep -o "<input[^>]*name=\"$1\"[^>]*>" "$tmp/page.html" | head -n 1 | grep -q 'checked'; then echo 1; else echo 0; fi
}

# GET the Manage Plugins page: sets rand, repos[], auto, unsupported
read_form() {
  request "$tmp/page.html" "$page"
  rand="$(input_value rand)"
  [[ "$rand" =~ ^[0-9a-f]{32}$ ]] || fail "no anti-CSRF 'rand' field on $page; is this an LMS server?"
  repos=()
  local r
  while IFS= read -r r; do
    [[ -n "$r" ]] && repos+=("$r")
  done < <(grep -o '<input[^>]*name="repos"[^>]*>' "$tmp/page.html" | sed -n 's/.*value="\([^"]*\)".*/\1/p' | html_unescape)
  auto="$(checkbox_state auto)"
  unsupported="$(checkbox_state useUnsupported)"
}

# POST the form with post_repos[], the current auto/useUnsupported values and extra fields
post_form() {
  local args=(--data-urlencode saveSettings=1 --data-urlencode "rand=$rand") r f
  for r in "${post_repos[@]}"; do args+=(--data-urlencode "repos=$r"); done
  [[ "$auto" == 1 ]] && args+=(--data-urlencode auto=1)
  [[ "$unsupported" == 1 ]] && args+=(--data-urlencode useUnsupported=1)
  for f in "$@"; do args+=(--data-urlencode "$f"); done
  request "$tmp/post.html" "${args[@]}" "$page"
}

# print the page's status area (restart notices, "Bad repository <url> - <error>")
print_status() {
  local text
  text="$(sed -n '/<div id="statusarea"/,/<\/div>/p' "$1" | sed 's/<[^>]*>/ /g' | tr -s ' \t\r\n' ' ' | sed 's/^ //; s/ $//')"
  [[ -n "$text" ]] && echo "lms-repo-install: LMS says: $text" >&2
  return 0
}

plugin_state() {
  local body out
  body="$(jq -cn --arg pref "plugin.state:$PLUGIN" '{id: 1, method: "slim.request", params: ["", ["pref", $pref, "?"]]}')"
  out="$(curl "${curl_opts[@]}" -H 'Content-Type: application/json' -d "$body" "$lms/jsonrpc.js")" || return 0
  jq -r '.result._p2 // empty' <<<"$out" 2>/dev/null
}

# wait_state <state> : polls plugin.state:<PLUGIN> for up to WAIT_S seconds; sets last_state
wait_state() {
  local i
  for ((i = 0; i < WAIT_S; i++)); do
    last_state="$(plugin_state)"
    [[ "$last_state" == "$1" ]] && return 0
    sleep 1
  done
  return 1
}

read_form

if [[ $uninstall -eq 1 ]]; then
  post_repos=()
  for r in "${repos[@]}"; do [[ "$r" == "$repo" ]] || post_repos+=("$r"); done
  say "unticking $PLUGIN and removing repository $repo"
  post_form "install:$PLUGIN=1"
  if wait_state needs-uninstall; then
    say "plugin.state:$PLUGIN = needs-uninstall"
    say "restart LMS to finish the uninstall"
    exit 0
  fi
  print_status "$tmp/post.html"
  fail "repository removed, but plugin.state:$PLUGIN is '${last_state:-unset}' after ${WAIT_S}s, not needs-uninstall; was $PLUGIN installed from a repository?"
fi

# 1. add the repository, keeping the existing ones
post_repos=("${repos[@]}")
if printf '%s\n' "${repos[@]}" | grep -qxF -- "$repo"; then
  say "repository already listed: $repo"
else
  say "adding repository $repo"
  post_repos+=("$repo")
  post_form
fi

# 2. LMS must now offer the plugin (a hidden install:<PLUGIN> field next to its checkbox)
read_form
if ! grep -q "name=\"install:$PLUGIN\"" "$tmp/page.html"; then
  print_status "$tmp/page.html"
  if grep -q "name=\"manual:$PLUGIN\"" "$tmp/page.html"; then
    fail "$PLUGIN is installed manually on this LMS (e.g. linked into its Plugins folder); remove that copy and restart LMS first"
  fi
  fail "LMS does not offer $PLUGIN from $repo; check the repository URL and file (run with --uninstall to remove the repository again)"
fi

# 3. tick it; LMS enables it in plugin.extensions:plugin and starts the download
say "installing $PLUGIN from $repo"
post_repos=("${repos[@]}")
post_form "install:$PLUGIN=1" "$PLUGIN=on"

# 4. the download is asynchronous: wait for the SHA1-checked zip
if wait_state needs-install; then
  say "$PLUGIN downloaded and SHA1-verified (plugin.state:$PLUGIN = needs-install)"
  say "restart LMS to finish the install"
  exit 0
fi
print_status "$tmp/post.html"
fail "plugin.state:$PLUGIN is '${last_state:-unset}' after ${WAIT_S}s, not needs-install: the download or SHA1 check failed (look for 'digest does not match' or 'unable to download' in the LMS server.log), or $PLUGIN is already installed at this version"
