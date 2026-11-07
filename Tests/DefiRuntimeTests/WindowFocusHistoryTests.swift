import DefiConfig
import DefiModel
import Foundation
import Testing

@testable import DefiRuntime

struct WindowFocusHistoryTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let a = WindowID(rawValue: 1)
  private let b = WindowID(rawValue: 2)
  private let c = WindowID(rawValue: 3)
  private let d = WindowID(rawValue: 4)

  /// Workspace `one` holds columns a and b, workspace `two` holds c and d; `one` is active on a.
  private func makeState() -> RuntimeState {
    var state = RuntimeState(config: Config(workspaces: WorkspacesConfig(names: ["one", "two"])))
    state.attachMonitor(monitorID)
    for id in [a, b, c, d] {
      state.windows[id] = Window(
        id: id, appID: "app", title: "", frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      )
    }
    state.monitors[0].workspaces[0].columns = [a, b].map { Column(window: $0, width: .fraction(0.5)) }
    state.monitors[0].workspaces[1].columns = [c, d].map { Column(window: $0, width: .fraction(0.5)) }
    state.monitors[0].activeWorkspace = WorkspaceID(rawValue: "one")
    return state
  }

  private func selected(_ state: RuntimeState) -> WindowID? { state.selectedWindowID(on: monitorID) }

  @Test
  func `Previous window crosses workspaces and toggles back`() throws {
    var state = makeState()
    state.recordCommittedFocus(a)
    focusWindow(d, state: &state)
    state.recordCommittedFocus(d)

    try reduce(.focusWindowPrevious, on: monitorID, state: &state)
    #expect(selected(state) == a)
    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "one"))
    // The history moves only once native focus confirms the selection.
    #expect(state.windowFocusHistory == WindowFocusHistory(current: d, previous: a))
    state.recordCommittedFocus(a)

    try reduce(.focusWindowPrevious, on: monitorID, state: &state)
    #expect(selected(state) == d)
    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "two"))
  }

  @Test
  func `Repeated focus of the same window keeps the previous one`() {
    var state = makeState()
    state.recordCommittedFocus(a)
    state.recordCommittedFocus(b)
    state.recordCommittedFocus(b)

    #expect(state.windowFocusHistory == WindowFocusHistory(current: b, previous: a))
  }

  @Test
  func `A closed window is skipped`() throws {
    var state = makeState()
    state.recordCommittedFocus(a)
    state.recordCommittedFocus(b)
    state.windows[b] = nil
    state.monitors[0].workspaces[0].columns.removeLast()
    state.recordCommittedFocus(c)

    #expect(state.windowFocusHistory == WindowFocusHistory(current: c, previous: a))
    // Back on the previous window after a close: it is not its own previous.
    state.windows[c] = nil
    state.recordCommittedFocus(a)
    #expect(state.windowFocusHistory == WindowFocusHistory(current: a, previous: nil))
  }

  @Test
  func `Without a live previous window nothing changes`() throws {
    var state = makeState()
    #expect(try changedState(after: .focusWindowPrevious, on: monitorID, from: state) == nil)

    state.recordCommittedFocus(c)
    state.recordCommittedFocus(a)
    state.windows[c] = nil
    state.monitors[0].workspaces[1].columns.removeFirst()

    #expect(state.previousFocusedWindowTarget == nil)
    #expect(try changedState(after: .focusWindowPrevious, on: monitorID, from: state) == nil)
  }

  @Test
  func `History survives a round trip and old stores decode without it`() throws {
    var state = makeState()
    state.recordCommittedFocus(c)
    state.recordCommittedFocus(a)

    let restored = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["one", "two"])),
      topology: try JSONDecoder().decode(WorkspaceTopology.self, from: JSONEncoder().encode(state.topology))
    )
    #expect(restored.windowFocusHistory == WindowFocusHistory(current: a, previous: c))

    var topology = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(state.topology)) as? [String: Any]
    )
    topology["windowFocusHistory"] = nil
    let old = try JSONDecoder().decode(
      WorkspaceTopology.self, from: JSONSerialization.data(withJSONObject: topology)
    )
    #expect(RuntimeState(config: Config(), topology: old).windowFocusHistory == WindowFocusHistory())
  }
}
