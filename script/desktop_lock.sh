#!/usr/bin/env bash
# Reserve this user's desktop across Defi worktrees and child commands.
# Usage: desktop_lock.sh [--wait] COMMAND...   run COMMAND holding the reservation (exit 75 when busy)
#        desktop_lock.sh --check               succeed when this process runs under the reservation
#        desktop_lock.sh --owner               print the holder as JSON, or null
set -euo pipefail

LOCK="${DEFI_DESKTOP_LOCK_PATH:-$HOME/Library/Caches/Defi/desktop-verification.lock}"
OWNER="$LOCK.owner"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# lockf exits 75 when another process holds the kernel lock; the kernel releases it when the holder exits.
busy() { [[ -e "$LOCK" ]] && ! lockf -k -s -t 0 "$LOCK" true; }

# shortcut: holding is inferred from the inherited path plus a busy lock, which trusts cooperating
# processes; pass a file descriptor instead if a non-cooperating writer ever needs excluding.
held() { [[ "${DEFI_DESKTOP_LOCK:-}" == "$LOCK" ]] && busy; }

case "${1:-}" in
  --check) held; exit ;;
  --owner) if busy && [[ -s "$OWNER" ]]; then cat "$OWNER"; else echo null; fi; exit ;;
  --owned)
    shift
    jq -cn --argjson pid $$ --arg cwd "$PWD" --arg report "${DEFI_VERIFICATION_REPORT:-}" \
      '{pid: $pid, cwd: $cwd, acquired_at: now, report: (if $report == "" then null else $report end)}' > "$OWNER"
    exec "$@"
    ;;
esac

wait=0
[[ "${1:-}" != --wait ]] || { wait=1; shift; }
[[ $# -gt 0 ]] || { echo "usage: desktop_lock.sh [--wait] COMMAND..., e.g. --wait bash for an interactive reservation" >&2; exit 2; }
held && exec "$@"
if [[ "$wait" -eq 0 ]] && busy; then
  echo "Desktop busy: $(cat "$OWNER" 2>/dev/null || echo "$LOCK")" >&2
  exit 75
fi
mkdir -p "$(dirname "$LOCK")"
export DEFI_DESKTOP_LOCK="$LOCK"
# Keep the file (-k): unlinking a locked inode would let another process lock a new one.
options=(-k)
[[ "$wait" -eq 1 ]] || options+=(-s -t 0)
# An interactive reservation stays in the foreground, where it owns the terminal.
[[ -t 0 ]] && exec lockf "${options[@]}" "$LOCK" "$SELF" --owned "$@"

# lockf releases the lock on SIGTERM while its command still runs, so a signal to our process group
# must not reach it: run it in its own group and signal the command's whole tree, as a group signal
# would, so a shell blocked on a synchronous child stops too and then cleans up.
holder=""
signal_tree() {
  local child
  for child in $(pgrep -P "$1" || true); do signal_tree "$child"; done
  kill -TERM "$1" 2>/dev/null || true
}
forward() {
  [[ -n "$holder" ]] || exit 143
  local command
  command="$(pgrep -P "$holder" || true)"
  if [[ -n "$command" ]]; then
    for command in $command; do signal_tree "$command"; done
  else
    kill -TERM "$holder"
  fi
}
trap forward INT TERM
set -m
lockf "${options[@]}" "$LOCK" "$SELF" --owned "$@" &
holder=$!
set +m
while :; do
  code=0
  wait "$holder" || code=$?
  kill -0 "$holder" 2>/dev/null || exit "$code"
done
