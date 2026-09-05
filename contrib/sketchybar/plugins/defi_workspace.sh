#!/bin/sh

set -eu

. "${CONFIG_DIR:-$HOME/.config/sketchybar}/plugins/defi_common.sh"
SKETCHYBAR_BIN="${BAR_NAME:-sketchybar}"
suffix=${NAME#defi.}
display=${suffix%%.*}
workspace=${suffix#*.}
state=${INFO:-}

if [ -z "$state" ]; then
  state="$("$DEFI_BIN" list-workspaces --json 2>/dev/null || true)"
fi
[ -n "$state" ] || exit 0

entry=$(printf '%s' "$state" | jq -c \
  --argjson display "$display" \
  --arg workspace "$workspace" \
  '.monitors[] | select(.display == $display) | .workspaces[] | select(.id == $workspace)')
[ -n "$entry" ] || exit 0

active=$(printf '%s' "$entry" | jq -r '.active')
count=$(printf '%s' "$entry" | jq -r '.windowCount')
label=$(printf '%s' "$entry" | jq -r '.name // if .kind == "trailing" then "+" else (.position | tostring) end')

if [ "$active" = true ]; then
  background=on
else
  background=off
fi

if [ "$count" -gt 0 ]; then
  icon_color=0xffffffff
else
  icon_color=0x66ffffff
fi

"$SKETCHYBAR_BIN" --set "$NAME" \
  icon="$label" \
  background.drawing="$background" \
  icon.color="$icon_color"
