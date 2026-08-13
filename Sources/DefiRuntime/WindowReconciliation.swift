import DefiConfig
import DefiCore
import DefiModel

public func discoverWindow(
  _ original: Window,
  decision: RuleDecision,
  placement: WindowPlacementPreference? = nil,
  state: inout RuntimeState
) throws {
  guard !state.monitors.isEmpty else {
    throw ReducerError.noMonitor
  }
  if state.windows[original.id] != nil {
    state.windows[original.id] = original
    return
  }

  var window = original
  window.floating = (original.floating || decision.floating) && !decision.forceTiling
  if decision.forceTiling {
    window.floatingOrigin = nil
  } else if decision.floating {
    window.floatingOrigin = .configured
  }
  window.forceTiling = decision.forceTiling
  window.intrinsicSize = decision.intrinsicSize
  let effectivePlacement = window.floatingOrigin == .automatic ? nil : placement
  let preferredMonitorID = effectivePlacement?.monitorID.flatMap { preferred in
    state.monitors.contains(where: { $0.id == preferred }) ? preferred : nil
  }
  let monitorID = preferredMonitorID ?? window.monitorID ?? state.monitors[0].id
  let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }) ?? 0
  let preferredWorkspaceID = effectivePlacement?.workspaceID
  let workspaceID =
    decision.workspace
    ?? preferredWorkspaceID.flatMap { preferred in
      state.monitors[monitorIndex].workspaces.contains(where: { $0.id == preferred })
        ? preferred
        : nil
    }
    ?? state.monitors[monitorIndex].activeWorkspace
  guard
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == workspaceID }
    )
  else {
    throw ReducerError.unknownWorkspace(workspaceID)
  }

  if window.floating && !window.forceTiling {
    state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.append(window.id)
    if decision.followFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedFloatingWindow =
        state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.count - 1
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .floating
    }
  } else {
    insertNewWindow(
      window.id,
      into: &state.monitors[monitorIndex].workspaces[workspaceIndex],
      settings: state.layout
    )
    if decision.followFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .tiled
    }
  }
  if decision.followFocus {
    state.monitors[monitorIndex].activeWorkspace = workspaceID
  }
  state.windows[window.id] = window
}

@discardableResult
public func moveFloatingWindow(
  _ windowID: WindowID,
  to targetMonitorID: MonitorID,
  state: inout RuntimeState
) -> Bool {
  guard
    let sourceMonitorIndex = state.monitors.firstIndex(where: { monitor in
      monitor.workspaces.contains(where: { $0.floatingWindows.contains(windowID) })
    }),
    state.monitors[sourceMonitorIndex].id != targetMonitorID,
    let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(
      where: { $0.floatingWindows.contains(windowID) }
    ),
    let targetMonitorIndex = state.monitors.firstIndex(where: {
      $0.id == targetMonitorID
    }),
    let targetWorkspaceIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[targetMonitorIndex].activeWorkspace }
    )
  else {
    return false
  }

  removeWindow(
    windowID,
    from: &state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex],
    settings: state.layout
  )
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].floatingWindows.append(
    windowID
  )
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].focusedFloatingWindow =
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].floatingWindows.count - 1
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].focusedLayer = .floating
  state.windows[windowID]?.monitorID = targetMonitorID
  return true
}

public func reconcileWindows(
  _ discovered: [Window],
  config: Config,
  placementPreferences: PlacementPreferences = PlacementPreferences(),
  externallyChangedWindowIDs: Set<WindowID> = [],
  state: inout RuntimeState
) {
  let discoveredIDs = Set(discovered.map(\.id))
  for existingID in Array(state.windows.keys) where !discoveredIDs.contains(existingID) {
    removeWindowEverywhere(existingID, state: &state)
    state.windows[existingID] = nil
    state.suspendedTiledPlacements[existingID] = nil
  }

  for window in discovered {
    if state.windows[window.id] == nil {
      try? discoverWindow(
        window,
        decision: config.decision(for: window),
        placement: placementPreferences.preference(for: window),
        state: &state
      )
    } else {
      var updated = window
      if let existing = state.windows[window.id] {
        if existing.floatingOrigin == .automatic {
          reclassifyAutomaticWindow(
            window.id,
            observedFloating: updated.floating,
            state: &state
          )
        } else if existing.floatingOrigin == nil,
          !existing.forceTiling,
          updated.floatingOrigin == .automatic,
          updated.floating
        {
          reclassifyTiledWindowAsAutomaticFloater(
            window.id,
            state: &state
          )
        } else {
          updated.floating = existing.floating
          updated.floatingOrigin = existing.floatingOrigin
        }
        updated.forceTiling = existing.forceTiling
        updated.intrinsicSize = existing.intrinsicSize
        if existing.intrinsicSize,
          !externallyChangedWindowIDs.contains(window.id)
        {
          updated.frame.width = existing.frame.width
          updated.frame.height = existing.frame.height
        }
      }
      state.windows[window.id] = updated
    }
  }
}

private func reclassifyTiledWindowAsAutomaticFloater(
  _ windowID: WindowID,
  state: inout RuntimeState
) {
  guard let location = state.location(containing: windowID),
    let monitorIndex = state.monitors.firstIndex(where: { $0.id == location.monitorID }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == location.workspaceID }
    )
  else {
    return
  }

  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  guard let columnIndex = workspace.columns.firstIndex(where: {
    $0.windows.contains(windowID)
  }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
  else { return }
  state.suspendedTiledPlacements[windowID] = SuspendedTiledPlacement(
    monitorID: location.monitorID,
    workspaceID: location.workspaceID,
    columnIndex: columnIndex,
    windowIndex: windowIndex,
    column: workspace.columns[columnIndex]
  )
  let selectedTiledWindowID = workspace.columns.indices.contains(workspace.focusedColumn)
    && workspace.columns[workspace.focusedColumn].windows.indices.contains(
      workspace.columns[workspace.focusedColumn].focusedWindow
    )
    ? workspace.columns[workspace.focusedColumn].windows[
      workspace.columns[workspace.focusedColumn].focusedWindow
    ]
    : nil
  let wasFocused = workspace.focusedLayer == .tiled
    && selectedTiledWindowID == windowID
  let previousTargetScrollOffset = workspace.targetScrollOffset
  removeWindow(windowID, from: &workspace, settings: state.layout)
  workspace.floatingWindows.append(windowID)
  if wasFocused {
    workspace.focusedFloatingWindow = workspace.floatingWindows.count - 1
    workspace.focusedLayer = .floating
  } else if let selectedTiledWindowID,
    let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(selectedTiledWindowID)
    }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(
      of: selectedTiledWindowID
    )
  {
    workspace.focusedColumn = columnIndex
    workspace.columns[columnIndex].focusedWindow = windowIndex
    workspace.targetScrollOffset = previousTargetScrollOffset
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

private func reclassifyAutomaticWindow(
  _ windowID: WindowID,
  observedFloating: Bool,
  state: inout RuntimeState
) {
  guard !observedFloating,
    let location = state.location(containing: windowID),
    let monitorIndex = state.monitors.firstIndex(where: { $0.id == location.monitorID }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == location.workspaceID }
    )
  else {
    return
  }

  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let wasFocused = workspace.focusedLayer == .floating
    && workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
    && workspace.floatingWindows[workspace.focusedFloatingWindow] == windowID
  let previouslySelectedTiledWindowID = workspace.columns.indices.contains(
    workspace.focusedColumn
  ) && workspace.columns[workspace.focusedColumn].windows.indices.contains(
    workspace.columns[workspace.focusedColumn].focusedWindow
  )
    ? workspace.columns[workspace.focusedColumn].windows[
      workspace.columns[workspace.focusedColumn].focusedWindow
    ]
    : nil
  let previousTargetScrollOffset = workspace.targetScrollOffset
  removeWindow(windowID, from: &workspace, settings: state.layout)
  if let placement = state.suspendedTiledPlacements.removeValue(forKey: windowID),
    placement.monitorID == location.monitorID,
    placement.workspaceID == location.workspaceID
  {
    let siblings = Set(placement.column.windows.filter { $0 != windowID })
    if let columnIndex = workspace.columns.firstIndex(where: {
      !$0.windows.allSatisfy { !siblings.contains($0) }
    }) {
      workspace.columns[columnIndex].windows.insert(
        windowID,
        at: min(placement.windowIndex, workspace.columns[columnIndex].windows.count)
      )
    } else {
      var column = placement.column
      column.windows = [windowID]
      column.focusedWindow = 0
      workspace.columns.insert(
        column,
        at: min(placement.columnIndex, workspace.columns.count)
      )
    }
  } else {
    insertNewWindow(windowID, into: &workspace, settings: state.layout)
  }
  if wasFocused {
    workspace.focusedLayer = .tiled
    if let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }),
      let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
    {
      workspace.focusedColumn = columnIndex
      workspace.columns[columnIndex].focusedWindow = windowIndex
    }
  } else if let previouslySelectedTiledWindowID,
    let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(previouslySelectedTiledWindowID)
    }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(
      of: previouslySelectedTiledWindowID
    )
  {
    workspace.focusedColumn = columnIndex
    workspace.columns[columnIndex].focusedWindow = windowIndex
    workspace.targetScrollOffset = previousTargetScrollOffset
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

private func removeWindowEverywhere(_ windowID: WindowID, state: inout RuntimeState) {
  for monitorIndex in state.monitors.indices {
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      removeWindow(
        windowID,
        from: &state.monitors[monitorIndex].workspaces[workspaceIndex],
        settings: state.layout
      )
    }
  }
}
