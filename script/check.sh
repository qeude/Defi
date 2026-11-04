#!/usr/bin/env bash
# The isolated feedback loop: pure tests and simulated-desktop scenarios, run in parallel
# processes under DEFI_ISOLATED=1 so any real macOS resource traps. Safe while Defi runs.
#   check.sh            run every lane; exit 1 when one fails
#   SHARDS=n check.sh   split the simulated-desktop campaign across n processes (default: half the cores, 1 to 4)
# Each lane logs to $LOGS/<lane>.log; failing lanes print their failure reports.
# The lanes only run built products, so they share .build without its SwiftPM lock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="${LOGS:-$ROOT/.build/check}"
# Lanes compete for CPU; timing-sensitive tests (IPC timeouts) fail on an oversubscribed machine.
cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
default_shards=$((cores / 2)); ((default_shards < 1)) && default_shards=1; ((default_shards > 4)) && default_shards=4
SHARDS="${SHARDS:-$default_shards}"
PURE='DefiModelTests|DefiCoreTests|DefiConfigTests|DefiRuntimeTests|DefiIPCTests|RealResourceGuardTests|WindowClassificationFixtureTests|TraceReplayTests'
mkdir -p "$LOGS"
rm -f "$LOGS"/*.log

cd "$ROOT" || exit 1
export DEFI_ISOLATED=1
lanes=(pure)
DEFI_SCENARIO_SHARD=0/1 swift test --skip-build --ignore-lock --filter "$PURE" >"$LOGS/pure.log" 2>&1 &
pids=($!)
for ((shard = 0; shard < SHARDS; shard++)); do
  lanes+=("desktop-$shard")
  DEFI_SCENARIO_SHARD="$shard/$SHARDS" swift test --skip-build --ignore-lock --filter FocusInvariantHarnessTests \
    >"$LOGS/desktop-$shard.log" 2>&1 &
  pids+=($!)
done

failed=0
for index in "${!pids[@]}"; do
  if wait "${pids[$index]}"; then
    echo "ok    ${lanes[$index]}"
  else
    failed=1
    echo "FAIL  ${lanes[$index]} ($LOGS/${lanes[$index]}.log)"
    grep -E -A40 '\] FAILURE|Fatal error|recorded an issue' "$LOGS/${lanes[$index]}.log" | head -80
  fi
done
grep -h -E 'scenarios from seed|known suspect' "$LOGS"/*.log | sort | uniq -c | sed 's/^ */  /'
exit "$failed"
