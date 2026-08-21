import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing
import XCTest

final class MouseReorderingTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  func testHorizontalDragReordersColumnsAfterCrossingNeighborCenter() throws {
    var state = try makeState(windowCount: 3)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    XCTAssertTrue(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: Rect(
          x: 900,
          y: target.y,
          width: target.width,
          height: target.height
        ),
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns.map(\.windows),
      [
        [WindowID(rawValue: 2)],
        [WindowID(rawValue: 1)],
        [WindowID(rawValue: 3)],
      ]
    )
    XCTAssertEqual(state.monitors[0].workspaces[0].focusedColumn, 1)
  }

  func testVerticalDragReordersWindowsWithinStack() throws {
    var state = try makeState(windowCount: 2)
    try reduce(.joinWindow(.left), on: monitorID, state: &state)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    XCTAssertTrue(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: Rect(
          x: target.x,
          y: 500,
          width: target.width,
          height: target.height
        ),
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].windows,
      [WindowID(rawValue: 2), WindowID(rawValue: 1)]
    )
    XCTAssertEqual(state.monitors[0].workspaces[0].columns[0].focusedWindow, 1)
  }

  func testHorizontalDragLeftReordersWithOffscreenPreviousColumn() throws {
    var state = try makeState(windowCount: 2)
    state.monitors[0].workspaces[0].scrollOffset = 0.8
    let draggedID = WindowID(rawValue: 2)
    let target = try targetFrame(for: draggedID, state: state)

    XCTAssertTrue(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: Rect(
          x: target.x - 900,
          y: target.y,
          width: target.width,
          height: target.height
        ),
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns.map(\.windows),
      [[WindowID(rawValue: 2)], [WindowID(rawValue: 1)]]
    )
  }

  func testSmallHorizontalDragKeepsColumnOrder() throws {
    var state = try makeState(windowCount: 2)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    XCTAssertFalse(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: Rect(
          x: target.x + 100,
          y: target.y,
          width: target.width,
          height: target.height
        ),
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns.map(\.windows),
      [[WindowID(rawValue: 1)], [WindowID(rawValue: 2)]]
    )
  }

  func testLiveHorizontalSwapDoesNotOscillateAtSamePointerPosition() throws {
    var state = try makeState(windowCount: 2)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)
    let draggedFrame = Rect(
      x: target.x + 900,
      y: target.y,
      width: target.width,
      height: target.height
    )

    XCTAssertTrue(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertFalse(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
  }

  func testUnequalWidthColumnsDoNotOscillateAtSamePointerPosition() throws {
    var state = try makeState(windowCount: 2)
    state.monitors[0].workspaces[0].columns[0].width = .pixels(300)
    state.monitors[0].workspaces[0].columns[1].width = .pixels(700)
    let draggedID = WindowID(rawValue: 1)
    let initialFrame = try targetFrame(for: draggedID, state: state)
    let neighborFrame = try targetFrame(
      for: WindowID(rawValue: 2),
      state: state
    )
    let draggedFrame = Rect(
      x: neighborFrame.x + neighborFrame.width / 2 - initialFrame.width / 2 + 1,
      y: initialFrame.y,
      width: initialFrame.width,
      height: initialFrame.height
    )

    XCTAssertTrue(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: initialFrame,
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertFalse(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: initialFrame,
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
  }

  func testScrollAnchorPreservesViewportAfterReorderFocusChanges() throws {
    var state = try makeState(windowCount: 2)
    let firstID = WindowID(rawValue: 1)
    state.monitors[0].workspaces[0].scrollOffset = 0.25
    state.monitors[0].workspaces[0].targetScrollOffset = 0.25
    let anchor = try XCTUnwrap(
      workspaceScrollAnchor(containing: firstID, state: state)
    )

    focusWindow(WindowID(rawValue: 2), state: &state)
    synchronizeScrollOffsets(
      state: &state,
      viewports: [monitorID: viewport]
    )
    restoreWorkspaceScroll(anchor, state: &state)

    XCTAssertEqual(state.monitors[0].workspaces[0].scrollOffset, 0.25)
    XCTAssertEqual(state.monitors[0].workspaces[0].targetScrollOffset, 0.25)
  }

  func testMouseGestureScrollAnchorSurvivesNonCrossingUpdates() throws {
    var state = try makeState(windowCount: 2)
    let draggedID = WindowID(rawValue: 2)
    state.monitors[0].workspaces[0].scrollOffset = 0.25
    state.monitors[0].workspaces[0].targetScrollOffset = 0.25
    let initialAnchor = resolvedMouseGestureScrollAnchor(
      current: nil,
      gestureWindowID: draggedID,
      mouseGestureActive: true,
      state: state
    )

    state.monitors[0].workspaces[0].scrollOffset = 0.8
    state.monitors[0].workspaces[0].targetScrollOffset = 0.8
    let preservedAnchor = resolvedMouseGestureScrollAnchor(
      current: initialAnchor,
      gestureWindowID: draggedID,
      mouseGestureActive: true,
      state: state
    )

    XCTAssertEqual(preservedAnchor?.scrollOffset, 0.25)
    XCTAssertNil(
      resolvedMouseGestureScrollAnchor(
        current: preservedAnchor,
        gestureWindowID: draggedID,
        mouseGestureActive: false,
        state: state
      )
    )
  }

  func testFocusedTiledWindowStartsMouseGestureBeforeFrameMoves() throws {
    let state = try makeState(windowCount: 2)
    let focusedID = WindowID(rawValue: 2)

    XCTAssertEqual(
      mouseGestureTiledWindowID(
        translatedWindowID: nil,
        activeWindowID: nil,
        mouseFocusIntentWindowID: focusedID,
        focusedWindowID: focusedID,
        state: state
      ),
      focusedID
    )
  }

  func testActiveGestureWindowRejectsUnrelatedTranslatedCandidate() throws {
    let state = try makeState(windowCount: 2)
    let translatedID = WindowID(rawValue: 2)
    let activeID = WindowID(rawValue: 1)

    XCTAssertEqual(
      mouseGestureTiledWindowID(
        translatedWindowID: translatedID,
        activeWindowID: activeID,
        mouseFocusIntentWindowID: activeID,
        focusedWindowID: activeID,
        state: state
      ),
      activeID
    )
  }

  func testReleaseOnlyGestureRecoversPreviousObservedFrame() {
    let windowID = WindowID(rawValue: 2)
    let previousFrame = Rect(x: 800, y: 0, width: 784, height: 684)
    let releasedFrame = Rect(x: 200, y: 0, width: 784, height: 684)

    XCTAssertEqual(
      resolvedMouseGestureInitialFrame(
        currentInitialFrame: nil,
        gestureWindowID: windowID,
        activeWindowID: nil,
        translatedWindowID: windowID,
        leftMouseButtonDown: false,
        previousObservedFrames: [windowID: previousFrame],
        actualFrame: releasedFrame
      ),
      previousFrame
    )
  }

  func testMouseGestureOriginUsesDisplayedAnimationPosition() {
    let observedFrame = Rect(x: 0, y: 20, width: 784, height: 684)

    XCTAssertEqual(
      resolvedMouseGestureOriginFrame(
        observedFrame: observedFrame,
        displayedX: 320,
        displayedY: 40
      ),
      Rect(x: 320, y: 40, width: 784, height: 684)
    )
    XCTAssertEqual(
      resolvedMouseGestureOriginFrame(
        observedFrame: observedFrame,
        displayedX: nil,
        displayedY: nil
      ),
      observedFrame
    )
  }

  func testMouseGestureOriginUsesDisplayedAnimationSize() {
    let observedFrame = Rect(x: 0, y: 20, width: 784, height: 684)

    XCTAssertEqual(
      resolvedMouseGestureOriginFrame(
        observedFrame: observedFrame,
        displayedX: 320,
        displayedY: 40,
        displayedWidth: 640,
        displayedHeight: 600
      ),
      Rect(x: 320, y: 40, width: 640, height: 600)
    )
  }

  func testLiveDragCanCrossMultipleColumnsAcrossUpdates() throws {
    var state = try makeState(windowCount: 3)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)
    let draggedFrame = Rect(
      x: 1_700,
      y: target.y,
      width: target.width,
      height: target.height
    )

    XCTAssertTrue(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertTrue(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns.map(\.windows),
      [
        [WindowID(rawValue: 2)],
        [WindowID(rawValue: 3)],
        [WindowID(rawValue: 1)],
      ]
    )
  }

  func testReleaseOnlyDragCrossesMultipleColumnsInOneSync() throws {
    var state = try makeState(windowCount: 4)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    XCTAssertTrue(
      reorderTiledWindowAfterCompletedMouseDrag(
        draggedID,
        actualFrame: Rect(
          x: 2_500,
          y: target.y,
          width: target.width,
          height: target.height
        ),
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns.map(\.windows),
      [
        [WindowID(rawValue: 2)],
        [WindowID(rawValue: 3)],
        [WindowID(rawValue: 4)],
        [WindowID(rawValue: 1)],
      ]
    )
  }

  func testLiveMouseSyncBypassesPendingReorderAnimation() {
    XCTAssertTrue(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: true,
        mouseGestureSyncPending: true,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false
      )
    )
    XCTAssertFalse(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: true,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: true
      )
    )
  }

  func testNativeFocusSyncBypassesCommandQuietPeriod() {
    XCTAssertTrue(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: false,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        nativeFocusSyncPending: true
      )
    )
  }

  func testNativeFocusSyncBypassesPendingAnimationWrites() {
    XCTAssertTrue(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: true,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        nativeFocusSyncPending: true
      )
    )
    XCTAssertTrue(
      desktopSynchronizationIsReady(
        scrollAnimationActive: true,
        animatedWritesPending: true,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        nativeFocusSyncPending: true
      )
    )
  }

  func testFrameDebtBypassesCommandQuietPeriod() {
    XCTAssertTrue(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: false,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        frameDebtPending: true
      )
    )
  }

  func testMouseReorderAnimationSurvivesLaterDragSamples() {
    XCTAssertFalse(
      mouseGestureAnimationCancellationIsNeeded(
        mouseReorderAnimationActive: true,
        scrollAnimationActive: false,
        animatedWritesPending: true
      )
    )
    XCTAssertTrue(
      mouseGestureAnimationCancellationIsNeeded(
        mouseReorderAnimationActive: false,
        scrollAnimationActive: true,
        animatedWritesPending: true
      )
    )
  }

  func testPostReleaseSettlementWaitsForStableLateFrame() {
    let initial = Rect(x: 0, y: 0, width: 500, height: 700)
    let released = Rect(x: 300, y: 0, width: 500, height: 700)
    let late = Rect(x: 700, y: 0, width: 500, height: 700)
    let settlement = MouseGestureSettlement(
      generation: 4,
      windowID: WindowID(rawValue: 1),
      initialFrame: initial,
      releasedFrame: released,
      now: 10,
      maximumDuration: 0.8
    )

    let changed = advanceMouseGestureSettlement(
      settlement,
      actualFrame: late,
      now: 10.1,
      animationPending: false
    )
    XCTAssertFalse(changed.shouldFinish)
    XCTAssertTrue(changed.settlement.observedPostReleaseChange)

    let stable = advanceMouseGestureSettlement(
      changed.settlement,
      actualFrame: late,
      now: 10.16,
      animationPending: false
    )
    XCTAssertTrue(stable.shouldFinish)
  }

  func testPostReleaseSettlementWaitsForReorderAnimation() {
    let frame = Rect(x: 300, y: 0, width: 500, height: 700)
    let settlement = MouseGestureSettlement(
      generation: 4,
      windowID: WindowID(rawValue: 1),
      initialFrame: Rect(x: 0, y: 0, width: 500, height: 700),
      releasedFrame: frame,
      now: 10,
      maximumDuration: 0.25
    )

    let update = advanceMouseGestureSettlement(
      settlement,
      actualFrame: frame,
      now: 10.3,
      animationPending: true
    )

    XCTAssertFalse(update.shouldFinish)
    XCTAssertEqual(update.settlement.nextCheckAt, 10.35, accuracy: 0.000_1)
  }

  func testPostReleaseSettlementFinishesAtDeadlineWithoutLateFrame() {
    let frame = Rect(x: 300, y: 0, width: 500, height: 700)
    let settlement = MouseGestureSettlement(
      generation: 4,
      windowID: WindowID(rawValue: 1),
      initialFrame: Rect(x: 0, y: 0, width: 500, height: 700),
      releasedFrame: frame,
      now: 10,
      maximumDuration: 0.25
    )

    let update = advanceMouseGestureSettlement(
      settlement,
      actualFrame: frame,
      now: 10.25,
      animationPending: false
    )

    XCTAssertTrue(update.shouldFinish)
  }

  func testSlowPostReleaseSettlementGetsLongerDeadline() {
    XCTAssertEqual(mouseGestureSettlementMaximumDuration(latencySensitive: false), 0.25)
    XCTAssertEqual(mouseGestureSettlementMaximumDuration(latencySensitive: true), 0.8)
  }

  func testPostReleaseSettlementUsesLateFrameForWidthLearning() {
    let external = Rect(x: 0, y: 0, width: 600, height: 700)
    let late = Rect(x: 0, y: 0, width: 800, height: 700)

    XCTAssertEqual(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: external,
        actualFrame: late,
        postReleaseSettlementActive: true
      ),
      external
    )
    XCTAssertEqual(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: nil,
        actualFrame: late,
        postReleaseSettlementActive: true
      ),
      late
    )
    XCTAssertNil(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: nil,
        actualFrame: late,
        postReleaseSettlementActive: false
      )
    )
  }

  func testResizeIsNotClassifiedAsTranslation() throws {
    let state = try makeState(windowCount: 1)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)

    XCTAssertNil(
      mouseTranslatedTiledWindowID(
        candidateWindowIDs: [windowID],
        externallyChangedFrames: [
          windowID: Rect(
            x: target.x,
            y: target.y,
            width: target.width + 100,
            height: target.height
          )
        ],
        state: state,
        viewports: [monitorID: viewport]
      )
    )
  }

  func testResizeWithPositionChangeDoesNotReorderColumn() throws {
    var state = try makeState(windowCount: 2)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)

    XCTAssertFalse(
      reorderTiledWindowAfterMouseDrag(
        windowID,
        actualFrame: Rect(
          x: target.x + 500,
          y: target.y,
          width: target.width + 100,
          height: target.height
        ),
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns.map(\.windows),
      [[WindowID(rawValue: 1)], [WindowID(rawValue: 2)]]
    )
  }

  func testTranslationCandidateFindsMovedTiledWindow() throws {
    let state = try makeState(windowCount: 1)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)

    XCTAssertEqual(
      mouseTranslatedTiledWindowID(
        candidateWindowIDs: [windowID],
        externallyChangedFrames: [
          windowID: Rect(
            x: target.x + 100,
            y: target.y,
            width: target.width,
            height: target.height
          )
        ],
        state: state,
        viewports: [monitorID: viewport]
      ),
      windowID
    )
  }

  func testTranslationCandidateIgnoresUnrelatedMismatch() throws {
    let state = try makeState(windowCount: 2)
    let firstID = WindowID(rawValue: 1)
    let secondID = WindowID(rawValue: 2)
    let firstTarget = try targetFrame(for: firstID, state: state)
    let secondTarget = try targetFrame(for: secondID, state: state)

    XCTAssertEqual(
      mouseTranslatedTiledWindowID(
        candidateWindowIDs: [secondID],
        externallyChangedFrames: [
          firstID: Rect(
            x: firstTarget.x + 300,
            y: firstTarget.y,
            width: firstTarget.width,
            height: firstTarget.height
          ),
          secondID: Rect(
            x: secondTarget.x - 300,
            y: secondTarget.y,
            width: secondTarget.width,
            height: secondTarget.height
          ),
        ],
        state: state,
        viewports: [monitorID: viewport]
      ),
      secondID
    )
  }

  func testTranslationCandidateIgnoresFloatingWindows() throws {
    var state = try makeState(windowCount: 1)
    try reduce(.toggleFloating, on: monitorID, state: &state)
    let windowID = WindowID(rawValue: 1)

    XCTAssertNil(
      mouseTranslatedTiledWindowID(
        candidateWindowIDs: [windowID],
        externallyChangedFrames: [
          windowID: Rect(x: 200, y: 100, width: 600, height: 500)
        ],
        state: state,
        viewports: [monitorID: viewport]
      )
    )
  }

  private func makeState(windowCount: Int) throws -> RuntimeState {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    for rawID in 1...windowCount {
      let window = Window(
        id: WindowID(rawValue: UInt64(rawID)),
        appID: "editor",
        title: "Window \(rawID)",
        frame: Rect(x: 0, y: 0, width: 784, height: 684),
        monitorID: monitorID
      )
      try discoverWindow(
        window,
        decision: RuleDecision(followFocus: true),
        isNativelyFocused: true,
        state: &state
      )
    }
    return state
  }

  private func targetFrame(for windowID: WindowID, state: RuntimeState) throws -> Rect {
    let workspace = state.monitors[0].workspaces[0]
    return try XCTUnwrap(
      computeLayout(
        workspace: workspace,
        viewport: viewport,
        windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
        settings: state.layout
      ).frames.first(where: { $0.windowID == windowID })?.frame
    )
  }
}

struct DesktopSynchronizationTests {
  @Test
  func waitsForCommandInputToSettle() {
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: false,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: true,
        commandQuietPeriodElapsed: false
      ) == false
    )
  }
}
