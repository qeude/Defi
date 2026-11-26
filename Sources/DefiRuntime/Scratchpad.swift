import DefiCore
import DefiModel

/// Where a window joining the scratchpad from the strip floats: a column frame would read as part
/// of the strip. Each later window cascades so none hides another whole.
public func scratchpadFloatingFrame(in viewport: Rect, cascade: Int) -> Rect {
  let width = viewport.width * 0.6, height = viewport.height * 0.6
  let step = 32.0 * Double(cascade % 5) - 64
  return Rect(
    x: viewport.x + (viewport.width - width) / 2 + step, y: viewport.y + (viewport.height - height) / 2 + step,
    width: width, height: height)
}

/// Adds the selected window to the scratchpad, floating it, or takes it out, where it stays as
/// an ordinary floating window. A window joins a scratchpad shown here and is parked with it otherwise.
func toggleScratchpadWindow(monitorIndex: Int, state: inout RuntimeState) throws {
  guard let workspaceIndex = activeWorkspaceIndex(monitorIndex, state: state) else {
    throw ReducerError.noMonitor
  }
  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  guard let windowID = workspace.selectedWindowID else { throw ReducerError.noFocusedWindow }
  if let index = state.scratchpadWindowIDs.firstIndex(of: windowID) {
    state.scratchpadWindowIDs.remove(at: index)
    return
  }
  let shown = state.scratchpadWindowIDs.contains(where: workspace.floatingWindows.contains)
  if !workspace.floatingWindows.contains(windowID) {
    state.suspendedTiledPlacements[windowID] = nil
    removeWindow(windowID, from: &workspace, settings: state.layout)
    workspace.floatingWindows.append(windowID)
    state.windows[windowID]?.floating = true
    state.windows[windowID]?.floatingOrigin = .user
  }
  state.scratchpadWindowIDs.append(windowID)
  if shown {
    workspace.focusedFloatingWindow = workspace.floatingWindows.firstIndex(of: windowID)!
    workspace.focusedLayer = .floating
  } else {
    hideScratchpadWindows([windowID], in: &workspace, settings: state.layout)
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

/// Parks the scratchpad when all of it shows on this monitor's active workspace and has the
/// focus; otherwise shows all of it there, from wherever it is, and focuses it.
func toggleScratchpad(monitorIndex: Int, state: inout RuntimeState) throws {
  guard !state.scratchpadWindowIDs.isEmpty else { return }
  guard let workspaceIndex = activeWorkspaceIndex(monitorIndex, state: state) else {
    throw ReducerError.noMonitor
  }
  let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  if state.scratchpadWindowIDs.allSatisfy(workspace.floatingWindows.contains),
    workspace.selectedWindowID.map(state.scratchpadWindowIDs.contains) == true
  {
    hideScratchpadWindows(
      state.scratchpadWindowIDs, in: &state.monitors[monitorIndex].workspaces[workspaceIndex],
      settings: state.layout)
  } else {
    showScratchpad(on: monitorIndex, focusing: nil, state: &state)
  }
}

/// Shows every scratchpad window as a floating window of the monitor's active workspace and
/// selects `focusing`, or the scratchpad window focused last.
func showScratchpad(on monitorIndex: Int, focusing: WindowID?, state: inout RuntimeState) {
  guard let workspaceIndex = activeWorkspaceIndex(monitorIndex, state: state) else { return }
  let members = state.scratchpadWindowIDs
  for sourceMonitorIndex in state.monitors.indices {
    for sourceWorkspaceIndex in state.monitors[sourceMonitorIndex].workspaces.indices {
      for windowID in members {
        removeWindow(
          windowID, from: &state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex],
          settings: state.layout)
      }
    }
  }
  let monitorID = state.monitors[monitorIndex].id
  for windowID in members { state.windows[windowID]?.monitorID = monitorID }
  let target = focusing ?? state.recentWindowIDs.first(where: members.contains) ?? members.last!
  state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows += members
  state.monitors[monitorIndex].workspaces[workspaceIndex].focusedFloatingWindow =
    state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.firstIndex(of: target)!
  state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .floating
}

private func hideScratchpadWindows(
  _ windowIDs: [WindowID], in workspace: inout Workspace, settings: LayoutSettings
) {
  let hidesSelection = workspace.selectedWindowID.map(windowIDs.contains) ?? false
  for windowID in windowIDs { removeWindow(windowID, from: &workspace, settings: settings) }
  workspace.scratchpadWindows = (workspace.scratchpadWindows ?? []) + windowIDs
  if hidesSelection, !workspace.columns.isEmpty { workspace.focusedLayer = .tiled }
}

private func activeWorkspaceIndex(_ monitorIndex: Int, state: RuntimeState) -> Int? {
  state.monitors[monitorIndex].workspaces.firstIndex {
    $0.id == state.monitors[monitorIndex].activeWorkspace
  }
}
