#!/usr/bin/env bash
# start.sh - start the LMS dev stack in the background (idempotent):
#   1. egress-proxy.mjs  (local CONNECT helper that reaches the internet via $HTTPS_PROXY)
#   2. Lyrion Music Server, wrapped in proxychains4 so its outbound TCP goes via (1)
#   3. squeezelite "DevPlayer" (00:00:00:00:00:01), audio paced to real time and discarded
# Waits until JSON-RPC answers and the player has connected. Logs: dev/logs/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_installed
start_egress
start_lms
start_player || true
log "ready: web UI http://localhost:$LMS_PORT/  JSON-RPC $LMS_RPC_URL"
