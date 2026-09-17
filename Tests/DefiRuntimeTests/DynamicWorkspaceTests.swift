import DefiConfig
import DefiCore
import DefiModel
import Testing

@testable import DefiRuntime

struct DynamicWorkspaceTests {
  private let primary = MonitorID(rawValue: 1)
  private let secondary = MonitorID(rawValue: 2)

  @Test
  func `First primary display connection adopts workspaces and remembers affinity`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(primary)
    let window = makeWindow(1, monitorID: primary)
    try discoverWindow(window, decision: RuleDecision(workspace: WorkspaceID(rawValue: "dev")), state: &state)
    state.monitors[0].activeWorkspace = WorkspaceID(rawValue: "dev")
    state.monitors[0].workspaces[0].columns[0].width = .pixels(600)
    state.monitors[0].workspaces[0].scrollOffset = 0.2
    let oldViewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let newViewport = Rect(x: 0, y: 0, width: 2_000, height: 1_000)

    state.retainMonitors(
      [secondary, primary], previousViewports: [primary: oldViewport],
      nextViewports: [primary: oldViewport, secondary: newViewport]
    )

    #expect(state.monitors[0].workspaces.compactMap(\.name) == ["dev", "web"])
    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "dev"))
    #expect(state.monitors[0].workspaces[0].affinity == secondary)
    #expect(state.monitors[0].workspaces[0].columns.first?.width == .pixels(1_200))
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.2)
    #expect(state.monitors[1].workspaces.map(\.kind) == [.trailing])
    #expect(state.windows[window.id]?.monitorID == secondary)

    state.retainMonitors([primary])
    state = RuntimeState(config: config, topology: state.topology)
    state.retainMonitors([secondary, primary])
    #expect(state.monitors[0].workspaces.compactMap(\.name) == ["dev", "web"])
    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "dev"))
  }

  @Test(arguments: [false, true])
  func `Secondary or remembered display does not take the existing stack`(remembered: Bool) {
    var state = RuntimeState(config: Config(workspaces: WorkspacesConfig(names: ["dev"])))
    state.attachMonitor(primary)
    if remembered {
      state.attachMonitor(secondary)
      state.retainMonitors([primary])
    }
    state.retainMonitors(remembered ? [secondary, primary] : [primary, secondary])
    #expect(state.monitors.first(where: { $0.id == primary })?.workspaces.compactMap(\.name) == ["dev"])
  }

  @Test
  func `Initial primary transfer preserves configured and disconnected affinities`() {
    var state = RuntimeState(config: Config(workspaces: WorkspacesConfig(
      names: ["dev", "pinned", "returning"], monitors: ["pinned": 1]
    )))
    state.attachMonitor(primary)
    let absent = MonitorID(rawValue: 3)
    state.monitors[0].workspaces[2].affinity = absent
    state.retainMonitors([secondary, primary])
    #expect(state.monitors[0].workspaces.compactMap(\.name) == ["dev"])
    #expect(state.monitors[1].workspaces.compactMap(\.name) == ["pinned", "returning"])
    #expect(state.monitors[1].workspaces[1].affinity == absent)
  }

  @Test
  func `Workspace monitor command carries tiled and floating windows and updates affinity`() throws {
    var state = RuntimeState(config: Config(workspaces: WorkspacesConfig(names: ["dev"])))
    state.attachMonitor(primary)
    state.attachMonitor(secondary)
    let tiled = makeWindow(1, monitorID: primary)
    var floating = makeWindow(2, monitorID: primary)
    floating.floating = true
    let dev = WorkspaceID(rawValue: "dev")
    try discoverWindow(tiled, decision: RuleDecision(workspace: dev), state: &state)
    try discoverWindow(floating, decision: RuleDecision(workspace: dev, floating: true), state: &state)
    state.monitors[0].activeWorkspace = dev
    let frames = [
      primary: Rect(x: 0, y: 0, width: 1_000, height: 700),
      secondary: Rect(x: 1_000, y: 0, width: 2_000, height: 1_400),
    ]
    let technical = isolatedDisplayArrangement(frames, primary: primary)
    try reduce(.moveWorkspaceToMonitor(.right), on: primary, state: &state,
               monitorFrames: frames, viewports: technical)
    #expect(state.monitors[1].activeWorkspace == dev)
    #expect(state.monitors[1].workspaces[0].affinity == secondary)
    #expect(state.location(containing: tiled.id)?.monitorID == secondary)
    #expect(state.location(containing: floating.id)?.monitorID == secondary)
    #expect(state.windows[floating.id]?.frame.x == technical[secondary]?.x)
    state.retainMonitors([primary])
    state.retainMonitors([primary, secondary])
    #expect(state.monitors[1].activeWorkspace == dev)
  }

  @Test
  func `Named workspaces are global and every monitor gets one trailing workspace`() {
    var state = RuntimeState(
      config: Config(
        workspaces: WorkspacesConfig(
          names: ["dev", "web", "chat"],
          monitors: ["chat": 2]
        )
      )
    )

    state.attachMonitor(primary)
    state.attachMonitor(secondary)

    #expect(state.monitors[0].workspaces.compactMap(\.name) == ["dev", "web"])
    #expect(state.monitors[1].workspaces.compactMap(\.name) == ["chat"])
    #expect(
      state.monitors.allSatisfy { monitor in
        monitor.workspaces.filter { $0.kind == .trailing }.count == 1
          && monitor.workspaces.last?.kind == .trailing
      })
    #expect(Set(state.monitors.flatMap(\.workspaces).map(\.id)).count == 5)
  }

  @Test
  func `Populated trailing workspace becomes ordinary and is replaced`() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(primary)
    let originalTrailing = state.monitors[0].activeWorkspace
    let window = makeWindow(1, monitorID: primary)

    try discoverWindow(window, decision: RuleDecision(), state: &state)

    #expect(state.monitors[0].workspaces.count == 2)
    #expect(state.monitors[0].workspaces[0].id == originalTrailing)
    #expect(state.monitors[0].workspaces[0].kind == .ordinary)
    #expect(state.monitors[0].workspaces[1].kind == .trailing)
    #expect(state.monitors[0].activeWorkspace == originalTrailing)
  }

  @Test
  func `Empty ordinary workspace disappears only after becoming inactive`() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(primary)
    let window = makeWindow(1, monitorID: primary)
    try discoverWindow(window, decision: RuleDecision(), state: &state)

    _ = reconcileWindows([], config: Config(), state: &state)
    #expect(state.monitors[0].workspaces.map(\.kind) == [.ordinary, .trailing])

    try reduce(.focusWorkspace(.relative(.down)), on: primary, state: &state)

    #expect(state.monitors[0].workspaces.map(\.kind) == [.trailing])
    #expect(state.monitors[0].activeWorkspace == state.monitors[0].workspaces[0].id)
  }

  @Test
  func `Workspace positions clamp to trailing and vertical navigation does not wrap`() throws {
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    )
    state.attachMonitor(primary)

    #expect(state.resolveWorkspaceTarget(.position(0), on: 0) == nil)

    try reduce(.focusWorkspace(.position(99)), on: primary, state: &state)
    #expect(state.monitors[0].workspaces.last?.id == state.monitors[0].activeWorkspace)

    let trailing = state.monitors[0].activeWorkspace
    try reduce(.focusWorkspace(.relative(.down)), on: primary, state: &state)
    #expect(state.monitors[0].activeWorkspace == trailing)

    try reduce(.focusWorkspace(.relative(.up)), on: primary, state: &state)
    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "web"))
  }

  @Test
  func `Named rule routes a window to the workspace owner`() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "chat"], monitors: ["chat": 2])
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(primary)
    state.attachMonitor(secondary)
    let window = makeWindow(1, monitorID: primary)

    try discoverWindow(
      window,
      decision: RuleDecision(
        workspace: WorkspaceID(rawValue: "chat"),
        followFocus: true
      ),
      isNativelyFocused: true,
      state: &state
    )

    #expect(state.location(containing: window.id)?.monitorID == secondary)
    #expect(state.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "chat"))
    #expect(state.monitors[1].activeWorkspace == WorkspaceID(rawValue: "chat"))
  }

  @Test
  func `Disconnected workspaces return only to the same monitor identity`() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "chat"], monitors: ["chat": 2])
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(primary)
    state.attachMonitor(secondary)
    let window = makeWindow(1, monitorID: secondary)
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "chat")),
      state: &state
    )

    state.retainMonitors([primary])

    #expect(state.workspaceLocation(for: WorkspaceID(rawValue: "chat"))?.monitorIndex == 0)
    #expect(state.location(containing: window.id)?.monitorID == primary)

    state.retainMonitors([primary, secondary])

    #expect(state.workspaceLocation(for: WorkspaceID(rawValue: "chat"))?.monitorIndex == 1)
    #expect(state.location(containing: window.id)?.monitorID == secondary)
  }

  @Test
  func `Moving a column to trailing follows it and creates the next trailing workspace`() throws {
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev"]))
    )
    state.attachMonitor(primary)
    let window = makeWindow(1, monitorID: primary)
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "dev")),
      state: &state
    )

    try reduce(
      .moveColumnToWorkspace(.relative(.down), follow: true),
      on: primary,
      state: &state
    )

    #expect(state.location(containing: window.id)?.workspaceID == state.monitors[0].activeWorkspace)
    #expect(state.monitors[0].workspaces.map(\.kind) == [.named, .ordinary, .trailing])
  }

  @Test
  func `Moving a column to a remote named workspace follows its owner`() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "chat"], monitors: ["chat": 2])
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(primary)
    state.attachMonitor(secondary)
    let window = makeWindow(1, monitorID: primary)
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "dev")),
      state: &state
    )

    try reduce(
      .moveColumnToWorkspace(.named("chat"), follow: true),
      on: primary,
      state: &state
    )

    #expect(state.location(containing: window.id)?.monitorID == secondary)
    #expect(state.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "chat"))
    #expect(state.monitors[1].activeWorkspace == WorkspaceID(rawValue: "chat"))
  }

  @Test
  func `Replacing every display identity preserves globally unique workspaces`() {
    let replacement = MonitorID(rawValue: 3)
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    )
    state.attachMonitor(primary)
    let originalNamedIDs = Set(
      state.monitors.flatMap(\.workspaces).filter { $0.kind == .named }.map(\.id)
    )

    state.retainMonitors([replacement])

    let replacementIDs = state.monitors.flatMap(\.workspaces).map(\.id)
    #expect(Set(replacementIDs).isSuperset(of: originalNamedIDs))
    #expect(Set(replacementIDs).count == replacementIDs.count)
    #expect(state.disconnectedMonitors[primary] != nil)
  }

  @Test
  func `Readding a removed configured name restores its named identity`() {
    var original = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev"]))
    )
    original.attachMonitor(primary)
    original.monitors[0].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 1), width: .fraction(0.8))
    ]

    let removed = RuntimeState(config: Config(), topology: original.topology)
    #expect(removed.monitors[0].workspaces[0].kind == .ordinary)

    let restored = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev"])),
      topology: removed.topology
    )
    #expect(restored.monitors[0].workspaces[0].kind == .named)
    #expect(restored.monitors[0].workspaces[0].name == "dev")
  }

  @Test
  func `Topology restore keeps workspace identity columns widths focus and scroll`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(primary)
    let window = makeWindow(1, monitorID: primary)
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "dev")),
      state: &state
    )
    state.monitors[0].workspaces[0].columns[0].width = .pixels(777)
    state.monitors[0].workspaces[0].scrollOffset = 42
    state.monitors[0].workspaces[0].targetScrollOffset = 84

    let restored = RuntimeState(config: config, topology: state.topology)

    #expect(restored.monitors == state.monitors)
    #expect(restored.windows == state.windows)
    #expect(restored.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "dev"))
  }

  private func makeWindow(_ id: UInt64, monitorID: MonitorID) -> Window {
    Window(
      id: WindowID(rawValue: id),
      appID: "app",
      title: "Window",
      frame: Rect(x: 0, y: 0, width: 500, height: 700),
      monitorID: monitorID
    )
  }
}
