import DefiCore
import DefiModel

public enum RuntimeCommand: Equatable, Sendable {
  case setReservedEdges([MonitorID: ReservedEdges])
  case clearReservedEdges([MonitorID])
}

public enum ReducerError: Error, Equatable, CustomStringConvertible, Sendable {
  case noMonitor
  case unknownMonitor(MonitorID)
  case unknownWorkspace(WorkspaceID)
  case noFocusedWindow
  case layout(LayoutError)

  public var description: String {
    switch self {
    case .noMonitor: "no monitor"
    case .unknownMonitor(let monitorID): "unknown monitor: \(monitorID)"
    case .unknownWorkspace(let id): "unknown workspace: \(id)"
    case .noFocusedWindow: "no focused window"
    case .layout(let error): "layout error: \(error)"
    }
  }
}

public func reduce(
  _ command: RuntimeCommand,
  state: inout RuntimeState
) throws {
  let monitorIDs: [MonitorID]
  switch command {
  case .setReservedEdges(let edges):
    monitorIDs = Array(edges.keys)
  case .clearReservedEdges(let ids):
    monitorIDs = ids
  }
  for monitorID in monitorIDs {
    guard state.monitors.contains(where: { $0.id == monitorID }) else {
      throw ReducerError.unknownMonitor(monitorID)
    }
  }

  switch command {
  case .setReservedEdges(let edges):
    state.reservedEdgesByMonitor.merge(edges) { _, next in next }
  case .clearReservedEdges(let monitorIDs):
    for monitorID in monitorIDs {
      state.reservedEdgesByMonitor[monitorID] = nil
    }
  }
}

public func reduce(
  _ command: Command,
  on requestedMonitorID: MonitorID?,
  state: inout RuntimeState,
  monitorFrames: [MonitorID: Rect] = [:],
  viewports: [MonitorID: Rect] = [:]
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
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
        try focusColumn(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .moveColumn(let direction), .moveWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
        try moveFocusedWindow(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .moveColumnToMonitor(let direction):
      try moveFocusedSelectionToMonitor(
        direction,
        movesWholeColumn: true,
        sourceMonitorIndex: monitorIndex,
        monitorFrames: monitorFrames,
        viewports: viewports,
        state: &state
      )
    case .moveWindowToMonitor(let direction):
      try moveFocusedSelectionToMonitor(
        direction,
        movesWholeColumn: false,
        sourceMonitorIndex: monitorIndex,
        monitorFrames: monitorFrames,
        viewports: viewports,
        state: &state
      )
    case .focusWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
        try focusWindow(direction, in: &state.monitors[monitorIndex].workspaces[index])
      }
    case .cycleWidth(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex) {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
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
    case .maximizeColumn:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex) {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
        maximizeColumn(
          &state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
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
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
        try joinFocusedWindow(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .unjoinWindows:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
        try unjoinFocusedWindow(
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .toggleFloating:
      try toggleFocusedFloating(monitorIndex: monitorIndex, state: &state)
    case .focusFloating(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      focusFloating(direction, workspace: &state.monitors[monitorIndex].workspaces[index])
    case .activateFloating:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].floatingWindows.isEmpty {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .floating
      }
    case .runStartupCommands:
      break
    }
  } catch let error as LayoutError {
    throw ReducerError.layout(error)
  }
}

public func changedState(
  after command: Command,
  on monitorID: MonitorID?,
  from state: RuntimeState,
  monitorFrames: [MonitorID: Rect] = [:],
  viewports: [MonitorID: Rect] = [:]
) throws -> RuntimeState? {
  var next = state
  try reduce(
    command,
    on: monitorID,
    state: &next,
    monitorFrames: monitorFrames,
    viewports: viewports
  )
  return next == state ? nil : next
}

private func moveFocusedSelectionToMonitor(
  _ direction: Direction,
  movesWholeColumn: Bool,
  sourceMonitorIndex: Int,
  monitorFrames: [MonitorID: Rect],
  viewports: [MonitorID: Rect],
  state: inout RuntimeState
) throws {
  let sourceMonitorID = state.monitors[sourceMonitorIndex].id
  guard let targetMonitorID = spatialMonitor(
    from: sourceMonitorID,
    toward: direction,
    frames: monitorFrames
  ),
    let targetMonitorIndex = state.monitors.firstIndex(where: {
      $0.id == targetMonitorID
    }),
    let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[sourceMonitorIndex].activeWorkspace }
    ),
    let targetWorkspaceIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[targetMonitorIndex].activeWorkspace }
    ),
    let selectedWindowID = state.selectedWindowID(on: sourceMonitorID)
  else { return }

  let rootWindowID = transientRootWindowID(selectedWindowID, windows: state.windows)
  let sourceWorkspace = state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex]
  let rootColumnIndex = sourceWorkspace.columns.firstIndex {
    $0.windows.contains(rootWindowID)
  }
  let movesColumn = movesWholeColumn && rootColumnIndex != nil
  let primaryWindowIDs: Set<WindowID>
  var transferredColumn: Column?
  if let rootColumnIndex, movesColumn {
    transferredColumn = sourceWorkspace.columns[rootColumnIndex]
    primaryWindowIDs = Set(transferredColumn?.windows ?? [])
  } else {
    primaryWindowIDs = [rootWindowID]
    if let rootColumnIndex {
      let sourceColumn = sourceWorkspace.columns[rootColumnIndex]
      transferredColumn = Column(
        window: rootWindowID,
        width: sourceColumn.width,
        preMaximizedWidth: sourceColumn.preMaximizedWidth
      )
    }
  }
  let movedWindowIDs = transientDescendants(
    of: primaryWindowIDs,
    windows: state.windows
  ).union(primaryWindowIDs)

  if let rootColumnIndex, movesColumn {
    state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex]
      .columns.remove(at: rootColumnIndex)
    repairWorkspaceScroll(
      &state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex],
      settings: state.layout
    )
  } else {
    removeWindow(
      rootWindowID,
      from: &state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex],
      settings: state.layout
    )
  }
  for windowID in movedWindowIDs.subtracting(primaryWindowIDs) {
    removeWindowFromEveryWorkspace(windowID, state: &state)
  }

  let sourceViewport = viewports[sourceMonitorID] ?? monitorFrames[sourceMonitorID]
  let targetViewport = viewports[targetMonitorID] ?? monitorFrames[targetMonitorID]
  let widthScale = sourceViewport.flatMap { source in
    targetViewport.map { $0.width / max(source.width, 1) }
  } ?? 1
  if var column = transferredColumn {
    scalePixelWidths(in: &column, by: widthScale)
    let insertionIndex = min(
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .focusedColumn + 1,
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .columns.count
    )
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .columns.insert(column, at: insertionIndex)
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .focusedColumn = insertionIndex
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .focusedLayer = .tiled
  }

  let auxiliaryWindowIDs = movedWindowIDs.subtracting(
    transferredColumn.map { Set($0.windows) } ?? []
  )
  for windowID in auxiliaryWindowIDs {
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .floatingWindows.append(windowID)
  }
  if auxiliaryWindowIDs.contains(selectedWindowID),
    let selectedIndex = state.monitors[targetMonitorIndex]
      .workspaces[targetWorkspaceIndex].floatingWindows.firstIndex(of: selectedWindowID)
  {
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .focusedFloatingWindow = selectedIndex
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .focusedLayer = .floating
  }
  state.monitors[targetMonitorIndex].activeWorkspace =
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].id
  repairWorkspaceScroll(
    &state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex],
    settings: state.layout
  )
  for windowID in movedWindowIDs {
    state.suspendedTiledPlacements[windowID] = nil
    state.windows[windowID]?.monitorID = targetMonitorID
    if state.windows[windowID]?.floating == true,
      let sourceViewport,
      let targetViewport,
      let frame = state.windows[windowID]?.frame
    {
      state.windows[windowID]?.frame = rebasedFloatingFrame(
        frame,
        from: sourceViewport,
        to: targetViewport
      )
    }
  }
}

private func transientRootWindowID(
  _ windowID: WindowID,
  windows: [WindowID: Window]
) -> WindowID {
  var root = windowID
  var visited = Set<WindowID>()
  while visited.insert(root).inserted,
    let owner = windows[root]?.transientOwnerID,
    windows[owner] != nil
  {
    root = owner
  }
  return root
}

private func transientDescendants(
  of ownerWindowIDs: Set<WindowID>,
  windows: [WindowID: Window]
) -> Set<WindowID> {
  var descendants = Set<WindowID>()
  var owners = ownerWindowIDs
  while true {
    let next = Set(windows.compactMap { windowID, window in
      window.transientOwnerID.map(owners.contains) == true
        && !ownerWindowIDs.contains(windowID)
        && !descendants.contains(windowID)
        ? windowID
        : nil
    })
    guard !next.isEmpty else { return descendants }
    descendants.formUnion(next)
    owners = next
  }
}

private func removeWindowFromEveryWorkspace(
  _ windowID: WindowID,
  state: inout RuntimeState
) {
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
  if let windowID = effectiveSelectedFloatingWindowID(in: source) {
    state.suspendedTiledPlacements[windowID] = nil
    removeWindow(
      windowID,
      from: &state.monitors[monitorIndex].workspaces[sourceIndex],
      settings: state.layout
    )
    state.monitors[monitorIndex].workspaces[targetIndex].floatingWindows.append(windowID)
    state.monitors[monitorIndex].workspaces[targetIndex].focusedFloatingWindow =
      state.monitors[monitorIndex].workspaces[targetIndex].floatingWindows.count - 1
    state.monitors[monitorIndex].workspaces[targetIndex].focusedLayer = .floating
    if follow {
      state.monitors[monitorIndex].activeWorkspace = workspaceID
    }
    return
  }
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
  state.monitors[monitorIndex].workspaces[targetIndex].focusedLayer = .tiled
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
  if let windowID = effectiveSelectedFloatingWindowID(in: workspace) {
    state.suspendedTiledPlacements[windowID] = nil
    removeWindow(windowID, from: &workspace, settings: state.layout)
    insertNewWindow(windowID, into: &workspace, settings: state.layout)
    state.windows[windowID]?.floating = false
    state.windows[windowID]?.floatingOrigin = .user
    workspace.focusedLayer = .tiled
  } else if workspace.columns.indices.contains(workspace.focusedColumn) {
    let column = workspace.columns[workspace.focusedColumn]
    guard column.windows.indices.contains(column.focusedWindow) else {
      throw ReducerError.noFocusedWindow
    }
    let windowID = column.windows[column.focusedWindow]
    state.suspendedTiledPlacements[windowID] = nil
    removeWindow(windowID, from: &workspace, settings: state.layout)
    workspace.floatingWindows.append(windowID)
    workspace.focusedFloatingWindow = workspace.floatingWindows.count - 1
    state.windows[windowID]?.floating = true
    state.windows[windowID]?.floatingOrigin = .user
    workspace.focusedLayer = .floating
  } else {
    throw ReducerError.noFocusedWindow
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

private func effectiveSelectedFloatingWindowID(in workspace: Workspace) -> WindowID? {
  guard workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow) else {
    return nil
  }
  if workspace.focusedLayer == .floating {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  guard workspace.columns.indices.contains(workspace.focusedColumn) else {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  let column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  return nil
}

private func focusFloating(_ direction: Direction, workspace: inout Workspace) {
  guard !workspace.floatingWindows.isEmpty else { return }
  workspace.focusedLayer = .floating
  switch direction {
  case .left, .up, .previous:
    workspace.focusedFloatingWindow =
      (workspace.focusedFloatingWindow - 1 + workspace.floatingWindows.count)
      % workspace.floatingWindows.count
  case .right, .down, .next:
    workspace.focusedFloatingWindow =
      (workspace.focusedFloatingWindow + 1) % workspace.floatingWindows.count
  case .first:
    workspace.focusedFloatingWindow = 0
  case .last:
    workspace.focusedFloatingWindow = workspace.floatingWindows.count - 1
  }
}
