import DefiConfig
import DefiCore
import DefiModel

public func discoverWindow(
  _ original: Window,
  decision: RuleDecision,
  placement: WindowPlacementPreference? = nil,
  isNativelyFocused: Bool = false,
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
  let transientLocation = transientPlacementLocation(for: window, state: state)
  let followsFocus = decision.followFocus && isNativelyFocused
  let preferredMonitorID = effectivePlacement?.monitorID.flatMap { preferred in
    state.monitors.contains(where: { $0.id == preferred }) ? preferred : nil
  }
  let monitorID =
    transientLocation?.monitorID
    ?? preferredMonitorID
    ?? window.monitorID
    ?? state.monitors[0].id
  let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }) ?? 0
  let preferredWorkspaceID = effectivePlacement?.workspaceID
  let workspaceID =
    transientLocation?.workspaceID
    ?? decision.workspace
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
    if followsFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedFloatingWindow =
        state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.count - 1
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .floating
    }
  } else {
    insertNewWindow(
      window.id,
      into: &state.monitors[monitorIndex].workspaces[workspaceIndex],
      settings: state.layout,
      focusInsertedWindow: followsFocus
    )
    if followsFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .tiled
    }
  }
  if followsFocus {
    state.monitors[monitorIndex].activeWorkspace = workspaceID
  }
  state.windows[window.id] = window
}

public func transientPlacementLocation(
  for window: Window,
  state: RuntimeState
) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
  guard window.isModal || window.floatingOrigin == .automatic else { return nil }
  if let ownerID = window.transientOwnerID,
    let ownerLocation = state.location(containing: ownerID)
  {
    return ownerLocation
  }
  let sameApplicationSelections = state.monitors.compactMap { monitor -> WindowID? in
    guard let selected = state.selectedWindowID(on: monitor.id),
      let selectedWindow = state.windows[selected],
      selectedWindow.appID == window.appID,
      window.processID.map({ selectedWindow.processID == $0 }) ?? true
    else { return nil }
    return selected
  }
  guard sameApplicationSelections.count == 1 else { return nil }
  return state.location(containing: sameApplicationSelections[0])
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

  state.suspendedTiledPlacements[windowID] = nil
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

@discardableResult
public func reconcileWindows(
  _ discovered: [Window],
  config: Config,
  placementPreferences: PlacementPreferences = PlacementPreferences(),
  externallyChangedWindowIDs: Set<WindowID> = [],
  viewports: [MonitorID: Rect] = [:],
  nativeFocusedWindowID: WindowID? = nil,
  state: inout RuntimeState
) -> Set<WindowID> {
  var relocatedTransientIDs = Set<WindowID>()
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
        isNativelyFocused: window.id == nativeFocusedWindowID,
        state: &state
      )
    } else {
      var updated = window
      if let existing = state.windows[window.id] {
        if existing.floatingOrigin == .automatic {
          reclassifyAutomaticWindow(
            window.id,
            observedFloating: updated.floating,
            preferredPlacement: config.decision(for: window).workspace == nil
              ? placementPreferences.preference(for: window)
              : nil,
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
  // ponytail: bounded convergence scan; owner-ordering can replace it if deep chains become common.
  for _ in discovered.indices {
    var relocatedInPass = false
    for window in discovered where relocateTransientIfNeeded(
      window.id,
      viewports: viewports,
      state: &state
    ) {
      relocatedTransientIDs.insert(window.id)
      relocatedInPass = true
    }
    if relocatedInPass == false { break }
  }
  return relocatedTransientIDs
}

@discardableResult
private func relocateTransientIfNeeded(
  _ windowID: WindowID,
  viewports: [MonitorID: Rect],
  state: inout RuntimeState
) -> Bool {
  guard let window = state.windows[windowID],
    let current = state.location(containing: windowID),
    let target = transientPlacementLocation(for: window, state: state),
    current.monitorID != target.monitorID || current.workspaceID != target.workspaceID,
    let targetMonitorIndex = state.monitors.firstIndex(where: {
      $0.id == target.monitorID
    }),
    let targetWorkspaceIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(
      where: { $0.id == target.workspaceID }
    )
  else { return false }

  let wasSelected = state.selectedWindowID(on: current.monitorID) == windowID
  var relocatedTiledColumn = state.monitors.first {
    $0.id == current.monitorID
  }?.workspaces.first {
    $0.id == current.workspaceID
  }?.columns.first {
    $0.windows.contains(windowID)
  }.map {
    Column(
      window: windowID,
      width: $0.width,
      preMaximizedWidth: $0.preMaximizedWidth
    )
  }
  if var column = relocatedTiledColumn,
    let sourceViewport = viewports[current.monitorID],
    let targetViewport = viewports[target.monitorID]
  {
    scalePixelWidths(
      in: &column,
      by: targetViewport.width / max(sourceViewport.width, 1)
    )
    relocatedTiledColumn = column
  }
  removeWindowEverywhere(windowID, state: &state)
  if window.floating && !window.forceTiling {
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .floatingWindows.append(windowID)
    if wasSelected {
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .focusedFloatingWindow = state.monitors[targetMonitorIndex]
        .workspaces[targetWorkspaceIndex].floatingWindows.count - 1
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .focusedLayer = .floating
    }
  } else {
    insertNewWindow(
      windowID,
      width: relocatedTiledColumn?.width
        ?? .fraction(state.layout.defaultColumnWidth),
      into: &state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex],
      settings: state.layout,
      focusInsertedWindow: wasSelected
    )
    if let preMaximizedWidth = relocatedTiledColumn?.preMaximizedWidth,
      let columnIndex = state.monitors[targetMonitorIndex]
        .workspaces[targetWorkspaceIndex].columns.firstIndex(where: {
          $0.windows.contains(windowID)
        })
    {
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .columns[columnIndex].preMaximizedWidth = preMaximizedWidth
    }
    if wasSelected {
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .focusedLayer = .tiled
    }
  }
  if wasSelected {
    state.monitors[targetMonitorIndex].activeWorkspace = target.workspaceID
  }
  if let placement = state.suspendedTiledPlacements[windowID] {
    var column = placement.column
    if let sourceViewport = viewports[current.monitorID],
      let targetViewport = viewports[target.monitorID]
    {
      scalePixelWidths(
        in: &column,
        by: targetViewport.width / max(sourceViewport.width, 1)
      )
    }
    state.suspendedTiledPlacements[windowID] = SuspendedTiledPlacement(
      monitorID: target.monitorID,
      workspaceID: target.workspaceID,
      columnIndex: placement.columnIndex,
      windowIndex: placement.windowIndex,
      column: column
    )
  }
  state.windows[windowID]?.monitorID = target.monitorID
  return true
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
  let priorPlacement = state.suspendedTiledPlacements.values.first {
    $0.monitorID == location.monitorID
      && $0.workspaceID == location.workspaceID
      && $0.column.windows.contains(windowID)
  }
  let originalColumn = priorPlacement?.column ?? workspace.columns[columnIndex]
  let removedColumnIndices = Set<Int>(state.suspendedTiledPlacements.values.compactMap { placement in
    guard placement.monitorID == location.monitorID,
      placement.workspaceID == location.workspaceID,
      !workspace.columns.contains(where: { column in
        column.windows.contains(where: placement.column.windows.contains)
      })
    else { return nil }
    return placement.columnIndex
  })
  let originalColumnIndex = removedColumnIndices.sorted().reduce(columnIndex) { index, removed in
    removed <= index ? index + 1 : index
  }
  state.suspendedTiledPlacements[windowID] = SuspendedTiledPlacement(
    monitorID: location.monitorID,
    workspaceID: location.workspaceID,
    columnIndex: priorPlacement?.columnIndex ?? originalColumnIndex,
    windowIndex: originalColumn.windows.firstIndex(of: windowID) ?? windowIndex,
    column: originalColumn
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

private func focusedWindowAfterSuspension(
  _ placement: SuspendedTiledPlacement,
  windowID: WindowID
) -> WindowID? {
  let survivingWindows = placement.column.windows.filter { $0 != windowID }
  guard !survivingWindows.isEmpty else { return nil }
  guard placement.column.windows.indices.contains(placement.column.focusedWindow) else {
    return survivingWindows[0]
  }
  let savedFocusedWindowID = placement.column.windows[placement.column.focusedWindow]
  guard savedFocusedWindowID == windowID else {
    return savedFocusedWindowID
  }
  return survivingWindows[
    min(placement.column.focusedWindow, survivingWindows.count - 1)
  ]
}

private func reclassifyAutomaticWindow(
  _ windowID: WindowID,
  observedFloating: Bool,
  preferredPlacement: WindowPlacementPreference? = nil,
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
  let suspendedPlacement = state.suspendedTiledPlacements.removeValue(forKey: windowID)
  if let placement = suspendedPlacement,
    placement.monitorID == location.monitorID,
    placement.workspaceID == location.workspaceID
  {
    let siblings = Set(placement.column.windows.filter { $0 != windowID })
    if let columnIndex = workspace.columns.firstIndex(where: {
      !$0.windows.allSatisfy { !siblings.contains($0) }
    }) {
      let focusedWindowID = placement.column.windows.indices.contains(
        placement.column.focusedWindow
      ) ? placement.column.windows[placement.column.focusedWindow] : nil
      let expectedFocusedWindowID = focusedWindowAfterSuspension(
        placement,
        windowID: windowID
      )
      let currentFocusedWindowID = workspace.columns[columnIndex].windows.indices.contains(
        workspace.columns[columnIndex].focusedWindow
      ) ? workspace.columns[columnIndex].windows[
        workspace.columns[columnIndex].focusedWindow
      ] : nil
      let insertionIndex = workspace.columns[columnIndex].windows.firstIndex { siblingID in
        guard let siblingIndex = placement.column.windows.firstIndex(of: siblingID) else {
          return false
        }
        return siblingIndex > placement.windowIndex
      } ?? workspace.columns[columnIndex].windows.count
      workspace.columns[columnIndex].windows.insert(
        windowID,
        at: insertionIndex
      )
      if let currentFocusedWindowID,
        let currentFocusedWindow = workspace.columns[columnIndex].windows.firstIndex(
          of: currentFocusedWindowID
        )
      {
        workspace.columns[columnIndex].focusedWindow = currentFocusedWindow
        if currentFocusedWindowID == expectedFocusedWindowID,
          let focusedWindowID,
          let focusedWindow = workspace.columns[columnIndex].windows.firstIndex(
            of: focusedWindowID
          )
        {
          workspace.columns[columnIndex].focusedWindow = focusedWindow
        }
      } else if let focusedWindowID,
        let focusedWindow = workspace.columns[columnIndex].windows.firstIndex(
          of: focusedWindowID
        )
      {
        workspace.columns[columnIndex].focusedWindow = focusedWindow
      }
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
    let destination = preferredPlacement.flatMap { preference -> (Int, Int)? in
      let destinationMonitorIndex = preference.monitorID.flatMap { preferredMonitorID in
        state.monitors.firstIndex(where: { $0.id == preferredMonitorID })
      } ?? monitorIndex
      guard let workspaceIndex = state.monitors[destinationMonitorIndex].workspaces.firstIndex(
          where: { $0.id == preference.workspaceID }
        )
      else { return nil }
      return (destinationMonitorIndex, workspaceIndex)
    }
    if let (destinationMonitorIndex, destinationWorkspaceIndex) = destination,
      destinationMonitorIndex != monitorIndex || destinationWorkspaceIndex != workspaceIndex
    {
      if let previouslySelectedTiledWindowID,
        let selectedColumnIndex = workspace.columns.firstIndex(where: {
          $0.windows.contains(previouslySelectedTiledWindowID)
        }),
        let selectedWindowIndex = workspace.columns[selectedColumnIndex].windows.firstIndex(
          of: previouslySelectedTiledWindowID
        )
      {
        workspace.focusedColumn = selectedColumnIndex
        workspace.columns[selectedColumnIndex].focusedWindow = selectedWindowIndex
        workspace.targetScrollOffset = previousTargetScrollOffset
      }
      state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
      var destinationWorkspace = state.monitors[destinationMonitorIndex]
        .workspaces[destinationWorkspaceIndex]
      insertNewWindow(
        windowID,
        into: &destinationWorkspace,
        settings: state.layout,
        focusInsertedWindow: false
      )
      if wasFocused,
        let destinationColumnIndex = destinationWorkspace.columns.firstIndex(where: {
          $0.windows.contains(windowID)
        }),
        let destinationWindowIndex = destinationWorkspace.columns[destinationColumnIndex]
          .windows.firstIndex(of: windowID)
      {
        destinationWorkspace.focusedLayer = .tiled
        destinationWorkspace.focusedColumn = destinationColumnIndex
        destinationWorkspace.columns[destinationColumnIndex].focusedWindow = destinationWindowIndex
        state.monitors[destinationMonitorIndex].activeWorkspace = destinationWorkspace.id
      }
      state.monitors[destinationMonitorIndex].workspaces[destinationWorkspaceIndex] =
        destinationWorkspace
      return
    }
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
