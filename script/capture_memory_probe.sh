#!/bin/zsh
# Replays human-paced column and workspace navigation on the installed daemon, then
# reports the memory window captures cost Defi and WindowServer. Run under
# `script/desktop_lock.py --wait`; returns to the starting workspace.
# Usage: script/capture_memory_probe.sh OTHER_WORKSPACE_NAME
set -euo pipefail

DEFI="$HOME/Applications/Defi.app/Contents/MacOS/defi"
ROUNDS="${ROUNDS:-6}"
field() { "$DEFI" status | grep -oE "$1=[^ ]+" | head -1 | cut -d= -f2-; }

start_workspace="$(field workspace)"
other_workspace="${1:?usage: capture_memory_probe.sh OTHER_WORKSPACE_NAME}"
trap '"$DEFI" focus-workspace-name "$start_workspace" >/dev/null' EXIT

for round in $(seq "$ROUNDS"); do
  for direction in right right right left left left; do
    "$DEFI" focus-column "$direction" >/dev/null; sleep 0.35
  done
  "$DEFI" focus-workspace-name "$other_workspace" >/dev/null; sleep 0.6
  for direction in right left; do "$DEFI" focus-column "$direction" >/dev/null; sleep 0.35; done
  "$DEFI" focus-workspace-name "$start_workspace" >/dev/null; sleep 0.6
done
sleep 3

daemon="$(pgrep -x defi-daemon)"
surfaces="$(vmmap --summary "$daemon" 2>/dev/null | awk '/^IOSurface /{print $2}')"
echo "rounds=$ROUNDS daemon=$daemon"
footprint "$daemon" 2>/dev/null | grep -E "Footprint:|phys_footprint_peak"
footprint "$daemon" 2>/dev/null | grep -E " (IOSurface|CG Raster Data|Malloc Large)$"
echo "IOSurface mapped=$surfaces"
top -l 1 -pid "$(pgrep -x WindowServer)" -stats command,mem | tail -1
"$DEFI" status | grep -oE "(workspace|focused|tapReenables|droppedFrames|windowCaptureMiB|windowCaptures|inputPlanN/P50/P95/P99)=[^ ]+"
