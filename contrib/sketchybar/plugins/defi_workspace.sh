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
  '.monitors[] | select(.display == $display) | .workspaces[] | select(.name == $workspace)')
[ -n "$entry" ] || exit 0

active=$(printf '%s' "$entry" | jq -r '.active')
count=$(printf '%s' "$entry" | jq -r '.windowCount')

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
  background.drawing="$background" \
  icon.color="$icon_color"
