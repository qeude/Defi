import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct DragEdgeScrollTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
  private let held = WindowID(rawValue: 1)
  private let rate = 120.0
  private var right: (x: Double, y: Double) { (viewport.width - 4, 350) }

  @Test
  func dwellsBeforeScrollingAndNeverCatchesUp() throws {
    let state = try makeState()
    var edge = try #require(session(state))
    let entered = edge.advance(pointer: right, now: 0, refreshRate: rate, state: state)
    #expect(entered)
    #expect(edge.isInEdgeZone && !edge.scrolled)
    edge.advance(pointer: right, now: 0.1, refreshRate: rate, state: state)
    edge.advance(pointer: right, now: DragEdgeScroll.dwell, refreshRate: rate, state: state)
    // The dwell ends: scrolling starts from now, without paying the dwell back as distance.
    #expect(!edge.scrolled)
    var now = DragEdgeScroll.dwell
    var previous = edge.offset
    let strip = stripViewport(viewport, settings: state.layout).width
    let largest = DragEdgeScroll.speeds.upperBound * viewport.width * 2 / rate / strip
    for gap in [1 / rate, 1 / rate, 1.0, 1 / rate] {
      now += gap
      let moved = edge.advance(pointer: right, now: now, refreshRate: rate, state: state)
      #expect(moved)
      // Monotonic, and a late tick moves at most two frames' worth.
      #expect(edge.offset > previous)
      #expect(edge.offset - previous <= largest + 1e-9)
      previous = edge.offset
    }
  }

  @Test
  func stopsAtTheStripEndAndDropsAfterTheLastColumn() throws {
    let state = try makeState()
    var edge = try #require(session(state))
    var now = 0.0
    for _ in 0..<2_000 {
      edge.advance(pointer: right, now: now, refreshRate: rate, state: state)
      now += 1 / rate
    }
    let end = edge.offset
    edge.advance(pointer: right, now: now, refreshRate: rate, state: state)
    #expect(edge.offset == end)
    let viewed = edge.applied(to: state)
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0)  // the drag never writes the state
    #expect(mouseDropTarget(held, pointer: edge.targetPointer(right), allowsStacking: !edge.isInEdgeZone,
      state: viewed, viewports: [monitorID: viewport]) == .column(index: 4))
  }

  @Test
  func columnsPassingUnderTheZoneNeverOfferAStack() throws {
    var state = try makeState()
    // A column's middle under the pointer at the right edge.
    let layout = computeLayout(workspace: state.monitors[0].workspaces[0], viewport: viewport,
      windows: state.monitors[0].workspaces[0].columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout)
    let second = try #require(layout.first { $0.windowID == WindowID(rawValue: 2) }?.frame)
    restoreWorkspaceScroll(WorkspaceScrollAnchor(monitorID: monitorID,
      workspaceID: state.monitors[0].workspaces[0].id,
      scrollOffset: (second.x + second.width / 2 - right.x) / stripViewport(viewport, settings: state.layout).width),
      state: &state)
    var edge = try #require(session(state))
    edge.advance(pointer: right, now: 0, refreshRate: rate, state: state)
    guard case .stack = try #require(mouseDropTarget(held, pointer: right, state: state,
      viewports: [monitorID: viewport])) else { Issue.record("expected a stack outside the zone"); return }
    guard case .column = try #require(mouseDropTarget(held, pointer: right, allowsStacking: !edge.isInEdgeZone,
      state: edge.applied(to: state), viewports: [monitorID: viewport])) else {
      Issue.record("expected a new column in the zone"); return
    }
  }

  @Test
  func leavingTheZoneStopsPastTheHysteresis() throws {
    let state = try makeState()
    var edge = try #require(session(state))
    var now = 0.0
    for _ in 0..<60 {
      edge.advance(pointer: right, now: now, refreshRate: rate, state: state)
      now += 1 / rate
    }
    let zoneStart = viewport.width - DragEdgeScroll.zoneWidth
    var previous = edge.offset
    edge.advance(pointer: (zoneStart - DragEdgeScroll.hysteresis / 2, 350), now: now, refreshRate: rate, state: state)
    #expect(edge.offset > previous)  // still inside the hysteresis
    previous = edge.offset
    now += 1 / rate
    edge.advance(pointer: (zoneStart - DragEdgeScroll.hysteresis - 1, 350), now: now, refreshRate: rate, state: state)
    #expect(!edge.isInEdgeZone && edge.offset == previous)
    // Coming back dwells again.
    now += 1 / rate
    edge.advance(pointer: right, now: now, refreshRate: rate, state: state)
    edge.advance(pointer: right, now: now + 1 / rate, refreshRate: rate, state: state)
    #expect(edge.offset == previous)
  }

  @Test
  func aNeighborDisplayIsNoEdgeButASideDockIs() throws {
    let state = try makeState()
    // A Dock on the right: the viewport stops 60 points before the screen edge.
    let docked = Rect(x: 0, y: 0, width: 940, height: 700)
    let screen = Rect(x: 0, y: 0, width: 1_000, height: 700)
    var edge = try #require(DragEdgeScroll(windowID: held, state: state,
      viewports: [monitorID: docked], monitorFrames: [monitorID: screen]))
    let pushed = (x: 999.0, y: 350.0)
    #expect(edge.targetPointer(pushed).x == docked.width)
    edge.advance(pointer: pushed, now: 0, refreshRate: rate, state: state)
    #expect(edge.isInEdgeZone)
    // Past the screen, the pointer is over another display: no scrolling, no clamping.
    let beyond = (x: 1_010.0, y: 350.0)
    edge.advance(pointer: beyond, now: 0.01, refreshRate: rate, state: state)
    #expect(!edge.isInEdgeZone)
    #expect(edge.targetPointer(beyond).x == beyond.x)
  }

  @Test
  func topologyChangesEndTheSession() throws {
    var state = try makeState()
    let edge = try #require(session(state))
    let viewports = [monitorID: viewport]
    #expect(edge.isCurrent(state: state, viewports: viewports, monitorFrames: viewports))
    #expect(!edge.isCurrent(state: state, viewports: [monitorID: Rect(x: 0, y: 25, width: 1_000, height: 675)],
      monitorFrames: viewports))
    state.windows[held]?.floating = true
    #expect(!edge.isCurrent(state: state, viewports: viewports, monitorFrames: viewports))
    #expect(DragEdgeScroll(windowID: held, state: state, viewports: viewports, monitorFrames: viewports) == nil)
  }

  private func session(_ state: RuntimeState) -> DragEdgeScroll? {
    DragEdgeScroll(windowID: held, state: state, viewports: [monitorID: viewport],
      monitorFrames: [monitorID: viewport])
  }

  /// Five single-window columns, the strip scrolled to its start.
  private func makeState() throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for rawID in 1...5 {
      try discoverWindow(
        Window(id: WindowID(rawValue: UInt64(rawID)), appID: "editor", title: "Window \(rawID)",
          frame: Rect(x: 0, y: 0, width: 784, height: 684), monitorID: monitorID),
        decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &state)
    }
    restoreWorkspaceScroll(
      WorkspaceScrollAnchor(monitorID: monitorID, workspaceID: state.monitors[0].workspaces[0].id, scrollOffset: 0),
      state: &state)
    return state
  }
}
