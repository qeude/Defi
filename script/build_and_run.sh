#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--stage|stage|--install-staged) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--stage|--install-staged BUNDLE [--verify]]" >&2; exit 2 ;;
esac
APP_NAME="Defi"
PROCESS_NAME="defi-daemon"
BUNDLE_ID="com.quentin.defi"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_ROOT="${DEFI_STAGING_ROOT:-$ROOT_DIR/dist}"
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

if [[ "$MODE" == "--install-staged" ]]; then
  [[ -d "${2:-}" ]] || { echo "A staged app bundle is required" >&2; exit 2; }
  STAGING_BUNDLE="$(cd "$2" && pwd)"
  [[ "$STAGING_BUNDLE" != "$INSTALL_BUNDLE" ]] || { echo "Stage outside the installed bundle" >&2; exit 2; }
  MODE="${3:-run}"
  case "$MODE" in
    run|--verify|verify|--debug|debug|--logs|logs|--telemetry|telemetry) ;;
    *) echo "Invalid installation mode: $MODE" >&2; exit 2 ;;
  esac
  if ! python3 "$ROOT_DIR/script/desktop_lock.py" --check; then
    exec python3 "$ROOT_DIR/script/desktop_lock.py" "$0" --install-staged "$STAGING_BUNDLE" "$MODE"
  fi
else
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

# Preparation never occupies the desktop. Install exactly this signed bundle.
exec python3 "$ROOT_DIR/script/desktop_lock.py" "$0" --install-staged "$STAGING_BUNDLE" "$MODE"
fi

codesign --verify --deep --strict --verbose=2 "$STAGING_BUNDLE"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$STAGING_BUNDLE/Contents/Info.plist")" == "$BUNDLE_ID" ]] \
  || { echo "Unexpected staged bundle identifier" >&2; exit 1; }
if [[ -d "$INSTALL_BUNDLE" ]]; then
  "$ROOT_DIR/script/check_signing.sh" "$INSTALL_BUNDLE" "$STAGING_BUNDLE"
fi

# Prepare a complete replacement before stopping the current app.
mkdir -p "$INSTALL_ROOT"
INSTALL_TRANSACTION="$(mktemp -d "$INSTALL_ROOT/.Defi-install.XXXXXX")"
REPLACEMENT_STARTED=0
INSTALL_COMMITTED=0
RUNTIME_WAS_RUNNING=0
pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null && RUNTIME_WAS_RUNNING=1
finish_install() {
  local result=$?
  trap - EXIT INT TERM
  if [[ "$INSTALL_COMMITTED" -eq 0 ]] && { [[ "$REPLACEMENT_STARTED" -eq 1 ]] || [[ -d "$INSTALL_TRANSACTION/previous.app" ]]; }; then
    echo "Installation failed; restoring the previous bundle" >&2
    "$INSTALLED_CLI" service stop >/dev/null 2>&1 || true
    for _ in {1..100}; do
      pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null || break
      sleep 0.1
    done
    if pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null; then
      echo "Daemon still running; recovery bundle retained at $INSTALL_TRANSACTION" >&2
      exit 1
    fi
    rm -rf "$INSTALL_BUNDLE"
    if [[ -d "$INSTALL_TRANSACTION/previous.app" ]]; then
      mv "$INSTALL_TRANSACTION/previous.app" "$INSTALL_BUNDLE" || exit 1
    fi
  fi
  if [[ "$INSTALL_COMMITTED" -eq 0 && "$RUNTIME_WAS_RUNNING" -eq 1 ]]; then
    "$INSTALLED_CLI" service start >/dev/null && wait_for_runtime || result=1
  fi
  rm -rf "$INSTALL_TRANSACTION"
  exit "$result"
}
wait_for_runtime() {
  for _ in {1..100}; do
    if "$INSTALLED_CLI" status >/dev/null 2>&1; then
      [[ "$(pgrep -u "$(id -u)" -x "$PROCESS_NAME" | wc -l | tr -d ' ')" -eq 1 ]] && return 0
    fi
    sleep 0.1
  done
  echo "Expected one IPC-ready $PROCESS_NAME" >&2
  return 1
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$STAGING_BUNDLE" "$INSTALL_TRANSACTION/candidate.app"
codesign --verify --deep --strict "$INSTALL_TRANSACTION/candidate.app"

LAUNCH_AT_LOGIN_WAS_ENABLED=0
if /bin/launchctl print "$SERVICE_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1; then
  LAUNCH_AT_LOGIN_WAS_ENABLED=1
  "$INSTALLED_CLI" service stop
  for _ in {1..50}; do
    pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null 2>&1; then
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
    pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
pkill -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null 2>&1 || true
for _ in {1..50}; do
  pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null 2>&1; then
  echo "$PROCESS_NAME is still running; refusing bundle replacement" >&2
  exit 1
fi
if [[ -e "$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist" ]]; then
  unlink "$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"
fi

if [[ -d "$INSTALL_BUNDLE" ]]; then
  mv "$INSTALL_BUNDLE" "$INSTALL_TRANSACTION/previous.app"
fi
REPLACEMENT_STARTED=1
mv "$INSTALL_TRANSACTION/candidate.app" "$INSTALL_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$INSTALL_BUNDLE"

start_runtime() {
  if [[ "$LAUNCH_AT_LOGIN_WAS_ENABLED" -eq 1 ]]; then
    "$INSTALLED_CLI" service enable
  fi
  "$INSTALLED_CLI" service start
  wait_for_runtime
  INSTALL_COMMITTED=1
}

case "$MODE" in
  run)
    start_runtime
    ;;
  --debug|debug)
    INSTALL_COMMITTED=1
    rm -rf "$INSTALL_TRANSACTION"
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
    rm -rf "$INSTALL_TRANSACTION"
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    start_runtime
    rm -rf "$INSTALL_TRANSACTION"
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --verify|verify)
    start_runtime
    for _ in {1..100}; do
      if pgrep -u "$(id -u)" -x "$PROCESS_NAME" >/dev/null 2>&1; then
        if STATUS_OUTPUT="$("$INSTALLED_CLI" status 2>/dev/null)" \
          && [[ -n "$STATUS_OUTPUT" ]]
        then
          DAEMON_COUNT="$(pgrep -u "$(id -u)" -x "$PROCESS_NAME" | wc -l | tr -d ' ')"
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
