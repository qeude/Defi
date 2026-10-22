#!/usr/bin/env bash
# Drives realistic rapid navigation against the installed daemon and scores the
# window-proxy overlay from its own log events. Exits non-zero when any budget fails.
set -euo pipefail

gap="${PROXY_STRESS_GAP:-0.07}"
rounds="${PROXY_STRESS_ROUNDS:-3}"
log=/usr/bin/log
predicate='subsystem == "com.qeude.defi" AND category == "ribbon-proxy"'

workspace() { defi status | grep -oE 'workspace=[^ ]+' | cut -d= -f2; }
run() { defi "$@" >/dev/null; sleep "$gap"; }

initial="$(workspace)"
trap '[ "$(workspace)" = "$initial" ] || defi focus-workspace-name "$initial" >/dev/null' EXIT
# log show takes whole seconds: start on a fresh one so no earlier event counts.
sleep 1
start="$(date '+%Y-%m-%d %H:%M:%S')"

for _ in $(seq "$rounds"); do
  for _ in 1 2 3 4; do run focus-column right; done
  for _ in 1 2 3 4; do run focus-column left; done
  run cycle-width next; run cycle-width previous
  run move-column right; run move-column left
  sleep 0.6
  run focus-workspace down; sleep 0.2; run focus-workspace down; sleep 0.2
  run focus-workspace up; sleep 0.2; run focus-workspace up
  sleep 0.6
done
sleep 1.5

events="$("$log" show --start "$start" --predicate "$predicate" --style compact 2>/dev/null)"
count() { grep -cE "$1" <<<"$events" || true; }
presents=$(count 'present windows=')
fallbacks=$(grep -E 'fallback ' <<<"$events" | grep -cvE 'fallback (surface|background)' || true)
timeouts=$(count 'landing-timeout')
strays=$(count 'landing-stray')
missing=$(grep -E 'present windows=' <<<"$events" | grep -cv 'missing=\[\]' || true)
# Informational: the daemon's percentile covers its last 120 commands, not only this run.
p99=$(defi status | grep -oE 'inputPlanN/P50/P95/P99=[^ ]+' | awk -F/ '{print $NF}')

printf 'presents=%s fallbacks=%s landing_timeouts=%s strays=%s presents_missing_pictures=%s rolling_input_p99_ms=%s\n' \
  "$presents" "$fallbacks" "$timeouts" "$strays" "$missing" "$p99"
grep -E 'fallback|landing-|cancel ' <<<"$events" | cut -c12-23,60-220 || true

[ "$presents" -gt 0 ] && [ "$fallbacks" -eq 0 ] && [ "$timeouts" -eq 0 ] && [ "$strays" -eq 0 ] \
  && [ "$missing" -eq 0 ]
