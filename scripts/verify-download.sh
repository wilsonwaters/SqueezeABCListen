#!/usr/bin/env bash
# verify-download.sh - download a plugin zip from the URL LMS will use and check it: HTTP 200,
# no response header line longer than LMS's limit, and the SHA1 of the body. Retries until it
# passes or the time is up, because raw.githubusercontent.com can take a moment to serve a file
# that was just pushed, and caches its answers (a 404 included) for 5 minutes.
#
# Usage: scripts/verify-download.sh [--timeout SECONDS] [--interval SECONDS] URL SHA1
#   URL         the download URL (redirects are followed, as LMS does)
#   SHA1        the expected SHA1 of the file (40 hex digits, any case)
#   --timeout   give up after about this many seconds (default 300); at least one try is made
#   --interval  seconds to wait between tries (default 15)
#
# The header limit is that of the Net::HTTP bundled with LMS 9.1.1: a response header line over
# 8,192 bytes ("Header line too long (limit is 8192)") makes LMS give up on the download. Such a
# line fails at once, without retrying; a non-200 status, a transport error or a different SHA1
# is retried.
# Exit codes: 0 verified, 1 failed, 2 usage error. Needs curl and sha1sum.
set -euo pipefail

MAX_HEADER_LINE=8192
timeout=300
interval=15
args=()

usage() {
  sed -n '7,11p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
say() { echo "verify-download.sh: $*"; }
die() { echo "verify-download.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; timeout="$2"; shift 2 ;;
    --interval) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; interval="$2"; shift 2 ;;
    -h | --help) usage ;;
    -*) echo "verify-download.sh: unknown option: $1" >&2; usage ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ ${#args[@]} -eq 2 ]] || usage
url="${args[0]}"
want="${args[1],,}"
[[ "$want" =~ ^[0-9a-f]{40}$ ]] || { echo "verify-download.sh: '${args[1]}' is not a SHA1 (40 hex digits)" >&2; usage; }

for tool in curl sha1sum; do
  command -v "$tool" >/dev/null || die "'$tool' is not installed"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

deadline=$((SECONDS + timeout))
attempt=0
while :; do
  attempt=$((attempt + 1))
  rm -f "$tmp/body" "$tmp/headers" "$tmp/err"
  code="$(curl -sS -L --max-time 60 -A 'SqueezeABCListen release check (curl)' \
    -D "$tmp/headers" -o "$tmp/body" -w '%{http_code}' "$url" 2>"$tmp/err")" || true

  # every response's headers, redirects included; CR counted, so the check errs on the safe side
  long="$(LC_ALL=C awk -v max="$MAX_HEADER_LINE" 'length($0) > max { print length($0) ": " substr($0, 1, 60) "..." }' "$tmp/headers" 2>/dev/null || true)"
  if [[ -n "$long" ]]; then
    die "$url sends a response header line longer than $MAX_HEADER_LINE bytes, which LMS 9.1.1 can't read (\"Header line too long\"): $long"
  fi

  if [[ "$code" == 200 && -f "$tmp/body" ]]; then
    got="$(sha1sum "$tmp/body" | cut -d' ' -f1)"
    if [[ "$got" == "$want" ]]; then
      say "verified $url: HTTP 200, sha1 $got, $(wc -c <"$tmp/body" | tr -d ' ') bytes, longest header line $(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$tmp/headers") bytes (try $attempt)"
      exit 0
    fi
    reason="sha1 $got, expected $want"
  elif [[ "$code" == 000 || -z "$code" ]]; then
    reason="no response ($(head -c 200 "$tmp/err" 2>/dev/null | tr '\n' ' '))"
  else
    reason="HTTP $code"
  fi

  if ((SECONDS >= deadline)); then
    die "$url did not verify after $attempt tries in ${timeout}s; last try: $reason"
  fi
  wait_s=$((deadline - SECONDS < interval ? deadline - SECONDS : interval))
  say "try $attempt: $reason; trying again in ${wait_s}s"
  sleep "$wait_s"
done
