import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct ColumnOrMonitorTests {
  private let left = MonitorID(rawValue: 1)
  private let right = MonitorID(rawValue: 2)
  private var frames: [MonitorID: Rect] {
    [
      left: Rect(x: 0, y: 0, width: 1_000, height: 800),
      right: Rect(x: 1_000, y: 0, width: 1_000, height: 800),
    ]
  }

  private func id(_ raw: UInt64) -> WindowID { WindowID(rawValue: raw) }

  /// Left monitor holds columns 1, 2 and 3; right monitor holds 10 and 11 with 11 selected.
  private func makeState(focusedColumn: Int = 2) -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(left)
    state.attachMonitor(right)
    state.monitors[0].workspaces[0].columns = [1, 2, 3].map {
      Column(window: id($0), width: .fraction(0.5))
    }
    state.monitors[0].workspaces[0].focusedColumn = focusedColumn
    state.monitors[1].workspaces[0].columns = [10, 11].map {
      Column(window: id($0), width: .fraction(0.5))
    }
    state.monitors[1].workspaces[0].focusedColumn = 1
    return state
  }

  private func resolved(_ command: Command, _ state: RuntimeState, frames: [MonitorID: Rect]? = nil)
    -> Command
  {
    resolvedCommand(command, on: left, state: state, monitorFrames: frames ?? self.frames)
  }

  @Test
  func `Inside the strip both commands stay column commands`() {
    let state = makeState(focusedColumn: 1)
    #expect(resolved(.focusColumnOrMonitor(.right), state) == .focusColumn(.right))
    #expect(resolved(.moveColumnOrToMonitor(.right), state) == .moveColumn(.right))
  }

  @Test
  func `At the last column they cross to the monitor on that side of the desk`() {
    let state = makeState()
    #expect(resolved(.focusColumnOrMonitor(.right), state) == .focusMonitor(.right))
    #expect(resolved(.moveColumnOrToMonitor(.right), state) == .moveColumnToMonitor(.right))
  }

  @Test
  func `At the first column with no monitor on that side they stay column commands`() {
    let state = makeState(focusedColumn: 0)
    #expect(resolved(.focusColumnOrMonitor(.left), state) == .focusColumn(.left))
    #expect(resolved(.moveColumnOrToMonitor(.left), state) == .moveColumn(.left))
  }

  @Test
  func `With one monitor they behave exactly like the plain commands`() throws {
    let state = makeState()
    let single = [left: frames[left]!]
    #expect(resolved(.focusColumnOrMonitor(.right), state, frames: single) == .focusColumn(.right))
    #expect(resolved(.moveColumnOrToMonitor(.right), state, frames: single) == .moveColumn(.right))
    #expect(
      try changedState(after: .moveColumnOrToMonitor(.right), on: left, from: state,
        monitorFrames: single)
        == changedState(after: .moveColumn(.right), on: left, from: state, monitorFrames: single))
  }

  @Test
  func `An empty workspace crosses in either direction that has a monitor`() {
    var state = makeState()
    state.monitors[0].workspaces[0].columns = []
    #expect(resolved(.focusColumnOrMonitor(.right), state) == .focusMonitor(.right))
  }

  @Test
  func `A floating selection at the edge returns to the strip first`() {
    var state = makeState()
    state.monitors[0].workspaces[0].focusedLayer = .floating
    #expect(resolved(.focusColumnOrMonitor(.right), state) == .focusColumn(.right))
  }

  @Test
  func `Moving past the edge inserts after the target's selection and keeps its other columns`()
    throws
  {
    var state = makeState()
    try reduce(.moveColumnOrToMonitor(.right), on: left, state: &state,
      monitorFrames: frames, viewports: frames)

    #expect(state.monitors[0].workspaces[0].columns.map(\.windows) == [[id(1)], [id(2)]])
    #expect(state.monitors[1].workspaces[0].columns.map(\.windows) == [[id(10)], [id(11)], [id(3)]])
    #expect(state.selectedWindowID(on: right) == id(3))
  }
}
