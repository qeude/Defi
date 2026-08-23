import DefiConfig
import DefiCore
import DefiModel
import Darwin

public func discoverWindow(
  _ original: Window,
  decision: RuleDecision,
  placement: WindowPlacementPreference? = nil,
  isNativelyFocused: Bool = false,
  isFrontmostAppSpawn: Bool = false,
  isNativeFullscreen: Bool = false,
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
  window.floating =
    ((original.floating && !isNativeFullscreen) || decision.floating)
    && !decision.forceTiling
  if decision.forceTiling {
    window.floatingOrigin = nil
  } else if decision.floating {
    window.floatingOrigin = .configured
  }
  window.forceTiling = decision.forceTiling
  window.intrinsicSize = decision.intrinsicSize
  let effectivePlacement = window.floatingOrigin == .automatic ? nil : placement
  let transientLocation = transientPlacementLocation(for: window, state: state)
  let followFocusIntent = decision.followFocus && isNativelyFocused
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
  // Policy: a managed window spawning into the active workspace of its
  // monitor always inserts after the focused column and takes focus - the
  // native focused-window event can legitimately lag window creation, so it
  // alone must not gate this.
  let followsFocus =
    followFocusIntent
    || (isFrontmostAppSpawn
        && workspaceID == state.monitors[monitorIndex].activeWorkspace
        && !window.floating)

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
  state: RuntimeState,
  locations: WindowLocationMap? = nil
) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
  func location(containing windowID: WindowID) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
    locations?[windowID] ?? state.location(containing: windowID)
  }
  guard window.isModal || window.floatingOrigin == .automatic else { return nil }
  if let ownerID = window.transientOwnerID,
    let ownerLocation = location(containing: ownerID)
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
  return location(containing: sameApplicationSelections[0])
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
  nativeFullscreenWindowIDs: Set<WindowID> = [],
  viewports: [MonitorID: Rect] = [:],
  nativeFocusedWindowID: WindowID? = nil,
  frontmostProcessID: pid_t? = nil,
  state: inout RuntimeState
) -> Set<WindowID> {
  var relocatedTransientIDs = Set<WindowID>()
  let discoveredIDs = Set(discovered.map(\.id))
  let fullscreenSpaceHidesOtherWindows =
    !nativeFullscreenWindowIDs.isEmpty || !state.nativeFullscreenWindowIDs.isEmpty
  for existingID in Array(state.windows.keys)
  where !discoveredIDs.contains(existingID) && !fullscreenSpaceHidesOtherWindows {
    removeWindowEverywhere(existingID, state: &state)
    state.windows[existingID] = nil
    state.nativeFullscreenFloatingWindowIDs.remove(existingID)
    state.nativeFullscreenTiledPlacements[existingID] = nil
    state.pendingNativeFullscreenWidthResetWindowIDs.remove(existingID)
    state.suspendedTiledPlacements[existingID] = nil
  }

  for window in discovered {
    if state.windows[window.id] == nil {
      try? discoverWindow(
        window,
        decision: config.decision(for: window),
        placement: placementPreferences.preference(for: window),
        isNativelyFocused: window.id == nativeFocusedWindowID,
        isFrontmostAppSpawn: window.processID != nil
          && window.processID == frontmostProcessID,
        isNativeFullscreen: nativeFullscreenWindowIDs.contains(window.id),
        state: &state
      )
    } else {
      var updated = window
      if let existing = state.windows[window.id] {
        if existing.floatingOrigin == .automatic,
          !nativeFullscreenWindowIDs.contains(window.id)
        {
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
          updated.floating,
          !nativeFullscreenWindowIDs.contains(window.id)
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
        updated.minimumTiledWidth = nativeFullscreenWindowIDs.contains(window.id)
          ? nil
          : existing.minimumTiledWidth
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
    var locations = state.windowLocationMap()
    for window in discovered where relocateTransientIfNeeded(
      window.id,
      viewports: viewports,
      locations: &locations,
      state: &state
    ) {
      relocatedTransientIDs.insert(window.id)
      relocatedInPass = true
    }
    if relocatedInPass == false { break }
  }
  reconcileNativeFullscreenWindows(nativeFullscreenWindowIDs, state: &state)
  return relocatedTransientIDs
}

private func reconcileNativeFullscreenWindows(
  _ nextWindowIDs: Set<WindowID>,
  state: inout RuntimeState
) {
  let exiting = state.nativeFullscreenWindowIDs.subtracting(nextWindowIDs).sorted {
    let lhs = state.nativeFullscreenTiledPlacements[$0]
    let rhs = state.nativeFullscreenTiledPlacements[$1]
    return (lhs?.columnIndex ?? .max, lhs?.windowIndex ?? .max, $0.rawValue)
      < (rhs?.columnIndex ?? .max, rhs?.windowIndex ?? .max, $1.rawValue)
  }
  for windowID in exiting {
    state.pendingNativeFullscreenWidthResetWindowIDs.insert(windowID)
    state.nativeFullscreenWindowIDs.remove(windowID)
    resumeNativeFullscreenWindow(windowID, state: &state)
  }

  let entering = nextWindowIDs.subtracting(state.nativeFullscreenWindowIDs).sorted {
    nativeFullscreenEntryOrder($0, state: state)
      < nativeFullscreenEntryOrder($1, state: state)
  }
  for windowID in entering {
    state.pendingNativeFullscreenWidthResetWindowIDs.remove(windowID)
    suspendNativeFullscreenWindow(windowID, state: &state)
    state.nativeFullscreenWindowIDs.insert(windowID)
  }
  state.nativeFullscreenWindowIDs = nextWindowIDs.intersection(state.windows.keys)
  normalizeNativeFullscreenColumns(state: &state)
}

private func nativeFullscreenEntryOrder(
  _ windowID: WindowID,
  state: RuntimeState
) -> (Int, Int, Int, UInt64) {
  for (monitorIndex, monitor) in state.monitors.enumerated() {
    for (workspaceIndex, workspace) in monitor.workspaces.enumerated() {
      for (columnIndex, column) in workspace.columns.enumerated() {
        if let windowIndex = column.windows.firstIndex(of: windowID) {
          return (monitorIndex, workspaceIndex, columnIndex, UInt64(windowIndex))
        }
      }
    }
  }
  return (.max, .max, .max, windowID.rawValue)
}

private func suspendNativeFullscreenWindow(
  _ windowID: WindowID,
  state: inout RuntimeState
) {
  guard let location = state.location(containing: windowID),
    let monitorIndex = state.monitors.firstIndex(where: { $0.id == location.monitorID }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == location.workspaceID }
    )
  else { return }
  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let selectedWindowID = selectedWindowID(in: workspace)
  let targetScrollOffset = workspace.targetScrollOffset
  if workspace.floatingWindows.contains(windowID) {
    let savedColumn = state.suspendedTiledPlacements[windowID]?.column
    removeWindow(windowID, from: &workspace, settings: state.layout)
    workspace.columns.append(
      Column(
        window: windowID,
        width: savedColumn?.width ?? .fraction(state.layout.defaultColumnWidth),
        preMaximizedWidth: savedColumn?.preMaximizedWidth
      )
    )
    state.nativeFullscreenFloatingWindowIDs.insert(windowID)
    state.nativeFullscreenWindowIDs.insert(windowID)
    normalizeNativeFullscreenColumns(
      &workspace,
      fullscreenWindowIDs: state.nativeFullscreenWindowIDs,
      placements: state.nativeFullscreenTiledPlacements
    )
    restoreSelection(selectedWindowID, in: &workspace)
    workspace.targetScrollOffset = targetScrollOffset
    state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
    return
  }
  guard
    let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
  else { return }

  let priorPlacement = state.nativeFullscreenWindowIDs.compactMap {
    state.nativeFullscreenTiledPlacements[$0]
  }.first { $0.column.windows.contains(windowID) }
  let originalColumn = priorPlacement?.column ?? workspace.columns[columnIndex]
  let visibleColumnIndex = workspace.columns[..<columnIndex].filter { column in
    column.windows.contains { !state.nativeFullscreenWindowIDs.contains($0) }
  }.count
  let removedColumnIndices = state.nativeFullscreenWindowIDs.compactMap {
    state.nativeFullscreenTiledPlacements[$0]?.columnIndex
  }.sorted()
  let originalColumnIndex = removedColumnIndices.reduce(visibleColumnIndex) {
    index, removed in removed <= index ? index + 1 : index
  }
  state.nativeFullscreenTiledPlacements[windowID] = SuspendedTiledPlacement(
    monitorID: location.monitorID,
    workspaceID: location.workspaceID,
    columnIndex: priorPlacement?.columnIndex ?? originalColumnIndex,
    windowIndex: originalColumn.windows.firstIndex(of: windowID) ?? windowIndex,
    column: originalColumn
  )
  removeWindow(windowID, from: &workspace, settings: state.layout)
  workspace.columns.append(
    Column(
      window: windowID,
      width: originalColumn.width,
      preMaximizedWidth: originalColumn.preMaximizedWidth
    )
  )
  state.nativeFullscreenWindowIDs.insert(windowID)
  normalizeNativeFullscreenColumns(
    &workspace,
    fullscreenWindowIDs: state.nativeFullscreenWindowIDs,
    placements: state.nativeFullscreenTiledPlacements
  )
  restoreSelection(selectedWindowID, in: &workspace)
  workspace.targetScrollOffset = targetScrollOffset
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

private func resumeNativeFullscreenWindow(
  _ windowID: WindowID,
  state: inout RuntimeState
) {
  if state.nativeFullscreenFloatingWindowIDs.remove(windowID) != nil {
    guard state.windows[windowID]?.floating == true,
      let location = state.location(containing: windowID),
      let monitorIndex = state.monitors.firstIndex(where: { $0.id == location.monitorID }),
      let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
        where: { $0.id == location.workspaceID }
      )
    else { return }
    var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
    let selectedWindowID = selectedWindowID(in: workspace)
    let targetScrollOffset = workspace.targetScrollOffset
    removeWindow(windowID, from: &workspace, settings: state.layout)
    workspace.floatingWindows.append(windowID)
    restoreSelection(selectedWindowID, in: &workspace)
    workspace.targetScrollOffset = targetScrollOffset
    state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
    return
  }
  guard let placement = state.nativeFullscreenTiledPlacements.removeValue(forKey: windowID),
    let monitorIndex = state.monitors.firstIndex(where: { $0.id == placement.monitorID }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == placement.workspaceID }
    )
  else { return }
  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let selectedWindowID = selectedWindowID(in: workspace)
  let targetScrollOffset = workspace.targetScrollOffset
  removeWindow(windowID, from: &workspace, settings: state.layout)
  normalizeNativeFullscreenColumns(
    &workspace,
    fullscreenWindowIDs: state.nativeFullscreenWindowIDs,
    placements: state.nativeFullscreenTiledPlacements
  )

  let visibleSiblings = placement.column.windows.filter {
    $0 != windowID && !state.nativeFullscreenWindowIDs.contains($0)
  }
  if let columnIndex = workspace.columns.firstIndex(where: { column in
    column.windows.contains(where: visibleSiblings.contains)
  }) {
    let insertionIndex =
      workspace.columns[columnIndex].windows.firstIndex { siblingID in
        guard let siblingIndex = placement.column.windows.firstIndex(of: siblingID) else {
          return false
        }
        return siblingIndex > placement.windowIndex
      } ?? workspace.columns[columnIndex].windows.count
    workspace.columns[columnIndex].windows.insert(windowID, at: insertionIndex)
    workspace.columns[columnIndex].width = placement.column.width
    workspace.columns[columnIndex].preMaximizedWidth = placement.column.preMaximizedWidth
  } else {
    let suspendedBefore = state.nativeFullscreenWindowIDs.compactMap {
      state.nativeFullscreenTiledPlacements[$0]
    }.filter {
      $0.monitorID == placement.monitorID
        && $0.workspaceID == placement.workspaceID
        && $0.columnIndex < placement.columnIndex
    }.count
    let visibleColumnCount = workspace.columns.filter { column in
      column.windows.contains { !state.nativeFullscreenWindowIDs.contains($0) }
    }.count
    let insertionIndex = min(
      max(placement.columnIndex - suspendedBefore, 0),
      visibleColumnCount
    )
    workspace.columns.insert(
      Column(
        window: windowID,
        width: placement.column.width,
        preMaximizedWidth: placement.column.preMaximizedWidth
      ),
      at: insertionIndex
    )
  }
  normalizeNativeFullscreenColumns(
    &workspace,
    fullscreenWindowIDs: state.nativeFullscreenWindowIDs,
    placements: state.nativeFullscreenTiledPlacements
  )
  restoreSelection(selectedWindowID, in: &workspace)
  workspace.targetScrollOffset = targetScrollOffset
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

func normalizeNativeFullscreenColumns(state: inout RuntimeState) {
  guard !state.nativeFullscreenWindowIDs.isEmpty else { return }
  for monitorIndex in state.monitors.indices {
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      normalizeNativeFullscreenColumns(
        &state.monitors[monitorIndex].workspaces[workspaceIndex],
        fullscreenWindowIDs: state.nativeFullscreenWindowIDs,
        placements: state.nativeFullscreenTiledPlacements
      )
    }
  }
}

private func normalizeNativeFullscreenColumns(
  _ workspace: inout Workspace,
  fullscreenWindowIDs: Set<WindowID>,
  placements: [WindowID: SuspendedTiledPlacement]
) {
  let selectedWindowID = selectedWindowID(in: workspace)
  var visibleColumns: [Column] = []
  var fullscreenColumns: [Column] = []
  for column in workspace.columns {
    let visibleWindowIDs = column.windows.filter { !fullscreenWindowIDs.contains($0) }
    if !visibleWindowIDs.isEmpty {
      var visible = column
      visible.windows = visibleWindowIDs
      visible.focusedWindow = min(visible.focusedWindow, visibleWindowIDs.count - 1)
      visibleColumns.append(visible)
    }
    for windowID in column.windows where fullscreenWindowIDs.contains(windowID) {
      let saved = placements[windowID]?.column
      fullscreenColumns.append(
        Column(
          window: windowID,
          width: saved?.width ?? column.width,
          preMaximizedWidth: saved?.preMaximizedWidth ?? column.preMaximizedWidth
        )
      )
    }
  }
  fullscreenColumns.sort {
    let lhsID = $0.windows[0]
    let rhsID = $1.windows[0]
    let lhs = placements[lhsID]
    let rhs = placements[rhsID]
    return (lhs?.columnIndex ?? .max, lhs?.windowIndex ?? .max, lhsID.rawValue)
      < (rhs?.columnIndex ?? .max, rhs?.windowIndex ?? .max, rhsID.rawValue)
  }
  workspace.columns = visibleColumns + fullscreenColumns
  restoreSelection(selectedWindowID, in: &workspace)
}

private func selectedWindowID(in workspace: Workspace) -> WindowID? {
  if workspace.focusedLayer == .floating,
    workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
  {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  let column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else { return nil }
  return column.windows[column.focusedWindow]
}

private func restoreSelection(
  _ windowID: WindowID?,
  in workspace: inout Workspace
) {
  guard let windowID else { return }
  if let floatingIndex = workspace.floatingWindows.firstIndex(of: windowID) {
    workspace.focusedFloatingWindow = floatingIndex
    workspace.focusedLayer = .floating
    return
  }
  guard
    let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
  else { return }
  workspace.focusedColumn = columnIndex
  workspace.columns[columnIndex].focusedWindow = windowIndex
  workspace.focusedLayer = .tiled
}

@discardableResult
private func relocateTransientIfNeeded(
  _ windowID: WindowID,
  viewports: [MonitorID: Rect],
  locations: inout WindowLocationMap,
  state: inout RuntimeState
) -> Bool {
  guard let window = state.windows[windowID],
    let current = locations[windowID] ?? state.location(containing: windowID),
    let target = transientPlacementLocation(
      for: window,
      state: state,
      locations: locations
    ),
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
  locations[windowID] = (target.monitorID, target.workspaceID)
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
