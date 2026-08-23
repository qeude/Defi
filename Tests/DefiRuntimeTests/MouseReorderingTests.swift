import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Numerics
import Testing

struct MouseReorderingTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  @Test
  func `Horizontal drag reorders columns after crossing neighbor center`() throws {
    var state = try makeState(windowCount: 3)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    #expect(
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
      ))
    #expect(
      state.monitors[0].workspaces[0].columns.map(\.windows) == [
        [WindowID(rawValue: 2)],
        [WindowID(rawValue: 1)],
        [WindowID(rawValue: 3)],
      ])
    #expect(state.monitors[0].workspaces[0].focusedColumn == 1)
  }

  @Test
  func `Vertical drag reorders windows within stack`() throws {
    var state = try makeState(windowCount: 2)
    try reduce(.joinWindow(.left), on: monitorID, state: &state)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    #expect(
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
      ))
    #expect(
      state.monitors[0].workspaces[0].columns[0].windows == [
        WindowID(rawValue: 2), WindowID(rawValue: 1),
      ])
    #expect(state.monitors[0].workspaces[0].columns[0].focusedWindow == 1)
  }

  @Test
  func `Horizontal drag left reorders with offscreen previous column`() throws {
    var state = try makeState(windowCount: 2)
    state.monitors[0].workspaces[0].scrollOffset = 0.8
    let draggedID = WindowID(rawValue: 2)
    let target = try targetFrame(for: draggedID, state: state)

    #expect(
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
      ))
    #expect(
      state.monitors[0].workspaces[0].columns.map(\.windows) == [
        [WindowID(rawValue: 2)], [WindowID(rawValue: 1)],
      ])
  }

  @Test
  func `Small horizontal drag keeps column order`() throws {
    var state = try makeState(windowCount: 2)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    #expect(
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
      ) == false)
    #expect(
      state.monitors[0].workspaces[0].columns.map(\.windows) == [
        [WindowID(rawValue: 1)], [WindowID(rawValue: 2)],
      ])
  }

  @Test
  func `Live horizontal swap does not oscillate at same pointer position`() throws {
    var state = try makeState(windowCount: 2)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)
    let draggedFrame = Rect(
      x: target.x + 900,
      y: target.y,
      width: target.width,
      height: target.height
    )

    #expect(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      ))
    #expect(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      ) == false)
  }

  @Test
  func `Unequal width columns do not oscillate at same pointer position`() throws {
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

    #expect(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: initialFrame,
        state: &state,
        viewports: [monitorID: viewport]
      ))
    #expect(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: initialFrame,
        state: &state,
        viewports: [monitorID: viewport]
      ) == false)
  }

  @Test
  func `Scroll anchor preserves viewport after reorder focus changes`() throws {
    var state = try makeState(windowCount: 2)
    let firstID = WindowID(rawValue: 1)
    state.monitors[0].workspaces[0].scrollOffset = 0.25
    state.monitors[0].workspaces[0].targetScrollOffset = 0.25
    let anchor = try #require(
      workspaceScrollAnchor(containing: firstID, state: state)
    )

    focusWindow(WindowID(rawValue: 2), state: &state)
    synchronizeScrollOffsets(
      state: &state,
      viewports: [monitorID: viewport]
    )
    restoreWorkspaceScroll(anchor, state: &state)

    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.25)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.25)
  }

  @Test
  func `Mouse gesture scroll anchor survives non crossing updates`() throws {
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

    #expect(preservedAnchor?.scrollOffset == 0.25)
    #expect(
      resolvedMouseGestureScrollAnchor(
        current: preservedAnchor,
        gestureWindowID: draggedID,
        mouseGestureActive: false,
        state: state
      ) == nil)
  }

  @Test
  func `Focused tiled window starts mouse gesture before frame moves`() throws {
    let state = try makeState(windowCount: 2)
    let focusedID = WindowID(rawValue: 2)

    #expect(
      mouseGestureTiledWindowID(
        translatedWindowID: nil,
        activeWindowID: nil,
        mouseFocusIntentWindowID: focusedID,
        focusedWindowID: focusedID,
        state: state
      ) == focusedID)
  }

  @Test
  func `Active gesture window rejects unrelated translated candidate`() throws {
    let state = try makeState(windowCount: 2)
    let translatedID = WindowID(rawValue: 2)
    let activeID = WindowID(rawValue: 1)

    #expect(
      mouseGestureTiledWindowID(
        translatedWindowID: translatedID,
        activeWindowID: activeID,
        mouseFocusIntentWindowID: activeID,
        focusedWindowID: activeID,
        state: state
      ) == activeID)
  }

  @Test
  func `Release only gesture recovers previous observed frame`() {
    let windowID = WindowID(rawValue: 2)
    let previousFrame = Rect(x: 800, y: 0, width: 784, height: 684)
    let releasedFrame = Rect(x: 200, y: 0, width: 784, height: 684)

    #expect(
      resolvedMouseGestureInitialFrame(
        currentInitialFrame: nil,
        gestureWindowID: windowID,
        activeWindowID: nil,
        translatedWindowID: windowID,
        leftMouseButtonDown: false,
        previousObservedFrames: [windowID: previousFrame],
        actualFrame: releasedFrame
      ) == previousFrame)
  }

  @Test
  func `Mouse gesture origin uses displayed animation position`() {
    let observedFrame = Rect(x: 0, y: 20, width: 784, height: 684)

    #expect(
      resolvedMouseGestureOriginFrame(
        observedFrame: observedFrame,
        displayedX: 320,
        displayedY: 40
      ) == Rect(x: 320, y: 40, width: 784, height: 684))
    #expect(
      resolvedMouseGestureOriginFrame(
        observedFrame: observedFrame,
        displayedX: nil,
        displayedY: nil
      ) == observedFrame)
  }

  @Test
  func `Mouse gesture origin uses displayed animation size`() {
    let observedFrame = Rect(x: 0, y: 20, width: 784, height: 684)

    #expect(
      resolvedMouseGestureOriginFrame(
        observedFrame: observedFrame,
        displayedX: 320,
        displayedY: 40,
        displayedWidth: 640,
        displayedHeight: 600
      ) == Rect(x: 320, y: 40, width: 640, height: 600))
  }

  @Test
  func `Live drag can cross multiple columns across updates`() throws {
    var state = try makeState(windowCount: 3)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)
    let draggedFrame = Rect(
      x: 1_700,
      y: target.y,
      width: target.width,
      height: target.height
    )

    #expect(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      ))
    #expect(
      reorderTiledWindowAfterMouseDrag(
        draggedID,
        actualFrame: draggedFrame,
        initialFrame: target,
        state: &state,
        viewports: [monitorID: viewport]
      ))
    #expect(
      state.monitors[0].workspaces[0].columns.map(\.windows) == [
        [WindowID(rawValue: 2)],
        [WindowID(rawValue: 3)],
        [WindowID(rawValue: 1)],
      ])
  }

  @Test
  func `Release only drag crosses multiple columns in one sync`() throws {
    var state = try makeState(windowCount: 4)
    let draggedID = WindowID(rawValue: 1)
    let target = try targetFrame(for: draggedID, state: state)

    #expect(
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
      ))
    #expect(
      state.monitors[0].workspaces[0].columns.map(\.windows) == [
        [WindowID(rawValue: 2)],
        [WindowID(rawValue: 3)],
        [WindowID(rawValue: 4)],
        [WindowID(rawValue: 1)],
      ])
  }

  @Test
  func `Live mouse sync bypasses pending reorder animation`() {
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: true,
        mouseGestureSyncPending: true,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false
      ))
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: true,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: true
      ) == false)
  }

  @Test
  func `Native focus sync bypasses command quiet period`() {
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: false,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        nativeFocusSyncPending: true
      ))
  }

  @Test
  func `Lifecycle event bypasses command quiet period`() {
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: false,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        lifecycleEventPending: true
      ))
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: true,
        animatedWritesPending: false,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        lifecycleEventPending: true
      ) == false)
  }

  @Test
  func `Native focus sync bypasses pending animation writes`() {
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: true,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        nativeFocusSyncPending: true
      ))
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: true,
        animatedWritesPending: true,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        nativeFocusSyncPending: true
      ))
  }

  @Test
  func `Frame debt bypasses command quiet period`() {
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: false,
        animatedWritesPending: false,
        mouseGestureSyncPending: false,
        needsDesktopSync: true,
        periodicSyncDue: false,
        commandQuietPeriodElapsed: false,
        frameDebtPending: true
      ))
  }

  @Test
  func `Mouse reorder animation survives later drag samples`() {
    #expect(
      mouseGestureAnimationCancellationIsNeeded(
        mouseReorderAnimationActive: true,
        scrollAnimationActive: false,
        animatedWritesPending: true
      ) == false)
    #expect(
      mouseGestureAnimationCancellationIsNeeded(
        mouseReorderAnimationActive: false,
        scrollAnimationActive: true,
        animatedWritesPending: true
      ))
  }

  @Test
  func `Post release settlement waits for stable late frame`() {
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
    #expect(changed.shouldFinish == false)
    #expect(changed.settlement.observedPostReleaseChange)

    let stable = advanceMouseGestureSettlement(
      changed.settlement,
      actualFrame: late,
      now: 10.16,
      animationPending: false
    )
    #expect(stable.shouldFinish)
  }

  @Test
  func `Post release settlement waits for reorder animation`() {
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

    #expect(update.shouldFinish == false)
    #expect(
      update.settlement.nextCheckAt.isApproximatelyEqual(
        to: 10.35,
        absoluteTolerance: 0.000_1
      )
    )
  }

  @Test
  func `Post release settlement finishes at deadline without late frame`() {
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

    #expect(update.shouldFinish)
  }

  @Test
  func `Slow post release settlement gets longer deadline`() {
    #expect(mouseGestureSettlementMaximumDuration(latencySensitive: false) == 0.25)
    #expect(mouseGestureSettlementMaximumDuration(latencySensitive: true) == 0.8)
  }

  @Test
  func `Post release settlement uses late frame for width learning`() {
    let external = Rect(x: 0, y: 0, width: 600, height: 700)
    let late = Rect(x: 0, y: 0, width: 800, height: 700)

    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: external,
        actualFrame: late,
        postReleaseSettlementActive: true
      ) == external)
    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: nil,
        actualFrame: late,
        postReleaseSettlementActive: true
      ) == late)
    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: nil,
        actualFrame: late,
        postReleaseSettlementActive: false
      ) == nil)
  }

  @Test
  func `Resize is not classified as translation`() throws {
    let state = try makeState(windowCount: 1)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)

    #expect(
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
      ) == nil)
  }

  @Test
  func `Resize with position change does not reorder column`() throws {
    var state = try makeState(windowCount: 2)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)

    #expect(
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
      ) == false)
    #expect(
      state.monitors[0].workspaces[0].columns.map(\.windows) == [
        [WindowID(rawValue: 1)], [WindowID(rawValue: 2)],
      ])
  }

  @Test
  func `Translation candidate finds moved tiled window`() throws {
    let state = try makeState(windowCount: 1)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)

    #expect(
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
      ) == windowID)
  }

  @Test
  func `Translation candidate ignores unrelated mismatch`() throws {
    let state = try makeState(windowCount: 2)
    let firstID = WindowID(rawValue: 1)
    let secondID = WindowID(rawValue: 2)
    let firstTarget = try targetFrame(for: firstID, state: state)
    let secondTarget = try targetFrame(for: secondID, state: state)

    #expect(
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
      ) == secondID)
  }

  @Test
  func `Translation candidate ignores floating windows`() throws {
    var state = try makeState(windowCount: 1)
    try reduce(.toggleFloating, on: monitorID, state: &state)
    let windowID = WindowID(rawValue: 1)

    #expect(
      mouseTranslatedTiledWindowID(
        candidateWindowIDs: [windowID],
        externallyChangedFrames: [
          windowID: Rect(x: 200, y: 100, width: 600, height: 500)
        ],
        state: state,
        viewports: [monitorID: viewport]
      ) == nil)
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
    return try #require(
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
