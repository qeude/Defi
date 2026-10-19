#!/usr/bin/env bash
# Drives width changes on the FOCUSED window and reports whether each one animated.
# Pairs return to the start: maximize-column x2, cycle-width next then prev.
# Usage: resize_check.sh [evidence-dir]   (run under `python3 script/desktop_lock.py --wait`)
set -u
out="${1:-dist/verification/evidence-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$out"
defi status > "$out/before.status" || { echo "daemon unreachable"; exit 1; }
focused="$(tr ' ' '\n' < "$out/before.status" | sed -n 's/^focused=//p')"
[ "$focused" = none ] && { echo "no focused window"; exit 1; }
fail=0
for cmd in maximize-column maximize-column "cycle-width next" "cycle-width prev"; do
  t0="$(defi trace | tail -1 | cut -d" " -f1)" # trace is a 512-line ring: slice by timestamp
  defi $cmd >/dev/null; sleep 1.2
  defi trace | awk -v t="$t0" '$1 > t' > "$out/trace-${cmd// /-}-$(date +%s).log"
  last="$(ls -t "$out"/trace-*.log | head -1)"
  line="$(grep -E ' cadence g=' "$last" | grep -B0 -v 'frames=1 ' | tail -1)"
  src="$(grep -E ' submit g=.*command-' "$last" | tail -1 | sed -n 's/.*source=\([^ ]*\).*/\1/p')"
  wr="$(echo "$line" | sed -n 's/.*appliedIntermediateWrites=\([0-9]*\).*/\1/p')"
  obs="$(grep -E 'command-converged' "$last" | tail -1 | sed -n 's/.*ms=\(.*\)/\1/p')"
  pos="$(grep -cE ' submit g=.*animated=[1-9]' "$last")"
  verdict=ANIMATED; [ -z "$src" ] && verdict=NO-TRACE && fail=1
  [ "$verdict" = ANIMATED ] && { [ -z "$wr" ] || [ "$wr" -eq 0 ]; } && verdict=JUMP-NO-STEPS && fail=1
  echo "$cmd: $verdict source=${src:-none} animatedFrames=$pos intermediateWrites=${wr:-none} convergedMs=${obs:-none}"
done
defi status > "$out/after.status"
tr ' ' '\n' < "$out/after.status" | grep -E '^(drift|droppedFrames|animating|axPending|resize)=' | tr '\n' ' '; echo
grep -q 'drift=0\[\]' "$out/after.status" || { echo "FAIL: drift"; fail=1; }
echo "evidence: $out"; exit $fail
