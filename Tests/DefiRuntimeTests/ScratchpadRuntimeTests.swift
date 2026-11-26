import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Foundation
import Testing

struct ScratchpadRuntimeTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let otherMonitorID = MonitorID(rawValue: 2)
  private let tiled = WindowID(rawValue: 1)
  private let terminal = WindowID(rawValue: 2)
  private let notes = WindowID(rawValue: 3)

  @Test
  func `A window added to a hidden scratchpad floats, parks, and shows again on toggle`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    var workspace = state.monitors[0].workspaces[0]
    #expect(state.scratchpadWindowIDs == [notes])
    #expect(state.windows[notes]?.floating == true)
    #expect(workspace.scratchpadWindows == [notes])
    #expect(!workspace.floatingWindows.contains(notes))
    #expect(workspace.columns.flatMap(\.windows) == [tiled, terminal])
    #expect(workspace.focusedLayer == .tiled)

    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    workspace = state.monitors[0].workspaces[0]
    #expect(workspace.scratchpadWindows == nil)
    #expect(workspace.floatingWindows == [notes])
    #expect(workspace.selectedWindowID == notes)

    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    workspace = state.monitors[0].workspaces[0]
    #expect(workspace.scratchpadWindows == [notes])
    #expect(workspace.floatingWindows.isEmpty)
    #expect(workspace.selectedWindowID == terminal)
  }

  @Test
  func `A window added while the scratchpad shows stays in view, and all its windows toggle together`()
    throws
  {
    var state = try makeState(windowCount: 3)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    try reduce(.focusColumn(.last), on: monitorID, state: &state)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    var workspace = state.monitors[0].workspaces[0]
    #expect(state.scratchpadWindowIDs == [notes, terminal])
    #expect(workspace.floatingWindows == [notes, terminal])
    #expect(workspace.selectedWindowID == terminal)

    // Switching to an empty workspace keeps the scratchpad window selected.
    try reduce(.focusFloating(.last), on: monitorID, state: &state)
    try reduce(.focusWorkspace(.relative(.down)), on: monitorID, state: &state)
    #expect(state.selectedWindowID(on: monitorID) == terminal)
    try reduce(.focusWorkspace(.relative(.up)), on: monitorID, state: &state)

    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    workspace = state.monitors[0].workspaces[0]
    #expect(workspace.scratchpadWindows == [notes, terminal])
    #expect(workspace.selectedWindowID == tiled)

    state.recordCommittedFocus(notes)
    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].selectedWindowID == notes)
  }

  @Test
  func `A shown scratchpad rides the active workspace, a parked one stays, and the trailing one stays empty`()
    throws
  {
    var state = try makeState(windowCount: 2)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    let home = state.monitors[0].activeWorkspace
    try reduce(.focusWorkspace(.relative(.down)), on: monitorID, state: &state)
    var trailing = state.monitors[0].workspaces.last!
    #expect(state.monitors[0].activeWorkspace == trailing.id)
    #expect(trailing.scratchpadWindows == nil)
    #expect(state.monitors[0].workspaces[0].scratchpadWindows == [terminal])

    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    trailing = state.monitors[0].workspaces.last!
    #expect(trailing.kind == .trailing)
    #expect(trailing.floatingWindows == [terminal])
    #expect(state.monitors[0].workspaces.count == 2)

    try reduce(.focusWorkspace(.relative(.up)), on: monitorID, state: &state)
    #expect(state.monitors[0].activeWorkspace == home)
    #expect(state.monitors[0].workspaces[0].floatingWindows == [terminal])
    #expect(state.monitors[0].workspaces.last!.isEmpty)

    // A workspace left holding only parked scratchpad windows goes, and they move to the active one.
    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    try reduce(.moveColumnToWorkspace(.relative(.down), follow: true), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces.allSatisfy { $0.id != home })
    #expect(state.monitors[0].workspaces[0].scratchpadWindows == [terminal])
    #expect(state.monitors[0].workspaces[0].columns.flatMap(\.windows) == [tiled])
  }

  @Test
  func `Toggling on another monitor brings the scratchpad there`() throws {
    var state = try makeState(windowCount: 2)
    state.attachMonitor(otherMonitorID)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    try reduce(.toggleScratchpad, on: monitorID, state: &state)

    try reduce(.toggleScratchpad, on: otherMonitorID, state: &state)
    #expect(state.monitorID(containing: terminal) == otherMonitorID)
    #expect(state.windows[terminal]?.monitorID == otherMonitorID)
    #expect(state.selectedWindowID(on: otherMonitorID) == terminal)
    #expect(state.monitors[0].workspaces.allSatisfy { !$0.floatingWindows.contains(terminal) })
  }

  @Test
  func `Focusing a parked scratchpad window shows the scratchpad`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    try reduce(.focusWindowID(notes), on: monitorID, state: &state)
    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.floatingWindows == [notes])
    #expect(workspace.scratchpadWindows == nil)
    #expect(workspace.selectedWindowID == notes)
  }

  @Test
  func `A window taken out of the scratchpad stays floating in view, and moving one in it is refused`()
    throws
  {
    var state = try makeState(windowCount: 2)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    let before = state
    #expect(throws: ReducerError.scratchpadWindowStays) {
      try reduce(
        .moveWindowToWorkspaceTarget(.relative(.down), follow: false), on: monitorID, state: &state)
    }
    #expect(state == before)

    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    #expect(state.scratchpadWindowIDs.isEmpty)
    #expect(state.monitors[0].workspaces[0].floatingWindows == [terminal])
    #expect(state.monitors[0].workspaces[0].selectedWindowID == terminal)
  }

  @Test
  func `Tiling a scratchpad window takes it out of the scratchpad`() throws {
    var state = try makeState(windowCount: 2)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    try reduce(.toggleScratchpad, on: monitorID, state: &state)
    try reduce(.toggleFloating, on: monitorID, state: &state)
    #expect(state.scratchpadWindowIDs.isEmpty)
    #expect(state.monitors[0].workspaces[0].columns.flatMap(\.windows) == [tiled, terminal])
  }

  @Test
  func `A parked scratchpad survives a restart and leaves when its window closes`() throws {
    var state = try makeState(windowCount: 2)
    try reduce(.toggleScratchpadWindow, on: monitorID, state: &state)
    let data = try JSONEncoder().encode(state.topology)
    var restored = RuntimeState(
      config: Config(), topology: try JSONDecoder().decode(WorkspaceTopology.self, from: data))
    #expect(restored.scratchpadWindowIDs == [terminal])
    #expect(restored.monitors[0].workspaces[0].scratchpadWindows == [terminal])

    reconcileWindows([try #require(restored.windows[tiled])], config: Config(), state: &restored)
    #expect(restored.windows[terminal] == nil)
    #expect(restored.scratchpadWindowIDs.isEmpty)
    #expect(restored.monitors[0].workspaces[0].scratchpadWindows == nil)
  }

  private func makeState(windowCount: Int) throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for rawID in 1...windowCount {
      let window = Window(
        id: WindowID(rawValue: UInt64(rawID)), appID: "editor", title: "Window \(rawID)",
        frame: Rect(x: 0, y: 0, width: 784, height: 684), monitorID: monitorID)
      try discoverWindow(
        window, decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &state)
    }
    return state
  }
}
