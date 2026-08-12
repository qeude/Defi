#!/bin/sh

set -eu

if [ -z "${DEFI_BIN:-}" ]; then
  if [ -x "$HOME/Applications/Defi.app/Contents/MacOS/defi" ]; then
    DEFI_BIN="$HOME/Applications/Defi.app/Contents/MacOS/defi"
  elif [ -x /Applications/Defi.app/Contents/MacOS/defi ]; then
    DEFI_BIN=/Applications/Defi.app/Contents/MacOS/defi
  else
    DEFI_BIN=$(command -v defi || true)
  fi
fi
[ -n "$DEFI_BIN" ] || exit 0
SKETCHYBAR_BIN="${BAR_NAME:-sketchybar}"
PLUGIN_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}/plugins"
STATE="$("$DEFI_BIN" list-workspaces --json 2>/dev/null || true)"

[ -n "$STATE" ] || exit 0
command -v jq >/dev/null 2>&1 || {
  printf '%s\n' "Defi SketchyBar integration requires jq" >&2
  exit 1
}

"$SKETCHYBAR_BIN" --add event \
  defi_workspace_change \
  com.quentin.defi.workspaceChanged

if ! "$SKETCHYBAR_BIN" --query defi.workspace_observer >/dev/null 2>&1; then
  "$SKETCHYBAR_BIN" --add item defi.workspace_observer left
fi

"$SKETCHYBAR_BIN" \
  --set defi.workspace_observer \
    drawing=off \
    script="$PLUGIN_DIR/defi_workspace_reconcile.sh" \
  --subscribe defi.workspace_observer defi_workspace_change

INFO="$STATE" "$PLUGIN_DIR/defi_workspace_reconcile.sh"

"$SKETCHYBAR_BIN" --update
