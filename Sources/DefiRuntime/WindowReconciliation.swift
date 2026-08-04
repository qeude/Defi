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
  window.floating = decision.floating
  window.forceTiling = decision.forceTiling
  window.intrinsicSize = decision.intrinsicSize
  let preferredMonitorID = placement?.monitorID.flatMap { preferred in
    state.monitors.contains(where: { $0.id == preferred }) ? preferred : nil
  }
  let monitorID = preferredMonitorID ?? window.monitorID ?? state.monitors[0].id
  let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }) ?? 0
  let preferredWorkspaceID = placement?.workspaceID
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
  } else {
    insertNewWindow(
      window.id,
      into: &state.monitors[monitorIndex].workspaces[workspaceIndex],
      settings: state.layout
    )
  }
  if decision.followFocus {
    state.monitors[monitorIndex].activeWorkspace = workspaceID
  }
  state.windows[window.id] = window
}

public func reconcileWindows(
  _ discovered: [Window],
  config: Config,
  placementPreferences: PlacementPreferences = PlacementPreferences(),
  state: inout RuntimeState
) {
  let discoveredIDs = Set(discovered.map(\.id))
  for existingID in Array(state.windows.keys) where !discoveredIDs.contains(existingID) {
    removeWindowEverywhere(existingID, state: &state)
    state.windows[existingID] = nil
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
        updated.floating = existing.floating
        updated.forceTiling = existing.forceTiling
        updated.intrinsicSize = existing.intrinsicSize
        if existing.intrinsicSize {
          updated.frame.width = existing.frame.width
          updated.frame.height = existing.frame.height
        }
      }
      state.windows[window.id] = updated
    }
  }
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
