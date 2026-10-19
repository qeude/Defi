#!/usr/bin/env bash
# Proves center_focused_column never / always / on-overflow on the installed daemon.
# Opens four scratch TextEdit documents on the trailing empty workspace, then for
# each mode focuses the first column and steps right once, and classifies where the
# focused window landed. The temporary config pins new columns to 0.5 (an exact fit)
# and presets to [0.5, 0.66], so one cycle-width step gives the 0.66 overflow phase.
# Restores the config, closes the documents and returns to the initial workspace.
# DRIVE=hotkeys sends the configured <mod>-leftbracket / <mod>-right key events
# through System Events instead of CLI commands, and checks the daemon captured them.
# Usage: [DRIVE=hotkeys] centering_check.sh [evidence-dir]   (run under `python3 script/desktop_lock.py --wait`)
set -u
out="${1:-dist/verification/evidence-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$out"
config="$HOME/.config/defi/config.toml"
defi status > "$out/before.status" || { echo "daemon unreachable"; exit 1; }
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

# Usage: set_layout key=toml-value...  Rewrites those [layout] keys and checks the result parses.
set_layout() {
  python3 - "$config" "$@" <<'PY' || { echo "FAIL: could not write [layout] $*"; exit 1; }
import re, sys, tomllib
path, pairs = sys.argv[1], [a.split('=', 1) for a in sys.argv[2:]]
text = open(path).read()
for key, _ in pairs:
    text = re.sub(rf'(?m)^{key}\s*=.*\n', '', text)
if not re.search(r'(?m)^\[layout\]\s*$', text):
    text = text.rstrip('\n') + '\n\n[layout]\n'
lines = ''.join(f'{key} = {value}\n' for key, value in pairs)
text = re.sub(r'(?m)^\[layout\]\s*\n', lambda m: m.group(0) + lines, text, count=1)
layout = tomllib.loads(text)['layout']
assert all(layout[key] == tomllib.loads(f'v = {value}')['v'] for key, value in pairs)
open(path, 'w').write(text)
PY
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

trailing="$(python3 -c 'import json,sys
d=json.load(sys.stdin)
m=next(m for m in d["monitors"] if m["focused"])
print(next(w["position"] for w in m["workspaces"] if w["kind"]=="trailing"))' < "$out/workspaces-before.json")"
set_layout "default_column_width=0.5" "preset_column_widths=[0.5, 0.66]"
defi focus-workspace-position "$trailing" > /dev/null; sleep 1
for _ in 1 2 3 4; do
  osascript -e 'tell application "TextEdit" to make new document' > /dev/null; sleep 1.2
done
osascript -e 'tell application "TextEdit" to activate' > /dev/null; sleep 1.5
count="$(defi list-workspaces --json | python3 -c 'import json,sys
d=json.load(sys.stdin)
m=next(m for m in d["monitors"] if m["focused"])
print(next(w["windowCount"] for w in m["workspaces"] if w["active"]))')"
[ "$count" = 4 ] || { echo "expected 4 scratch columns, got $count"; exit 1; }

modifiers="$(python3 - "$config" <<'PY'
import re, sys, tomllib
config = tomllib.loads(open(sys.argv[1]).read())
modifier = config.get('default_key_modifier', 'alt')
names = {'alt': 'option', 'option': 'option', 'opt': 'option', 'cmd': 'command', 'command': 'command',
         'ctrl': 'control', 'control': 'control', 'shift': 'shift'}
parts = re.split(r'[+-]', config.get('modifier_combinations', {}).get(modifier, modifier))
print(', '.join(f'{names[p.strip().lower()]} down' for p in parts))
PY
)" || { echo "cannot resolve default_key_modifier"; exit 1; }
step() {
  if [ "${DRIVE:-cli}" = hotkeys ]; then
    local code; [ "$1" = first ] && code=33 || code=124
    osascript -e "tell application \"System Events\" to key code $code using {$modifiers}"
  else
    defi focus-column "$1" > /dev/null
  fi
}

fail=0
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
