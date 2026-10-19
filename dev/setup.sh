#!/usr/bin/env bash
# setup.sh - install the local LMS dev environment (idempotent; safe to re-run):
#   * apt: squeezelite, proxychains4, pv, jq, perl SSL modules (LMS doesn't bundle them)
#   * Lyrion Music Server (full tarball, bundled CPAN) -> /opt/lms-dev/lyrionmusicserver-<ver>,
#     symlinked as /opt/lms-dev/server; prefs/cache/run dirs under /opt/lms-dev
#   * dev/browser npm deps (playwright pinned to the pre-installed chromium; no browser download)
# Starts nothing - run dev/start.sh afterwards. Must run as root.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ $EUID -eq 0 ]] || die "run as root"

# --- OS packages ---
pkgs=(squeezelite proxychains4 pv jq curl ca-certificates libio-socket-ssl-perl libnet-ssleay-perl)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  log "apt-get install ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # policy-rc.d in this container stops the squeezelite package from starting a system instance
  apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
else
  log "apt packages already installed"
fi
command -v node >/dev/null || die "node is required (for egress-proxy.mjs and dev/browser)"

# --- Lyrion Music Server ---
lms_dir="$LMS_BASE/lyrionmusicserver-$LMS_VERSION"
if [[ ! -f "$lms_dir/slimserver.pl" ]]; then
  mkdir -p "$LMS_BASE/dl"
  tgz="$LMS_BASE/dl/lyrionmusicserver-$LMS_VERSION.tgz"
  if [[ ! -s "$tgz" ]]; then
    log "downloading $LMS_TARBALL_URL"
    curl -fL --retry 3 -o "$tgz.part" "$LMS_TARBALL_URL"   # curl honours $HTTPS_PROXY
    mv "$tgz.part" "$tgz"
  fi
  if [[ -n "${LMS_TARBALL_MD5:-}" ]]; then
    echo "$LMS_TARBALL_MD5  $tgz" | md5sum -c --quiet - || { rm -f "$tgz"; die "md5 mismatch for $tgz (deleted, re-run)"; }
  fi
  log "extracting to $lms_dir"
  tar xzf "$tgz" -C "$LMS_BASE" --no-same-owner
  [[ -f "$lms_dir/slimserver.pl" ]] || die "unexpected tarball layout (no $lms_dir/slimserver.pl)"
else
  log "LMS $LMS_VERSION already installed at $lms_dir"
fi
ln -sfn "$lms_dir" "$LMS_HOME"
mkdir -p "$LMS_PREFS" "$LMS_CACHE" "$LMS_RUN" "$LMS_PLUGIN_DIR" "$LOG_DIR"
perl -MIO::Socket::SSL -MNet::SSLeay -e1 || die "perl SSL modules not loadable"
write_proxychains_conf

# --- headless browser helper deps ---
if [[ -f "$DEV_DIR/browser/package.json" && ! -d "$DEV_DIR/browser/node_modules/playwright" ]]; then
  log "npm install in dev/browser"
  (cd "$DEV_DIR/browser" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund >/dev/null)
fi

log "setup complete: LMS $LMS_VERSION at $LMS_HOME (prefs $LMS_PREFS, cache $LMS_CACHE, logs $LOG_DIR)"
log "next: dev/start.sh   then optionally dev/link-plugin.sh --restart"
