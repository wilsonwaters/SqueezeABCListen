#!/usr/bin/env bash
# publish-release-asset.sh - add a release zip to the release-assets branch. LMS downloads the
# plugin from there (raw.githubusercontent.com/<owner>/<repo>/release-assets/<zip>, repo.xml's
# <url>), because LMS 9.1.1 can't read the redirect GitHub sends for release asset downloads.
#
# Usage: scripts/publish-release-asset.sh [--branch NAME] [--remote NAME] [--dry-run] ZIP
#   ZIP        the zip to publish, named ABCListen-X.Y.Z.zip; stored under that name at the
#              branch root
#   --branch   the branch (default: release-assets)
#   --remote   the remote to fetch from and push to (default: origin)
#   --dry-run  make the commit locally and show it, but don't push
#
# The branch holds only the zips and a README. The first publish creates it as an orphan branch,
# with no history in common with main. A zip that is already there with the same content is left
# alone (exit 0, nothing pushed); one with different content is never replaced (exit 1). Commits
# are made with git commit-tree, so the working tree and index are not touched. Author and
# committer are the configured git identity (user.name/user.email); the message is
# "Add ABCListen-X.Y.Z.zip". A rejected push (the branch moved) is retried on the new tip up to 3
# times. A refusal (an HTTP 403, "Permission to ... denied", GH006 protected branch, GH013
# rulesets) is not; scripts/push-refused.sh, next to this script, tells the two apart.
# Exit codes: 0 published or already there, 1 failure, 2 usage error. Needs git.
set -euo pipefail

branch=release-assets
remote=origin
dry_run=0
zip=""

usage() {
  sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die() { echo "publish-release-asset.sh: $*" >&2; exit 1; }
say() { echo "publish-release-asset.sh: $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 ]] || usage; branch="$2"; shift 2 ;;
    --remote) [[ $# -ge 2 ]] || usage; remote="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage ;;
    -*) echo "publish-release-asset.sh: unknown option: $1" >&2; usage ;;
    *) [[ -z "$zip" ]] || usage; zip="$1"; shift ;;
  esac
done
[[ -n "$zip" ]] || usage
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "'$branch' is not a valid branch name"

name="$(basename "$zip")"
[[ "$name" =~ ^ABCListen-[0-9]+\.[0-9]+\.[0-9]+\.zip$ ]] || die "$name is not named ABCListen-X.Y.Z.zip"
[[ -f "$zip" ]] || die "$zip not found"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
# the rule for a refused push, shared with the repo.xml push of the Release workflow
push_refused="$(dirname "${BASH_SOURCE[0]}")/push-refused.sh"
[[ -x "$push_refused" ]] || die "$push_refused not found; it tells a refused push from a rejected one"

blob="$(git hash-object -w -- "$zip")"
remote_ref="refs/remotes/$remote/$branch"

readme() {
  cat <<EOF
# $branch

This branch holds the plugin zips that \`repo.xml\` on \`main\` points LMS at, served by
raw.githubusercontent.com from this branch (\`ABCListen-X.Y.Z.zip\`). The Release workflow
(\`.github/workflows/release.yml\` on \`main\`) adds one zip per release: the same file that is
attached to the GitHub Release of that version, whose SHA1 is the \`<sha>\` in \`repo.xml\`.

- **Don't merge this branch** into \`main\` or anything else, and don't merge anything into it.
  It shares no history with \`main\`.
- **Never change or delete a zip here.** LMS installs from these URLs and checks each file's SHA1.
- Why not the GitHub Release download URL: LMS 9.1.1 can't read the redirect GitHub sends for
  it (a header line longer than 8,192 characters).

See \`RELEASING.md\` on \`main\`.
EOF
}

# the commit of the branch on the remote, fetched; empty when the branch doesn't exist yet
fetch_tip() {
  local rc=0
  git ls-remote --exit-code "$remote" "refs/heads/$branch" >/dev/null || rc=$?
  if [[ $rc -eq 2 ]]; then
    return 0
  elif [[ $rc -ne 0 ]]; then
    die "could not list the branches of $remote (git ls-remote exit $rc)"
  fi
  git fetch -q --no-tags "$remote" "+refs/heads/$branch:$remote_ref" || die "could not fetch $branch from $remote"
  git rev-parse --verify -q "$remote_ref^{commit}" || die "could not read $remote_ref"
}

# sets $commit to $tip plus the zip, or to a new orphan commit (README and zip) when $tip is
# empty; leaves it empty when the identical zip is already on $tip. Not called as an if/&&/||
# condition, so that set -e stops the script when a git command fails.
make_commit() {
  local tip="$1" existing readme_blob tree
  commit=""
  if [[ -z "$tip" ]]; then
    readme_blob="$(readme | git hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\t%s\n100644 blob %s\t%s\n' "$readme_blob" README.md "$blob" "$name" | git mktree)"
    commit="$(git commit-tree "$tree" -m "Add $name" -m "Starts the $branch branch: release zips that repo.xml points LMS at. Never merge it.")"
    return 0
  fi
  existing="$(git ls-tree "$tip" -- "$name")"
  if [[ -n "$existing" ]]; then
    [[ "$existing" == "100644 blob $blob"$'\t'"$name" ]] ||
      die "$branch already has a different $name ($existing); a published zip is never replaced"
    return 0
  fi
  tree="$({ git ls-tree "$tip"; printf '100644 blob %s\t%s\n' "$blob" "$name"; } | git mktree)"
  commit="$(git commit-tree "$tree" -p "$tip" -m "Add $name")"
}

show() {
  git --no-pager log -1 --format='commit %H%nAuthor:    %an <%ae>%nCommitter: %cn <%ce>%nParents:   %P%n%n    %s%n' "$1"
  git --no-pager ls-tree -l "$1"
}

for attempt in 1 2 3 4; do
  tip="$(fetch_tip)"
  make_commit "$tip"
  if [[ -z "$commit" ]]; then
    say "$name is already on $branch (commit $tip) with the same content; nothing to publish"
    exit 0
  fi
  if [[ -z "$tip" ]]; then
    say "$branch does not exist on $remote yet; creating it as an orphan branch"
  fi
  show "$commit"
  if [[ $dry_run -eq 1 ]]; then
    say "dry run: $name not pushed to $branch"
    exit 0
  fi
  if out="$(git push "$remote" "$commit:refs/heads/$branch" 2>&1)"; then
    echo "$out"
    say "published $name to $branch on $remote (commit $commit)"
    exit 0
  fi
  echo "$out"
  if "$push_refused" <<<"$out"; then
    die "push to $branch refused. GITHUB_TOKEN needs contents: write, and branch protection and rulesets must let GitHub Actions create and push $branch (RELEASING.md, Prerequisites)"
  fi
  [[ $attempt -eq 4 ]] && break
  say "push rejected ($branch moved?); retrying on its new tip, retry $attempt of 3"
  sleep $((attempt * 2))
done
die "could not push $name to $branch after 3 retries"
