import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct FocusWindowOrWorkspaceTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let first = WorkspaceID(rawValue: "first")
  private let second = WorkspaceID(rawValue: "second")
  private let third = WorkspaceID(rawValue: "third")

  /// Named workspaces first, second and third, with `second` active and a trailing
  /// workspace after them. Stacks are windows `[10, 11]`, `[20, 21]` and `[30, 31]`.
  private func makeState() -> RuntimeState {
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["first", "second", "third"]))
    )
    state.attachMonitor(monitorID)
    for (index, base) in [10, 20, 30].enumerated() {
      state.monitors[0].workspaces[index].columns = [
        Column(
          windows: [WindowID(rawValue: UInt64(base)), WindowID(rawValue: UInt64(base + 1))],
          focusedWindow: 0, width: .fraction(0.5)
        )
      ]
    }
    state.monitors[0].activeWorkspace = second
    return state
  }

  private func active(_ state: RuntimeState) -> WorkspaceID { state.monitors[0].activeWorkspace }

  private func focusedWindow(_ state: RuntimeState, in id: WorkspaceID) -> Int? {
    state.monitors[0].workspaces.first { $0.id == id }?.columns.first?.focusedWindow
  }

  private func resolved(_ direction: Direction, _ state: RuntimeState) -> Command {
    resolvedCommand(.focusWindowOrWorkspace(direction), on: monitorID, state: state)
  }

  @Test
  func `Down inside a stack moves the focus within it`() throws {
    var state = makeState()
    #expect(resolved(.down, state) == .focusWindow(.down))

    try reduce(.focusWindowOrWorkspace(.down), on: monitorID, state: &state)

    #expect(active(state) == second)
    #expect(focusedWindow(state, in: second) == 1)
  }

  @Test
  func `Down at the bottom of a stack enters the next workspace on its remembered window`() throws {
    var state = makeState()
    state.monitors[0].workspaces[1].columns[0].focusedWindow = 1
    state.monitors[0].workspaces[2].columns[0].focusedWindow = 1
    #expect(resolved(.down, state) == .focusWorkspace(.relative(.down)))

    try reduce(.focusWindowOrWorkspace(.down), on: monitorID, state: &state)

    #expect(active(state) == third)
    #expect(focusedWindow(state, in: third) == 1)
    #expect(focusedWindow(state, in: second) == 1)
  }

  @Test
  func `Up at the top of a stack enters the previous workspace on its remembered window`() throws {
    var state = makeState()
    #expect(resolved(.up, state) == .focusWorkspace(.relative(.up)))

    try reduce(.focusWindowOrWorkspace(.up), on: monitorID, state: &state)

    #expect(active(state) == first)
    #expect(focusedWindow(state, in: first) == 0)
  }

  @Test
  func `Up inside a stack moves the focus within it`() throws {
    var state = makeState()
    state.monitors[0].workspaces[1].columns[0].focusedWindow = 1

    try reduce(.focusWindowOrWorkspace(.up), on: monitorID, state: &state)

    #expect(active(state) == second)
    #expect(focusedWindow(state, in: second) == 0)
  }

  @Test(arguments: [Direction.up, .down])
  func `A single-window column crosses to the adjacent workspace`(direction: Direction) {
    var state = makeState()
    state.monitors[0].workspaces[1].columns = [Column(window: WindowID(rawValue: 10), width: .fraction(0.5))]

    #expect(resolved(direction, state) == .focusWorkspace(.relative(direction)))
  }

  @Test(arguments: [Direction.up, .down])
  func `An empty workspace crosses to the adjacent workspace`(direction: Direction) {
    var state = makeState()
    state.monitors[0].workspaces[1].columns = []

    #expect(resolved(direction, state) == .focusWorkspace(.relative(direction)))
  }

  @Test
  func `A floating selection beside tiled columns behaves as focus-window`() throws {
    var state = makeState()
    state.monitors[0].workspaces[1].floatingWindows = [WindowID(rawValue: 99)]
    state.monitors[0].workspaces[1].focusedLayer = .floating
    state.monitors[0].workspaces[1].columns[0].focusedWindow = 1
    #expect(resolved(.down, state) == .focusWindow(.down))

    try reduce(.focusWindowOrWorkspace(.down), on: monitorID, state: &state)

    #expect(active(state) == second)
    #expect(state.monitors[0].workspaces[1].focusedLayer == .tiled)
  }

  @Test
  func `A floating-only workspace crosses to the adjacent workspace`() {
    var state = makeState()
    state.monitors[0].workspaces[1].columns = []
    state.monitors[0].workspaces[1].floatingWindows = [WindowID(rawValue: 99)]
    state.monitors[0].workspaces[1].focusedLayer = .floating

    #expect(resolved(.down, state) == .focusWorkspace(.relative(.down)))
  }

  @Test
  func `The topmost workspace has nothing above it`() throws {
    var state = makeState()
    state.monitors[0].activeWorkspace = first

    #expect(try changedState(after: .focusWindowOrWorkspace(.up), on: monitorID, from: state) == nil)
  }

  @Test
  func `The last workspace with windows leads down to the trailing one`() throws {
    var state = makeState()
    state.monitors[0].activeWorkspace = third
    state.monitors[0].workspaces[2].columns[0].focusedWindow = 1

    try reduce(.focusWindowOrWorkspace(.down), on: monitorID, state: &state)

    #expect(state.monitors[0].workspaces.first { $0.id == active(state) }?.kind == .trailing)
  }

  @Test(arguments: [Direction.up, .down])
  func `Resolving twice gives the same command`(direction: Direction) {
    for focusedWindow in 0...1 {
      var state = makeState()
      state.monitors[0].workspaces[1].columns[0].focusedWindow = focusedWindow
      let once = resolved(direction, state)

      #expect(resolvedCommand(once, on: monitorID, state: state) == once)
    }
  }

  @Test
  func `Other commands resolve to themselves`() {
    let state = makeState()
    for command in [Command.focusWindow(.down), .focusWorkspace(.relative(.up)), .centerColumn] {
      #expect(resolvedCommand(command, on: monitorID, state: state) == command)
    }
  }
}
