#!/usr/bin/env bash
# check-package.sh - check the plugin zip layout and repo.xml. Called by scripts/check.sh, so it
# runs locally and in CI.
#
# Usage: scripts/check-package.sh [--zip FILE]
#   (none)      build with scripts/build.sh into a temporary directory and check that zip
#   --zip FILE  check FILE (named ABCListen-X.Y.Z.zip), plus FILE.sha1 when it exists
#
# Zip rules: install.xml and Plugin.pm at the root; no entry under ABCListen/, Plugins/, t/, dev/,
# ai-state/, scripts/, docs/, .github/ or .git*; no .DS_Store or __MACOSX; at most 5 MB; the .sha1
# matches; the version in the zip's install.xml equals the one in the file name.
# Repository rules: repo.xml is well-formed, has name="ABCListen", and its minTarget/maxTarget
# equal ABCListen/install.xml's targetApplication minVersion/maxVersion. repo.xml's version and
# sha may lag the zip (they are only updated by the release workflow), so they are not compared.
# Without a repo.xml the repository rules are skipped with a note.
# Prints one line per check and exits 1 if any failed. Needs zip, unzip, sha1sum and xmllint.
set -uo pipefail

MAX_BYTES=$((5 * 1024 * 1024))
zip=""
tmp=""

usage() {
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip) [[ $# -ge 2 ]] || usage; zip="$2"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "check-package.sh: unknown argument: $1" >&2; usage ;;
  esac
done

# --zip is relative to the caller's directory; everything else to the repository root
[[ -z "$zip" || "$zip" == /* ]] || zip="$PWD/$zip"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }
indent() { local l; while IFS= read -r l; do echo "       $l"; done; }

for tool in zip unzip sha1sum xmllint; do
  command -v "$tool" >/dev/null || { echo "check-package.sh: '$tool' is not installed" >&2; exit 1; }
done

cleanup() { [[ -n "$tmp" ]] && rm -rf "$tmp"; }
trap cleanup EXIT

if [[ -z "$zip" ]]; then
  tmp="$(mktemp -d)"
  scripts/build.sh --out "$tmp" >/dev/null || { echo "check-package.sh: scripts/build.sh failed" >&2; exit 1; }
  shopt -s nullglob
  built=("$tmp"/ABCListen-*.zip)
  shopt -u nullglob
  [[ ${#built[@]} -eq 1 ]] || { echo "check-package.sh: expected one zip from build.sh, got ${#built[@]}" >&2; exit 1; }
  zip="${built[0]}"
fi

[[ -f "$zip" ]] || { echo "check-package.sh: $zip not found" >&2; exit 1; }
name="$(basename "$zip")"
echo "Checking $name"

# ---- zip contents ----
if ! entries="$(unzip -Z1 "$zip" 2>&1)"; then
  bad "unreadable zip: $entries"
  entries=""
fi

for required in install.xml Plugin.pm; do
  if grep -qxF "$required" <<<"$entries"; then ok "$required at the zip root"; else bad "$required is not at the zip root"; fi
done

forbidden="$(grep -E '^(ABCListen/|Plugins/|t/|dev/|ai-state/|scripts/|docs/|\.github/|\.git)' <<<"$entries")"
if [[ -z "$forbidden" ]]; then
  ok "no ABCListen/, Plugins/, t/, dev/, ai-state/, scripts/, docs/, .github/ or .git entries"
else
  bad "entries with a forbidden prefix (ABCListen/, Plugins/, t/, dev/, ai-state/, scripts/, docs/, .github/, .git):"
  indent <<<"$forbidden"
fi

junk="$(grep -E '(^|/)(\.DS_Store|__MACOSX)(/|$)' <<<"$entries")"
if [[ -z "$junk" ]]; then
  ok "no .DS_Store or __MACOSX entries"
else
  bad ".DS_Store or __MACOSX entries:"
  indent <<<"$junk"
fi

bytes="$(wc -c <"$zip" | tr -d ' ')"
if ((bytes <= MAX_BYTES)); then ok "size $bytes bytes (limit $MAX_BYTES)"; else bad "size $bytes bytes is over the $MAX_BYTES byte limit"; fi

# ---- .sha1 sibling ----
if [[ -f "$zip.sha1" ]]; then
  actual="$(sha1sum "$zip" | cut -d' ' -f1)"
  expected_line="$actual  $name"
  line="$(head -n 1 "$zip.sha1")"
  if [[ "$line" == "$expected_line" ]]; then
    ok "$name.sha1 matches ($actual)"
  else
    bad "$name.sha1 does not match: has '$line', expected '$expected_line'"
  fi
else
  echo "note $name.sha1 not found, sha1 not checked"
fi

# ---- version: file name vs install.xml inside the zip ----
if [[ "$name" =~ ^ABCListen-([0-9]+\.[0-9]+\.[0-9]+)\.zip$ ]]; then
  file_version="${BASH_REMATCH[1]}"
  zip_version="$(unzip -p "$zip" install.xml 2>/dev/null | sed -n 's|.*<version>\(.*\)</version>.*|\1|p' | head -n 1)"
  if [[ "$zip_version" == "$file_version" ]]; then
    ok "version $zip_version in install.xml matches the file name"
  else
    bad "version mismatch: file name says $file_version, install.xml in the zip says '${zip_version}'"
  fi
else
  bad "file name $name is not ABCListen-X.Y.Z.zip"
fi

# ---- repo.xml ----
if [[ ! -f repo.xml ]]; then
  echo "note repo.xml not found, repository checks skipped"
else
  if xmllint --noout repo.xml; then ok "repo.xml is well-formed"; else bad "xmllint repo.xml"; fi

  xpath() { xmllint --xpath "$1" "$2" 2>/dev/null; }
  entries_named="$(xpath 'count(/extensions/plugins/plugin[@name="ABCListen"])' repo.xml)"
  if [[ "$entries_named" == 1 ]]; then
    ok "repo.xml has one plugin entry named ABCListen"
  else
    bad "repo.xml has ${entries_named:-0} plugin entries named ABCListen, expected 1"
  fi

  for pair in minTarget:minVersion maxTarget:maxVersion; do
    repo_attr="${pair%%:*}"
    manifest_el="${pair##*:}"
    repo_value="$(xpath "string(/extensions/plugins/plugin[@name=\"ABCListen\"]/@$repo_attr)" repo.xml)"
    manifest_value="$(xpath "normalize-space(/extension/targetApplication/$manifest_el)" ABCListen/install.xml)"
    if [[ -n "$repo_value" && "$repo_value" == "$manifest_value" ]]; then
      ok "repo.xml $repo_attr ($repo_value) equals install.xml $manifest_el"
    else
      bad "repo.xml $repo_attr '$repo_value' differs from install.xml $manifest_el '$manifest_value'"
    fi
  done
fi

if ((failures > 0)); then
  echo "check-package.sh: $failures check(s) FAILED"
  exit 1
fi
echo "check-package.sh: all package checks passed"
