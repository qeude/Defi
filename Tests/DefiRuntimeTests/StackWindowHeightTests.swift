import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct StackWindowHeightTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 1_000)
  private let ids = (1...8).map { WindowID(rawValue: $0) }

  private func stackState(focusedWindow: Int = 0, count: Int = 3) -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.layout = LayoutSettings(
      innerHorizontalGap: 0, innerVerticalGap: 0,
      outerTopGap: 0, outerRightGap: 0, outerBottomGap: 0, outerLeftGap: 0
    )
    state.attachMonitor(monitorID)
    for id in ids.prefix(count) {
      state.windows[id] = Window(
        id: id, appID: "app", title: "\(id.rawValue)",
        frame: Rect(x: 0, y: 0, width: 500, height: 300), monitorID: monitorID
      )
    }
    state.monitors[0].workspaces[0].columns = [
      Column(windows: Array(ids.prefix(count)), focusedWindow: focusedWindow, width: .fraction(0.5))
    ]
    return state
  }

  private func heights(_ state: RuntimeState) -> [Double] {
    computeLayout(
      workspace: state.monitors[0].workspaces[0], viewport: viewport,
      windows: Array(state.windows.values), settings: state.layout
    ).map { ($0.frame.height).rounded() }
  }

  private func apply(_ command: String, _ state: inout RuntimeState) throws {
    try reduce(
      parseCommand(command), on: monitorID, state: &state, viewports: [monitorID: viewport]
    )
  }

  @Test
  func `Height commands resize the focused window and the siblings absorb it`() throws {
    var state = stackState()
    try apply("set-window-height 50%", &state)
    #expect(heights(state) == [500, 250, 250])
    try apply("set-window-height +10%", &state)
    #expect(heights(state) == [600, 200, 200])
    try apply("set-window-height 300", &state)
    #expect(heights(state) == [300, 350, 350])
    try apply("reset-window-height", &state)
    #expect(heights(state) == [333, 333, 333])
    #expect(state.monitors[0].workspaces[0].columns[0].windowHeights == nil)
  }

  @Test
  func `Preset heights cycle and wrap`() throws {
    var state = stackState(focusedWindow: 1, count: 2)
    try apply("switch-preset-window-height", &state)
    #expect(heights(state) == [340, 660])
    try apply("switch-preset-window-height", &state)
    #expect(heights(state) == [670, 330])
    try apply("switch-preset-window-height", &state)
    #expect(heights(state) == [500, 500])
  }

  @Test
  func `A preset the stack cannot hold still wraps`() throws {
    // Eight windows leave the focused one at most 65%, below the 0.66 preset.
    var state = stackState(count: 8)
    var focused: [Double] = []
    for _ in 0..<4 {
      try apply("switch-preset-window-height", &state)
      focused.append(heights(state)[0])
    }
    #expect(focused == [330, 500, 650, 330])
  }

  @Test
  func `A single window keeps filling its column`() throws {
    var state = stackState(count: 1)
    try apply("set-window-height 30%", &state)
    #expect(state.monitors[0].workspaces[0].columns[0].windowHeights == nil)
    #expect(heights(state) == [1_000])
  }

  @Test
  func `A dragged bottom edge resizes only the window below`() throws {
    var state = stackState()
    // The first window's bottom edge dragged from 333 down to 433.
    let learned = learnStackedWindowHeight(
      ids[0], actualFrame: Rect(x: 0, y: 0, width: 500, height: 433.33),
      state: &state, viewports: [monitorID: viewport]
    )
    #expect(learned)
    #expect(heights(state) == [433, 233, 333])
    // The stack's outer bottom edge and a window moved as a whole carry no height.
    #expect(!learnStackedWindowHeight(
      ids[2], actualFrame: Rect(x: 0, y: 666.67, width: 500, height: 300),
      state: &state, viewports: [monitorID: viewport]
    ))
    #expect(!learnStackedWindowHeight(
      ids[2], actualFrame: Rect(x: 0, y: 700, width: 500, height: 333.33),
      state: &state, viewports: [monitorID: viewport]
    ))
  }

  @Test
  func `A dragged top edge resizes only the window above`() throws {
    var state = stackState()
    let learned = learnStackedWindowHeight(
      ids[2], actualFrame: Rect(x: 0, y: 566.67, width: 500, height: 433.33),
      state: &state, viewports: [monitorID: viewport]
    )
    #expect(learned)
    #expect(heights(state) == [333, 233, 433])
  }

  @Test
  func `Proportions follow a closed window and survive a topology round trip`() throws {
    var state = stackState()
    try apply("set-window-height 50%", &state)
    var workspace = state.monitors[0].workspaces[0]
    removeWindow(ids[1], from: &workspace, settings: state.layout)
    #expect(workspace.columns[0].windowHeights?.keys.sorted { $0.rawValue < $1.rawValue }
      == [ids[0], ids[2]])
    let restored = RuntimeState(config: Config(), topology: state.topology)
    #expect(restored.monitors[0].workspaces[0].columns[0].windowHeights
      == state.monitors[0].workspaces[0].columns[0].windowHeights)
  }
}
