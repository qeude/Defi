import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct WindowDragResizeTests {
  private let frame = Rect(x: 100, y: 0, width: 600, height: 900)

  @Test(arguments: [
    (150.0, 100.0, true, WindowResizeEdges.Vertical.top),
    (650, 450, false, nil),
    (650, 850, false, .bottom),
    (150, 450, true, nil),
  ] as [(Double, Double, Bool, WindowResizeEdges.Vertical?)])
  func pointerPicksTheNearestSideAndOuterThirds(x: Double, y: Double, left: Bool, vertical: WindowResizeEdges.Vertical?) {
    #expect(WindowResizeEdges(pointer: (x, y), frame: frame) == WindowResizeEdges(left: left, vertical: vertical))
  }

  @Test
  func draggedEdgesMoveAndTheOppositeOnesStay() {
    let left = windowResizedFrame(frame, edges: WindowResizeEdges(left: true, vertical: .top), dx: -50, dy: 30)
    #expect(left == Rect(x: 50, y: 30, width: 650, height: 870))
    let right = windowResizedFrame(frame, edges: WindowResizeEdges(left: false, vertical: .bottom), dx: -1_000, dy: 10)
    #expect(right == Rect(x: 100, y: 0, width: 50, height: 910))
  }

  @Test
  func leftEdgeResizeKeepsTheRightEdgeByScrollingTheStrip() throws {
    let monitorID = MonitorID(rawValue: 1)
    let viewport = Rect(x: 0, y: 0, width: 2_000, height: 1_000)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let ids = (1...5).map { WindowID(rawValue: UInt64($0)) }
    for id in ids {
      state.windows[id] = Window(id: id, appID: "app", title: "", frame: Rect(x: 0, y: 0, width: 600, height: 900),
        monitorID: monitorID)
    }
    state.monitors[0].workspaces[0].columns = ids.map { Column(window: $0, width: .pixels(800)) }
    state.monitors[0].workspaces[0].focusedColumn = 3
    let viewports = [monitorID: viewport]
    synchronizeScrollOffsets(state: &state, viewports: viewports)
    let before = try #require(mouseDropPreviewFrames(in: state, viewports: viewports)[ids[3]])
    let resized = tiledWindowResized(ids[3], from: before, edges: WindowResizeEdges(left: true, vertical: nil),
      dx: -100, dy: 0, state: state, viewports: viewports)
    let after = try #require(mouseDropPreviewFrames(in: resized, viewports: viewports)[ids[3]])
    #expect(abs(after.width - before.width - 100) < 1)
    #expect(abs((after.x + after.width) - (before.x + before.width)) < 1, "\(before) \(after)")
  }
}
