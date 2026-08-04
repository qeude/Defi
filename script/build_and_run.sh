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
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
CLI_BINARY="$APP_MACOS/defi"
INSTALLED_BINARY="$INSTALL_BUNDLE/Contents/MacOS/$PROCESS_NAME"
INSTALLED_CLI="$INSTALL_BUNDLE/Contents/MacOS/defi"
INFO_PLIST_SOURCE="$ROOT_DIR/Support/Defi-Info.plist"
DEFAULT_CONFIG_SOURCE="$ROOT_DIR/defi.example.toml"
CONFIG_DIR="$HOME/.config/defi"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SERVICE_LABEL="com.quentin.defi"
SERVICE_DOMAIN="gui/$(id -u)"

cd "$ROOT_DIR"

swift build
BIN_DIR="$(swift build --show-bin-path)"

rm -rf "$STAGING_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BIN_DIR/$PROCESS_NAME" "$APP_BINARY"
cp "$BIN_DIR/defi" "$CLI_BINARY"
cp "$INFO_PLIST_SOURCE" "$APP_CONTENTS/Info.plist"
chmod +x "$APP_BINARY" "$CLI_BINARY"

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

SERVICE_WAS_LOADED=0
if /bin/launchctl print "$SERVICE_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1; then
  SERVICE_WAS_LOADED=1
  "$INSTALLED_CLI" service stop
  for _ in {1..50}; do
    pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "$PROCESS_NAME did not stop before bundle replacement" >&2
    exit 1
  fi
else
  if [[ -x "$INSTALLED_CLI" ]]; then
    "$INSTALLED_CLI" quit >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
  pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$INSTALL_ROOT"
rm -rf "$INSTALL_BUNDLE"
ditto "$STAGING_BUNDLE" "$INSTALL_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$INSTALL_BUNDLE"

if [[ ! -e "$CONFIG_FILE" ]]; then
  mkdir -p "$CONFIG_DIR"
  cp "$DEFAULT_CONFIG_SOURCE" "$CONFIG_FILE"
  echo "Installed default config: $CONFIG_FILE"
fi

open_app() {
  /usr/bin/open -n "$INSTALL_BUNDLE"
}

start_runtime() {
  if [[ "$SERVICE_WAS_LOADED" -eq 1 ]]; then
    "$INSTALLED_CLI" service start
    sleep 0.2
    if ! /bin/launchctl print "$SERVICE_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1; then
      "$INSTALLED_CLI" service start
    fi
  else
    open_app
  fi
}

case "$MODE" in
  run)
    start_runtime
    ;;
  --debug|debug)
    if [[ "$SERVICE_WAS_LOADED" -eq 1 ]]; then
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
      if [[ "$SERVICE_WAS_LOADED" -eq 1 ]] \
        && ! /bin/launchctl print "$SERVICE_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1
      then
        "$INSTALLED_CLI" service start >/dev/null
      fi
      if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        if STATUS_OUTPUT="$("$INSTALLED_CLI" status 2>/dev/null)" \
          && [[ -n "$STATUS_OUTPUT" ]]
        then
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
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
