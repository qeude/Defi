#!/bin/bash
# Runs in the defi-e2e guest's GUI session for script/perf_release.sh; never on a user's Mac.
# Usage: perf_guest.sh ROUNDS NAVIGATIONS WINDOWS BASE CANDIDATE  (bundles at ~/defi-perf/LABEL/Defi.app)
# Rounds alternate which build goes first, so drift in the guest and warm caches hit both builds alike.
set -euo pipefail
ROUNDS=$1 NAVIGATIONS=$2 WINDOWS=$3 BASE=$4 CANDIDATE=$5
DIR=~/defi-perf
APP=~/Applications/Defi.app
CLI=$APP/Contents/MacOS/defi
CONFIG=~/.config/defi/config.toml
mkdir -p "$DIR/out" ~/.config/defi

stop_daemon() {
  [[ ! -x "$CLI" ]] || "$CLI" service stop >/dev/null 2>&1 || true
  pkill -x defi-daemon 2>/dev/null || true
}
wait_for() { # wait_for SECONDS COMMAND...
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep 0.2
  done
}
# The guest may manage windows of its own, such as a Finder window it opens at login.
settled() {
  local status
  status="$("$CLI" status 2>/dev/null)" || return 1
  [[ "$status" == running* && "$status" == *axPending=false* &&
    "$status" == *focusPending=false* && "$status" == *animating=false* && "$status" == *"drift=0["* &&
    "$status" == *"settling=0 "* ]] && (($(sed -E 's/.* windows=([0-9]+) .*/\1/' <<<"$status") >= WINDOWS))
}
cpu_seconds() { # ps TIME is [[DD-]HH:]MM:SS.ss
  ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

# Keep the guest's current app and config; the run uses a fixed config so builds see the same layout.
stop_daemon
rm -rf "$DIR/Defi.app.orig" "$DIR/config.toml.orig"
[[ ! -d "$APP" ]] || mv "$APP" "$DIR/Defi.app.orig"
[[ ! -f "$CONFIG" ]] || cp "$CONFIG" "$DIR/config.toml.orig"
restore() {
  exec 3>&-
  pkill -f "$DIR/Fixture.app" 2>/dev/null || true
  stop_daemon
  rm -rf "$APP"
  [[ ! -d "$DIR/Defi.app.orig" ]] || mv "$DIR/Defi.app.orig" "$APP"
  [[ ! -f "$DIR/config.toml.orig" ]] || mv "$DIR/config.toml.orig" "$CONFIG"
}
trap restore EXIT
printf '[layout]\ndefault_column_width = 0.6\n\n[menu_bar]\nenabled = false\n' > "$CONFIG"

for round in $(seq 1 "$ROUNDS"); do
  order=("$BASE" "$CANDIDATE")
  ((round % 2)) || order=("$CANDIDATE" "$BASE")
  for label in "${order[@]}"; do
    echo "round $round/$ROUNDS: $label"
    stop_daemon
    rm -rf "$APP"
    cp -R "$DIR/$label/Defi.app" "$APP"
    # LaunchServices can refuse an open (-600) just after the previous daemon quits.
    started=0
    for _ in 1 2 3; do
      "$CLI" service start >/dev/null || { sleep 2; continue; }
      wait_for 30 sh -c "'$CLI' status 2>/dev/null | grep -q '^running'" && { started=1; break; }
    done
    ((started)) || { echo "$label did not start" >&2; exit 1; }

    rm -f "$DIR/fixture.in"
    mkfifo "$DIR/fixture.in"
    "$DIR/Fixture.app/Contents/MacOS/PerformanceFixture" < "$DIR/fixture.in" > "$DIR/out/fixture.log" 2>&1 &
    fixture=$!
    exec 3> "$DIR/fixture.in"
    for i in $(seq 1 "$WINDOWS"); do
      printf '{"seq":%d,"command":"create","id":"w%d"}\n' "$i" "$i" >&3
    done
    wait_for 60 settled || { echo "$label did not settle with $WINDOWS fixture windows: $("$CLI" status)" >&2; exit 1; }

    # Ordinary navigation: sweeps across the strip at a human pace; the first sweep may start at an edge.
    for n in $(seq 1 "$NAVIGATIONS"); do
      if (( (n - 1) / (WINDOWS - 1) % 2 == 0 )); then direction=right; else direction=left; fi
      "$CLI" focus-column "$direction" >/dev/null
      sleep 0.25
    done
    wait_for 15 settled || echo "$label round $round did not settle; recording anyway" >&2
    "$CLI" status > "$DIR/out/$label-$round.status"
    daemon="$(pgrep -x defi-daemon | head -1)"
    before="$(cpu_seconds "$daemon")"
    sleep 10
    printf '%s %s %s\n' "$before" "$(cpu_seconds "$daemon")" "$(ps -o rss= -p "$daemon" | tr -d ' ')" \
      > "$DIR/out/$label-$round.idle"

    exec 3>&-
    wait "$fixture" 2>/dev/null || true
  done
done
