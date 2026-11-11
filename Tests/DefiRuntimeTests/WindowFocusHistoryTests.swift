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
    #expect(state.recentWindowIDs == [d, a])
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

    #expect(state.recentWindowIDs == [b, a])
  }

  @Test
  func `A closed window is skipped`() throws {
    var state = makeState()
    state.recordCommittedFocus(a)
    state.recordCommittedFocus(b)
    state.windows[b] = nil
    state.monitors[0].workspaces[0].columns.removeLast()
    state.recordCommittedFocus(c)

    #expect(state.recentWindowIDs == [c, a])
    // Back on the previous window after a close: it is not its own previous.
    state.windows[c] = nil
    state.recordCommittedFocus(a)
    #expect(state.recentWindowIDs == [a])
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
    #expect(restored.recentWindowIDs == [a, c])

    var topology = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(state.topology)) as? [String: Any]
    )
    topology["recentWindowIDs"] = nil
    // The former single-entry history is ignored.
    topology["windowFocusHistory"] = ["current": 1, "previous": 3]
    let old = try JSONDecoder().decode(
      WorkspaceTopology.self, from: JSONSerialization.data(withJSONObject: topology)
    )
    #expect(RuntimeState(config: Config(), topology: old).recentWindowIDs.isEmpty)
  }

  @Test
  func `Previous window skips an older entry whose window left its workspace`() {
    var state = makeState()
    for id in [d, c, b, a] { state.recordCommittedFocus(id) }
    state.monitors[0].workspaces[0].columns.removeLast()

    #expect(state.recentWindowIDs == [a, b, c, d])
    #expect(state.previousFocusedWindowTarget == c)
  }

  @Test
  func `Switcher lists recent windows first, then the others in workspace order`() {
    var state = makeState()
    state.recordCommittedFocus(c)
    state.recordCommittedFocus(a)

    #expect(state.recentWindowCandidates == [a, c, b, d])
  }

  @Test
  func `A brief switcher press selects the previous window and focuses nothing`() {
    var state = makeState()
    state.recordCommittedFocus(c)
    state.recordCommittedFocus(a)
    let before = state

    var switcher = RecentWindowsSwitcher()
    switcher.step(forward: true, in: state)
    #expect(switcher.selectedWindowID == state.previousFocusedWindowTarget)
    #expect(state == before)
    #expect(switcher.close() == c)
    #expect(!switcher.isOpen)
  }

  @Test
  func `Switcher steps forward and backward, wrapping`() {
    var state = makeState()
    state.recordCommittedFocus(c)
    state.recordCommittedFocus(a)

    var switcher = RecentWindowsSwitcher()
    switcher.step(forward: false, in: state)
    #expect(switcher.selectedWindowID == d)
    switcher.step(forward: true, in: state)
    #expect(switcher.selectedWindowID == a)
    switcher.step(forward: true, in: state)
    switcher.step(forward: true, in: state)
    #expect(switcher.selectedWindowID == b)
    switcher.step(forward: false, in: state)
    #expect(switcher.selectedWindowID == c)
  }

  @Test
  func `Switcher without history still opens on the second window`() {
    var switcher = RecentWindowsSwitcher()
    switcher.step(forward: true, in: makeState())
    #expect(switcher.windowIDs == [a, b, c, d])
    #expect(switcher.selectedWindowID == b)

    var empty = RecentWindowsSwitcher()
    empty.step(forward: true, in: RuntimeState(config: Config()))
    #expect(!empty.isOpen)
  }

  @Test
  func `A window closed while the switcher is open leaves the list`() {
    var state = makeState()
    var switcher = RecentWindowsSwitcher()
    switcher.step(forward: true, in: state)
    switcher.step(forward: true, in: state)
    #expect(switcher.selectedWindowID == c)

    // The selection passes to the next window.
    state.windows[c] = nil
    state.monitors[0].workspaces[1].columns.removeFirst()
    switcher.retainManagedWindows(in: state)
    #expect(switcher.windowIDs == [a, b, d])
    #expect(switcher.selectedWindowID == d)

    // An earlier window leaves without moving the selection.
    state.monitors[0].workspaces[0].columns.removeFirst()
    switcher.retainManagedWindows(in: state)
    #expect(switcher.selectedWindowID == d)

    // The last selected window closes: the selection stays on the list.
    state.monitors[0].workspaces[1].columns.removeFirst()
    switcher.retainManagedWindows(in: state)
    #expect(switcher.selectedWindowID == b)

    state.monitors[0].workspaces[0].columns.removeFirst()
    switcher.retainManagedWindows(in: state)
    #expect(!switcher.isOpen)
    #expect(switcher.close() == nil)
  }
}
