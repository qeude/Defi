#!/usr/bin/env bash
# Checkpoint and restore Defi's existing session store under the desktop reservation.
# Usage: desktop_session.sh checkpoint DIR | restore DIR | start | daemons
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${DEFI_CLI:-$HOME/Applications/Defi.app/Contents/MacOS/defi}"
STATE="${DEFI_STATE_DIR:-$HOME/Library/Application Support/Defi}"
STORE=workspace-topology.json
POLL="${DEFI_SESSION_POLL:-0.1}"

fail() { echo "$*" >&2; exit 1; }

# The CLI talks to a daemon that can hang; never let one call stall verification.
cli() {
  "$CLI" "$@" &
  local pid=$! watchdog code=0
  (sleep 15 && kill "$pid") >/dev/null 2>&1 &
  watchdog=$!
  while :; do
    wait "$pid"
    code=$?
    kill -0 "$pid" 2>/dev/null || break
  done
  pkill -P "$watchdog" 2>/dev/null
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$code"
}

daemons() {
  local pids
  pids="$(pgrep -u "$(id -u)" -x defi-daemon)"
  [[ $? -le 1 ]] || fail "Could not inspect daemon processes"
  [[ -z "$pids" ]] && echo 0 || echo "$pids" | wc -l | tr -d ' '
}

stop() {
  cli service stop >/dev/null || return 1
  for _ in {1..100}; do
    [[ "$(daemons)" -eq 0 ]] && return 0
    sleep "$POLL"
  done
  echo "Daemon still running; refusing to replace session stores" >&2
  return 1
}

start() {
  local attempt status
  for attempt in {0..99}; do
    # LaunchServices can refuse a launch (-600) just after the previous instance exits.
    if (( attempt % 10 == 0 )) && [[ "$(daemons)" -eq 0 ]]; then
      cli service start >/dev/null 2>&1
    fi
    if status="$(cli status 2>/dev/null)" && [[ "$(daemons)" -eq 1 && "$status" != *"monitors=0["* ]] \
        && [[ "$status" =~ (^|[^[:alnum:]_])snapshots=[1-9][0-9]*/ ]]; then
      return 0
    fi
    sleep "$POLL"
  done
  echo "Expected one IPC-ready daemon with discovered monitors" >&2
  return 1
}

checkpoint() {
  local dir=$1
  [[ ! -e "$dir" ]] || fail "Checkpoint directory already exists: $dir"
  mkdir -p "$dir" || exit 1
  [[ "$(daemons)" -eq 1 ]] || fail "Session checkpoint requires exactly one running daemon"
  cli status > "$dir/status.txt" || exit 1
  cli list-workspaces --json > "$dir/workspaces.json" || exit 1
  # Shutdown flushes the topology store before unparking windows.
  if stop && cp "$STATE/$STORE" "$dir/$STORE" && touch "$dir/ready"; then
    return 0
  fi
  start
  fail "Session checkpoint failed"
}

replace_store() {
  local dir=$1 transaction stopped=0 changed=0 restarted=0
  transaction="$(mktemp -d "$STATE/.restore-XXXXXX")" || return 1
  # Prepare the store on the destination filesystem before stopping the app.
  if jq empty "$dir/$STORE" && cp "$dir/$STORE" "$transaction/$STORE" \
      && stop && stopped=1 \
      && cp "$STATE/$STORE" "$transaction/$STORE.backup" && changed=1 \
      && mv "$transaction/$STORE" "$STATE/$STORE" && restarted=1 \
      && start; then
    rm -rf "$transaction"
    return 0
  fi
  if (( stopped )); then
    # A failed readiness check can leave a live, partially started daemon.
    if ! { { (( ! restarted )) || stop; } \
        && { (( ! changed )) || { cp "$transaction/$STORE.backup" "$transaction/$STORE" && mv "$transaction/$STORE" "$STATE/$STORE"; }; } \
        && start; }; then
      echo "Session restore failed; recovery failed; backup retained at $transaction" >&2
      return 1
    fi
  fi
  rm -rf "$transaction"
  echo "Session restore failed; the previous store is back in place" >&2
  return 1
}

# Numbers within 1e-6, objects with the same keys, arrays of the same length, all compared deeply.
CLOSE='def close($a; $b):
  if ($a|type) == "number" and ($b|type) == "number" then (($a - $b) | if . < 0 then -. else . end) < 0.000001
  elif ($a|type) == "object" and ($b|type) == "object" then ($a|keys) == ($b|keys) and all($a|keys[]; . as $k | close($a[$k]; $b[$k]))
  elif ($a|type) == "array" and ($b|type) == "array" then ($a|length) == ($b|length) and all(range($a|length); . as $i | close($a[$i]; $b[$i]))
  else $a == $b end;'

restore() {
  local dir=$1 monitor id active focused current display initial status
  [[ -e "$dir/ready" ]] || fail "No complete session checkpoint available"
  [[ "$(jq -r .sessionID "$dir/$STORE")" == "$(jq -r .sessionID "$STATE/$STORE")" ]] \
    || fail "Login session changed; refusing stale session restoration"
  replace_store "$dir" || exit 1
  # Restore other monitors first, then the initially focused monitor.
  while IFS=$'\t' read -r id active focused; do
    current="$(cli list-workspaces --json | jq -c --argjson id "$id" '.monitors[] | select(.id == $id)')" || exit 1
    [[ -n "$current" ]] || fail "Monitor topology changed during verification"
    if [[ "$(jq -r .activeWorkspace <<< "$current")" != "$active" ]] \
        || [[ "$focused" == true && "$(jq -r .focused <<< "$current")" != true ]]; then
      display="$(jq -r .display <<< "$current")"
      cli --monitor "$display" workspace "$active" >/dev/null || exit 1
    fi
  done < <(jq -r '.monitors | sort_by(.focused)[] | [.id, .activeWorkspace, .focused] | @tsv' "$dir/workspaces.json")
  initial="$(grep -oE '(^|[[:space:]])focused=[^[:space:]]+' "$dir/status.txt" | head -1 | sed 's/.*focused=//')"
  # Validates persisted logical state and managed-frame convergence;
  # native focus and visual quality still require the Computer Use reservation.
  for _ in {1..100}; do
    sleep "$POLL"
    status="$(cli status)" || exit 1
    echo "$status" > "$dir/restored-status.txt"
    jq . "$STATE/$STORE" > "$dir/restored-topology.json"
    if jq -en --slurpfile a "$STATE/$STORE" --slurpfile b "$dir/$STORE" \
          "$CLOSE close(\$a[0].topology.monitors; \$b[0].topology.monitors)" >/dev/null \
        && [[ " $status " == *" focused=$initial "* && "$status" == *"drift=0["* ]] \
        && [[ "$status" == *"focusPending=false"* && "$status" == *"axPending=false"* ]] \
        && [[ "$(daemons)" -eq 1 ]]; then
      echo "Restored all monitor workspaces, logical focus, widths, scroll, and managed-frame convergence"
      return 0
    fi
  done
  fail "Session restoration incomplete; inspect $dir/restored-topology.json and restored-status.txt"
}

# Sourcing loads the functions above for tests.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
case "${1:-}" in
  daemons) daemons; exit ;;
  checkpoint|restore|start) ;;
  *) echo "usage: desktop_session.sh checkpoint DIR | restore DIR | start | daemons" >&2; exit 2 ;;
esac
"$ROOT/script/desktop_lock.sh" --check || fail "A desktop reservation is required"
# Finish the operation, which restarts the daemon on failure, before reporting the interruption.
INTERRUPTED=0
trap 'INTERRUPTED=1' INT TERM
mode=$1
shift
"$mode" "$@" || exit 1
[[ "$INTERRUPTED" -eq 0 ]] || { echo "Session operation interrupted" >&2; exit 130; }
