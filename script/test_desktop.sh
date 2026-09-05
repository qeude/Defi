#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED_CLI="$HOME/Applications/Defi.app/Contents/MacOS/defi"
RUNTIME_WAS_RUNNING=0

restore_runtime() {
  if [[ "$RUNTIME_WAS_RUNNING" -eq 1 ]]; then
    "$INSTALLED_CLI" service start >/dev/null
  fi
}
trap restore_runtime EXIT

if [[ -x "$INSTALLED_CLI" ]] \
  && "$INSTALLED_CLI" status >/dev/null 2>&1
then
  RUNTIME_WAS_RUNNING=1
  "$INSTALLED_CLI" service stop >/dev/null
  sleep 0.5
fi

cd "$ROOT_DIR"
DEFI_E2E=1 swift test --filter DesktopE2ETests
