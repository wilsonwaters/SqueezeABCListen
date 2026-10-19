#!/usr/bin/env bash
# logs.sh - show/tail the dev stack logs (all live in dev/logs/, git-ignored).
# Usage: dev/logs.sh [server|stdout|squeezelite|egress] [-n LINES] [-f|--no-follow]
#   server      : LMS server.log (default)       stdout : LMS stdout/stderr (perl warnings)
#   squeezelite : squeezelite log                 egress : egress-proxy.log (outbound requests)
# Follows (tail -F) when run on a terminal, otherwise prints the last lines and exits;
# -f forces following, --no-follow disables it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
which=server; lines=100
if [[ -t 1 ]]; then follow=1; else follow=0; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    server|stdout|squeezelite|egress) which="$1" ;;
    -n) lines="$2"; shift ;;
    -f) follow=1 ;;
    --no-follow) follow=0 ;;
    *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
  shift
done
case "$which" in
  server) f="$LOG_DIR/server.log" ;;
  stdout) f="$LOG_DIR/lms-stdout.log" ;;
  squeezelite) f="$LOG_DIR/squeezelite.log" ;;
  egress) f="$LOG_DIR/egress-proxy.log" ;;
esac
[[ -f "$f" ]] || die "no log yet: $f"
if [[ $follow -eq 1 ]]; then exec tail -n "$lines" -F "$f"; else tail -n "$lines" "$f"; fi
