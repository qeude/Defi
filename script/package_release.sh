#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Defi"
IDENTITY="Defi Release"
INFO_PLIST="$ROOT_DIR/Support/Defi-Info.plist"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
ZIP_NAME="$APP_NAME-v$VERSION.zip"
ZIP_PATH="$ROOT_DIR/dist/$ZIP_NAME"
CHECKSUM_PATH="$ZIP_PATH.sha256"

security find-identity -p codesigning -v \
  | grep -F "\"$IDENTITY\"" >/dev/null \
  || {
    echo "Missing signing identity: $IDENTITY" >&2
    echo "Run ./script/setup_release_certificate.sh first." >&2
    exit 1
  }

DEFI_BUILD_ARCH=arm64 \
DEFI_CODESIGN_IDENTITY="$IDENTITY" \
  "$ROOT_DIR/script/build_and_run.sh" --stage

[[ "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/defi-daemon")" == "arm64" ]]
[[ "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/defi")" == "arm64" ]]
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dvv "$APP_BUNDLE" 2>&1 \
  | grep -F "Authority=$IDENTITY" >/dev/null

if find "$APP_BUNDLE" -type f \( \
  -name '*.p12' -o -name '*.pem' -o -name '*.key' \
  -o -name '*.mobileprovision' -o -name '.env*' \
\) -print -quit | grep -q .; then
  echo "Release bundle contains a private or provisioning file" >&2
  exit 1
fi

if strings "$APP_BUNDLE/Contents/MacOS/defi-daemon" \
    "$APP_BUNDLE/Contents/MacOS/defi" \
  | grep -Ei '/Users/|[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' \
    >/dev/null; then
  echo "Release binaries contain a personal path or email address" >&2
  exit 1
fi

unlink "$ZIP_PATH" >/dev/null 2>&1 || true
unlink "$CHECKSUM_PATH" >/dev/null 2>&1 || true
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
(
  cd "$ROOT_DIR/dist"
  /usr/bin/shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
)
/usr/bin/unzip -tq "$ZIP_PATH"

echo "Created $ZIP_PATH"
echo "Created $CHECKSUM_PATH"
