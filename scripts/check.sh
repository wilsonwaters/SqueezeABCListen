#!/usr/bin/env bash
# check.sh - the project's single quality gate, run locally and in CI.
#   1. compile check of every ABCListen/**/*.pm (against the t/lib Slim:: stubs)
#   2. unit tests: prove -lr -It/lib t
#   3. xmllint --noout ABCListen/install.xml (and repo.xml when it exists)
#   4. strings lint (scripts/lint-strings.pl)
#   5. shellcheck scripts/*.sh (skipped with a notice when shellcheck is missing, except in CI)
# Runs every step, prints a summary and exits non-zero if any step failed.
# Needs perl with URI::Escape (Debian/Ubuntu: liburi-perl), prove and xmllint (libxml2-utils).
# Locally, the shellcheck step is optional.
# Other LMS-bundled modules are shimmed in t/lib; HTML::Entities (libhtml-parser-perl) is
# optional: without it the tests only exercise the built-in entity decoder.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

failed=()
step() { printf '\n==> %s\n' "$*"; }
fail() { failed+=("$1"); printf 'FAILED: %s\n' "$1"; }

step "Compile check (ABCListen/**/*.pm)"
count=0
while IFS= read -r -d '' pm; do
  count=$((count + 1))
  if out="$(perl -It/lib -MABCListenTest -wc "$pm" 2>&1)" && [[ "$out" == "$pm syntax OK" ]]; then
    echo "ok   $pm"
  else
    echo "$out"
    fail "compile: $pm"
  fi
done < <(find ABCListen -name '*.pm' -print0 | sort -z)
[[ $count -gt 0 ]] || fail "compile: no modules found"

step "Unit tests (prove -lr -It/lib t)"
prove -lr -It/lib t || fail "unit tests"

step "XML validation"
if ! command -v xmllint >/dev/null; then
  fail "xmllint not installed (apt-get install libxml2-utils)"
else
  for xml in ABCListen/install.xml repo.xml; do
    [[ -e "$xml" ]] || continue
    if xmllint --noout "$xml"; then echo "ok   $xml"; else fail "xmllint: $xml"; fi
  done
fi

step "Strings lint"
perl scripts/lint-strings.pl || fail "strings lint"

step "shellcheck scripts/*.sh"
if command -v shellcheck >/dev/null; then
  if shellcheck scripts/*.sh; then echo "ok   shellcheck: $(echo scripts/*.sh)"; else fail "shellcheck"; fi
elif [[ -n "${CI:-}" ]]; then
  fail "shellcheck not installed (CI must run it: apt-get install shellcheck)"
else
  echo "NOTICE: shellcheck not installed, skipped (apt-get install shellcheck); CI runs it"
fi

echo
if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'check.sh: %d step(s) FAILED:\n' "${#failed[@]}"
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi
echo "check.sh: all checks passed"
