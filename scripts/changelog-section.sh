#!/usr/bin/env bash
# changelog-section.sh - print the body of one version's section of CHANGELOG.md, e.g. for the
# release notes of that version.
#
# Usage: scripts/changelog-section.sh VERSION [FILE]
#   VERSION  e.g. 0.1.0, as written between the brackets of its heading
#   FILE     the changelog (default: CHANGELOG.md at the repository root)
#
# The section starts after the heading "## [VERSION]" (with or without " - YYYY-MM-DD" after it)
# and ends before the next "## " heading or the first link reference definition ("[x]: url")
# at the bottom of the file. The version is compared as a plain string, so its dots match only
# dots. Leading and trailing blank lines are left out.
# Exit codes: 0 the body was printed; 1 no such section, or it is empty (nothing is printed);
# 2 usage error or unreadable file. Needs awk.
set -uo pipefail

usage() {
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 && -n "$1" ]] || usage
case "$1" in -h | --help) usage ;; esac

version="$1"
file="${2:-$(dirname "${BASH_SOURCE[0]}")/../CHANGELOG.md}"
[[ -r "$file" ]] || { echo "changelog-section.sh: can't read $file" >&2; exit 2; }

awk -v version="$version" '
  # "## [<v>]" optionally followed by " - <date>" or other text: sets heading to <v>
  function heading_version(line,    rest) {
    if (line !~ /^## \[/) return ""
    rest = substr(line, 5)
    return substr(rest, 1, index(rest, "]") - 1)
  }
  /^## / {
    if (found) exit
    if (heading_version($0) == version) found = 1
    next
  }
  found && /^\[[^]]+\]: / { exit }
  found {
    lines[++n] = $0
    if ($0 ~ /[^[:space:]]/) { if (!first) first = n; last = n }
  }
  END {
    if (!first) exit 1
    for (i = first; i <= last; i++) print lines[i]
  }
' "$file"
