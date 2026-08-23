import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct LayoutGapRuntimeTests {
  @Test
  func mapsOuterOverridesAndFallsBackToUniformGap() {
    let config = Config(
      layout: LayoutConfig(
        gaps: 8,
        outerTopGap: 1,
        outerBottomGap: 0
      )
    )

    let state = RuntimeState(config: config)

    #expect(state.layout.innerHorizontalGap == 4)
    #expect(state.layout.innerVerticalGap == 4)
    #expect(state.layout.outerTopGap == 1)
    #expect(state.layout.outerRightGap == 8)
    #expect(state.layout.outerBottomGap == 0)
    #expect(state.layout.outerLeftGap == 8)
  }

  @Test
  func outsideBorderStaysInsideViewportAtScrolledEdges() {
    let config = Config(
      layout: LayoutConfig(gaps: 4),
      decorations: DecorationsConfig(
        borders: BordersConfig(width: 4, placement: "outside")
      )
    )
    let monitorID = MonitorID(rawValue: 1)
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let workspaceIndex = 0
    state.monitors[0].workspaces[workspaceIndex].columns = (1...3).map {
      Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5))
    }
    state.monitors[0].workspaces[workspaceIndex].focusedColumn = 1

    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    state.monitors[0].workspaces[workspaceIndex].scrollOffset =
      state.monitors[0].workspaces[workspaceIndex].targetScrollOffset
    let frame = computeLayout(
      workspace: state.monitors[0].workspaces[workspaceIndex],
      viewport: viewport,
      settings: state.layout
    ).frames[1].frame

    #expect(frame.x + frame.width == 996)

    state.monitors[0].workspaces[workspaceIndex].scrollOffset = 0.5
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    state.monitors[0].workspaces[workspaceIndex].scrollOffset =
      state.monitors[0].workspaces[workspaceIndex].targetScrollOffset
    let leftAlignedFrame = computeLayout(
      workspace: state.monitors[0].workspaces[workspaceIndex],
      viewport: viewport,
      settings: state.layout
    ).frames[1].frame

    #expect(leftAlignedFrame.x == 4)
  }
}
