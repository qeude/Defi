#!/usr/bin/env bash
# Read-only health check for the running Defi daemon.
set -u
echo "daemons: $(pgrep -u "$(id -u)" -x defi-daemon | wc -l | tr -d ' ')"
for pid in $(pgrep -u "$(id -u)" -x defi-daemon); do
  ps -o pid=,lstart=,etime=,command= -p "$pid"
done
echo "defi on PATH: $(command -v defi || echo missing)"
if ! status="$(defi status 2>&1)"; then
  echo "status: unreachable ($status)"
  exit 1
fi
echo "$status" | cut -d' ' -f1-3
echo "$status" | tr ' ' '\n' | grep -E '^(session|workspace|overview|overviewPermission|overviewPreviews|overviewReceivedPreviews|overviewPreviewFailures|overviewCaptures|overviewSurface|hotkeys|observationFailures)=' | tr '\n' ' '
echo
