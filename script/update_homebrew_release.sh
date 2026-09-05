#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: update_homebrew_release.sh VERSION CHECKSUM_FILE}"
CHECKSUM_FILE="${2:?missing checksum file}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
SHA256="$(cut -d ' ' -f 1 "$CHECKSUM_FILE")"
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 1
[[ "$(< "$CHECKSUM_FILE")" == "$SHA256  Defi-v$VERSION.zip" ]] || exit 1
: "${GH_TOKEN:?Set HOMEBREW_TAP_TOKEN with contents and pull-requests write access to qeude/homebrew-tap}"

REPO=qeude/homebrew-tap
BRANCH="release/defi-$VERSION"
BASE_SHA="$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)"
if ! gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$BASE_SHA" >/dev/null
else
  # Preserve existing edits on retry; conflicts require maintainer resolution.
  gh api "repos/$REPO/merges" -f base="$BRANCH" -f head="$BASE_SHA" >/dev/null
fi
FILE_JSON="$(gh api "repos/$REPO/contents/Casks/defi.rb?ref=$BRANCH")"
FILE_SHA="$(printf '%s' "$FILE_JSON" | jq -r .sha)"
CONTENT="$(printf '%s' "$FILE_JSON" | jq -r .content | base64 --decode \
  | ruby -e '
    text = STDIN.read
    abort "Unexpected Cask format" unless text.scan(/^  version ".*"$/).size == 1 && text.scan(/^  sha256 ".*"$/).size == 1
    text.sub!(/^  version ".*"$/, "  version \"#{ARGV[0]}\"")
    text.sub!(/^  sha256 ".*"$/, "  sha256 \"#{ARGV[1]}\"")
    print text
  ' "$VERSION" "$SHA256" | base64 | tr -d '\n')"
gh api --method PUT "repos/$REPO/contents/Casks/defi.rb" \
  -f message="chore: update Defi to $VERSION" -f branch="$BRANCH" \
  -f sha="$FILE_SHA" -f content="$CONTENT" >/dev/null
if [[ "$(gh pr list --repo "$REPO" --head "$BRANCH" --json number --jq length)" == 0 ]]; then
  gh pr create --repo "$REPO" --base main --head "$BRANCH" \
    --title "chore: update Defi to $VERSION" \
    --body "Update to https://github.com/qeude/Defi/releases/tag/v$VERSION. SHA-256: $SHA256."
fi
