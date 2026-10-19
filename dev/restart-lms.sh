#!/usr/bin/env bash
# restart-lms.sh - restart only LMS (e.g. to reload plugin Perl code after edits).
# squeezelite and the egress-proxy keep running; squeezelite reconnects by itself.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_installed
start_egress            # no-op if already running
stop_lms
start_lms
start_player && log "$PLAYER_NAME connected" || true   # waits for the reconnect (or starts it)
