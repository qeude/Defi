#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Build before stopping the app or reserving the desktop.
if [[ "${1:-}" != "--run-built-tests" ]]; then
  swift build --build-tests
  exec python3 "$ROOT_DIR/script/desktop_lock.py" "$0" --run-built-tests "$@"
fi
shift
if ! python3 "$ROOT_DIR/script/desktop_lock.py" --check; then
  echo "--run-built-tests requires a desktop reservation" >&2
  exit 2
fi
FILTER="${1:-DesktopE2ETests}"
[[ "$FILTER" == DesktopE2ETests* ]] || { echo "Filter must start with DesktopE2ETests" >&2; exit 2; }
INSTALLED_CLI="$HOME/Applications/Defi.app/Contents/MacOS/defi"
RUNTIME_WAS_RUNNING=0

restore_runtime() {
  local result=$?
  trap - EXIT
  if [[ "$RUNTIME_WAS_RUNNING" -eq 1 ]]; then
    if ! "$INSTALLED_CLI" service start >/dev/null; then
      echo "Failed to restore Defi after desktop tests" >&2
      result=1
    else
      for _ in {1..100}; do
        "$INSTALLED_CLI" status >/dev/null 2>&1 && break
        sleep 0.1
      done
      if ! "$INSTALLED_CLI" status >/dev/null 2>&1 || [[ "$(pgrep -u "$(id -u)" -x defi-daemon | wc -l | tr -d ' ')" -ne 1 ]]; then
        echo "Expected exactly one restored defi-daemon" >&2
        result=1
      fi
    fi
  fi
  exit "$result"
}
trap restore_runtime EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if pgrep -u "$(id -u)" -x defi-daemon >/dev/null; then
  [[ -x "$INSTALLED_CLI" ]] || { echo "Cannot stop the running daemon without the installed CLI" >&2; exit 1; }
  RUNTIME_WAS_RUNNING=1
  "$INSTALLED_CLI" service stop >/dev/null
  for _ in {1..50}; do
    pgrep -u "$(id -u)" -x defi-daemon >/dev/null || break
    sleep 0.1
  done
  if pgrep -u "$(id -u)" -x defi-daemon >/dev/null; then
    echo "Daemon still running; refusing competing desktop writes" >&2
    exit 1
  fi
fi

DEFI_E2E=1 swift test --skip-build --disable-swift-testing --no-parallel --filter "$FILTER"
