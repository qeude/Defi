#!/usr/bin/env bash
# Proves center_focused_column never / always / on-overflow, always_center_single_column,
# center-column, focus-window-or-workspace and focus-workspace-previous on the installed daemon.
# Opens four scratch TextEdit documents on the trailing empty workspace, then for
# each mode focuses the first column and steps right once, and classifies where the
# focused window landed. The temporary config pins new columns to 0.5 (an exact fit)
# and presets to [0.5, 0.66], so one cycle-width step gives the 0.66 overflow phase.
# Restores the config, closes the documents and returns to the initial workspace.
# DRIVE=hotkeys sends the configured <mod>-leftbracket / <mod>-right / <mod>-c key events
# through System Events instead of CLI commands, and checks the daemon captured them.
# Usage: [DRIVE=hotkeys] centering_check.sh [evidence-dir]   (run under `script/desktop_lock.sh --wait`)
set -u
out="${1:-dist/verification/evidence-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$out"
config="$HOME/.config/defi/config.toml"
# A daemon that has just started reports monitors=0 until discovery finishes.
for _ in $(seq 1 40); do
  defi status > "$out/before.status" 2>/dev/null && ! grep -q 'monitors=0\[\]' "$out/before.status" && break
  sleep 0.5
done
[ -s "$out/before.status" ] || { echo "daemon unreachable"; exit 1; }
field() { tr ' ' '\n' < "$1" | sed -n "s/^$2=//p"; }
monitors="$(field "$out/before.status" monitors)"
case "$monitors" in 1\[*) ;; *) echo "needs exactly one monitor, got $monitors"; exit 1 ;; esac
screen_width="$(echo "$monitors" | sed -n 's/.*:\([0-9]*\)x.*/\1/p')"
initial="$(field "$out/before.status" workspace)"
pgrep -x TextEdit > /dev/null && { echo "TextEdit is running; quit it first so no user document is touched"; exit 1; }
defi list-workspaces --json > "$out/workspaces-before.json"
created_config=0
if [ ! -f "$config" ]; then mkdir -p "$(dirname "$config")"; : > "$config"; created_config=1; fi
cp "$config" "$out/config.toml.backup"

cat > "$out/bounds.swift" <<'SWIFT'
import CoreGraphics
let id = UInt32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
let bounds = list.first?[kCGWindowBounds as String] as? [String: Double] ?? [:]
print(Int(bounds["X"] ?? -1), Int(bounds["Width"] ?? -1))
SWIFT
swiftc -O -o "$out/bounds" "$out/bounds.swift" 2>/dev/null || { echo "bounds helper failed to build"; exit 1; }

restore() {
  osascript -e 'tell application "TextEdit" to close every window saving no' \
    -e 'tell application "TextEdit" to quit saving no' > /dev/null 2>&1
  # The workspace switch must wait for TextEdit to exit, or a closing window pulls focus back.
  for _ in $(seq 1 50); do pgrep -x TextEdit > /dev/null || break; sleep 0.2; done
  pgrep -x TextEdit > /dev/null && echo "FAIL: TextEdit still running"
  if [ "$created_config" = 1 ]; then rm -f "$config"; else cp "$out/config.toml.backup" "$config"; fi
  sleep 1.5
  defi focus-workspace-name "$initial" > /dev/null
  defi status > "$out/after.status"
  defi list-workspaces --json > "$out/workspaces-after.json"
}
trap restore EXIT

# Usage: set_layout key=toml-value...  Rewrites those [layout] keys, first in the table.
set_layout() {
  local pair keys="" lines=""
  for pair in "$@"; do keys="$keys ${pair%%=*}"; lines="$lines${pair%%=*} = ${pair#*=}"$'\n'; done
  KEYS="$keys" LINES="$lines" awk '
    BEGIN { n = split(ENVIRON["KEYS"], key, " "); lines = ENVIRON["LINES"] }
    { for (i = 1; i <= n; i++) if (index($0, key[i]) == 1 && substr($0, length(key[i]) + 1) ~ /^[ \t]*=/) next }
    !done && /^\[layout\][ \t]*$/ { print; printf "%s", lines; done = 1; next }
    { print }
    END { if (!done) { print ""; print "[layout]"; printf "%s", lines } }' "$config" > "$config.tmp" \
    && mv "$config.tmp" "$config" || { echo "FAIL: could not write [layout] $*"; exit 1; }
  sleep 1.5
}
set_mode() { set_layout "center_focused_column=\"$1\""; }

where() {
  local id x w
  id="$(defi status | tr ' ' '\n' | sed -n 's/^focused=//p')"
  read -r x w < <("$out/bounds" "$id")
  local center=$((x + w / 2)) right=$((x + w)) half=$((screen_width / 2))
  if [ $((center - half)) -le 24 ] && [ $((half - center)) -le 24 ]; then echo centered
  elif [ $((screen_width - right)) -le 24 ] && [ $((right - screen_width)) -le 24 ]; then echo right-edge
  else echo "x=$x width=$w"; fi
}

trailing="$(jq -r 'first(.monitors[] | select(.focused)) | first(.workspaces[] | select(.kind == "trailing")) | .position' \
  "$out/workspaces-before.json")"
set_layout "default_column_width=0.5" "preset_column_widths=[0.5, 0.66]"
defi focus-workspace-position "$trailing" > /dev/null; sleep 1
fail=0
expect() {
  local got; got="$(where)"
  [ "$got" = "$2" ] && verdict=PASS || { verdict=FAIL; fail=1; }
  echo "$1: $verdict expected=$2 got=$got"
}
new_document() { osascript -e 'tell application "TextEdit" to make new document' > /dev/null; sleep 1.2; }
scratch_count() {
  defi list-workspaces --json \
    | jq -r 'first(.monitors[] | select(.focused)) | first(.workspaces[] | select(.active)) | .windowCount'
}
# TextEdit's iCloud open panel can appear on launch and on activation, and Defi tiles it.
close_open_panel() {
  osascript -e 'tell application "TextEdit" to activate' \
    -e 'tell application "System Events" to key code 53' > /dev/null 2>&1
  sleep 1
}
open -g -a TextEdit --args -NSShowAppCentricOpenPanelInsteadOfUntitledFile NO; sleep 2
osascript -e 'tell application "TextEdit" to close every window saving no' > /dev/null; sleep 1
new_document
osascript -e 'tell application "TextEdit" to activate' > /dev/null; sleep 1.5
close_open_panel
[ "$(scratch_count)" = 1 ] || { echo "lone column checks would run with $(scratch_count) columns"; exit 1; }
set_layout 'center_focused_column="never"' 'always_center_single_column=true'
expect "lone column, single-column setting on" centered
set_layout 'center_focused_column="always"' 'always_center_single_column=false'
expect "lone column, always" centered
set_layout 'center_focused_column="never"'
# A reload that only recenters must still move windows with animations off.
cp "$config" "$out/config.animations-on"
awk '/^\[/ { section = ($0 ~ /^\[animation\][ \t]*$/); print; if (section) { print "enabled = false"; found = 1 }; next }
  section && /^enabled[ \t]*=/ { next }
  { print }
  END { if (!found) { print ""; print "[animation]"; print "enabled = false" } }' "$config" > "$config.tmp" \
  && mv "$config.tmp" "$config" || { echo "FAIL: could not disable animations"; exit 1; }
sleep 1.5
set_layout 'always_center_single_column=true'
expect "lone column, animations off" centered
cp "$out/config.animations-on" "$config"
sleep 1.5
for _ in 1 2 3 4; do
  close_open_panel
  [ "$(scratch_count)" -lt 4 ] && new_document
done
close_open_panel
count="$(scratch_count)"
[ "$count" = 4 ] || { echo "expected 4 scratch columns, got $count"; exit 1; }

# The System Events modifier list for `mod`.
modifiers="$(awk '
  function clean(v) { sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v); gsub(/"/, "", v); return v }
  /^\[/ { table = $0; gsub(/^\[|\][ \t]*$/, "", table); next }
  table == "" && /^mod[ \t]*=/ { modifier = clean($0) }
  END {
    split("alt option option option opt option cmd command command command ctrl control control control shift shift", pairs, " ")
    for (i = 1; i < 16; i += 2) name[pairs[i]] = pairs[i + 1]
    if (modifier == "") modifier = "ctrl+alt"
    n = split(modifier, part, /[+]/)
    for (i = 1; i <= n; i++) {
      p = tolower(part[i]); gsub(/^[ \t]+|[ \t]+$/, "", p)
      if (!(p in name)) exit 1
      list = list (i > 1 ? ", " : "") name[p] " down"
    }
    print list
  }' "$config")" || { echo "cannot resolve mod"; exit 1; }
step() {
  if [ "${DRIVE:-cli}" = hotkeys ]; then
    local code; [ "$1" = first ] && code=33 || code=124
    osascript -e "tell application \"System Events\" to key code $code using {$modifiers}"
  else
    defi focus-column "$1" > /dev/null
  fi
}

captured_before="$(defi status | tr ' ' '\n' | sed -n 's/^captured=//p')"
check() {
  local mode="$1" expected="$2" t0 got
  set_mode "$mode"
  step first; sleep 0.8
  t0="$(defi trace | tail -1 | cut -d' ' -f1)"
  step right; sleep 0.8
  defi trace | awk -v t="$t0" '$1 > t' > "$out/trace-$3-$mode.log"
  got="$(where)"
  [ "$got" = "$expected" ] && verdict=PASS || { verdict=FAIL; fail=1; }
  echo "$3 $mode: $verdict expected=$expected got=$got"
}

check never right-edge width-0.50
check always centered width-0.50
check on-overflow right-edge width-0.50
set_mode always
defi focus-column first > /dev/null; sleep 0.8; expect "first column, always" centered
defi focus-column last > /dev/null; sleep 0.8; expect "last column, always" centered
set_mode never
defi focus-column first > /dev/null; sleep 0.8
if [ "${DRIVE:-cli}" = hotkeys ]; then
  osascript -e "tell application \"System Events\" to key code 8 using {$modifiers}" # <mod>-c
else
  defi center-column > /dev/null
fi
sleep 0.8; expect "first column, center-column" centered
defi focus-column right > /dev/null; sleep 0.8; expect "center-column dropped by the next column" right-edge

workspace() { defi status | tr ' ' '\n' | sed -n 's/^workspace=//p'; }
expect_workspace() {
  local got; got="$(workspace)"
  [ "$got" = "$2" ] && verdict=PASS || { verdict=FAIL; fail=1; }
  echo "$1: $verdict expected=$2 got=$got"
}
scratch="$(workspace)"
defi focus-workspace-name "$initial" > /dev/null; sleep 1
defi focus-workspace-previous > /dev/null; sleep 1; expect_workspace "previous workspace" "$scratch"
defi focus-workspace-previous > /dev/null; sleep 1; expect_workspace "previous workspace again" "$initial"
defi focus-workspace-previous > /dev/null; sleep 1; expect_workspace "previous workspace toggles" "$scratch"
defi focus-window-or-workspace up > /dev/null; sleep 1
above="$(workspace)"
if [ "$above" != "$scratch" ]; then verdict=PASS; else verdict=FAIL; fail=1; fi
echo "stack end crosses up: $verdict from=$scratch to=$above"
defi focus-window-or-workspace down > /dev/null; sleep 1; expect_workspace "stack end crosses down" "$scratch"
defi focus-column first > /dev/null
for _ in 1 2 3 4; do
  defi cycle-width next > /dev/null; sleep 0.5; defi focus-column right > /dev/null; sleep 0.5
done
check never right-edge width-0.66
check always centered width-0.66
check on-overflow centered width-0.66

captured_after="$(defi status | tr ' ' '\n' | sed -n 's/^captured=//p')"
echo "drive=${DRIVE:-cli} captured=$((captured_after - captured_before))"
if [ "${DRIVE:-cli}" = hotkeys ] && [ $((captured_after - captured_before)) -lt 12 ]; then
  echo "FAIL: hotkeys not captured"; fail=1
fi
trap - EXIT; restore
tr ' ' '\n' < "$out/after.status" | grep -E '^(workspace|drift|droppedFrames|animating|axPending|focusPending)=' | tr '\n' ' '; echo
grep -q 'drift=0\[\]' "$out/after.status" || { echo "FAIL: drift"; fail=1; }
pgrep -x TextEdit > /dev/null && { echo "FAIL: scratch TextEdit left running"; fail=1; }
[ "$(field "$out/after.status" workspace)" = "$initial" ] || { echo "FAIL: initial workspace not restored"; fail=1; }
if [ "$created_config" = 1 ]; then
  [ ! -e "$config" ] || { echo "FAIL: temporary config not removed"; fail=1; }
else
  cmp -s "$config" "$out/config.toml.backup" || { echo "FAIL: config not restored"; fail=1; }
fi
echo "daemons: $(pgrep -u "$(id -u)" -x defi-daemon | wc -l | tr -d ' ')"
echo "evidence: $out"; exit $fail
