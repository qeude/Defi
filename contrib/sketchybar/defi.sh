#!/bin/sh

set -eu

. "${CONFIG_DIR:-$HOME/.config/sketchybar}/plugins/defi_common.sh"
SKETCHYBAR_BIN="${BAR_NAME:-sketchybar}"
PLUGIN_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}/plugins"
STATE="$("$DEFI_BIN" list-workspaces --json 2>/dev/null || true)"

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

[ -n "$STATE" ] || exit 0
INFO="$STATE" "$PLUGIN_DIR/defi_workspace_reconcile.sh"

"$SKETCHYBAR_BIN" --update
