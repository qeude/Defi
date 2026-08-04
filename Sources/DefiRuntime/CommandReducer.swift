import DefiCore
import DefiModel

public enum ReducerError: Error, Equatable, CustomStringConvertible, Sendable {
  case noMonitor
  case unknownWorkspace(WorkspaceID)
  case noFocusedWindow
  case layout(LayoutError)

  public var description: String {
    switch self {
    case .noMonitor: "no monitor"
    case .unknownWorkspace(let id): "unknown workspace: \(id)"
    case .noFocusedWindow: "no focused window"
    case .layout(let error): "layout error: \(error)"
    }
  }
}

public func reduce(
  _ command: Command,
  on requestedMonitorID: MonitorID?,
  state: inout RuntimeState
) throws {
  guard !state.monitors.isEmpty else {
    throw ReducerError.noMonitor
  }
  let monitorIndex =
    requestedMonitorID.flatMap { requestedID in
      state.monitors.firstIndex(where: { $0.id == requestedID })
    } ?? 0
  let layout = state.layout

  func workspaceIndex(_ monitor: Monitor) throws -> Int {
    guard
      let index = monitor.workspaces.firstIndex(
        where: { $0.id == monitor.activeWorkspace }
      )
    else {
      throw ReducerError.unknownWorkspace(monitor.activeWorkspace)
    }
    return index
  }

  do {
    switch command {
    case .focusColumn(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        try focusColumn(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .moveColumn(let direction), .moveWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        try moveFocusedWindow(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .focusWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        try focusWindow(direction, in: &state.monitors[monitorIndex].workspaces[index])
      }
    case .cycleWidth(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex) {
        cycleWidth(
          of: &state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
          direction: direction,
          presets: layout.presetColumnWidths
        )
        state.monitors[monitorIndex].workspaces[index].targetScrollOffset =
          focusedColumnLeftScrollOffset(
            workspace: state.monitors[monitorIndex].workspaces[index]
          )
      }
    case .toggleFullscreen:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex) {
        toggleFullscreen(
          of: &state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
          defaultWidth: layout.defaultColumnWidth
        )
        state.monitors[monitorIndex].workspaces[index].targetScrollOffset =
          focusedColumnLeftScrollOffset(
            workspace: state.monitors[monitorIndex].workspaces[index]
          )
      }
    case .switchWorkspace(let workspaceID):
      guard state.monitors[monitorIndex].workspaces.contains(where: { $0.id == workspaceID })
      else {
        throw ReducerError.unknownWorkspace(workspaceID)
      }
      state.monitors[monitorIndex].activeWorkspace = workspaceID
    case .moveWindowToWorkspace(let workspaceID):
      try moveFocusedWindow(
        to: workspaceID,
        follow: true,
        monitorIndex: monitorIndex,
        state: &state
      )
    case .sendWindowToWorkspace(let workspaceID):
      try moveFocusedWindow(
        to: workspaceID,
        follow: false,
        monitorIndex: monitorIndex,
        state: &state
      )
    case .joinWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      try joinFocusedWindow(
        direction,
        in: &state.monitors[monitorIndex].workspaces[index],
        settings: layout
      )
    case .unjoinWindows:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      try unjoinFocusedWindow(
        in: &state.monitors[monitorIndex].workspaces[index],
        settings: layout
      )
    case .toggleFloating:
      try toggleFocusedFloating(monitorIndex: monitorIndex, state: &state)
    case .focusFloating(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      focusFloating(direction, workspace: &state.monitors[monitorIndex].workspaces[index])
    case .runStartupCommands:
      break
    }
  } catch let error as LayoutError {
    throw ReducerError.layout(error)
  }
}

private func moveFocusedWindow(
  to workspaceID: WorkspaceID,
  follow: Bool,
  monitorIndex: Int,
  state: inout RuntimeState
) throws {
  let sourceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
    where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
  )
  let targetIndex = state.monitors[monitorIndex].workspaces.firstIndex(
    where: { $0.id == workspaceID }
  )
  guard let sourceIndex, let targetIndex else {
    throw ReducerError.unknownWorkspace(workspaceID)
  }
  let source = state.monitors[monitorIndex].workspaces[sourceIndex]
  guard source.columns.indices.contains(source.focusedColumn) else {
    throw ReducerError.noFocusedWindow
  }
  let column = source.columns[source.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else {
    throw ReducerError.noFocusedWindow
  }
  let windowID = column.windows[column.focusedWindow]
  removeWindow(
    windowID,
    from: &state.monitors[monitorIndex].workspaces[sourceIndex],
    settings: state.layout
  )
  insertNewWindow(
    windowID,
    into: &state.monitors[monitorIndex].workspaces[targetIndex],
    settings: state.layout
  )
  if follow {
    state.monitors[monitorIndex].activeWorkspace = workspaceID
  }
}

private func toggleFocusedFloating(
  monitorIndex: Int,
  state: inout RuntimeState
) throws {
  let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
    where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
  )
  guard let workspaceIndex else { throw ReducerError.noMonitor }
  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  if workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow) {
    let windowID = workspace.floatingWindows.remove(at: workspace.focusedFloatingWindow)
    insertNewWindow(windowID, into: &workspace, settings: state.layout)
    state.windows[windowID]?.floating = false
  } else if workspace.columns.indices.contains(workspace.focusedColumn) {
    let column = workspace.columns[workspace.focusedColumn]
    guard column.windows.indices.contains(column.focusedWindow) else {
      throw ReducerError.noFocusedWindow
    }
    let windowID = column.windows[column.focusedWindow]
    removeWindow(windowID, from: &workspace, settings: state.layout)
    workspace.floatingWindows.append(windowID)
    workspace.focusedFloatingWindow = workspace.floatingWindows.count - 1
    state.windows[windowID]?.floating = true
  } else {
    throw ReducerError.noFocusedWindow
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

private func focusFloating(_ direction: Direction, workspace: inout Workspace) {
  guard !workspace.floatingWindows.isEmpty else { return }
  switch direction {
  case .left, .up, .previous:
    workspace.focusedFloatingWindow = max(workspace.focusedFloatingWindow - 1, 0)
  case .right, .down, .next:
    workspace.focusedFloatingWindow = min(
      workspace.focusedFloatingWindow + 1,
      workspace.floatingWindows.count - 1
    )
  case .first:
    workspace.focusedFloatingWindow = 0
  case .last:
    workspace.focusedFloatingWindow = workspace.floatingWindows.count - 1
  }
}
