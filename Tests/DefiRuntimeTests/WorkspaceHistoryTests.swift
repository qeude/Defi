import DefiConfig
import DefiModel
import Foundation
import Testing

@testable import DefiRuntime

struct WorkspaceHistoryTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let other = MonitorID(rawValue: 2)
  private let one = WorkspaceID(rawValue: "one")
  private let two = WorkspaceID(rawValue: "two")
  private let three = WorkspaceID(rawValue: "three")

  /// Named workspaces one, two and three on one monitor, each holding one window
  /// (1, 2 and 3), with `one` active.
  private func makeState() -> RuntimeState {
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["one", "two", "three"]))
    )
    state.attachMonitor(monitorID)
    for index in 0..<3 {
      let id = WindowID(rawValue: UInt64(index + 1))
      state.windows[id] = Window(
        id: id, appID: "app-\(index + 1)", title: "Window \(index + 1)",
        frame: Rect(x: 0, y: 0, width: 800, height: 700), monitorID: monitorID
      )
      state.monitors[0].workspaces[index].columns = [Column(window: id, width: .fraction(0.5))]
    }
    state.monitors[0] = Monitor(
      id: monitorID, workspaces: state.monitors[0].workspaces, activeWorkspace: one
    )
    return state
  }

  private func run(_ command: Command, on id: MonitorID? = nil, _ state: inout RuntimeState) throws {
    try reduce(command, on: id ?? monitorID, state: &state)
  }

  private func active(_ state: RuntimeState) -> WorkspaceID { state.monitors[0].activeWorkspace }

  @Test
  func `Previous returns to the last workspace and toggles back`() throws {
    var state = makeState()
    try run(.focusWorkspace(.named("two")), &state)
    #expect(state.monitors[0].previousWorkspace == one)

    try run(.focusWorkspace(.lastActive), &state)
    #expect(active(state) == one)
    #expect(state.monitors[0].previousWorkspace == two)

    try run(.focusWorkspace(.lastActive), &state)
    #expect(active(state) == two)
  }

  @Test
  func `Previous follows the order of visits`() throws {
    var state = makeState()
    try run(.focusWorkspace(.named("two")), &state)
    try run(.focusWorkspace(.named("three")), &state)

    try run(.focusWorkspace(.lastActive), &state)
    #expect(active(state) == two)
    try run(.focusWorkspace(.lastActive), &state)
    #expect(active(state) == three)
  }

  @Test
  func `Without history previous changes nothing`() throws {
    let state = makeState()

    #expect(try changedState(after: .focusWorkspace(.lastActive), on: monitorID, from: state) == nil)
  }

  @Test
  func `A native focus change counts as a visit`() throws {
    var state = makeState()
    #expect(focusWindow(WindowID(rawValue: 3), state: &state))
    #expect(active(state) == three)

    try run(.focusWorkspace(.lastActive), &state)

    #expect(active(state) == one)
  }

  @Test
  func `Writing the active workspace again leaves the history alone`() throws {
    var state = makeState()
    try run(.focusWorkspace(.named("two")), &state)

    state.monitors[0].activeWorkspace = two

    #expect(state.monitors[0].previousWorkspace == one)
  }

  @Test
  func `A removed workspace is not a destination`() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let first = state.monitors[0].activeWorkspace
    state.monitors[0].workspaces[0].columns = [Column(window: WindowID(rawValue: 1), width: .fraction(0.5))]
    state.maintainWorkspaceLifecycle()
    try run(.focusWorkspace(.relative(.down)), &state)
    #expect(state.monitors[0].previousWorkspace == first)
    state.monitors[0].workspaces[0].columns = []
    state.maintainWorkspaceLifecycle()
    #expect(!state.monitors[0].workspaces.contains { $0.id == first })
    let before = state

    try run(.focusWorkspace(.lastActive), &state)

    #expect(state == before)
  }

  @Test
  func `A workspace that moved to another monitor is not a destination`() throws {
    var state = makeState()
    state.attachMonitor(other)
    try run(.focusWorkspace(.named("two")), &state)
    #expect(state.monitors[0].previousWorkspace == one)
    let moved = state.monitors[0].workspaces.remove(at: 0)
    state.monitors[1].workspaces.insert(moved, at: 0)
    let otherActive = state.monitors[1].activeWorkspace

    try run(.focusWorkspace(.lastActive), &state)

    #expect(active(state) == two)
    #expect(state.monitors[1].activeWorkspace == otherActive)
    #expect(state.workspaceLocation(for: one)?.monitorIndex == 1)
  }

  @Test
  func `Each monitor keeps its own history`() throws {
    var state = makeState()
    state.attachMonitor(other)
    state.monitors[1].workspaces[0].columns = [Column(window: WindowID(rawValue: 7), width: .fraction(0.5))]
    state.maintainWorkspaceLifecycle()
    let originalOtherActive = state.monitors[1].activeWorkspace

    try run(.focusWorkspace(.relative(.down)), on: other, &state)

    #expect(state.monitors[1].previousWorkspace == originalOtherActive)
    #expect(state.monitors[0].previousWorkspace == nil)
    #expect(active(state) == one)
  }

  @Test
  func `A reconnected display restores its workspace without recording a visit`() {
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", "chat"], monitors: ["chat": 2]))
    )
    state.attachMonitor(monitorID)
    state.attachMonitor(other)
    let chat = WorkspaceID(rawValue: "chat")
    state.monitors[1].activeWorkspace = chat
    state.retainMonitors([monitorID])

    state.attachMonitor(other)

    let reconnected = state.monitors.first { $0.id == other }
    #expect(reconnected?.activeWorkspace == chat)
    #expect(reconnected?.previousWorkspace == nil)
  }

  @Test
  func `History survives a round trip and old stores decode without it`() throws {
    var state = makeState()
    try run(.focusWorkspace(.named("two")), &state)
    state.monitors[0].workspaces[1].scrollFocus = ScrollFocus(
      windowID: WindowID(rawValue: 2), centered: false, pinned: true
    )

    let restored = try JSONDecoder().decode(
      WorkspaceTopology.self, from: JSONEncoder().encode(state.topology)
    )
    #expect(restored.monitors[0].previousWorkspace == one)
    #expect(restored.monitors[0].workspaces[1].scrollFocus?.pinned == true)

    var monitor = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(state.monitors[0])) as? [String: Any]
    )
    monitor["previousWorkspace"] = nil
    var workspaces = try #require(monitor["workspaces"] as? [[String: Any]])
    var focus = try #require(workspaces[1]["scrollFocus"] as? [String: Any])
    focus["pinned"] = nil
    workspaces[1]["scrollFocus"] = focus
    monitor["workspaces"] = workspaces
    let old = try JSONDecoder().decode(
      Monitor.self, from: JSONSerialization.data(withJSONObject: monitor)
    )
    #expect(old.previousWorkspace == nil)
    #expect(old.workspaces[1].scrollFocus?.pinned == nil)
  }
}
