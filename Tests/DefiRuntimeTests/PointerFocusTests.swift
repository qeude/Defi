import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct PointerFocusTests {
  @Test
  func pointerFocusRecoveryTargetsLogicalWindowAfterUnmanagedExit() {
    let logicalWindowID = WindowID(rawValue: 1)

    #expect(
      pointerFocusRecoveryWindowID(
        pointerWindowIsManaged: false,
        pointerWindowIsReady: false,
        targetAccepted: false,
        logicalFocusWindowID: logicalWindowID
      ) == logicalWindowID
    )
    #expect(
      pointerFocusRecoveryWindowID(
        pointerWindowIsManaged: true,
        pointerWindowIsReady: false,
        targetAccepted: false,
        logicalFocusWindowID: logicalWindowID
      ) == nil
    )
  }
  @Test
  func rejectedPointerTargetDoesNotAdvanceFocusGuard() {
    #expect(
      pointerFocusGuardTimestamp(
        pointerTimestamp: 12,
        targetAccepted: false
      ) == nil
    )
    #expect(
      pointerFocusGuardTimestamp(
        pointerTimestamp: 12,
        targetAccepted: true
      ) == 12
    )
  }

  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 800)

  @Test
  func pointerFocusChangesVisibleSelectionWithoutScrolling() throws {
    var state = try makeState(columnWidths: [0.4, 0.4])
    let originalOffset = state.monitors[0].workspaces[0].targetScrollOffset

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == monitorID)
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 2))
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == originalOffset)
  }

  @Test
  func pointerFocusPreviewDoesNotMutateSelection() throws {
    let state = try makeState(columnWidths: [0.4, 0.4])
    let original = state

    let focusedMonitor = pointerFocusMonitorWithoutScrolling(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == monitorID)
    #expect(state == original)
  }

  @Test
  func pointerFocusRejectsTargetThatWouldScrollStrip() throws {
    var state = try makeState(columnWidths: [0.5, 0.5, 0.5])
    let original = state

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 3),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == nil)
    #expect(state == original)
  }

  @Test
  func pointerFocusRejectsCenteringThatWouldMoveVisibleStrip() throws {
    var state = try makeState(
      columnWidths: [0.4, 0.4, 0.4],
      centerFocusedColumn: .always
    )
    let original = state

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == nil)
    #expect(state == original)
  }

  @Test
  func repeatedPointerFocusDoesNothing() throws {
    var state = try makeState(columnWidths: [0.4, 0.4])

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 1),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == nil)
  }

  @Test
  func alreadySelectedPointerTargetCanRestoreNativeFocus() throws {
    var state = try makeState(columnWidths: [0.4, 0.4])
    let original = state

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 1),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport],
      acceptsAlreadySelectedWindow: true
    )

    #expect(focusedMonitor == monitorID)
    #expect(state == original)
  }

  @Test
  func cursorWarpRequiresEnabledKeyboardInput() {
    #expect(
      keyboardCursorWarpTimestamp(
        mouseFollowsFocus: true,
        capturedInputTimestamp: 12
      ) == 12
    )
    #expect(
      keyboardCursorWarpTimestamp(
        mouseFollowsFocus: true,
        capturedInputTimestamp: nil
      ) == nil
    )
    #expect(
      keyboardCursorWarpTimestamp(
        mouseFollowsFocus: false,
        capturedInputTimestamp: 12
      ) == nil
    )
  }

  @Test
  func commandFocusAlwaysKeepsAnInputGuard() {
    #expect(
      commandFocusInputTimestamp(
        capturedInputTimestamp: 12,
        commandHandledAt: 14
      ) == 12
    )
    #expect(
      commandFocusInputTimestamp(
        capturedInputTimestamp: nil,
        commandHandledAt: 14
      ) == 14
    )
  }

  @Test
  func pendingPointerFocusRequiresSameWindowAndNoNewerInput() {
    let windowID = WindowID(rawValue: 42)

    #expect(
      pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: windowID,
        requestGeneration: 4,
        currentGeneration: 4,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
    #expect(
      !pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: WindowID(rawValue: 43),
        requestGeneration: 4,
        currentGeneration: 4,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
    #expect(
      !pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: windowID,
        requestGeneration: 4,
        currentGeneration: 4,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 13
      )
    )
  }

  @Test
  func newerPointerTransitionInvalidatesRequestWithoutGeneralInput() {
    #expect(
      !pointerFocusRequestIsCurrent(
        requestGeneration: 4,
        currentGeneration: 5,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
    #expect(
      !pointerFocusRetryIsCurrent(
        pendingWindowID: WindowID(rawValue: 42),
        windowUnderPointerID: WindowID(rawValue: 42),
        requestGeneration: 4,
        currentGeneration: 5,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
  }

  @Test
  func pointerFocusIntentOnlyYieldsToNewerInput() {
    #expect(
      pointerFocusIntentIsCurrent(
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
    #expect(
      !pointerFocusIntentIsCurrent(
        pointerTimestamp: 12,
        latestUserInputTimestamp: 13
      )
    )
  }

  @Test
  func stalePointerCancellationDoesNotRearmTransition() {
    #expect(
      cancelledPointerFocusShouldRearm(
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
    #expect(
      !cancelledPointerFocusShouldRearm(
        pointerTimestamp: 12,
        latestUserInputTimestamp: 13
      )
    )
  }

  @Test
  func commandFocusRefreshesPendingOrSubmittedPreservedTarget() {
    let windowID = WindowID(rawValue: 42)

    #expect(
      commandFocusIsPreserved(
        pendingWindowID: windowID,
        submittedWindowID: nil,
        selectedWindowID: windowID
      )
    )
    #expect(
      commandFocusIsPreserved(
        pendingWindowID: nil,
        submittedWindowID: windowID,
        selectedWindowID: windowID
      )
    )
    #expect(
      !commandFocusIsPreserved(
        pendingWindowID: WindowID(rawValue: 43),
        submittedWindowID: nil,
        selectedWindowID: windowID
      )
    )
    #expect(
      !commandFocusIsPreserved(
        pendingWindowID: nil,
        submittedWindowID: nil,
        selectedWindowID: windowID
      )
    )
  }

  @Test
  func supersededCommandFocusCompletionCannotRollbackSelection() {
    let windowID = WindowID(rawValue: 42)

    #expect(
      commandFocusCompletionIsCurrent(
        submittedWindowID: windowID,
        submittedGeneration: 4,
        completedWindowID: windowID,
        completedGeneration: 4
      )
    )
    #expect(
      !commandFocusCompletionIsCurrent(
        submittedWindowID: nil,
        submittedGeneration: nil,
        completedWindowID: windowID,
        completedGeneration: 4
      )
    )
    #expect(
      !commandFocusCompletionIsCurrent(
        submittedWindowID: WindowID(rawValue: 43),
        submittedGeneration: 5,
        completedWindowID: windowID,
        completedGeneration: 4
      )
    )
  }

  @Test
  func pointerFocusRetryIsBoundedAndRequiresCurrentIntent() {
    #expect(
      nextPointerFocusRetryCount(
        currentRetryCount: 0,
        maximumRetryCount: 1,
        intentCurrent: true
      ) == 1
    )
    #expect(
      nextPointerFocusRetryCount(
        currentRetryCount: 1,
        maximumRetryCount: 1,
        intentCurrent: true
      ) == nil
    )
    #expect(
      nextPointerFocusRetryCount(
        currentRetryCount: 0,
        maximumRetryCount: 1,
        intentCurrent: false
      ) == nil
    )
  }

  @Test
  func focusReadinessIsIsolatedPerMonitorAndIncludesAllFrameWrites() {
    let otherMonitorID = MonitorID(rawValue: 2)

    #expect(
      focusMonitorIsReady(
        targetMonitorID: monitorID,
        scrollingMonitorIDs: [otherMonitorID],
        pendingFrameMonitorIDs: [otherMonitorID],
        deferredSlowMonitorIDs: [otherMonitorID]
      )
    )
    #expect(
      !focusMonitorIsReady(
        targetMonitorID: monitorID,
        scrollingMonitorIDs: [monitorID],
        pendingFrameMonitorIDs: [],
        deferredSlowMonitorIDs: []
      )
    )
    #expect(
      !focusMonitorIsReady(
        targetMonitorID: monitorID,
        scrollingMonitorIDs: [],
        pendingFrameMonitorIDs: [monitorID],
        deferredSlowMonitorIDs: []
      )
    )
    #expect(
      !focusMonitorIsReady(
        targetMonitorID: monitorID,
        scrollingMonitorIDs: [],
        pendingFrameMonitorIDs: [],
        deferredSlowMonitorIDs: [monitorID]
      )
    )
  }

  private func makeState(
    columnWidths: [Double],
    centerFocusedColumn: CenterFocusedColumnConfig = .never
  ) throws -> RuntimeState {
    let config = Config(
      layout: LayoutConfig(centerFocusedColumn: centerFocusedColumn)
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    for (index, width) in columnWidths.enumerated() {
      let id = WindowID(rawValue: UInt64(index + 1))
      try discoverWindow(
        Window(
          id: id,
          appID: "app-\(index + 1)",
          title: "Window \(index + 1)",
          frame: viewport,
          monitorID: monitorID
        ),
        decision: RuleDecision(),
        state: &state
      )
      state.monitors[0].workspaces[0].columns[index].width = .fraction(width)
    }
    _ = focusWindow(WindowID(rawValue: 1), state: &state)
    synchronizeScrollOffsets(
      state: &state,
      viewports: [monitorID: viewport]
    )
    return state
  }
}
