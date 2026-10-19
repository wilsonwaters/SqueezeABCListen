#!/usr/bin/env bash
# install-material.sh - install the Material Skin plugin (the popular third-party LMS web UI,
# https://github.com/CDrummond/lms-material) into the dev LMS, pinned to $MATERIAL_VERSION.
# Idempotent (called by setup.sh): if that version is already installed it does nothing.
#   * downloads the release zip once to $LMS_BASE/dl/ and checks its sha1 (from extensions.xml)
#   * unpacks it to <LMS>/Plugins/MaterialSkin, LMS's "manual install" dir on Unix, so the
#     Extension Manager never auto-updates or uninstalls it (unlike cache/InstalledPlugins)
# LMS only loads it on (re)start: dev/restart-lms.sh (hold the test-bed lock if LMS is shared).
# Then it is served at http://localhost:9000/material/
# Usage: dev/install-material.sh [--force] [--uninstall]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
force=0; uninstall=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --uninstall) uninstall=1 ;;
    *) die "usage: $0 [--force] [--uninstall]" ;;
  esac
done
[[ -d "$LMS_HOME" ]] || die "LMS not installed - run dev/setup.sh"
[[ -L "$MATERIAL_DIR" ]] && die "$MATERIAL_DIR is a symlink (dev link?) - leaving it alone"
lms_running() { pid_alive "$LMS_PIDFILE"; }

if [[ $uninstall -eq 1 ]]; then
  if [[ -d "$MATERIAL_DIR" ]]; then rm -rf "$MATERIAL_DIR"; log "removed $MATERIAL_DIR"; else log "Material Skin not installed"; fi
  lms_running && log "restart LMS to unload it: dev/restart-lms.sh"
  exit 0
fi

installed=""
[[ -f "$MATERIAL_DIR/install.xml" ]] && installed="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$MATERIAL_DIR/install.xml" | head -n 1)"
[[ -e "$LMS_CACHE/InstalledPlugins/Plugins/MaterialSkin" ]] &&
  log "WARNING: $LMS_CACHE/InstalledPlugins/Plugins/MaterialSkin also exists (Extension Manager install) - remove it to avoid clashes"
if [[ $force -eq 0 && "$installed" == "$MATERIAL_VERSION" ]]; then
  log "Material Skin $installed already installed at $MATERIAL_DIR"
  exit 0
fi

command -v unzip >/dev/null || die "'unzip' missing - run dev/setup.sh"
mkdir -p "$LMS_BASE/dl" "$LMS_PLUGIN_DIR"
zip="$LMS_BASE/dl/lms-material-$MATERIAL_VERSION.zip"
if [[ ! -s "$zip" ]]; then
  log "downloading $MATERIAL_ZIP_URL"
  curl -fL --retry 3 -sS -o "$zip.part" "$MATERIAL_ZIP_URL"   # curl honours $HTTPS_PROXY
  mv "$zip.part" "$zip"
fi
if [[ -n "${MATERIAL_ZIP_SHA1:-}" ]]; then
  echo "$MATERIAL_ZIP_SHA1  $zip" | sha1sum -c --quiet - || { rm -f "$zip"; die "sha1 mismatch for $zip (deleted, re-run)"; }
else
  log "WARNING: no MATERIAL_ZIP_SHA1 for $MATERIAL_VERSION - not verified"
fi

# unpack next to the zip (not inside Plugins/, which LMS scans), check it, then swap it in
tmp="$LMS_BASE/dl/MaterialSkin-$MATERIAL_VERSION.unpack"
rm -rf "$tmp"
unzip -q "$zip" -d "$tmp"
grep -q '<module>Plugins::MaterialSkin::Plugin</module>' "$tmp/install.xml" 2>/dev/null &&
  grep -q "<version>$MATERIAL_VERSION</version>" "$tmp/install.xml" ||
  { rm -rf "$tmp"; die "unexpected zip layout/version in $zip (no matching install.xml at its root)"; }
rm -rf "$MATERIAL_DIR"
mv "$tmp" "$MATERIAL_DIR"
log "installed Material Skin $MATERIAL_VERSION at $MATERIAL_DIR${installed:+ (replaced $installed)}"
if lms_running; then
  log "LMS is running - restart it to load Material: dev/restart-lms.sh, then http://localhost:$LMS_PORT/material/"
fi
