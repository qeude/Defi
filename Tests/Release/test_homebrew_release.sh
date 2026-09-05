#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -f "$TEST_DIR/checksum"; rmdir "$TEST_DIR"' EXIT
CHECKSUM="$(printf '%064d' 1)"
printf '%s  Defi-v0.2.2.zip\n' "$CHECKSUM" > "$TEST_DIR/checksum"

# No GitHub writes: exercise the script through a fake CLI boundary.
gh() {
  case "$*" in
    'api repos/qeude/homebrew-tap/git/ref/heads/'*) printf 'base-sha\n' ;;
    'api repos/qeude/homebrew-tap/contents/'*)
      local fixture
      fixture=$'cask "defi" do\n  version "0.2.1"\n  sha256 "old"\n  # preserve this\nend\n'
      if [[ "${BAD_FORMAT:-0}" == 1 ]]; then fixture='unexpected format'; fi
      jq -n --arg content "$(printf '%s' "$fixture" | base64)" '{sha:"file-sha", content:$content}'
      ;;
    'api --method PUT '*)
      local argument content=''
      for argument in "$@"; do
        if [[ "$argument" == content=* ]]; then content="${argument#content=}"; fi
      done
      local updated
      updated="$(printf '%s' "$content" | base64 --decode)"
      [[ "$updated" == *'version "0.2.2"'* &&
         "$updated" == *"sha256 \"$CHECKSUM\""* &&
         "$updated" == *'# preserve this'* ]] || return 1
      ;;
    'pr list '*) printf '0\n' ;;
    'pr create '*) printf 'PR created\n' ;;
    *) echo "Unexpected gh invocation: $*" >&2; return 1 ;;
  esac
}
export -f gh
export CHECKSUM

result="$(GH_TOKEN=test bash "$ROOT/script/update_homebrew_release.sh" 0.2.2 "$TEST_DIR/checksum")"
[[ "$result" == 'PR created' ]] || exit 1
if BAD_FORMAT=1 GH_TOKEN=test bash "$ROOT/script/update_homebrew_release.sh" 0.2.2 "$TEST_DIR/checksum" 2>/dev/null; then
  echo 'Accepted an unexpected Cask format' >&2; exit 1
fi
for version in '0.2.2-alpha' '../main' '0.2.3'; do
  if GH_TOKEN=test bash "$ROOT/script/update_homebrew_release.sh" "$version" "$TEST_DIR/checksum"; then
    echo 'Accepted an invalid version or mismatched checksum filename' >&2; exit 1
  fi
done
echo 'Homebrew release checks passed'
