import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct MouseReorderingTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  @Test(arguments: [700.0, 500.0])
  func completedDragTilesOnDestinationMonitor(height: Double) throws {
    var state = try makeState(windowCount: 2)
    let destination = MonitorID(rawValue: 2)
    state.attachMonitor(destination)
    let windowID = WindowID(rawValue: 1)
    let initial = try targetFrame(for: windowID, state: state)
    let target = Rect(x: 1_000, y: -height, width: 800, height: height)
    let workspaceID = state.monitors[1].activeWorkspace
    let released = Rect(x: target.x + 30, y: target.y + 20,
                        width: initial.width, height: min(initial.height, height - 20))
    #expect(mouseTranslatedTiledWindowID(
      candidateWindowIDs: [windowID], externallyChangedFrames: [windowID: released],
      state: state, viewports: [monitorID: viewport, destination: target],
      monitorFrames: [monitorID: viewport, destination: target]
    ) == windowID)

    #expect(reorderTiledWindowAfterCompletedMouseDrag(
      windowID,
      actualFrame: released,
      initialFrame: initial, state: &state,
      viewports: [monitorID: viewport, destination: target],
      monitorFrames: [monitorID: viewport, destination: target]
    ))
    #expect(state.location(containing: windowID)?.monitorID == destination)
    #expect(state.location(containing: windowID)?.workspaceID == workspaceID)
    #expect(state.selectedWindowID(on: destination) == windowID)
    #expect(state.windows[windowID]?.floating == false)
    #expect(state.monitors[1].workspaces.filter { $0.kind == .trailing }.count == 1)
    #expect(state.monitors[0].workspaces.flatMap(\.columns).flatMap(\.windows) == [WindowID(rawValue: 2)])
  }

  @Test
  func completedDragUsesCurrentLayoutAfterFrameDrift() throws {
    var state = try makeState(windowCount: 2)
    let destination = MonitorID(rawValue: 2)
    state.attachMonitor(destination)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)
    let initial = Rect(x: 400, y: target.y, width: 1_000, height: target.height)
    let released = Rect(x: 1_000, y: target.y, width: 400, height: target.height)
    let destinationViewport = Rect(x: 1_000, y: 0, width: 1_000, height: 700)
    let viewports = [monitorID: viewport, destination: destinationViewport]
    let monitorFrames = viewports

    #expect(mouseTranslatedTiledWindowID(
      candidateWindowIDs: [windowID], externallyChangedFrames: [windowID: released],
      state: state, viewports: viewports, monitorFrames: monitorFrames
    ) == windowID)
    #expect(reorderTiledWindowAfterCompletedMouseDrag(
      windowID, actualFrame: released, initialFrame: initial, state: &state,
      viewports: viewports, monitorFrames: monitorFrames
    ))
    #expect(state.monitorID(containing: windowID) == destination)
  }

  @Test
  func completedDragResolvesWorkspaceIndicesAfterFocusPrunesEmptyWorkspaces() throws {
    var state = try makeState(windowCount: 2)
    let destination = MonitorID(rawValue: 2)
    state.attachMonitor(destination)
    let destinationIndex = try #require(state.monitors.firstIndex(where: { $0.id == destination }))
    let trailing = try #require(state.monitors[destinationIndex].workspaces.last)
    let emptyID = WorkspaceID(rawValue: "fixture-empty-ordinary")
    let inactiveID = WorkspaceID(rawValue: "fixture-inactive")
    let activeID = WorkspaceID(rawValue: "fixture-active")
    state.monitors[destinationIndex].workspaces = [
      Workspace(id: emptyID, kind: .ordinary),
      Workspace(id: inactiveID, kind: .named),
      Workspace(id: activeID, kind: .named),
      trailing,
    ]
    state.monitors[destinationIndex].activeWorkspace = activeID

    let windowID = WindowID(rawValue: 1)
    let initial = try targetFrame(for: windowID, state: state)
    let destinationViewport = Rect(x: 1_000, y: 0, width: 1_000, height: 700)
    let released = Rect(
      x: 1_030, y: 20, width: initial.width, height: initial.height - 40
    )
    let viewports = [monitorID: viewport, destination: destinationViewport]
    let monitorFrames = viewports

    #expect(reorderTiledWindowAfterCompletedMouseDrag(
      windowID, actualFrame: released, initialFrame: initial, state: &state,
      viewports: viewports, monitorFrames: monitorFrames
    ))
    #expect(state.location(containing: windowID)?.monitorID == destination)
    #expect(state.location(containing: windowID)?.workspaceID == activeID)
  }

  @Test
  func completedDragTransfersFromDestinationReservedBand() throws {
    var state = try makeState(windowCount: 2)
    let destination = MonitorID(rawValue: 2)
    state.attachMonitor(destination)
    let windowID = WindowID(rawValue: 1)
    let initial = try targetFrame(for: windowID, state: state)
    let destinationViewport = Rect(x: 1_000, y: 0, width: 1_000, height: 650)
    let released = Rect(
      x: 1_100, y: 690 - (initial.height - 20) / 2,
      width: initial.width, height: initial.height - 20
    )
    #expect(mouseTranslatedTiledWindowID(
      candidateWindowIDs: [windowID], externallyChangedFrames: [windowID: released],
      state: state, viewports: [monitorID: viewport, destination: destinationViewport],
      monitorFrames: [monitorID: viewport, destination: Rect(x: 1_000, y: 0, width: 1_000, height: 700)]
    ) == windowID)
    #expect(reorderTiledWindowAfterCompletedMouseDrag(
      windowID, actualFrame: released, initialFrame: initial, state: &state,
      viewports: [monitorID: viewport, destination: destinationViewport],
      monitorFrames: [monitorID: viewport, destination: Rect(x: 1_000, y: 0, width: 1_000, height: 700)]
    ))
    #expect(state.monitorID(containing: windowID) == destination)
  }

  @Test
  func resizingAcrossMonitorBoundaryDoesNotTransferWindow() throws {
    var state = try makeState(windowCount: 2)
    let destination = MonitorID(rawValue: 2)
    state.attachMonitor(destination)
    state.monitors[0].workspaces[0].scrollOffset = 0.3
    let windowID = WindowID(rawValue: 2)
    let sourceViewport = Rect(x: 0, y: 0, width: 1_300, height: 700)
    let destinationViewport = Rect(x: 1_300, y: 0, width: 1_000, height: 700)
    let workspace = state.monitors[0].workspaces[0]
    let initial = try #require(computeLayout(
      workspace: workspace, viewport: sourceViewport,
      windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout
    ).first(where: { $0.windowID == windowID })?.frame)
    let released = Rect(
      x: initial.x + initial.width - 250, y: initial.y,
      width: 250, height: initial.height
    )
    let viewports = [monitorID: sourceViewport, destination: destinationViewport]
    #expect(initial.x + initial.width / 2 < destinationViewport.x)
    #expect(released.x + released.width / 2 >= destinationViewport.x)
    #expect(mouseTranslatedTiledWindowID(
      candidateWindowIDs: [windowID], externallyChangedFrames: [windowID: released],
      state: state, viewports: viewports, monitorFrames: viewports
    ) == nil)
    #expect(!reorderTiledWindowAfterCompletedMouseDrag(
      windowID, actualFrame: released, initialFrame: initial,
      state: &state, viewports: viewports, monitorFrames: viewports
    ))
    #expect(state.monitorID(containing: windowID) == monitorID)
  }

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

  @Test(
    arguments: [
      (320.0, 40.0, nil, nil, Rect(x: 320, y: 40, width: 784, height: 684)),
      (nil, nil, nil, nil, Rect(x: 0, y: 20, width: 784, height: 684)),
      (320.0, 40.0, 640.0, 600.0, Rect(x: 320, y: 40, width: 640, height: 600)),
    ] as [(Double?, Double?, Double?, Double?, Rect)]
  )
  func `Mouse gesture origin uses displayed animation geometry`(
    displayedX: Double?,
    displayedY: Double?,
    displayedWidth: Double?,
    displayedHeight: Double?,
    expected: Rect
  ) {
    let observedFrame = Rect(x: 0, y: 20, width: 784, height: 684)

    #expect(
      resolvedMouseGestureOriginFrame(
        observedFrame: observedFrame,
        displayedX: displayedX,
        displayedY: displayedY,
        displayedWidth: displayedWidth,
        displayedHeight: displayedHeight
      ) == expected)
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
        viewports: [monitorID: viewport],
        monitorFrames: [monitorID: viewport]
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
  func `Post release settlement waits for a stable late frame, else its deadline, and learns from it`() {
    let initial = Rect(x: 0, y: 0, width: 500, height: 700)
    let released = Rect(x: 300, y: 0, width: 500, height: 700)
    let late = Rect(x: 700, y: 0, width: 500, height: 700)
    let fast = mouseGestureSettlementMaximumDuration(latencySensitive: false)
    #expect(mouseGestureSettlementMaximumDuration(latencySensitive: true) > fast, "slow apps get longer")
    func settlement(_ duration: Double) -> MouseGestureSettlement {
      MouseGestureSettlement(generation: 4, windowID: WindowID(rawValue: 1), initialFrame: initial,
        releasedFrame: released, now: 10, maximumDuration: duration)
    }
    let changed = advanceMouseGestureSettlement(settlement(0.8), actualFrame: late, now: 10.1)
    #expect(!changed.shouldFinish)
    #expect(changed.settlement.observedPostReleaseChange)
    #expect(advanceMouseGestureSettlement(changed.settlement, actualFrame: late, now: 10.16).shouldFinish)
    #expect(!advanceMouseGestureSettlement(settlement(fast), actualFrame: released, now: 10 + fast / 2).shouldFinish)
    #expect(advanceMouseGestureSettlement(settlement(fast), actualFrame: released, now: 10 + fast).shouldFinish)
    let external = Rect(x: 0, y: 0, width: 600, height: 700)
    #expect(mouseGestureWidthLearningFrame(externallyChangedFrame: external, actualFrame: late,
      postReleaseSettlementActive: true) == external)
    #expect(mouseGestureWidthLearningFrame(externallyChangedFrame: nil, actualFrame: late,
      postReleaseSettlementActive: true) == late)
    #expect(mouseGestureWidthLearningFrame(externallyChangedFrame: nil, actualFrame: late,
      postReleaseSettlementActive: false) == nil)
  }

  @Test
  func `Post release settlement ignores a late frame matching a Defi write`() {
    let external = Rect(x: 0, y: 0, width: 600, height: 700)
    let delayedWrite = Rect(x: 0, y: 0, width: 800, height: 700)

    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: nil,
        actualFrame: delayedWrite,
        postReleaseSettlementActive: true,
        actualFrameMatchesRecentDefiWrite: true
      ) == nil)
    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: external,
        actualFrame: delayedWrite,
        postReleaseSettlementActive: true,
        actualFrameMatchesRecentDefiWrite: true
      ) == external)
  }

  @Test
  func `Overlay stretch learns the width once, on release`() {
    let dragged = Rect(x: 0, y: 0, width: 600, height: 700)
    let released = Rect(x: 0, y: 0, width: 640, height: 700)

    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: dragged,
        actualFrame: dragged,
        postReleaseSettlementActive: false,
        overlayHoldsGesture: true
      ) == nil)
    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: nil,
        actualFrame: released,
        postReleaseSettlementActive: false,
        releasedResizeFrame: released
      ) == released)
    #expect(
      mouseGestureWidthLearningFrame(
        externallyChangedFrame: dragged,
        actualFrame: dragged,
        postReleaseSettlementActive: false
      ) == dragged)
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
        viewports: [monitorID: viewport],
        monitorFrames: [monitorID: viewport]
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
        viewports: [monitorID: viewport],
        monitorFrames: [monitorID: viewport]
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
        viewports: [monitorID: viewport],
        monitorFrames: [monitorID: viewport]
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
        viewports: [monitorID: viewport],
        monitorFrames: [monitorID: viewport]
      ) == nil)
  }

  @Test
  func `Dropping over the middle of another column stacks the window into it`() throws {
    var state = try makeState(windowCount: 3)
    let dragged = WindowID(rawValue: 1)
    let host = try targetFrame(for: WindowID(rawValue: 2), state: state)
    let target = try #require(mouseStackTarget(
      dragged, pointer: (host.x + host.width / 2, host.y + host.height * 3 / 4),
      state: state, viewports: [monitorID: viewport]))
    #expect(target.row == 1)
    #expect(target.preview.height == host.height / 2)
    #expect(stackTiledWindow(dragged, into: target, state: &state, viewports: [monitorID: viewport]))
    #expect(state.monitors[0].workspaces[0].columns.map(\.windows) == [
      [WindowID(rawValue: 2), WindowID(rawValue: 1)],
      [WindowID(rawValue: 3)],
    ])
    #expect(state.monitors[0].workspaces[0].focusedColumn == 0)
    #expect(state.monitors[0].workspaces[0].columns[0].focusedWindow == 1)
  }

  @Test
  func `The edges of a column reorder instead of stacking`() throws {
    let state = try makeState(windowCount: 3)
    let host = try targetFrame(for: WindowID(rawValue: 2), state: state)
    #expect(mouseStackTarget(
      WindowID(rawValue: 1), pointer: (host.x + 10, host.y + host.height / 2),
      state: state, viewports: [monitorID: viewport]) == nil)
  }

  @Test
  func `Pulling a stacked window sideways out of its column unstacks it`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.joinWindow(.left), on: monitorID, state: &state)
    let columns = state.monitors[0].workspaces[0].columns.map(\.windows)
    let stacked = try #require(columns.first { $0.count == 2 })
    let dragged = stacked[1]
    let frame = try targetFrame(for: dragged, state: state)
    #expect(reorderTiledWindowAfterMouseDrag(
      dragged,
      actualFrame: Rect(x: frame.x + frame.width * 0.7, y: frame.y, width: frame.width, height: frame.height),
      state: &state, viewports: [monitorID: viewport]))
    let after = state.monitors[0].workspaces[0].columns.map(\.windows)
    #expect(after.count == columns.count + 1)
    #expect(after.contains([dragged]))
    #expect(after.contains([stacked[0]]))
  }

  @Test
  func `The drop target follows the pointer and applies exactly what it previews`() throws {
    var state = try makeState(windowCount: 3)
    let dragged = WindowID(rawValue: 2)
    let first = try targetFrame(for: WindowID(rawValue: 1), state: state)
    let target = try #require(mouseDropTarget(
      dragged, pointer: (first.x + 5, first.y + 5), state: state, viewports: [monitorID: viewport]))
    #expect(target == .column(index: 0))
    #expect(applyMouseDrop(dragged, target, state: &state, viewports: [monitorID: viewport]))
    #expect(state.monitors[0].workspaces[0].columns.map(\.windows) == [
      [WindowID(rawValue: 2)], [WindowID(rawValue: 1)], [WindowID(rawValue: 3)],
    ])
  }

  @Test
  func `Dropping a window back on its own place changes nothing`() throws {
    var state = try makeState(windowCount: 3)
    let dragged = WindowID(rawValue: 1)
    let own = try targetFrame(for: dragged, state: state)
    let target = try #require(mouseDropTarget(
      dragged, pointer: (own.x + 5, own.y + 5), state: state, viewports: [monitorID: viewport]))
    #expect(target == .column(index: 0))
    #expect(!applyMouseDrop(dragged, target, state: &state, viewports: [monitorID: viewport]))
  }

  @Test
  func `A click or a vertical drag inside its own stack previews no drop`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.joinWindow(.left), on: monitorID, state: &state)
    let stacked = try #require(state.monitors[0].workspaces[0].columns.first { $0.windows.count == 2 })
    let frame = try targetFrame(for: stacked.windows[1], state: state)
    #expect(mouseDropTarget(
      stacked.windows[1], pointer: (frame.x + frame.width / 2, frame.y + 5),
      state: state, viewports: [monitorID: viewport]) == nil)
  }

  @Test
  func `A pointer off the monitor leaves the drop to the cross-display path`() throws {
    let state = try makeState(windowCount: 3)
    #expect(mouseDropTarget(
      WindowID(rawValue: 1), pointer: (viewport.x + viewport.width + 50, viewport.y + 50),
      state: state, viewports: [monitorID: viewport]) == nil)
  }

  @Test
  func `Leaving a stack keeps the same window focused in it`() throws {
    var state = try makeState(windowCount: 4)
    var workspace = state.monitors[0].workspaces[0]
    let columnIndex = 0
    workspace.columns = [Column(window: WindowID(rawValue: 1), width: workspace.columns[0].width)]
      + workspace.columns.dropFirst(3)
    workspace.columns[0].windows = [1, 2, 3].map { WindowID(rawValue: $0) }
    workspace.columns[columnIndex].focusedWindow = 1
    let focused = workspace.columns[columnIndex].windows[1]
    let leaving = workspace.columns[columnIndex].windows[0]
    state.monitors[0].workspaces[0] = workspace
    #expect(applyMouseDrop(leaving, .column(index: workspace.columns.count), state: &state,
      viewports: [monitorID: viewport]))
    let column = try #require(state.monitors[0].workspaces[0].columns.first { $0.windows.contains(focused) })
    #expect(column.windows[column.focusedWindow] == focused)
  }

  @Test
  func `A pointer resting on a boundary keeps the previewed target`() throws {
    var state = try makeState(windowCount: 3)
    narrowColumns(&state)
    let third = try targetFrame(for: WindowID(rawValue: 3), state: state)
    let stackEdge = third.x + third.width / 4
    let gap = try #require(dropTarget(1, stackEdge - 10, state: state))
    guard case .column = gap, case .stack = dropTarget(1, stackEdge + 5, state: state) else {
      Issue.record("the outer quarter targets a gap and the middle half stacks")
      return
    }
    #expect(dropTarget(1, stackEdge + 5, previous: gap, state: state) == gap)
    guard case .stack = dropTarget(1, stackEdge + 40, previous: gap, state: state) else {
      Issue.record("a clear move past the boundary changes the target")
      return
    }
  }

  @Test
  func `No target under the pointer is never held by the hysteresis`() throws {
    var state = try makeState(windowCount: 3)
    narrowColumns(&state)
    let edge = viewport.x + viewport.width
    let inside = try #require(dropTarget(1, edge - 10, state: state))

    #expect(dropTarget(1, edge + 10, state: state) == nil)
    #expect(dropTarget(1, edge + 10, previous: inside, state: state) == nil)
  }

  @Test
  func `A pointer resting on the edge of a stacked display keeps the previewed target`() throws {
    var state = try makeState(windowCount: 2)
    state.attachMonitor(secondMonitorID)
    let below = Rect(x: 0, y: viewport.height, width: viewport.width, height: viewport.height)
    let viewports = [monitorID: viewport, secondMonitorID: below]
    func target(_ y: Double, previous: MouseDropTarget? = nil) -> MouseDropTarget? {
      mouseDropTarget(WindowID(rawValue: 1), pointer: (viewport.width / 2, y), previous: previous,
        state: state, viewports: viewports, monitorFrames: viewports)
    }
    let above = try #require(target(viewport.height - 10))
    guard case .display = target(viewport.height + 10) else {
      Issue.record("past the edge, the pointer targets the display below")
      return
    }

    #expect(target(viewport.height + 10, previous: above) == above)
  }

  @Test
  func `A drop on another display lands at the gap under the pointer`() throws {
    var (state, viewports) = try makeTwoDisplayState()
    state.monitors[0].workspaces[0].columns[0].width = .pixels(300)
    let destination = state.monitors[1].workspaces[0]
    let frames = computeLayout(
      workspace: destination, viewport: viewports[secondMonitorID]!,
      windows: destination.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout)
    let third = try #require(frames.first { $0.windowID == WindowID(rawValue: 3) }?.frame)
    let target = try #require(mouseDropTarget(
      WindowID(rawValue: 1), pointer: (third.x + third.width / 2 + 10, 350),
      state: state, viewports: viewports, monitorFrames: viewports))

    #expect(target == .display(secondMonitorID, workspaceID: destination.id, gap: 1))
    #expect(applyMouseDrop(WindowID(rawValue: 1), target, state: &state, viewports: viewports,
      monitorFrames: viewports))
    #expect(state.monitors[0].workspaces[0].columns.map { $0.windows.map(\.rawValue) } == [[2]])
    #expect(state.monitors[1].workspaces[0].columns.map { $0.windows.map(\.rawValue) } == [[3], [1], [4]])
    #expect(state.monitors[1].workspaces[0].columns[1].width == .pixels(300))
    #expect(state.selectedWindowID(on: secondMonitorID) == WindowID(rawValue: 1))
  }

  @Test
  func `A display drop preview closes the gap here and opens the slot there`() throws {
    var (state, viewports) = try makeTwoDisplayState()
    let target = MouseDropTarget.display(secondMonitorID, workspaceID: state.monitors[1].workspaces[0].id, gap: 1)
    #expect(applyMouseDrop(WindowID(rawValue: 1), target, state: &state, viewports: viewports,
      monitorFrames: viewports))
    let after = mouseDropPreviewFrames(in: state, viewports: viewports)

    let held = try #require(after[WindowID(rawValue: 1)])
    #expect(held.x >= secondViewport.x && held.x < secondViewport.x + secondViewport.width)
    // The window left behind fills its display.
    let second = try #require(after[WindowID(rawValue: 2)])
    #expect(second.x >= viewport.x && second.x + second.width <= viewport.x + viewport.width)
    // Its new neighbour on the other display makes room after it.
    let fourth = try #require(after[WindowID(rawValue: 4)])
    #expect(fourth.x >= held.x + held.width)
  }

  @Test
  func `A display drop keeps its gap when transient columns move along`() throws {
    var (state, viewports) = try makeTwoDisplayState()
    state.windows[WindowID(rawValue: 2)]?.transientOwnerID = WindowID(rawValue: 1)
    state.monitors[1].workspaces[0].focusedColumn = 0
    let target = MouseDropTarget.display(secondMonitorID, workspaceID: state.monitors[1].workspaces[0].id, gap: 2)

    #expect(applyMouseDrop(WindowID(rawValue: 1), target, state: &state, viewports: viewports,
      monitorFrames: viewports))
    #expect(state.monitors[1].workspaces[0].columns.map { $0.windows.map(\.rawValue) } == [[3], [2], [4], [1]])
  }

  @Test
  func `An empty display workspace takes the window at gap zero`() throws {
    var state = try makeState(windowCount: 2)
    state.attachMonitor(secondMonitorID)
    let viewports = [monitorID: viewport, secondMonitorID: secondViewport]
    let target = try #require(mouseDropTarget(
      WindowID(rawValue: 1), pointer: (1_500, 350), state: state, viewports: viewports, monitorFrames: viewports))

    #expect(target == .display(secondMonitorID, workspaceID: state.monitors[1].activeWorkspace, gap: 0))
    #expect(applyMouseDrop(WindowID(rawValue: 1), target, state: &state, viewports: viewports,
      monitorFrames: viewports))
    #expect(state.monitorID(containing: WindowID(rawValue: 1)) == secondMonitorID)
  }

  @Test
  func `A display drop onto a workspace no longer active changes nothing`() throws {
    var (state, viewports) = try makeTwoDisplayState()
    let target = MouseDropTarget.display(secondMonitorID, workspaceID: state.monitors[1].workspaces[0].id, gap: 1)
    state.monitors[1].activeWorkspace = try #require(state.monitors[1].workspaces.last?.id)
    let before = state

    #expect(!applyMouseDrop(WindowID(rawValue: 1), target, state: &state, viewports: viewports,
      monitorFrames: viewports))
    #expect(state == before)
  }

  private let secondMonitorID = MonitorID(rawValue: 2)
  private let secondViewport = Rect(x: 1_000, y: 0, width: 1_000, height: 700)

  /// Windows 1 and 2 on the first display, 3 and 4 on the second.
  private func makeTwoDisplayState() throws -> (RuntimeState, [MonitorID: Rect]) {
    var state = try makeState(windowCount: 2)
    state.attachMonitor(secondMonitorID)
    for rawID in 3...4 {
      try discoverWindow(
        Window(
          id: WindowID(rawValue: UInt64(rawID)), appID: "editor", title: "Window \(rawID)",
          frame: Rect(x: 1_000, y: 0, width: 784, height: 684), monitorID: secondMonitorID
        ),
        decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &state
      )
    }
    state.monitors[1].workspaces[0].scrollOffset = 0
    state.monitors[1].workspaces[0].targetScrollOffset = 0
    return (state, [monitorID: viewport, secondMonitorID: secondViewport])
  }

  private func narrowColumns(_ state: inout RuntimeState) {
    // Narrow columns keep every column on the monitor.
    for index in state.monitors[0].workspaces[0].columns.indices {
      state.monitors[0].workspaces[0].columns[index].width = .pixels(300)
    }
    state.monitors[0].workspaces[0].scrollOffset = 0
    state.monitors[0].workspaces[0].targetScrollOffset = 0
  }

  private func dropTarget(
    _ rawID: UInt64, _ pointerX: Double, previous: MouseDropTarget? = nil, state: RuntimeState
  ) -> MouseDropTarget? {
    mouseDropTarget(
      WindowID(rawValue: rawID), pointer: (pointerX, viewport.height / 2), previous: previous,
      state: state, viewports: [monitorID: viewport])
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
      ).first(where: { $0.windowID == windowID })?.frame
    )
  }
}

struct DesktopSynchronizationTests {
  struct SynchronizationCase: CustomTestStringConvertible, Sendable {
    let name: String
    var scrollAnimationActive = false
    var mouseGestureSyncPending = false
    var needsDesktopSync = true
    var periodicSyncDue = false
    var commandQuietPeriodElapsed = false
    var nativeFocusSyncPending = false
    var nativeFocusHasNewerHumanIntent = true
    var frameDebtPending = false
    var lifecycleEventPending = false
    let isReady: Bool

    var testDescription: String { name }
  }

  static let synchronizationCases = [
    SynchronizationCase(
      name: "waits for command input to settle",
      periodicSyncDue: true,
      isReady: false
    ),
    SynchronizationCase(
      name: "native focus sync bypasses command quiet period",
      nativeFocusSyncPending: true,
      isReady: true
    ),
    SynchronizationCase(
      name: "lifecycle event bypasses command quiet period",
      lifecycleEventPending: true,
      isReady: true
    ),
    SynchronizationCase(
      name: "lifecycle event waits for scroll animation",
      scrollAnimationActive: true,
      lifecycleEventPending: true,
      isReady: false
    ),
    SynchronizationCase(
      name: "native focus sync bypasses scroll animation",
      scrollAnimationActive: true,
      nativeFocusSyncPending: true,
      isReady: true
    ),
    SynchronizationCase(
      name: "frame debt bypasses command quiet period",
      frameDebtPending: true,
      isReady: true
    ),
  ]

  @Test(arguments: synchronizationCases)
  func desktopSynchronizationReadinessFollowsPendingWork(_ scenario: SynchronizationCase) {
    #expect(
      desktopSynchronizationIsReady(
        scrollAnimationActive: scenario.scrollAnimationActive,
        mouseGestureSyncPending: scenario.mouseGestureSyncPending,
        needsDesktopSync: scenario.needsDesktopSync,
        periodicSyncDue: scenario.periodicSyncDue,
        commandQuietPeriodElapsed: scenario.commandQuietPeriodElapsed,
        nativeFocusSyncPending: scenario.nativeFocusSyncPending,
        nativeFocusHasNewerHumanIntent: scenario.nativeFocusHasNewerHumanIntent,
        frameDebtPending: scenario.frameDebtPending,
        lifecycleEventPending: scenario.lifecycleEventPending
      ) == scenario.isReady
    )
  }
}
