#!/usr/bin/env bash
# stop.sh - stop squeezelite, LMS and the egress-proxy (idempotent).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
stop_player
stop_lms
stop_egress
log "stopped"
