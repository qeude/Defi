import DefiModel

@discardableResult
public func focusWindow(
  _ windowID: WindowID,
  state: inout RuntimeState
) -> Bool {
  for monitorIndex in state.monitors.indices {
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      for columnIndex in state.monitors[monitorIndex].workspaces[workspaceIndex].columns.indices {
        if let windowIndex = state.monitors[monitorIndex]
          .workspaces[workspaceIndex]
          .columns[columnIndex]
          .windows
          .firstIndex(of: windowID)
        {
          let activatedWorkspace =
            state.monitors[monitorIndex].activeWorkspace
            != state.monitors[monitorIndex].workspaces[workspaceIndex].id
          state.monitors[monitorIndex].workspaces[workspaceIndex].focusedColumn = columnIndex
          state.monitors[monitorIndex].activeWorkspace =
            state.monitors[monitorIndex].workspaces[workspaceIndex].id
          state.monitors[monitorIndex]
            .workspaces[workspaceIndex]
            .columns[columnIndex]
            .focusedWindow = windowIndex
          return activatedWorkspace
        }
      }
    }
  }
  return false
}

public func nativeFocusChangesSelection(
  _ windowID: WindowID,
  activeMonitorID: MonitorID?,
  state: RuntimeState
) -> Bool {
  guard let focusedMonitorID = state.monitorID(containing: windowID) else {
    return false
  }
  return activeMonitorID != focusedMonitorID
    || state.selectedWindowID(on: focusedMonitorID) != windowID
}
