import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
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
          x: target.x - 500,
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
      x: target.x + 500,
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

  func testFocusedTiledWindowStartsMouseGestureBeforeFrameMoves() throws {
    let state = try makeState(windowCount: 2)
    let focusedID = WindowID(rawValue: 2)

    XCTAssertEqual(
      mouseGestureTiledWindowID(
        translatedWindowID: nil,
        activeWindowID: nil,
        focusedWindowID: focusedID,
        state: state
      ),
      focusedID
    )
  }

  func testTranslatedWindowReplacesStaleGestureCandidate() throws {
    let state = try makeState(windowCount: 2)
    let translatedID = WindowID(rawValue: 2)

    XCTAssertEqual(
      mouseGestureTiledWindowID(
        translatedWindowID: translatedID,
        activeWindowID: WindowID(rawValue: 1),
        focusedWindowID: WindowID(rawValue: 1),
        state: state
      ),
      translatedID
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

  func testResizeIsNotClassifiedAsTranslation() throws {
    let state = try makeState(windowCount: 1)
    let windowID = WindowID(rawValue: 1)
    let target = try targetFrame(for: windowID, state: state)

    XCTAssertNil(
      mouseTranslatedTiledWindowID(
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

  func testTranslationCandidateIgnoresFloatingWindows() throws {
    var state = try makeState(windowCount: 1)
    try reduce(.toggleFloating, on: monitorID, state: &state)
    let windowID = WindowID(rawValue: 1)

    XCTAssertNil(
      mouseTranslatedTiledWindowID(
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
      try discoverWindow(window, decision: RuleDecision(), state: &state)
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
