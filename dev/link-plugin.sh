#!/usr/bin/env bash
# link-plugin.sh - install the plugin under development into the local LMS by symlinking
# the repo working tree (default <repo>/ABCListen, namespace Plugins::ABCListen) to
# <LMS>/Plugins/<name>, a directory LMS scans for install.xml on Unix. Code is read
# straight from the repo; after edits run dev/restart-lms.sh (or pass --restart).
# If the default src_dir does not exist yet, it logs a hint and links nothing (exit 0).
# Usage: dev/link-plugin.sh [--restart] [--unlink] [src_dir [name]]
#   src_dir : plugin dir containing install.xml (default: $PLUGIN_SRC)
#   name    : dir name under Plugins/, must match Plugins::<name>:: (default: basename of src_dir)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
restart=0; unlink=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --restart) restart=1 ;;
    --unlink) unlink=1 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
if [[ $# -ge 1 ]]; then src="$1"; name="${2:-$(basename "$1")}"; else src="$PLUGIN_SRC"; name="$PLUGIN_NAME"; fi
link="$LMS_PLUGIN_DIR/$name"
[[ -d "$LMS_HOME" ]] || die "LMS not installed - run dev/setup.sh"
mkdir -p "$LMS_PLUGIN_DIR"

if [[ $unlink -eq 1 ]]; then
  if [[ -L "$link" ]]; then rm -f "$link"; log "removed $link"; else log "no symlink at $link"; fi
elif [[ $# -eq 0 && ! -d "$src" ]]; then
  # default source (<repo>/ABCListen) not created yet: nothing to link, not an error
  log "plugin dir $src does not exist yet - nothing linked."
  log "create it (with install.xml, Plugin.pm under namespace Plugins::$name) and re-run this script"
  [[ -L "$link" && ! -e "$link" ]] && { rm -f "$link"; log "removed dangling symlink $link"; }
else
  src="$(cd "$src" 2>/dev/null && pwd)" || die "plugin source dir not found: ${1:-$PLUGIN_SRC}"
  [[ -e "$link" && ! -L "$link" ]] && die "$link exists and is not a symlink - remove it first"
  ln -sfn "$src" "$link"
  log "linked $link -> $src"
  [[ -f "$src/install.xml" ]] || log "WARNING: $src/install.xml missing - LMS will ignore the plugin until it exists"
  # a copy installed through the Extension Manager would shadow/clash with the dev link
  for d in "$LMS_CACHE/InstalledPlugins/Plugins/$name" "$LMS_CACHE/DownloadedPlugins/$name.zip"; do
    [[ -e "$d" ]] && log "WARNING: $d also exists (Extension Manager install) - remove it to avoid clashes"
  done
fi

if [[ $restart -eq 1 ]]; then
  marker="$(date '+%y-%m-%d %H:%M:%S')"
  "$DEV_DIR/restart-lms.sh"
  log "plugin state pref: $(rpc_raw - "[\"pref\",\"plugin.state:$name\",\"?\"]" | jq -r '.result._p2 // "unset (= enabled by default)"')"
  log "server.log lines mentioning $name since restart:"
  awk -v m="[$marker" '$0 >= m' "$LOG_DIR/server.log" | grep -a -i -- "$name" | tail -n 20 >&2 || log "  (none)"
fi
