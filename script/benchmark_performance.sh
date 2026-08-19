#!/bin/sh
set -eu

cli="${DEFI_CLI:-$HOME/Applications/Defi.app/Contents/MacOS/defi}"
cycles="${DEFI_BENCHMARK_CYCLES:-10}"
settle="${DEFI_BENCHMARK_SETTLE_SECONDS:-0.45}"

if [ ! -x "$cli" ]; then
  echo "missing installed Defi CLI: $cli" >&2
  exit 1
fi

focus_id() {
  "$cli" status | sed -E 's/.* focused=([^ ]+).*/\1/'
}

wait_until_ready() {
  for _ in $(jot 50); do
    status="$($cli status 2>/dev/null || true)"
    if printf '%s\n' "$status" | grep -q ' timerHz=2 ' \
      && printf '%s\n' "$status" | grep -q ' axPending=false ' \
      && printf '%s\n' "$status" | grep -q ' focusPending=false '
    then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

initial_focus="$(focus_id)"
forward=right
reverse=left
"$cli" focus-column "$forward" >/dev/null
sleep "$settle"
if [ "$(focus_id)" = "$initial_focus" ]; then
  forward=left
  reverse=right
  "$cli" focus-column "$forward" >/dev/null
  sleep "$settle"
  if [ "$(focus_id)" = "$initial_focus" ]; then
    echo "benchmark needs an adjacent column" >&2
    exit 1
  fi
  "$cli" focus-column "$reverse" >/dev/null
  sleep "$settle"
else
  "$cli" focus-column "$reverse" >/dev/null
  sleep "$settle"
fi
wait_until_ready

"$cli" service restart >/dev/null
wait_until_ready
if [ "$(focus_id)" != "$initial_focus" ]; then
  echo "service restart changed focused window $initial_focus" >&2
  exit 1
fi

for _ in $(jot "$cycles"); do
  "$cli" focus-column "$forward" >/dev/null
  sleep "$settle"
  "$cli" focus-column "$reverse" >/dev/null
  sleep "$settle"
done

for _ in $(jot 10); do
  status="$($cli status)"
  if printf '%s\n' "$status" | grep -q ' timerHz=2 ' \
    && printf '%s\n' "$status" | grep -q ' axPending=false ' \
    && printf '%s\n' "$status" | grep -q ' focusPending=false '
  then
    break
  fi
  sleep 0.5
done
printf '%s\n' "$status" | tr ' ' '\n' | grep -E \
  '^(workspace=|focused=|timerHz=|slowApps=|slowAppDetails=|axAppDetails=|snapshotP50/P95=|commandLatency=|input(Plan|Write|Observed|Converged|Focus)N)'

pids="$(pgrep -f '/Defi.app/Contents/MacOS/defi-daemon' || true)"
if [ "$(printf '%s\n' "$pids" | grep -c .)" -ne 1 ]; then
  echo "expected exactly one installed defi-daemon" >&2
  exit 1
fi
pid="$pids"
top -l 2 -s 2 -pid "$pid" -stats pid,cpu,mem,command | awk -v pid="$pid" '
  $1 == "PID" { header = $0 }
  $1 == pid { sample = $0 }
  END { print header; print sample }
'

if [ "$(focus_id)" != "$initial_focus" ]; then
  echo "benchmark did not restore focused window $initial_focus" >&2
  exit 1
fi
