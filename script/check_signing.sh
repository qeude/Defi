#!/usr/bin/env bash
# Read-only TCC identity check. Run before stopping or replacing an installed app.
set -euo pipefail
[[ "$#" -eq 2 ]] || { echo "usage: $0 INSTALLED_BUNDLE STAGED_BUNDLE" >&2; exit 2; }
CERTIFICATE_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/defi-signature-check.XXXXXX")"
trap 'rm -rf -- "$CERTIFICATE_DIRECTORY"' EXIT
codesign --verify --deep --strict "$1"
codesign --verify --deep --strict "$2"
codesign -d --extract-certificates="$CERTIFICATE_DIRECTORY/installed-" "$1"
codesign -d --extract-certificates="$CERTIFICATE_DIRECTORY/staged-" "$2"
if [[ ! -f "$CERTIFICATE_DIRECTORY/installed-0" || ! -f "$CERTIFICATE_DIRECTORY/staged-0" ]] \
  || ! cmp -s "$CERTIFICATE_DIRECTORY/installed-0" "$CERTIFICATE_DIRECTORY/staged-0"; then
  echo "Signing certificate changed or missing; refusing to replace the installed app" >&2
  exit 1
fi
INSTALLED_REQUIREMENT="$(codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p')"
STAGED_REQUIREMENT="$(codesign -dr - "$2" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$INSTALLED_REQUIREMENT" || "$INSTALLED_REQUIREMENT" != "$STAGED_REQUIREMENT" ]]; then
  echo "Signing requirement changed; refusing to replace the installed app" >&2
  exit 1
fi
