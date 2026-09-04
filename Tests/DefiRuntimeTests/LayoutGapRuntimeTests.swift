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
      ),
      decorations: DecorationsConfig(
        borders: BordersConfig(placement: "inside")
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
  func outsideBorderReservesEveryViewportEdge() {
    let config = Config(
      layout: LayoutConfig(
        gaps: 4,
        outerTopGap: 1,
        outerRightGap: 2,
        outerBottomGap: 0,
        outerLeftGap: 3
      ),
      decorations: DecorationsConfig(
        borders: BordersConfig(width: 4, placement: "outside")
      )
    )

    let layout = RuntimeState(config: config).layout

    #expect(layout.innerHorizontalGap == 2)
    #expect(layout.outerTopGap == 4)
    #expect(layout.outerRightGap == 4)
    #expect(layout.outerBottomGap == 4)
    #expect(layout.outerLeftGap == 4)
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

    #expect(state.monitors[0].workspaces[workspaceIndex].targetScrollOffset == 0)
    #expect(frame.x + frame.width == 998)

    state.monitors[0].workspaces[workspaceIndex].scrollOffset = 0.5
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    state.monitors[0].workspaces[workspaceIndex].scrollOffset =
      state.monitors[0].workspaces[workspaceIndex].targetScrollOffset
    let leftAlignedFrame = computeLayout(
      workspace: state.monitors[0].workspaces[workspaceIndex],
      viewport: viewport,
      settings: state.layout
    ).frames[1].frame

    #expect(state.monitors[0].workspaces[workspaceIndex].targetScrollOffset == 0.5)
    #expect(leftAlignedFrame.x == 2)
  }

  @Test
  func configReloadPreservesLayoutStateAndOnlyRequestsNecessaryReflows() {
    let monitorID = MonitorID(rawValue: 1)
    let windowID = WindowID(rawValue: 1)
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev"]))
    )
    state.attachMonitor(monitorID)
    state.monitors[0].workspaces[0].columns = [
      Column(window: windowID, width: .pixels(640))
    ]
    state.monitors[0].workspaces[0].scrollOffset = 0.25
    state.windows[windowID] = Window(
      id: windowID,
      appID: "test",
      title: "Test",
      frame: Rect(x: 0, y: 0, width: 640, height: 800)
    )

    let defaultsOnly = state.applyConfiguration(
      Config(
        layout: LayoutConfig(
          defaultColumnWidth: 0.5,
          presetColumnWidths: [0.5, 1]
        ),
        workspaces: WorkspacesConfig(names: ["dev"])
      )
    )

    #expect(defaultsOnly == false)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(640))
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.25)

    let geometryChanged = state.applyConfiguration(
      Config(
        layout: LayoutConfig(gaps: 20),
        workspaces: WorkspacesConfig(names: ["dev", "web"])
      )
    )

    #expect(geometryChanged)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(640))
    #expect(state.monitors[0].workspaces[0].columns[0].windows == [windowID])
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.25)
    #expect(state.monitors[0].workspaces.contains { $0.id == WorkspaceID(rawValue: "web") })
  }
}
