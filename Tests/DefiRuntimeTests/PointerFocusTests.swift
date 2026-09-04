import DefiConfig
import DefiCore
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
      ) == logicalWindowID
    )
  }

  @Test
  func completedPointerFocusRecoveryKeepsLogicalTargetAfterCancellationRace() {
    let logicalWindowID = WindowID(rawValue: 1)

    #expect(
      pointerFocusRecoveryTargetAfterCancellation(
        cancellationSucceeded: false,
        logicalFocusWindowID: logicalWindowID
      ) == logicalWindowID
    )
    #expect(
      pointerFocusRecoveryTargetAfterCancellation(
        cancellationSucceeded: true,
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

  @Test(arguments: [false, true])
  func pointerFocusChangesVisibleSelectionWithoutScrolling(sameProcess: Bool) throws {
    var state = try makeState(columnWidths: [0.4, 0.4])
    if sameProcess {
      for id in [WindowID(rawValue: 1), WindowID(rawValue: 2)] {
        state.windows[id]?.appID = "same.app"
        state.windows[id]?.processID = 42
      }
    }
    let originalOffset = state.monitors[0].workspaces[0].targetScrollOffset

    let focusedMonitor = focusWindowFromPointer(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport],
      maximumScrollAmount: 0
    )

    #expect(focusedMonitor == monitorID)
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 2))
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == originalOffset)
  }

  @Test(arguments: [0.0, 4.0, 8.0, 12.0])
  func halfWidthPointerFocusNeverMovesTheStrip(gaps: Double) throws {
    var state = try makeState(columnWidths: [0.8, 0.5, 0.5], gaps: gaps)
    state.monitors[0].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 1), width: .fraction(0.8)),
      Column(window: WindowID(rawValue: 2), width: .fraction(0.5)),
      Column(window: WindowID(rawValue: 3), width: .fraction(0.5)),
    ]
    for id in [WindowID(rawValue: 2), WindowID(rawValue: 3)] {
      state.windows[id]?.appID = "same.app"
      state.windows[id]?.processID = 42
    }
    _ = focusWindow(WindowID(rawValue: 2), state: &state)
    let originalOffset = focusedColumnLeftScrollOffset(
      workspace: state.monitors[0].workspaces[0], viewport: viewport,
      windows: Array(state.windows.values), settings: state.layout
    )
    state.monitors[0].workspaces[0].scrollOffset = originalOffset
    state.monitors[0].workspaces[0].targetScrollOffset = originalOffset
    let originalFrames = computeLayout(
      workspace: state.monitors[0].workspaces[0], viewport: viewport,
      windows: Array(state.windows.values), settings: state.layout
    ).frames
    for target in [3, 2, 3, 2] {
      #expect(focusWindowFromPointer(
        WindowID(rawValue: UInt64(target)), activeMonitorID: monitorID,
        state: &state, viewports: [monitorID: viewport], maximumScrollAmount: 0
      ) == monitorID)
      #expect(state.monitors[0].workspaces[0].targetScrollOffset == originalOffset)
      state.monitors[0].workspaces[0].scrollOffset =
        state.monitors[0].workspaces[0].targetScrollOffset
      #expect(computeLayout(
        workspace: state.monitors[0].workspaces[0], viewport: viewport,
        windows: Array(state.windows.values), settings: state.layout
      ).frames == originalFrames)
    }
  }

  @Test
  func pointerFocusStillRejectsClippedContent() throws {
    var state = try makeState(columnWidths: [0.5, 0.51, 0.5], gaps: 0)
    state.monitors[0].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 1), width: .fraction(0.5)),
      Column(window: WindowID(rawValue: 2), width: .fraction(0.51)),
      Column(window: WindowID(rawValue: 3), width: .fraction(0.5)),
    ]
    #expect(pointerFocusMonitor(
      WindowID(rawValue: 2), activeMonitorID: monitorID,
      state: state, viewports: [monitorID: viewport], maximumScrollAmount: 0
    ) == nil)
  }

  @Test
  func pointerFocusPreviewDoesNotMutateSelection() throws {
    let state = try makeState(columnWidths: [0.4, 0.4])
    let original = state

    let focusedMonitor = pointerFocusMonitor(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: state,
      viewports: [monitorID: viewport],
      maximumScrollAmount: 0
    )

    #expect(focusedMonitor == monitorID)
    #expect(state == original)
  }

  @Test
  func pointerFocusRejectsTargetThatWouldScrollStrip() throws {
    var state = try makeState(columnWidths: [0.5, 0.5, 0.5])
    let original = state

    let focusedMonitor = focusWindowFromPointer(
      WindowID(rawValue: 3),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport],
      maximumScrollAmount: 0
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

    let focusedMonitor = focusWindowFromPointer(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport],
      maximumScrollAmount: 0
    )

    #expect(focusedMonitor == nil)
    #expect(state == original)
  }

  @Test
  func repeatedPointerFocusDoesNothing() throws {
    var state = try makeState(columnWidths: [0.4, 0.4])

    let focusedMonitor = focusWindowFromPointer(
      WindowID(rawValue: 1),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == nil)
  }

  @Test
  func modalBlocksPointerFocusBehindItButAllowsDescendants() throws {
    var state = try makeState(columnWidths: [0.3, 0.3, 0.3])
    let ownerID = WindowID(rawValue: 1)
    let modalID = WindowID(rawValue: 2)
    let descendantID = WindowID(rawValue: 3)
    state.windows[ownerID]?.appID = "app"
    state.windows[modalID]?.appID = "app"
    state.windows[modalID]?.isModal = true
    state.windows[modalID]?.transientOwnerID = ownerID
    state.windows[descendantID]?.appID = "app"
    state.windows[descendantID]?.transientOwnerID = modalID

    #expect(modalAllowsPointerFocus(ownerID, state: state) == false)
    #expect(modalAllowsPointerFocus(modalID, state: state))
    #expect(modalAllowsPointerFocus(descendantID, state: state))
  }

  @Test
  func documentModalAllowsPointerFocusInAnUnrelatedDocument() throws {
    var state = try makeState(columnWidths: [0.25, 0.25, 0.25, 0.25])
    let ownerID = WindowID(rawValue: 1)
    let modalID = WindowID(rawValue: 2)
    let unrelatedDocumentID = WindowID(rawValue: 4)
    for windowID in [ownerID, modalID, unrelatedDocumentID] {
      state.windows[windowID]?.appID = "app"
    }
    state.windows[modalID]?.isModal = true
    state.windows[modalID]?.transientOwnerID = ownerID

    #expect(modalAllowsPointerFocus(unrelatedDocumentID, state: state))
  }

  @Test
  func ownerlessModalStillBlocksTheRestOfItsApplication() throws {
    var state = try makeState(columnWidths: [0.5, 0.5])
    let modalID = WindowID(rawValue: 1)
    let documentID = WindowID(rawValue: 2)
    state.windows[modalID]?.appID = "app"
    state.windows[modalID]?.isModal = true
    state.windows[documentID]?.appID = "app"

    #expect(modalAllowsPointerFocus(documentID, state: state) == false)
    #expect(modalAllowsPointerFocus(modalID, state: state))
  }

  @Test
  func ownerlessModalDoesNotBlockAnotherInstanceOfTheSameApplication() throws {
    var state = try makeState(columnWidths: [0.5, 0.5])
    let modalID = WindowID(rawValue: 1)
    let documentID = WindowID(rawValue: 2)
    state.windows[modalID]?.appID = "app"
    state.windows[modalID]?.processID = 100
    state.windows[modalID]?.isModal = true
    state.windows[documentID]?.appID = "app"
    state.windows[documentID]?.processID = 200

    #expect(modalAllowsPointerFocus(documentID, state: state))
  }

  @Test
  func ownerlessModalBlocksItsApplicationAcrossMonitors() throws {
    var state = try makeState(columnWidths: [0.5, 0.5])
    let modalID = WindowID(rawValue: 1)
    let documentID = WindowID(rawValue: 2)
    let otherMonitorID = MonitorID(rawValue: 2)
    state.windows[modalID]?.appID = "app"
    state.windows[modalID]?.isModal = true
    state.windows[documentID]?.appID = "app"
    state.monitors[0].workspaces[0].columns.removeLast()
    state.attachMonitor(otherMonitorID)
    state.monitors[1].workspaces[0].columns = [
      Column(window: documentID, width: .fraction(0.5))
    ]
    state.windows[documentID]?.monitorID = otherMonitorID

    #expect(modalAllowsPointerFocus(documentID, state: state) == false)
  }

  @Test
  func alreadySelectedPointerTargetCanRestoreNativeFocus() throws {
    var state = try makeState(columnWidths: [0.4, 0.4])
    let original = state

    let focusedMonitor = focusWindowFromPointer(
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
  func barePointerFocusScrollsMinimallyToRevealTarget() throws {
    var state = try makeState(columnWidths: [0.5, 0.5, 0.5])
    let originalOffset = state.monitors[0].workspaces[0].targetScrollOffset

    let focusedMonitor = focusWindowFromPointer(
      WindowID(rawValue: 3),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == monitorID)
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 3))
    #expect(
      state.monitors[0].workspaces[0].targetScrollOffset > originalOffset
    )
  }

  @Test
  func pointerFocusHonorsViewportFractionScrollLimit() throws {
    let original = try makeState(columnWidths: [0.5, 0.5, 0.5])
    var unrestricted = original
    #expect(
      focusWindowFromPointer(
        WindowID(rawValue: 3),
        activeMonitorID: monitorID,
        state: &unrestricted,
        viewports: [monitorID: viewport]
      ) == monitorID
    )
    let requiredAmount =
      abs(
        unrestricted.monitors[0].workspaces[0].targetScrollOffset
          - original.monitors[0].workspaces[0].targetScrollOffset
      )

    var rejected = original
    #expect(
      focusWindowFromPointer(
        WindowID(rawValue: 3),
        activeMonitorID: monitorID,
        state: &rejected,
        viewports: [monitorID: viewport],
        maximumScrollAmount: requiredAmount / 2
      ) == nil
    )
    #expect(rejected == original)

    var accepted = original
    #expect(
      focusWindowFromPointer(
        WindowID(rawValue: 3),
        activeMonitorID: monitorID,
        state: &accepted,
        viewports: [monitorID: viewport],
        maximumScrollAmount: requiredAmount
      ) == monitorID
    )
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
  func displayChangeRequeueKeepsPointerInputGuard() {
    #expect(
      pointerDisplacedFocusInputTimestamp(
        commandInputTimestamp: 12,
        pointerInputTimestamp: 18
      ) == 18
    )
    #expect(
      pointerDisplacedFocusInputTimestamp(
        commandInputTimestamp: 18,
        pointerInputTimestamp: 12
      ) == 18
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
      pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: WindowID(rawValue: 43),
        requestGeneration: 4,
        currentGeneration: 4,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      ) == false)
    #expect(
      pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: windowID,
        requestGeneration: 4,
        currentGeneration: 4,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 13
      ) == false)
  }

  @Test
  func newerPointerTransitionInvalidatesRequestWithoutGeneralInput() {
    #expect(
      pointerFocusRequestIsCurrent(
        requestGeneration: 4,
        currentGeneration: 5,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      ) == false)
    #expect(
      pointerFocusRetryIsCurrent(
        pendingWindowID: WindowID(rawValue: 42),
        windowUnderPointerID: WindowID(rawValue: 42),
        requestGeneration: 4,
        currentGeneration: 5,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      ) == false)
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
      pointerFocusIntentIsCurrent(
        pointerTimestamp: 12,
        latestUserInputTimestamp: 13
      ) == false)
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
      cancelledPointerFocusShouldRearm(
        pointerTimestamp: 12,
        latestUserInputTimestamp: 13
      ) == false)
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
      commandFocusIsPreserved(
        pendingWindowID: WindowID(rawValue: 43),
        submittedWindowID: nil,
        selectedWindowID: windowID
      ) == false)
    #expect(
      commandFocusIsPreserved(
        pendingWindowID: nil,
        submittedWindowID: WindowID(rawValue: 43),
        selectedWindowID: windowID
      ) == false)
    #expect(
      commandFocusIsPreserved(
        pendingWindowID: nil,
        submittedWindowID: nil,
        selectedWindowID: windowID
      ) == false)
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
  func focusReadinessIsIsolatedPerMonitorAndTargetWindow() {
    let otherMonitorID = MonitorID(rawValue: 2)
    let targetWindowID = WindowID(rawValue: 1)
    let otherWindowID = WindowID(rawValue: 2)

    #expect(
      focusTargetIsReady(
        targetMonitorID: monitorID,
        targetWindowID: targetWindowID,
        scrollingMonitorIDs: [otherMonitorID],
        pendingFrameWindowIDs: [otherWindowID]
      )
    )
    #expect(
      focusTargetIsReady(
        targetMonitorID: monitorID,
        targetWindowID: targetWindowID,
        scrollingMonitorIDs: [monitorID],
        pendingFrameWindowIDs: []
      ) == false)
    #expect(
      focusTargetIsReady(
        targetMonitorID: monitorID,
        targetWindowID: targetWindowID,
        scrollingMonitorIDs: [],
        pendingFrameWindowIDs: [targetWindowID]
      ) == false)
    #expect(
      focusTargetIsReady(
        targetMonitorID: monitorID,
        targetWindowID: targetWindowID,
        scrollingMonitorIDs: [],
        pendingFrameWindowIDs: [otherWindowID]
      )
    )
  }

  @Test
  func pointerFocusReadinessRemainsMonitorWide() {
    let otherMonitorID = MonitorID(rawValue: 2)

    #expect(
      focusMonitorIsReady(
        targetMonitorID: monitorID,
        scrollingMonitorIDs: [],
        pendingFrameMonitorIDs: [monitorID]
      ) == false)
    #expect(
      focusMonitorIsReady(
        targetMonitorID: monitorID,
        scrollingMonitorIDs: [otherMonitorID],
        pendingFrameMonitorIDs: [otherMonitorID]
      )
    )
  }

  private func makeState(
    columnWidths: [Double],
    gaps: Double = 8,
    centerFocusedColumn: CenterFocusedColumnConfig = .never
  ) throws -> RuntimeState {
    let config = Config(
      layout: LayoutConfig(centerFocusedColumn: centerFocusedColumn, gaps: gaps)
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
