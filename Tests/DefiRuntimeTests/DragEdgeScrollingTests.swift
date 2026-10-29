import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct DragEdgeScrollingTests {
  let monitor = MonitorID(rawValue: 1)
  let window = WindowID(rawValue: 1)
  let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  func fixture() throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitor)
    for id in 1...5 {
      try discoverWindow(Window(id: WindowID(rawValue: UInt64(id)), appID: "test", title: "test",
        frame: viewport, monitorID: monitor), decision: RuleDecision(followFocus: true),
        isNativelyFocused: true, state: &state)
    }
    focusWindow(window, state: &state)
    restoreWorkspaceScroll(workspaceScrollAnchor(containing: window, state: state)!, state: &state)
    state.monitors[0].workspaces[0].scrollOffset = 0
    state.monitors[0].workspaces[0].targetScrollOffset = 0
    return state
  }

  @Test
  func dwellStationaryMotionAndBoundedCatchUp() throws {
    var state = try fixture()
    var drag = try #require(DragEdgeScrolling(windowID: window, generation: 1,
      state: state, viewports: [monitor: viewport], monitorFrames: [monitor: viewport]))
    let original = state
    #expect(!drag.advance(pointer: (995, 200), now: 0, refreshRate: 60, state: &state))
    #expect(!drag.advance(pointer: (995, 200), now: 0.19, refreshRate: 60, state: &state))
    #expect(state == original)
    #expect(drag.advance(pointer: (995, 200), now: 0.21, refreshRate: 60, state: &state))
    let first = state.monitors[0].workspaces[0].scrollOffset
    #expect(first > 0 && first <= 0.015)
    #expect(drag.advance(pointer: (995, 200), now: 10, refreshRate: 60, state: &state))
    #expect(state.monitors[0].workspaces[0].scrollOffset - first <= 0.015)
    #expect(state.monitors[0].workspaces[0].columns == original.monitors[0].workspaces[0].columns)
    #expect(state.selectedWindowID(on: monitor) == original.selectedWindowID(on: monitor))
    #expect(state.windows == original.windows)
    #expect(!drag.advance(pointer: (500, 200), now: 10.01, refreshRate: 60, state: &state))
    #expect(!drag.advance(pointer: (995, 200), now: 10.02, refreshRate: 60, state: &state))
  }

  @Test(arguments: [30.0, 60.0, 120.0])
  func boundsHysteresisAndReverseDwell(refresh: Double) throws {
    var state = try fixture()
    var drag = try #require(DragEdgeScrolling(windowID: window, generation: 1,
      state: state, viewports: [monitor: viewport], monitorFrames: [monitor: viewport]))
    _ = drag.advance(pointer: (999, 200), now: 0, refreshRate: refresh, state: &state)
    #expect(drag.advance(pointer: (945, 200), now: 0.21, refreshRate: refresh, state: &state))
    let hysteresisOffset = state.monitors[0].workspaces[0].scrollOffset
    #expect(!drag.advance(pointer: (930, 200), now: 0.22, refreshRate: refresh, state: &state))
    #expect(state.monitors[0].workspaces[0].scrollOffset == hysteresisOffset)
    for tick in 0...Int(refresh * 10) {
      _ = drag.advance(pointer: (999, 200), now: 1 + Double(tick) / refresh, refreshRate: refresh, state: &state)
    }
    let maximum = state.monitors[0].workspaces[0].scrollOffset
    #expect(maximum > 2 && maximum < 4)
    #expect(!drag.advance(pointer: (999, 200), now: 12, refreshRate: refresh, state: &state))
    #expect(!drag.advance(pointer: (1, 200), now: 13, refreshRate: refresh, state: &state))
    #expect(!drag.advance(pointer: (1, 200), now: 13.19, refreshRate: refresh, state: &state))
    for tick in 0...Int(refresh * 10) {
      _ = drag.advance(pointer: (1, 200), now: 13.21 + Double(tick) / refresh, refreshRate: refresh, state: &state)
    }
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0)
    #expect(!drag.advance(pointer: (1, 200), now: 24, refreshRate: refresh, state: &state))
  }

  @Test
  func cancellationRestoresAndCommitRetainsScroll() throws {
    var state = try fixture()
    var drag = try #require(DragEdgeScrolling(windowID: window, generation: 8,
      state: state, viewports: [monitor: viewport], monitorFrames: [monitor: viewport]))
    let original = state
    _ = drag.advance(pointer: (999, 200), now: 0, refreshRate: 120, state: &state)
    _ = drag.advance(pointer: (999, 200), now: 0.3, refreshRate: 120, state: &state)
    #expect(state != original)
    let committed = drag.currentAnchor(state: state)
    #expect(committed.scrollOffset > 0)
    drag.cancel(state: &state)
    #expect(state == original)
  }

  @Test
  func neighborAndTopologyDoNotMutateOtherMonitor() throws {
    var state = try fixture()
    let other = MonitorID(rawValue: 2)
    state.attachMonitor(other)
    let neighbor = Rect(x: 1_000, y: 0, width: 1_000, height: 700)
    var drag = try #require(DragEdgeScrolling(windowID: window, generation: 1,
      state: state, viewports: [monitor: viewport, other: neighbor],
      monitorFrames: [monitor: viewport, other: neighbor]))
    let original = state
    _ = drag.advance(pointer: (1_001, 200), now: 0, refreshRate: 60, state: &state)
    #expect(!drag.advance(pointer: (1_001, 200), now: 1, refreshRate: 60, state: &state))
    #expect(state == original)
    #expect(drag.isCurrent(generation: 1, state: state,
      viewports: [monitor: viewport, other: neighbor], monitorFrames: [monitor: viewport, other: neighbor]))
    #expect(!drag.isCurrent(generation: 2, state: state,
      viewports: [monitor: viewport, other: neighbor], monitorFrames: [monitor: viewport, other: neighbor]))
    #expect(!drag.isCurrent(generation: 1, state: state,
      viewports: [monitor: viewport], monitorFrames: [monitor: viewport]))
    state.monitors[1].activeWorkspace = WorkspaceID(rawValue: "changed")
    #expect(!drag.isCurrent(generation: 1, state: state,
      viewports: [monitor: viewport, other: neighbor], monitorFrames: [monitor: viewport, other: neighbor]))
  }

  @Test
  func scrollChangesTargetsAndPreviewWithoutChangingMembership() throws {
    var state = try fixture()
    var drag = try #require(DragEdgeScrolling(windowID: window, generation: 1,
      state: state, viewports: [monitor: viewport], monitorFrames: [monitor: viewport]))
    let original = state
    let initialTarget = mouseDropTarget(window, pointer: (990, 200), state: state, viewports: [monitor: viewport])
    let initialFrames = mouseDropPreviewFrames(in: state, viewports: [monitor: viewport])
    for tick in 0...240 {
      _ = drag.advance(pointer: (990, 200), now: Double(tick) / 60, refreshRate: 60, state: &state)
    }
    let target = try #require(mouseDropTarget(window, pointer: (990, 200), state: state, viewports: [monitor: viewport]))
    #expect(target != initialTarget)
    #expect(mouseDropPreviewFrames(in: state, viewports: [monitor: viewport]) != initialFrames)
    #expect(state.monitors[0].workspaces[0].columns == original.monitors[0].workspaces[0].columns)
    let anchor = drag.currentAnchor(state: state)
    #expect(applyMouseDrop(window, target, state: &state, viewports: [monitor: viewport]))
    restoreWorkspaceScroll(anchor, state: &state)
    #expect(state.monitors[0].workspaces[0].scrollOffset == anchor.scrollOffset)
    #expect(state.selectedWindowID(on: monitor) == window)
  }
}
