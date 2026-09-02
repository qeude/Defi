#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Defi"
PROCESS_NAME="defi-daemon"
BUNDLE_ID="com.quentin.defi"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_ROOT="$ROOT_DIR/dist"
STAGING_BUNDLE="$STAGING_ROOT/$APP_NAME.app"
DMG_ROOT="$STAGING_ROOT/dmg-root"
INFO_PLIST_SOURCE="$ROOT_DIR/Support/Defi-Info.plist"
ICON_SOURCE="$ROOT_DIR/Support/Defi.icon"

cd "$ROOT_DIR"

swift build
BIN_DIR="$(swift build --show-bin-path)"
DEFI_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST_SOURCE")"
DMG_PATH="$STAGING_ROOT/$APP_NAME-$DEFI_VERSION.dmg"
APP_CONTENTS="$STAGING_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
ICON_INFO_PLIST="$STAGING_ROOT/assetcatalog-generated-info.plist"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
CLI_BINARY="$APP_MACOS/defi"

rm -rf "$STAGING_BUNDLE" "$DMG_ROOT" "$DMG_PATH"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$DMG_ROOT"

cp "$BIN_DIR/$PROCESS_NAME" "$APP_BINARY"
cp "$BIN_DIR/defi" "$CLI_BINARY"
cp "$INFO_PLIST_SOURCE" "$APP_CONTENTS/Info.plist"
chmod +x "$APP_BINARY" "$CLI_BINARY"

MINIMUM_SYSTEM_VERSION="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$INFO_PLIST_SOURCE")"
/usr/bin/xcrun actool "$ICON_SOURCE" \
  --compile "$APP_RESOURCES" \
  --output-format human-readable-text \
  --output-partial-info-plist "$ICON_INFO_PLIST" \
  --notices \
  --warnings \
  --app-icon "$APP_NAME" \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target "$MINIMUM_SYSTEM_VERSION" \
  --platform macosx
/usr/bin/plutil -insert CFBundleIconFile -string \
  "$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$ICON_INFO_PLIST")" \
  "$APP_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleIconName -string \
  "$(/usr/bin/plutil -extract CFBundleIconName raw -o - "$ICON_INFO_PLIST")" \
  "$APP_CONTENTS/Info.plist"

SIGNING_IDENTITY="$("$ROOT_DIR/script/resolve_signing_identity.sh")"

codesign --force \
  --options runtime \
  --timestamp=none \
  --identifier "$BUNDLE_ID.cli" \
  --sign "$SIGNING_IDENTITY" \
  "$CLI_BINARY"
codesign --force \
  --options runtime \
  --timestamp=none \
  --sign "$SIGNING_IDENTITY" \
  "$STAGING_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$STAGING_BUNDLE"

ditto "$STAGING_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
  -volname "$APP_NAME $DEFI_VERSION" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "Created $DMG_PATH"
