#!/usr/bin/env bash
# build.sh - package the plugin as <out>/ABCListen-<version>.zip plus a sha1sum-format .sha1 file.
#
# Usage: scripts/build.sh [--src DIR] [--out DIR]
#   --src DIR  plugin directory containing install.xml (default: ABCListen)
#   --out DIR  output directory, created if missing (default: dist)
#
# The version comes from <version> in <src>/install.xml and must be X.Y.Z. The zip holds the
# *contents* of the plugin directory (install.xml at the zip root, no ABCListen/ prefix), which
# is the layout LMS's PluginDownloader expects. Junk files are left out and symlinks are stored
# as the files they point to. An existing zip of the same name is replaced, never updated in
# place. On success it prints two lines to stdout:
#   zip=<out>/ABCListen-<version>.zip
#   sha1=<40 hex digits>
# Needs zip and sha1sum.
set -euo pipefail

src=ABCListen
out=dist

usage() {
  sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die() { echo "build.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) [[ $# -ge 2 ]] || usage; src="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "build.sh: unknown argument: $1" >&2; usage ;;
  esac
done

for tool in zip sha1sum; do
  command -v "$tool" >/dev/null || die "'$tool' is not installed"
done

manifest="$src/install.xml"
[[ -f "$manifest" ]] || die "$manifest not found"

# First <version>...</version> in the manifest, taken verbatim (no trimming), so " 0.1.0",
# "v0.1.0", "0.1" and "1.0.0a" are all rejected below.
version="$(sed -n 's|.*<version>\(.*\)</version>.*|\1|p' "$manifest" | head -n 1)"
[[ -n "$version" ]] || die "no <version> element in $manifest"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "version '$version' in $manifest is not of the form X.Y.Z (digits only, no prefix or suffix)"

mkdir -p "$out"
out_abs="$(cd "$out" && pwd)"
name="ABCListen-$version.zip"

# zip updates existing archives in place, so start from scratch.
rm -f "$out_abs/$name" "$out_abs/$name.sha1"

# No -y: symlinks are followed and stored as regular files. -X leaves out uid/gid and extra
# timestamps.
(
  cd "$src"
  zip -q -r -X "$out_abs/$name" . \
    -x '.DS_Store' '*/.DS_Store' '__MACOSX' '__MACOSX/*' '*/__MACOSX' '*/__MACOSX/*' \
       '*~' '*.swp' '*.orig'
)

(cd "$out_abs" && sha1sum "$name" > "$name.sha1")
sha1="$(cut -d' ' -f1 "$out_abs/$name.sha1")"

echo "zip=${out%/}/$name"
echo "sha1=$sha1"
