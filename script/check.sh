#!/usr/bin/env bash
# The isolated feedback loop: pure tests and simulated-desktop scenarios, run in parallel
# processes under DEFI_ISOLATED=1 so any real macOS resource traps. Safe while Defi runs.
#   check.sh            run every lane; exit 1 when a lane fails, 2 on a setup error
#   SHARDS=n check.sh   split the simulated-desktop campaign across n processes (default: half the cores, 1 to 4)
#   FAIL_FAST=1 check.sh  stop every lane at the first failure (mutation runs)
# Each lane logs to $LOGS/<lane>.log; failing lanes print their failure reports.
# The lanes only run built products, so they share .build without its SwiftPM lock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="${LOGS:-$ROOT/.build/check}"
# Lanes compete for CPU; timing-sensitive tests (IPC timeouts) fail on an oversubscribed machine.
cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
default_shards=$((cores / 2)); ((default_shards < 1)) && default_shards=1; ((default_shards > 4)) && default_shards=4
SHARDS="${SHARDS:-$default_shards}"
[[ "$SHARDS" =~ ^[1-9][0-9]*$ ]] || { echo "SHARDS must be a positive integer, got '$SHARDS'" >&2; exit 2; }
PURE='DefiModelTests|DefiCoreTests|DefiConfigTests|DefiRuntimeTests|RealResourceGuardTests|WindowClassificationFixtureTests|TraceReplayTests|PermissionScenarioTests|KnownSuspectMatchTests|FidelityTraceTests'
# DefiDaemon and the DefiMacOS unit suites that run under the guard: input monitor, focus and frame
# writers, discovery.
# Suites left out open real windows or launch processes, or trap on a real resource throughout.
MACOS='AXTimeoutBatchTests|AccessibilityPermissionMonitorTests|BorderGeometryReadTests|BudgetedFreshReadPartitionTests|CheatsheetHotKeyTests|CheatsheetLayoutTests|ClampedFrameWriteTests|ConfigMigrationTests|CursorTests|DefiSettingsModelTests|DeinitWithTaskLocalTests|DelayedObservationCampaignRegressionTests|DisplayArrangementControllerTests|FocusMutationTests|FrameCommitTests|FrameCommitTransitionTests|FrameGeometryReadTests|FrameSettlementVerificationTests|HotKeyModifierReleaseTests|HotKeyRegistrationStatusTests|HotKeyTests|IncrementalDiscoveryRegressionTests|KeyboardLayoutLabelTests|KeyboardLayoutResolverTests|LosslessTOMLDocumentTests|MenuBarTests|MonitorTests|MousePressApplicationTests|NativeWindowTabDiscoveryTests|ObservationCampaignRegressionTests|OverviewHotKeyTests|OverviewNavigationTests|OverviewPreviewTests|OverviewScrollTests|PlatformEventTests|ProcessDiscoveryRetryRegressionTests|ResourceFluidityPolicyTests|RibbonProxyRecordingTests|RibbonProxyTests|SettingsSearchTests|UserInputTrackingTests|WindowBorderSyncTests|WindowBorderTests|WindowClassificationReviewFeedbackTests|WindowDiscoveryTests|WindowSnapshotStabilityTests'
# Tests in those suites that reach a real resource (Accessibility elements, AppKit panels).
MACOS_SKIP='applicationObservationAlsoRecoversAfterBackoff|borderPanelsFloatOnlyWhileActiveWindowIsFrontmost|borderTranslationKeepsFramesAndRepairsStacking|cachelessUnrequestedApplicationDoesNotTriggerAnotherWindowListRead|closingWindowRingStaysHiddenWhilePlansStillTrackIt|deferredReadsDoNotConsumeRetriesAndExhaustionKeepsBindings|eachDisplayOverlayHidesOnlyItsOwnBordersUntilEveryOneLands|failedMoveNeverReplaysAFrameCapturedBeforeANewerMove|failedReadsAreDeliveredOnce|failedRetiredEnhancedUIRestoreRemainsRecoverable|initialInactiveBorderBatchReservesEveryAllocation|monitorBindingSelectsTheNeighborMonitorsFocusedWindow|monitorShortcutsFollowTheArrangedDeskOverTechnicalFrames|mouseDragAndReleaseSampleNativeGeometryWithoutNotificationsOrSnapshotCompletion|moveToMonitorDropsTheSelectionAfterTheNeighborsFocusedColumn|notificationIngressCoalescesBeforeReadsAndWriterRenderingIsCacheOnly|ownedSurfaceWindowIDRemainsReadableAfterRapidOverlayChanges|parkedWindowStoppedByItsTitleBarNeedsNoRepair|retiredEnhancedUIRestoreInvalidatesARediscoveredDisable|selectionHandoffKeepsNativeBorderPanelsOrderedAndTransparent|selectionHandoffShowsTheNewWindowWhenOnlyTheOldOneWasHidden|settingsSwitchSharesOverlayWithScreenRecordings|skyLightMoveStaysAuthoritativeAcrossStackingAndReveal|supersededOffscreenWriteDoesNotRetryAnObsoleteTarget|suppressedBordersStayHiddenUntilRestored|swiftUIMenuKeepsWorkspaceSelectionAndCommandRouting|transientDiscoveryLossKeepsTheSameSerializedAXLane|translationReusesBorderPathsAndSelectionBacking|unchangedSelectionPreservesStackingUntilExplicitObservation|unsupportedWindowObservationDoesNotDisableItsSiblingOrKeepRetrying|untrackedWindowBordersAreReusedInsteadOfCreatingPanels|windowObservationRecoversAfterTransientFailures'
mkdir -p "$LOGS" && LOGS="$(cd "$LOGS" && pwd)" || exit 2
rm -f "$LOGS"/*.log

cd "$ROOT" || exit 2
export DEFI_ISOLATED=1
# IPC tests use real socket timeouts, so they run alone before the CPU-heavy lanes start.
if swift test --skip-build --ignore-lock --filter DefiIPCTests >"$LOGS/ipc.log" 2>&1; then
  echo "ok    ipc"
else
  echo "FAIL  ipc ($LOGS/ipc.log)"; grep -E 'recorded an issue|error' "$LOGS/ipc.log" | head -20; exit 1
fi
lanes=(pure)
DEFI_SCENARIO_SHARD=0/1 swift test --skip-build --ignore-lock --filter "$PURE" >"$LOGS/pure.log" 2>&1 &
pids=($!)
lanes+=(macos)
swift test --skip-build --ignore-lock --filter "DefiMacOSTests\\.($MACOS)\\b|DefiDaemonTests" \
  --skip "[./]($MACOS_SKIP)\\(" >"$LOGS/macos.log" 2>&1 &
pids+=($!)
for ((shard = 0; shard < SHARDS; shard++)); do
  lanes+=("desktop-$shard")
  DEFI_SCENARIO_SHARD="$shard/$SHARDS" swift test --skip-build --ignore-lock --filter FocusInvariantHarnessTests \
    >"$LOGS/desktop-$shard.log" 2>&1 &
  pids+=($!)
done

# FAIL_FAST=1 (mutation runs): the first failing lane stops the others; one failure is enough.
if [[ "${FAIL_FAST:-}" == 1 ]]; then
  while :; do
    running=0
    for index in "${!pids[@]}"; do
      pid="${pids[$index]}"
      if kill -0 "$pid" 2>/dev/null; then
        running=1
      elif ! wait "$pid"; then
        echo "FAIL  ${lanes[$index]} ($LOGS/${lanes[$index]}.log)"
        for other in "${pids[@]}"; do pkill -P "$other" 2>/dev/null; kill "$other" 2>/dev/null; done
        exit 1
      fi
    done
    ((running)) || break
    sleep 0.5
  done
fi

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
