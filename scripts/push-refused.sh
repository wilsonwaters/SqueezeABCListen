#!/usr/bin/env bash
# push-refused.sh - tells a refused git push from one rejected only because the branch moved. The
# release tooling retries a rejected push on the new tip, but never a refused one, which no retry
# can fix. scripts/publish-release-asset.sh (release-assets) and the "Commit and push repo.xml"
# step of .github/workflows/release.yml (main) both ask this script, so they always agree.
#
# Usage: scripts/push-refused.sh <<<"$output"
#   reads the output (stdout and stderr) of the git push that failed on stdin
#
# Exit 0, refused, when a line has, in any case:
#   - an HTTP 403 status: "The requested URL returned error: 403", "HTTP 403", "HTTP/2 403"
#     (GITHUB_TOKEN is read-only, or has no write access);
#   - "Permission to OWNER/REPO.git denied to USER", or "Permission denied";
#   - "refusing to allow a GitHub App to create or update workflow ..." (the push changes a
#     workflow file and the token has no workflows permission);
#   - "GH006: Protected branch update failed" or "(protected branch hook declined)" (branch
#     protection), or "GH013: Repository rule violations found" (rulesets).
# Exit 1 otherwise: not a refusal, so the push is retried. In particular a "403" anywhere else,
# such as inside a commit SHA, a path or a port number, is not a refusal (#75).
# Exit 2: usage error. Needs grep.
set -euo pipefail

if [[ $# -ne 0 ]]; then
  sed -n '7,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

patterns=(
  'returned error: 403([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])http(/[0-9.]+)? 403([^[:alnum:]]|$)'
  'permission (to .* )?denied'
  'refusing to allow .* to create or update workflow'
  '(^|[^[:alnum:]])gh006:|protected branch'
  '(^|[^[:alnum:]])gh013:|repository rule violation'
)
args=()
for pattern in "${patterns[@]}"; do args+=(-e "$pattern"); done

# read all of it first, so that a writer piping into this script never gets SIGPIPE
output="$(cat)"
grep -Eiq "${args[@]}" <<<"$output"
