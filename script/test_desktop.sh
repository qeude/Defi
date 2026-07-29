#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED_CLI="$HOME/Applications/Defi.app/Contents/MacOS/defi"
SERVICE_LABEL="com.quentin.defi"
SERVICE_DOMAIN="gui/$(id -u)"
SERVICE_WAS_LOADED=0

restore_service() {
  if [[ "$SERVICE_WAS_LOADED" -eq 1 ]]; then
    "$INSTALLED_CLI" service start >/dev/null
  fi
}
trap restore_service EXIT

if [[ -x "$INSTALLED_CLI" ]] \
  && /bin/launchctl print "$SERVICE_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1
then
  SERVICE_WAS_LOADED=1
  "$INSTALLED_CLI" service stop >/dev/null
  sleep 0.5
fi

cd "$ROOT_DIR"
DEFI_E2E=1 swift test --filter DesktopE2ETests
