#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Defi"
PROCESS_NAME="defi-daemon"
BUNDLE_ID="com.quentin.defi"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_ROOT="$ROOT_DIR/dist"
STAGING_BUNDLE="$STAGING_ROOT/$APP_NAME.app"
INSTALL_ROOT="$HOME/Applications"
INSTALL_BUNDLE="$INSTALL_ROOT/$APP_NAME.app"
APP_CONTENTS="$STAGING_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
ICON_INFO_PLIST="$STAGING_ROOT/assetcatalog-generated-info.plist"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
CLI_BINARY="$APP_MACOS/defi"
INSTALLED_BINARY="$INSTALL_BUNDLE/Contents/MacOS/$PROCESS_NAME"
INSTALLED_CLI="$INSTALL_BUNDLE/Contents/MacOS/defi"
INFO_PLIST_SOURCE="$ROOT_DIR/Support/Defi-Info.plist"
ICON_SOURCE="$ROOT_DIR/Support/Defi.icon"
SERVICE_LABEL="com.quentin.defi"
SERVICE_DOMAIN="gui/$(id -u)"

cd "$ROOT_DIR"

BUILD_CONFIGURATION="release"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  BUILD_CONFIGURATION="debug"
fi
BUILD_ARGUMENTS=(-c "$BUILD_CONFIGURATION")
if [[ -n "${DEFI_BUILD_ARCH:-}" ]]; then
  BUILD_ARGUMENTS+=(--arch "$DEFI_BUILD_ARCH")
fi
swift build "${BUILD_ARGUMENTS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"

rm -rf "$STAGING_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
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

if [[ "$MODE" == "--stage" || "$MODE" == "stage" ]]; then
  echo "Staged $STAGING_BUNDLE"
  exit 0
fi

LAUNCH_AT_LOGIN_WAS_ENABLED=0
if /bin/launchctl print "$SERVICE_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1; then
  LAUNCH_AT_LOGIN_WAS_ENABLED=1
  "$INSTALLED_CLI" service stop
  for _ in {1..50}; do
    pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "$PROCESS_NAME did not stop before bundle replacement" >&2
    exit 1
  fi
fi
if [[ -x "$INSTALLED_CLI" ]]; then
  if "$INSTALLED_CLI" service status 2>/dev/null \
    | grep -q 'launch-at-login=enabled'
  then
    LAUNCH_AT_LOGIN_WAS_ENABLED=1
  fi
  "$INSTALLED_CLI" service stop >/dev/null 2>&1 || true
  "$INSTALLED_CLI" quit >/dev/null 2>&1 || true
  for _ in {1..50}; do
    pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
if [[ -e "$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist" ]]; then
  unlink "$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"
fi

mkdir -p "$INSTALL_ROOT"
rm -rf "$INSTALL_BUNDLE"
ditto "$STAGING_BUNDLE" "$INSTALL_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$INSTALL_BUNDLE"

start_runtime() {
  if [[ "$LAUNCH_AT_LOGIN_WAS_ENABLED" -eq 1 ]]; then
    "$INSTALLED_CLI" service enable
  fi
  "$INSTALLED_CLI" service start
}

case "$MODE" in
  run)
    start_runtime
    ;;
  --debug|debug)
    if [[ "$LAUNCH_AT_LOGIN_WAS_ENABLED" -eq 1 ]]; then
      set +e
      lldb -- "$INSTALLED_BINARY"
      DEBUG_STATUS=$?
      set -e
      "$INSTALLED_CLI" service start
      exit "$DEBUG_STATUS"
    fi
    exec lldb -- "$INSTALLED_BINARY"
    ;;
  --logs|logs)
    start_runtime
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    start_runtime
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --verify|verify)
    start_runtime
    for _ in {1..100}; do
      if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        if STATUS_OUTPUT="$("$INSTALLED_CLI" status 2>/dev/null)" \
          && [[ -n "$STATUS_OUTPUT" ]]
        then
          DAEMON_COUNT="$(pgrep -x "$PROCESS_NAME" | wc -l | tr -d ' ')"
          if [[ "$DAEMON_COUNT" -ne 1 ]]; then
            echo "expected exactly one $PROCESS_NAME, found $DAEMON_COUNT" >&2
            exit 1
          fi
          echo "$STATUS_OUTPUT"
          exit 0
        fi
      fi
      sleep 0.1
    done
    echo "$PROCESS_NAME did not become IPC-ready within 10 seconds" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--stage]" >&2
    exit 2
    ;;
esac
