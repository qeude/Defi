import DefiConfig
import DefiModel
import Testing

@testable import DefiRuntime

struct NativeFocusTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func currentCommandFocusRetriesOnceWhileSelectionMatches() {
    let windowID = WindowID(rawValue: 2)

    #expect(
      nextCommandFocusRetryCount(
        currentRetryCount: 0,
        maximumRetryCount: 1,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWindowID: windowID,
        selectedWindowID: windowID
      ) == 1
    )
    #expect(
      nextCommandFocusRetryCount(
        currentRetryCount: 1,
        maximumRetryCount: 1,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWindowID: windowID,
        selectedWindowID: windowID
      ) == nil
    )
  }

  @Test
  func alreadySelectedWindowDoesNotChangeNativeFocusSelection() throws {
    var state = try makeState()
    let selected = WindowID(rawValue: 1)
    #expect(focusWindow(selected, state: &state) == false)

    #expect(
      nativeFocusChangesSelection(
        selected,
        activeMonitorID: monitorID,
        state: state
      ) == false
    )
  }

  @Test
  func focusInsideActiveWorkspaceDoesNotReportWorkspaceActivation() throws {
    var state = try makeState()

    #expect(focusWindow(WindowID(rawValue: 2), state: &state) == false)
  }

  @Test
  func differentWindowChangesNativeFocusSelection() throws {
    var state = try makeState()
    focusWindow(WindowID(rawValue: 1), state: &state)

    #expect(
      nativeFocusChangesSelection(
        WindowID(rawValue: 2),
        activeMonitorID: monitorID,
        state: state
      )
    )
  }

  @Test
  func mouseDownDefersNativeFocusMutationUntilRelease() {
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: false,
        leftMouseButtonDown: true,
        mouseReleaseFocusIntentCurrent: false,
        keyboardFocusIntentCurrent: false
      ) == false
    )
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: false,
        mouseInteractionEnded: true,
        leftMouseButtonDown: false,
        mouseReleaseFocusIntentCurrent: true,
        keyboardFocusIntentCurrent: false
      )
    )
  }

  @Test
  func nonMouseNativeFocusMutatesImmediately() {
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: false,
        leftMouseButtonDown: false,
        mouseReleaseFocusIntentCurrent: false,
        keyboardFocusIntentCurrent: false
      )
    )
  }

  @Test
  func keyboardFocusMutatesWhileMouseIsHeld() {
    #expect(
      keyboardFocusIntentIsCurrent(
        keyboardFocusIntentTimestamp: 12,
        latestCommandInputTimestamp: 11
      )
    )
    #expect(
      keyboardFocusIntentIsCurrent(
        keyboardFocusIntentTimestamp: 10,
        latestCommandInputTimestamp: 11
      ) == false
    )
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: false,
        leftMouseButtonDown: true,
        mouseReleaseFocusIntentCurrent: false,
        keyboardFocusIntentCurrent: true
      )
    )
    #expect(
      keyboardFocusPreemptsMouseGesture(
        nativeFocusAccepted: true,
        keyboardFocusIntentCurrent: true,
        leftMouseButtonDown: true,
        postReleaseSettlementActive: false
      )
    )
    #expect(
      keyboardFocusPreemptsMouseGesture(
        nativeFocusAccepted: false,
        keyboardFocusIntentCurrent: true,
        leftMouseButtonDown: true,
        postReleaseSettlementActive: false
      ) == false
    )
  }

  @Test
  func keyboardFocusPreemptsPostReleaseMouseSettlement() {
    #expect(
      keyboardFocusPreemptsMouseGesture(
        nativeFocusAccepted: true,
        keyboardFocusIntentCurrent: true,
        leftMouseButtonDown: false,
        postReleaseSettlementActive: true
      )
    )
    #expect(
      keyboardFocusPreemptsMouseGesture(
        nativeFocusAccepted: true,
        keyboardFocusIntentCurrent: true,
        leftMouseButtonDown: false,
        postReleaseSettlementActive: false
      ) == false
    )
  }

  @Test
  func newerCommandRejectsDeferredMouseReleaseFocus() {
    let focusedWindowID = WindowID(rawValue: 2)
    #expect(
      mouseReleaseFocusIntentIsCurrent(
        focusedWindowID: focusedWindowID,
        mouseFocusIntentWindowID: focusedWindowID,
        mouseFocusIntentTimestamp: 10,
        latestCommandInputTimestamp: 11,
        nativeFocusChanged: true
      ) == false
    )
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: true,
        leftMouseButtonDown: false,
        mouseReleaseFocusIntentCurrent: false,
        keyboardFocusIntentCurrent: false
      ) == false
    )
  }

  @Test
  func currentMouseReleaseAcceptsObservedFocusWithoutWindowHint() {
    #expect(
      mouseReleaseFocusIntentIsCurrent(
        focusedWindowID: WindowID(rawValue: 2),
        mouseFocusIntentWindowID: nil,
        mouseFocusIntentTimestamp: 12,
        latestCommandInputTimestamp: 11,
        nativeFocusChanged: true
      )
    )
  }

  @Test
  func dockClickWaitsForObservedManagedFocusAfterRelease() {
    let focusedWindowID = WindowID(rawValue: 2)
    let released = updatedDeferredMouseFocusIntent(
      current: nil,
      mouseFocusIntentWindowID: nil,
      mouseFocusIntentTimestamp: 12,
      focusedWindowID: WindowID(rawValue: 1),
      nativeFocusChanged: false,
      mouseInteractionEnded: true
    )
    #expect(released?.mouseInteractionEnded == true)
    #expect(released?.focusObserved == false)

    let observed = updatedDeferredMouseFocusIntent(
      current: released,
      mouseFocusIntentWindowID: nil,
      mouseFocusIntentTimestamp: 12,
      focusedWindowID: focusedWindowID,
      nativeFocusChanged: true,
      mouseInteractionEnded: false
    )
    #expect(observed?.windowID == focusedWindowID)
    #expect(observed?.focusObserved == true)
    #expect(
      mouseReleaseFocusIntentIsCurrent(
        focusedWindowID: focusedWindowID,
        mouseFocusIntentWindowID: observed?.windowID,
        mouseFocusIntentTimestamp: observed?.timestamp,
        latestCommandInputTimestamp: 11,
        nativeFocusChanged: observed?.focusObserved == true
      )
    )
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: false,
        mouseInteractionEnded: true,
        leftMouseButtonDown: false,
        deferredMouseFocusPending: true,
        deferredMouseFocusReady: true,
        mouseReleaseFocusIntentCurrent: true,
        keyboardFocusIntentCurrent: false,
        nativeFocusSuppressed: true
      )
    )
    #expect(
      !nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: false,
        leftMouseButtonDown: false,
        mouseReleaseFocusIntentCurrent: false,
        keyboardFocusIntentCurrent: false,
        nativeFocusSuppressed: true
      )
    )
  }

  @Test
  func consumedMouseFocusIntentIsNotRecreatedByPeriodicSnapshot() {
    #expect(
      updatedDeferredMouseFocusIntent(
        current: nil,
        consumedMouseFocusIntentTimestamp: 12,
        mouseFocusIntentWindowID: WindowID(rawValue: 2),
        mouseFocusIntentTimestamp: 12,
        focusedWindowID: WindowID(rawValue: 2),
        nativeFocusChanged: false,
        mouseInteractionEnded: false
      ) == nil
    )
  }

  @Test
  func linkActivationRebindsMouseIntentToNativeTarget() {
    let sourceWindowID = WindowID(rawValue: 1)
    let targetWindowID = WindowID(rawValue: 2)

    let observed = updatedDeferredMouseFocusIntent(
      current: DeferredMouseFocusIntent(
        timestamp: 12,
        windowID: sourceWindowID
      ),
      mouseFocusIntentWindowID: sourceWindowID,
      mouseFocusIntentTimestamp: 12,
      focusedWindowID: targetWindowID,
      nativeFocusChanged: true,
      mouseInteractionEnded: true
    )

    #expect(observed?.windowID == targetWindowID)
    #expect(observed?.focusObserved == true)
  }

  @Test
  func delayedMouseFocusCannotBypassNewerCommandAfterReleaseMarker() {
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: false,
        leftMouseButtonDown: false,
        deferredMouseFocusPending: true,
        deferredMouseFocusReady: true,
        mouseReleaseFocusIntentCurrent: false,
        keyboardFocusIntentCurrent: false
      ) == false
    )
  }

  @Test
  func queuedHotKeyKeepsCapturedInputOrder() {
    #expect(
      resolvedLatestCommandInputTimestamp(
        previousTimestamp: 0,
        capturedInputTimestamp: 10,
        commandHandledAt: 12
      ) == 10
    )
    #expect(
      resolvedLatestCommandInputTimestamp(
        previousTimestamp: 11,
        capturedInputTimestamp: 10,
        commandHandledAt: 12
      ) == 11
    )
    #expect(
      resolvedLatestCommandInputTimestamp(
        previousTimestamp: 11,
        capturedInputTimestamp: nil,
        commandHandledAt: 12
      ) == 12
    )
  }

  @Test
  func currentUnmutatedCancellationRestoresPreviousSelection() {
    #expect(
      commandFocusCancellationFallback(
        cancelledBeforeMutation: true,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWindowID: WindowID(rawValue: 2),
        selectedWindowID: WindowID(rawValue: 2),
        previousSelectedWindowID: WindowID(rawValue: 1),
        sourceWorkspaceID: WorkspaceID(rawValue: "dev"),
        previousSelectedWindowWorkspaceID: WorkspaceID(rawValue: "dev")
      ) == WindowID(rawValue: 1)
    )
  }

  @Test
  func exhaustedMutatedFailureRestoresPreviousSelection() {
    #expect(
      commandFocusCancellationFallback(
        cancelledBeforeMutation: false,
        rollbackAfterMutation: true,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWindowID: WindowID(rawValue: 2),
        selectedWindowID: WindowID(rawValue: 2),
        previousSelectedWindowID: WindowID(rawValue: 1),
        sourceWorkspaceID: WorkspaceID(rawValue: "dev"),
        previousSelectedWindowWorkspaceID: WorkspaceID(rawValue: "dev")
      ) == WindowID(rawValue: 1)
    )
  }

  @Test
  func inputCancelledMutationRestoresPreviousSelectionUnlessClickedAgain() {
    #expect(
      commandFocusCancellationFallback(
        cancelledBeforeMutation: false,
        rollbackAfterMutation: true,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWindowID: WindowID(rawValue: 2),
        selectedWindowID: WindowID(rawValue: 2),
        previousSelectedWindowID: WindowID(rawValue: 1),
        sourceWorkspaceID: WorkspaceID(rawValue: "dev"),
        previousSelectedWindowWorkspaceID: WorkspaceID(rawValue: "dev")
      ) == WindowID(rawValue: 1)
    )
    #expect(
      cancelledFocusTargetsRequestedWindow(
        requestedWindowID: WindowID(rawValue: 2),
        requestedWindowIsNativelyFocused: false,
        cancellingFocusTargetWindowID: WindowID(rawValue: 2)
      )
    )
  }

  @Test
  func newerClickOnRequestedWindowPreventsCancellationRollback() {
    let requestedWindowID = WindowID(rawValue: 2)

    #expect(
      cancelledFocusTargetsRequestedWindow(
        requestedWindowID: requestedWindowID,
        requestedWindowIsNativelyFocused: false,
        cancellingFocusTargetWindowID: requestedWindowID
      )
    )
    #expect(
      cancelledFocusTargetsRequestedWindow(
        requestedWindowID: requestedWindowID,
        requestedWindowIsNativelyFocused: true,
        cancellingFocusTargetWindowID: nil
      )
    )
    #expect(
      !cancelledFocusTargetsRequestedWindow(
        requestedWindowID: requestedWindowID,
        requestedWindowIsNativelyFocused: false,
        cancellingFocusTargetWindowID: WindowID(rawValue: 3)
      )
    )
  }

  @Test
  func staleOrMutatedCancellationCannotRestoreOldSelection() {
    #expect(
      commandFocusCancellationFallback(
        cancelledBeforeMutation: true,
        requestGeneration: 3,
        currentGeneration: 4,
        requestedWindowID: WindowID(rawValue: 2),
        selectedWindowID: WindowID(rawValue: 2),
        previousSelectedWindowID: WindowID(rawValue: 1),
        sourceWorkspaceID: WorkspaceID(rawValue: "dev"),
        previousSelectedWindowWorkspaceID: WorkspaceID(rawValue: "dev")
      ) == nil
    )
    #expect(
      commandFocusCancellationFallback(
        cancelledBeforeMutation: false,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWindowID: WindowID(rawValue: 2),
        selectedWindowID: WindowID(rawValue: 2),
        previousSelectedWindowID: WindowID(rawValue: 1),
        sourceWorkspaceID: WorkspaceID(rawValue: "dev"),
        previousSelectedWindowWorkspaceID: WorkspaceID(rawValue: "dev")
      ) == nil
    )
    #expect(
      commandFocusCancellationFallback(
        cancelledBeforeMutation: true,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWindowID: WindowID(rawValue: 2),
        selectedWindowID: WindowID(rawValue: 2),
        previousSelectedWindowID: WindowID(rawValue: 1),
        sourceWorkspaceID: WorkspaceID(rawValue: "dev"),
        previousSelectedWindowWorkspaceID: WorkspaceID(rawValue: "web")
      ) == nil
    )
  }

  @Test
  func currentWorkspaceFocusCancellationRestoresPreviousWorkspace() {
    let requestedWindowID = WindowID(rawValue: 2)
    let dev = WorkspaceID(rawValue: "dev")
    let web = WorkspaceID(rawValue: "web")

    #expect(
      workspaceFocusCancellationFallback(
        cancelledBeforeMutation: true,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWorkspaceID: web,
        activeWorkspaceID: web,
        previousWorkspaceID: dev,
        requestedWindowID: requestedWindowID,
        selectedWindowID: requestedWindowID
      ) == dev
    )
  }

  @Test
  func staleWorkspaceFocusCancellationCannotRollbackNewerState() {
    let requestedWindowID = WindowID(rawValue: 2)
    let dev = WorkspaceID(rawValue: "dev")
    let web = WorkspaceID(rawValue: "web")

    #expect(
      workspaceFocusCancellationFallback(
        cancelledBeforeMutation: true,
        requestGeneration: 3,
        currentGeneration: 4,
        requestedWorkspaceID: web,
        activeWorkspaceID: web,
        previousWorkspaceID: dev,
        requestedWindowID: requestedWindowID,
        selectedWindowID: requestedWindowID
      ) == nil
    )
    #expect(
      workspaceFocusCancellationFallback(
        cancelledBeforeMutation: true,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWorkspaceID: web,
        activeWorkspaceID: dev,
        previousWorkspaceID: dev,
        requestedWindowID: requestedWindowID,
        selectedWindowID: requestedWindowID
      ) == nil
    )
  }

  @Test
  func movedWindowWorkspaceFocusCancellationKeepsCommandAtomic() {
    let requestedWindowID = WindowID(rawValue: 2)
    let dev = WorkspaceID(rawValue: "dev")
    let web = WorkspaceID(rawValue: "web")

    #expect(
      workspaceFocusCancellationFallback(
        cancelledBeforeMutation: true,
        requestGeneration: 4,
        currentGeneration: 4,
        requestedWorkspaceID: web,
        activeWorkspaceID: web,
        previousWorkspaceID: dev,
        requestedWindowID: requestedWindowID,
        selectedWindowID: requestedWindowID,
        restoresPreviousWorkspace: false
      ) == nil
    )
  }

  @Test
  func pendingWorkspaceFocusRefreshRequiresSameMonitorWorkspaceAndSelection() {
    let monitor = MonitorID(rawValue: 1)
    let workspace = WorkspaceID(rawValue: "web")
    let window = WindowID(rawValue: 2)

    #expect(
      pendingWorkspaceFocusIsPreserved(
        pendingMonitorID: monitor,
        commandMonitorID: monitor,
        requestedWorkspaceID: workspace,
        activeWorkspaceID: workspace,
        requestedWindowID: window,
        selectedWindowID: window
      )
    )
    #expect(
      !pendingWorkspaceFocusIsPreserved(
        pendingMonitorID: monitor,
        commandMonitorID: MonitorID(rawValue: 2),
        requestedWorkspaceID: workspace,
        activeWorkspaceID: workspace,
        requestedWindowID: window,
        selectedWindowID: window
      )
    )
    #expect(
      !pendingWorkspaceFocusIsPreserved(
        pendingMonitorID: monitor,
        commandMonitorID: monitor,
        requestedWorkspaceID: workspace,
        activeWorkspaceID: workspace,
        requestedWindowID: window,
        selectedWindowID: WindowID(rawValue: 3)
      )
    )
  }

  @Test
  func selectedWindowOnDifferentActiveMonitorChangesSelection() throws {
    var state = try makeState()
    let selected = WindowID(rawValue: 1)
    focusWindow(selected, state: &state)

    #expect(
      nativeFocusChangesSelection(
        selected,
        activeMonitorID: MonitorID(rawValue: 2),
        state: state
      )
    )
  }

  @Test
  func acceptedNativeSelectionCarriesCursorWarpGuard() {
    #expect(
      nativeFocusCursorWarpTimestamp(
        mouseFollowsFocus: true,
        nativeFocusAccepted: true,
        selectionChanged: true,
        latestUserInputTimestamp: 12
      ) == 12
    )
    #expect(
      nativeFocusCursorWarpTimestamp(
        mouseFollowsFocus: true,
        nativeFocusAccepted: true,
        selectionChanged: false,
        latestUserInputTimestamp: 12
      ) == nil
    )
    #expect(
      nativeFocusCursorWarpTimestamp(
        mouseFollowsFocus: false,
        nativeFocusAccepted: true,
        selectionChanged: true,
        latestUserInputTimestamp: 12
      ) == nil
    )
    #expect(
      nativeFocusCursorWarpTimestamp(
        mouseFollowsFocus: true,
        nativeFocusAccepted: false,
        selectionChanged: true,
        latestUserInputTimestamp: 12
      ) == nil
    )
  }

  @Test
  func selectedRemovalPreservesWorkspaceAgainstAutomaticExternalFocus() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.localFallback, fixture.external],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.external.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 10,
        state: fixture.state
      ) == .preserve(localFallback: fixture.localFallback.id)
    )
  }

  @Test
  func inputAfterRemovalAcceptsImmediateExternalFocus() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.localFallback, fixture.external],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.external.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 11,
        state: fixture.state
      ) == .accept
    )
    #expect(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: fixture.devWorkspace,
        previousSelectedWindowID: fixture.selected.id,
        removedWindowIDs: [fixture.selected.id],
        userInputAfterWindowTopology: true,
        latestUserInputTimestamp: 11
      ) == nil
    )
  }

  @Test
  func localNativeFallbackIsAccepted() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.localFallback, fixture.external],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.localFallback.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 10,
        state: fixture.state
      ) == .accept
    )
  }

  @Test
  func delayedRemovalFallbackCarriesMonitorForViewportAlignment() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.localFallback, fixture.external],
      from: &fixture
    )
    let decision = windowRemovalFocusDecision(
      guard: guardToken,
      nativeFocusedWindowID: nil,
      nativeFocusChanged: false,
      latestUserInputTimestamp: 10,
      state: fixture.state
    )

    #expect(
      guardedWindowRemovalFocusAction(
        decision: decision,
        focusGuard: guardToken,
        newlyCreated: true
      ) == GuardedWindowRemovalFocusAction(
        windowID: fixture.localFallback.id,
        monitorID: monitorID,
        inputTimestamp: 10
      )
    )
    #expect(
      guardedWindowRemovalFocusAction(
        decision: decision,
        focusGuard: guardToken,
        newlyCreated: false
      ) == nil
    )
  }

  @Test
  func consecutiveSameApplicationClosuresRetargetLatestFallback() throws {
    let workspaceID = WorkspaceID(rawValue: "dev")
    let config = Config(workspaces: WorkspacesConfig(names: [workspaceID.rawValue]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let windows = (1...3).map { rawID in
      Window(
        id: WindowID(rawValue: UInt64(rawID)),
        appID: "terminal",
        title: "Terminal \(rawID)",
        frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      )
    }
    for window in windows {
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    focusWindow(windows[0].id, state: &state)

    reconcileWindows(Array(windows.dropFirst()), config: config, state: &state)
    let firstFallback = try #require(state.selectedWindowID(on: monitorID))
    let firstGuard = try #require(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: workspaceID,
        previousSelectedWindowID: windows[0].id,
        removedWindowIDs: [windows[0].id],
        userInputAfterWindowTopology: false,
        latestUserInputTimestamp: 10
      )
    )
    let finalWindow = try #require(
      windows.dropFirst().first(where: { $0.id != firstFallback })
    )
    reconcileWindows([finalWindow], config: config, state: &state)
    let secondGuard = try #require(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: workspaceID,
        previousSelectedWindowID: firstFallback,
        removedWindowIDs: [firstFallback],
        userInputAfterWindowTopology: false,
        latestUserInputTimestamp: 10
      )
    )
    let secondDecision = windowRemovalFocusDecision(
      guard: secondGuard,
      nativeFocusedWindowID: nil,
      nativeFocusChanged: false,
      latestUserInputTimestamp: 10,
      state: state
    )

    #expect(
      guardedWindowRemovalFocusAction(
        decision: secondDecision,
        focusGuard: secondGuard,
        newlyCreated: true
      ) == GuardedWindowRemovalFocusAction(
        windowID: finalWindow.id,
        monitorID: monitorID,
        inputTimestamp: 10
      )
    )
    #expect(firstGuard.monitorID == secondGuard.monitorID)
  }

  @Test
  func nonSelectedRemovalDoesNotCreateFocusGuard() throws {
    let fixture = try makeRemovalFixture()

    #expect(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: fixture.devWorkspace,
        previousSelectedWindowID: fixture.selected.id,
        removedWindowIDs: [fixture.localFallback.id],
        userInputAfterWindowTopology: false,
        latestUserInputTimestamp: 10
      ) == nil
    )
  }

  @Test
  func emptyWorkspaceStaysActiveWithoutInventingFallback() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.external],
      removedWindowIDs: [fixture.selected.id, fixture.localFallback.id],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.external.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 10,
        state: fixture.state
      ) == .preserve(localFallback: nil)
    )
    #expect(
      fixture.state.monitors[0].activeWorkspace == fixture.devWorkspace
    )
  }

  @Test
  func nativeFocusPreservesTwoVisibleColumns() throws {
    var state = try makeState(windowCount: 2)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 2), state: &state)

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0)
  }

  @Test
  func nativeFocusPreservesVisibleColumnInsideOverflowingStrip() throws {
    var state = try makeState(windowCount: 4)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 3), state: &state)
    state.monitors[0].workspaces[0].scrollOffset = 0.5

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.5)
  }

  @Test
  func nativeFocusAlignmentCannotOverscrollPastStripEnd() throws {
    var state = try makeState(windowCount: 4)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 4), state: &state)

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 1)
  }

  private func makeState(windowCount: Int = 2) throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for id in 1...windowCount {
      let window = Window(
        id: WindowID(rawValue: UInt64(id)),
        appID: "app-\(id)",
        title: "Window \(id)",
        frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      )
      try discoverWindow(
        window,
        decision: RuleDecision(followFocus: true),
        state: &state
      )
    }
    return state
  }

  private struct RemovalFixture {
    var state: RuntimeState
    let config: Config
    let devWorkspace: WorkspaceID
    let selected: Window
    let localFallback: Window
    let external: Window
  }

  private func makeRemovalFixture() throws -> RemovalFixture {
    let devWorkspace = WorkspaceID(rawValue: "dev")
    let webWorkspace = WorkspaceID(rawValue: "web")
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"])
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let selected = Window(
      id: WindowID(rawValue: 1),
      appID: "selected",
      title: "Selected",
      frame: Rect(x: 0, y: 0, width: 800, height: 700),
      monitorID: monitorID
    )
    let localFallback = Window(
      id: WindowID(rawValue: 2),
      appID: "fallback",
      title: "Fallback",
      frame: Rect(x: 0, y: 0, width: 800, height: 700),
      monitorID: monitorID
    )
    let external = Window(
      id: WindowID(rawValue: 3),
      appID: "external",
      title: "External",
      frame: Rect(x: 0, y: 0, width: 800, height: 700),
      monitorID: monitorID
    )
    try discoverWindow(selected, decision: RuleDecision(), state: &state)
    try discoverWindow(localFallback, decision: RuleDecision(), state: &state)
    try discoverWindow(
      external,
      decision: RuleDecision(workspace: webWorkspace),
      state: &state
    )
    focusWindow(selected.id, state: &state)
    return RemovalFixture(
      state: state,
      config: config,
      devWorkspace: devWorkspace,
      selected: selected,
      localFallback: localFallback,
      external: external
    )
  }

  private func removeSelectedWindow(
    keeping windows: [Window],
    removedWindowIDs: Set<WindowID>? = nil,
    from fixture: inout RemovalFixture
  ) throws -> WindowRemovalFocusGuard {
    reconcileWindows(windows, config: fixture.config, state: &fixture.state)
    return try #require(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: fixture.devWorkspace,
        previousSelectedWindowID: fixture.selected.id,
        removedWindowIDs: removedWindowIDs ?? [fixture.selected.id],
        userInputAfterWindowTopology: false,
        latestUserInputTimestamp: 10
      )
    )
  }

  private func setColumnWidths(_ width: ColumnWidth, state: inout RuntimeState) {
    for index in state.monitors[0].workspaces[0].columns.indices {
      state.monitors[0].workspaces[0].columns[index].width = width
    }
  }
}
