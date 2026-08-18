import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct BackgroundWindowDiscoveryTests {
  @Test
  func tiledWindowDiscoveredWithoutFollowFocusPreservesSelectionAndScroll() throws {
    let monitorID = MonitorID(rawValue: 1)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let selectedWindow = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Selected",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    let backgroundWindow = Window(
      id: WindowID(rawValue: 2),
      appID: "mail",
      title: "Background",
      frame: Rect(x: 600, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )

    try discoverWindow(
      selectedWindow,
      decision: RuleDecision(followFocus: true),
      state: &state
    )
    state.monitors[0].workspaces[0].scrollOffset = 0.25
    state.monitors[0].workspaces[0].targetScrollOffset = 0.25

    try discoverWindow(backgroundWindow, decision: RuleDecision(), state: &state)

    #expect(state.selectedWindowID(on: monitorID) == selectedWindow.id)
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.25)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.25)
  }
}
