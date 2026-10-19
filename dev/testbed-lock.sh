#!/usr/bin/env bash
# testbed-lock.sh - mutual exclusion for the single shared LMS test bed, so parallel agents
# don't re-point the plugin link or restart LMS under each other.
# Usage: dev/testbed-lock.sh acquire <owner> [timeout_s=1800]   # waits until free, then takes it
#        dev/testbed-lock.sh release <owner>                    # only the owner can release
#        dev/testbed-lock.sh status
# A lock older than 60 minutes is considered stale and is broken automatically.
# Typical session (always run dev scripts from the MAIN checkout, /home/user/SqueezeABCListen/dev):
#   dev/testbed-lock.sh acquire O1
#   PLUGIN_SRC=<your-worktree>/ABCListen dev/link-plugin.sh --restart
#   ... verify ...
#   dev/link-plugin.sh --restart          # re-link the main checkout
#   dev/testbed-lock.sh release O1
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
LOCK="$LMS_RUN/testbed.lock"
STALE_S=3600
mkdir -p "$LMS_RUN"

owner_of() { cat "$LOCK/owner" 2>/dev/null || echo "?"; }
age_of() { echo $(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || date +%s) )); }

case "${1:-}" in
  acquire)
    owner="${2:?owner required}"; timeout="${3:-1800}"; waited=0
    while ! mkdir "$LOCK" 2>/dev/null; do
      if [[ "$(owner_of)" == "$owner" ]]; then log "already held by $owner"; exit 0; fi
      if (( $(age_of) > STALE_S )); then
        log "breaking stale lock held by $(owner_of) ($(age_of)s old)"; rm -rf "$LOCK"; continue
      fi
      (( waited >= timeout )) && die "timed out after ${timeout}s waiting for test bed (held by $(owner_of))"
      (( waited % 60 == 0 )) && log "test bed busy (held by $(owner_of)), waiting..."
      sleep 5; waited=$((waited + 5))
    done
    echo "$owner" > "$LOCK/owner"
    log "test bed lock acquired by $owner"
    ;;
  release)
    owner="${2:?owner required}"
    [[ -d "$LOCK" ]] || { log "lock not held"; exit 0; }
    [[ "$(owner_of)" == "$owner" ]] || die "lock held by $(owner_of), not $owner"
    rm -rf "$LOCK"; log "test bed lock released by $owner"
    ;;
  status)
    if [[ -d "$LOCK" ]]; then echo "held by $(owner_of) for $(age_of)s"; else echo "free"; fi
    ;;
  *) die "usage: $0 acquire <owner> [timeout_s] | release <owner> | status" ;;
esac
