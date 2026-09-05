#!/bin/sh

set -eu

. "${CONFIG_DIR:-$HOME/.config/sketchybar}/plugins/defi_common.sh"
SKETCHYBAR_BIN="${BAR_NAME:-sketchybar}"
PLUGIN_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}/plugins"
STATE_FILE="${CONFIG_DIR:-$HOME/.config/sketchybar}/.defi-items"
state=${INFO:-}

if [ -z "$state" ]; then
  state="$("$DEFI_BIN" list-workspaces --json 2>/dev/null || true)"
fi
[ -n "$state" ] || exit 0

next_file="$STATE_FILE.next.$$"
trap 'rm -f "$next_file"' EXIT
printf '%s' "$state" \
  | jq -r '.monitors[] | .display as $display | .workspaces[] | "defi.\($display).\(.id)"' \
  > "$next_file"

if [ -f "$STATE_FILE" ]; then
  while IFS= read -r item; do
    if ! grep -Fqx "$item" "$next_file" \
      && "$SKETCHYBAR_BIN" --query "$item" >/dev/null 2>&1; then
      "$SKETCHYBAR_BIN" --remove "$item"
    fi
  done < "$STATE_FILE"
fi

while IFS= read -r item; do
  if "$SKETCHYBAR_BIN" --query "$item" >/dev/null 2>&1; then
    continue
  fi
  suffix=${item#defi.}
  display=${suffix%%.*}
  workspace=${suffix#*.}
  "$SKETCHYBAR_BIN" \
    --add item "$item" left \
    --set "$item" \
      display="$display" \
      icon="$workspace" \
      label.drawing=off \
      background.drawing=off \
      background.corner_radius=5 \
      background.height=22 \
      script="$PLUGIN_DIR/defi_workspace.sh" \
      click_script="$PLUGIN_DIR/defi_workspace_click.sh" \
    --subscribe "$item" defi_workspace_change
  NAME="$item" INFO="$state" "$PLUGIN_DIR/defi_workspace.sh"
done < "$next_file"

mv "$next_file" "$STATE_FILE"
trap - EXIT
