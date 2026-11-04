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
if [[ "$wait" -eq 1 ]]; then
  exec lockf -k "$LOCK" "$SELF" --owned "$@"
fi
exec lockf -k -s -t 0 "$LOCK" "$SELF" --owned "$@"
