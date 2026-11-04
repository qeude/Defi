#!/usr/bin/env bash
# Mutation check for the isolated loop: plants one known bug at a time, runs script/check.sh,
# and reports whether the loop kills it. Measures the loop's detection power on today's code.
#   mutate.sh          every mutant; exit 1 when one survives
#   ONLY=regex mutate.sh   only mutants whose description matches
# Each mutant is "file^original fragment^replacement^description". Sources are restored
# after every mutant, even on interruption.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
MUTANTS=(
  'Sources/DefiCore/Layout.swift^let left = max(settings.innerHorizontalGap, 0)^let left = max(settings.innerHorizontalGap, 0) / 2^columns keep half their inner gap'
  'Sources/DefiCore/Layout.swift^let top = windowIndex == 0 ? max(settings.outerTopGap, 0) : verticalInner^let top = verticalInner^first row ignores the outer top gap'
  'Sources/DefiCore/Types.swift^public let parkedSliverWidth = 1.0^public let parkedSliverWidth = 40.0^parked windows leave 40 pt on screen'
  'Sources/DefiRuntime/RuntimeState.swift^$0.kind == .ordinary && $0.isEmpty && $0.id != activeWorkspace^$0.kind == .ordinary && false^empty inactive workspaces are never removed'
  'Sources/DefiCore/StackConstraints.swift^guard windowIDs.count > 1 else { return .fits }^return .fits^every stack fits'
  'Sources/DefiCore/Layout.swift^guard let minimum, minimum > requested + tiledWidthRoundingLimit else { return 0 }^guard let minimum, minimum > requested + 1e12 else { return 0 }^minimum widths are ignored'
  'Sources/DefiCore/Workspace.swift^workspace.focusedColumn = min(workspace.focusedColumn + 1, workspace.columns.count - 1)^workspace.focusedColumn = min(workspace.focusedColumn + 2, workspace.columns.count - 1)^focus right skips a column'
  'Sources/DefiCore/Workspace.swift^workspace.focusedColumn = adjustedTarget^workspace.focusedColumn = 0^joining a column focuses the first column'
  'Sources/DefiRuntime/FocusSelection.swift^    || commandCapturedAfterRequest^    || false^a newer key press no longer keeps the cancelled focus target (#216)'
  'Sources/DefiCore/Workspace.swift^let index = min(workspace.focusedColumn + 1, workspace.columns.count)^let index = min(workspace.focusedColumn, workspace.columns.count)^new windows open left of the focused column (layout)'
  'Sources/DefiCore/Workspace.swift^workspace.columns.swapAt(source, target)^workspace.columns.swapAt(source, source)^move left/right shifts focus without moving the column (layout)'
  'Sources/DefiCore/Workspace.swift^: min(workspace.focusedColumn, workspace.columns.count - 1)^: max(workspace.focusedColumn - 1, 0)^closing a column always focuses its left neighbour (layout)'
  'Sources/DefiCore/Workspace.swift^column.width = column.preMaximizedWidth ?? .fraction(defaultWidth)^column.width = .fraction(defaultWidth)^unmaximize forgets the width before maximize (layout)'
  'Sources/DefiCore/Workspace.swift^at: columnIndex + 1^at: columnIndex^unjoin opens the column left while focus moves right (layout)'
  'Sources/DefiCore/Parking.swift^let sides = frame.x + width / 2 < left + display.width / 2^let sides = frame.x + width / 2 > left + display.width / 2^hidden windows park at the far side edge (parking)'
  'Sources/DefiCore/WorkspaceScrolling.swift^: min(max(workspace.scrollOffset, minimumScroll), maximumScroll)^: maximumScroll^reveal scrolling always left-aligns the focused column (scroll)'
  'Sources/DefiCore/Layout.swift^widths[absorber] -= deviation^widths[absorber] += deviation^neighbour absorbs a snapped width with the wrong sign (layout)'
  'Sources/DefiCore/Layout.swift^strip.width = max(viewport.width - left - right, 1)^strip.width = max(viewport.width - left, 1)^strip ignores the right outer gap (layout)'
  'Sources/DefiRuntime/WorkspaceCommands.swift^    state.monitors[monitorIndex].workspaces[targetIndex].kind != .trailing^    true^workspace reorder swaps past the trailing workspace (lifecycle)'
  'Sources/DefiRuntime/RuntimeState.swift^return (monitorIndex, min(position - 1, monitors[monitorIndex].workspaces.count - 1))^return (monitorIndex, min(position, monitors[monitorIndex].workspaces.count - 1))^workspace position N selects N+1 (workspace routing)'
  'Sources/DefiRuntime/WindowReconciliation.swift^    || (isFrontmostAppSpawn && !window.floating)^    || false^windows spawned by the frontmost app no longer take focus (reconciliation)'
  'Sources/DefiRuntime/RuntimeState.swift^if workspace.kind == .trailing && workspace.isEmpty { continue }^if workspace.isEmpty { continue }^display loss drops empty ordinary and named workspaces (monitor migration)'
  'Sources/DefiRuntime/FocusSelection.swift^    || state.selectedWindowID(on: focusedMonitorID) != windowID^    || false^native focus on another window of the same monitor never selects it (focus)'
  'Sources/DefiRuntime/FocusSelection.swift^applicationActivation && switchesWorkspace && latestUserInputTimestamp^applicationActivation && latestUserInputTimestamp^every echoed activation is rejected, not only workspace switches (focus)'
  'Sources/DefiRuntime/FocusSelection.swift^if keyboardFocusIntentCurrent && nativeFocusChanged {^if nativeFocusChanged {^native focus changes mutate selection without keyboard intent (focus)'
  'Sources/DefiRuntime/DeferredFocusSelection.swift^max(previousTimestamp, capturedInputTimestamp ?? commandHandledAt)^capturedInputTimestamp ?? commandHandledAt^latest command input timestamp can move backwards (focus)'
  'Sources/DefiRuntime/FocusState.swift^static let commandFocusRetryLimit = 3^static let commandFocusRetryLimit = 0^slow apps get no command focus retry (#210) (focus)'
  'Sources/DefiRuntime/FocusState.swift^cancelledBeforeMutation: result == .cancelled || result == .failed,^cancelledBeforeMutation: result == .cancelled,^failed workspace focus keeps the new workspace (focus)'
  'Sources/DefiRuntime/FocusState.swift^      state.location(containing: fallback)?.monitorID == request.monitorID^      true^command focus rollback may select a window on another monitor (focus)'
  'Sources/DefiDaemon/DaemonCommandFocus.swift^restoresPreviousFocusOnFailure: false,^restoresPreviousFocusOnFailure: true,^failed command focus falls back to the window it left (#210) (daemon focus)'
  'Sources/DefiMacOS/AXFocusWriterExecution.swift^            || !operations.applicationIsActive(request.processID),^            || false,^inactive applications are not activated on focus (AX focus writer)'
  'Sources/DefiMacOS/AXFocusWriterExecution.swift^    return inputGuardIsCurrent(queued.request)^    return true^focus writes ignore newer user input (AX focus writer)'
  'Sources/DefiMacOS/AXFocusModels.swift^(requested || validatesCurrentFocus) && !targetIsFocused^(requested || validatesCurrentFocus)^already-focused windows get a redundant AX focus write (AX focus writer)'
  'Sources/DefiMacOS/UserInputTracking.swift^guard latestTimestamp > timestamp else {^guard latestTimestamp >= timestamp else {^focus recovery target reported without newer input (input tracker)'
  'Sources/DefiMacOS/HotKeys.swift^guard let command = bindings[key], !keyboardCaptured() else {^guard let command = bindings[key] else {^hotkeys fire while the keyboard is captured (input monitor)'
  'Sources/DefiMacOS/FrameCommit.swift^position: abs(reference.x - target.x) >= 0.5^position: abs(reference.x - target.x) >= 0^unchanged frames are rewritten every layout (frames)'
  'Sources/DefiMacOS/FrameCommit.swift^size: !positionsOnly^size: true^position-only navigation also writes sizes (frames)'
  'Sources/DefiMacOS/FrameCommit.swift^return previousTarget ?? nativeReference()^return nativeReference() ?? previousTarget^write diffing uses the stale native frame over the last target (frames)'
  'Sources/DefiMacOS/AXFrameCoordinatorSettlement.swift^    return latestGeneration == generation^    return true^superseded frame writes are never treated as stale (frame coordinator)'
  'Sources/DefiMacOS/AXFrameCoordinator.swift^writes: preservedWrites,^writes: writes,^a newer frame drops superseded size writes (frame coordinator)'
  'Sources/DefiMacOS/FrameCommit.swift^return [visibleWindowIDs, windowIDs.intersection(parkedWindowIDs)]^return [windowIDs.intersection(parkedWindowIDs), visibleWindowIDs]^parking writes run before visible writes (frame coordinator)'
  'Sources/DefiMacOS/FrameCommitPolicy.swift^&& actual.y <= target.y + 1 && actual.y >= target.y - parkingVerticalSlack^&& actual.y <= target.y + 1 && actual.y >= target.y - 1^tall title bar parking is repaired forever (frame policy)'
  'Sources/DefiMacOS/Platform.swift^if subrole == kAXStandardWindowSubrole, hasCloseButton, canResize, canGrow {^if subrole == kAXStandardWindowSubrole, hasCloseButton, canGrow {^fixed-size standard windows are tiled (classification)'
  'Sources/DefiMacOS/Platform.swift^return previousDisposition ?? .unavailable^return .unavailable^transient AX errors forget the previous disposition (classification)'
  'Sources/DefiMacOS/SnapshotEngine.swift^guard rawWindows?.count == 1,^guard rawWindows?.isEmpty == false,^activation fallback admits multi-window apps (snapshot focus)'
  'Sources/DefiMacOS/SnapshotEngine.swift^return candidates.count == 1 ? candidates[0].id : nil^return candidates.first?.id^stable focus guesses the first window of a multi-window app (snapshot focus)'
  'Sources/DefiMacOS/SnapshotEngine.swift^if resolvedProcessID != focusedProcessID && !requiresConfirmedWindow {^if !requiresConfirmedWindow {^cached window wins over the AX focused window (snapshot focus)'
  'Sources/DefiRuntime/MouseReordering.swift^if sourceColumnIndex < targetIndex { targetIndex -= 1 }^if sourceColumnIndex > targetIndex { targetIndex -= 1 }^stack drop after removing a column targets the wrong column (mouse)'
  'Sources/DefiRuntime/MouseReordering.swift^leavesColumn && index == layout.sourceColumnIndex ? nil^index == layout.sourceColumnIndex ? nil^drop slot ignores a stacked source column (mouse)'
  'Sources/DefiCore/DisplayArrangement.swift^$0.y + $0.height > $1.y^$0.y + $0.height < $1.y^staircase applied only without vertical overlap (display staircase)'
  'Sources/DefiRuntime/OverviewRuntime.swift^let sourceColumnIndex, sourceColumnIndex < insertionIndex^let sourceColumnIndex, sourceColumnIndex > insertionIndex^overview drop to the right lands one column off (overview)'
  'Sources/DefiMacOS/WindowBorderPlanning.swift^UInt8((color >> 24) & 0xff)^UInt8(color & 0xff)^border alpha read from the wrong channel (borders)'
  'Sources/DefiCore/MonitorRouting.swift^$0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 < $1.1^$0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 > $1.1^monitor focus picks the farthest display (monitor routing)'
)

restore() { [ -n "${current:-}" ] && [ -f "$current.mutate-backup" ] && mv "$current.mutate-backup" "$current"; current=; }
trap restore EXIT
trap 'restore; exit 130' INT TERM

# One run per checkout: concurrent runs would share the backups and plant into each other.
LOCK="$ROOT/.build/mutate.lock"
mkdir -p "$ROOT/.build"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "another mutation run holds $LOCK" >&2; exit 2
fi
trap 'restore; rmdir "$LOCK"' EXIT

# A kill only means something against a passing baseline.
if ! swift build --build-tests >/dev/null 2>&1; then echo "baseline does not build" >&2; exit 2; fi
if ! ./script/check.sh >/dev/null 2>&1; then echo "baseline make check fails; fix it first" >&2; exit 2; fi

survivors=0
skipped=0
ran=0
for mutant in "${MUTANTS[@]}"; do
  IFS='^' read -r current original replacement description <<<"$mutant"
  [[ -z "${ONLY:-}" || "$description" =~ $ONLY ]] || continue
  ran=$((ran + 1))
  cp "$current" "$current.mutate-backup"
  if ! ORIGINAL="$original" REPLACEMENT="$replacement" perl -0pi -e '$o = quotemeta($ENV{ORIGINAL}); s/$o/$ENV{REPLACEMENT}/ or exit 3' "$current"; then
    echo "SKIP     $description (original line not found)"; skipped=$((skipped + 1)); restore; continue
  fi
  if ! swift build --build-tests >/dev/null 2>&1; then
    echo "SKIP     $description (does not compile)"; skipped=$((skipped + 1)); restore; continue
  fi
  output="$(./script/check.sh 2>&1)"; status=$?
  if [ "$status" -eq 0 ]; then
    echo "SURVIVED $description"; survivors=$((survivors + 1))
  elif [ "$status" -ne 1 ] || ! grep -qE 'recorded an issue|Test Case .* failed|Fatal error|unexpected signal' "$ROOT"/.build/check/*.log 2>/dev/null; then
    # A kill needs a failing test or a crash in a lane log; anything else is a setup error.
    echo "ERROR    $description (check.sh exited $status without a test failure)"; restore; exit 2
  else
    # Which lanes and tests caught it: the new scenarios, or the existing unit tests.
    lanes="$(grep -oE '^FAIL +[a-z0-9-]+' <<<"$output" | awk '{print $2}' | sort -u | tr '\n' ' ')"
    tests="$(grep -ohE '(Test|Test Case) [^ ]+ (recorded an issue|failed)' "$ROOT"/.build/check/*.log 2>/dev/null | awk '{print $2}' | sed -E 's/\(.*//' | sort -u | head -3 | tr '\n' ' ')"
    echo "KILLED   $description [lanes: ${lanes}tests: ${tests}]"
  fi
  restore
done
swift build --build-tests >/dev/null 2>&1 || { echo "rebuilding the restored sources failed" >&2; exit 2; }
echo "$survivors of $ran mutants survived, $skipped skipped"
((ran > skipped)) || { echo "every mutant was skipped" >&2; exit 2; }
[ "$survivors" -eq 0 ]
