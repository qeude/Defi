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

  if let selectedWindowID = state.selectedWindowID(on: state.monitors[monitorIndex].id),
    state.nativeFullscreenWindowIDs.contains(selectedWindowID),
    commandMutatesNativeFullscreenSelection(command)
  {
    return
  }

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
        let column = state.monitors[monitorIndex].workspaces[index].columns[columnIndex]
        for windowID in column.windows
        where state.pendingNativeFullscreenWidthResetWindowIDs.remove(windowID) != nil {
          state.windows[windowID]?.minimumTiledWidth = nil
          state.windows[windowID]?.maximumTiledWidth = nil
        }
        let minimumFraction: Double? = viewports[state.monitors[monitorIndex].id].flatMap {
          viewport in
          guard viewport.width > 0 else { return nil }
          let minimumWidth = column.windows.compactMap {
            state.windows[$0]?.minimumTiledWidth
          }.max()
          return minimumWidth.map { $0 / viewport.width }
        }
        let maximumFraction: Double? = viewports[state.monitors[monitorIndex].id].flatMap {
          viewport in
          guard viewport.width > 0 else { return nil }
          let maximumWidths = column.windows.compactMap {
            state.windows[$0]?.maximumTiledWidth
          }
          guard maximumWidths.count == column.windows.count else { return nil }
          return maximumWidths.max().map { $0 / viewport.width }
        }
        cycleWidth(
          of: &state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
          direction: direction,
          presets: layout.presetColumnWidths,
          minimumFraction: minimumFraction,
          maximumFraction: maximumFraction
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
      guard let target = state.workspaceLocation(for: workspaceID) else {
        throw ReducerError.unknownWorkspace(workspaceID)
      }
      state.monitors[target.monitorIndex].activeWorkspace = workspaceID
    case .focusWorkspace(let target):
      guard let destination = state.resolveWorkspaceTarget(target, on: monitorIndex) else {
        throw ReducerError.unknownWorkspace(workspaceID(for: target))
      }
      state.monitors[destination.monitorIndex].activeWorkspace =
        state.monitors[destination.monitorIndex].workspaces[destination.workspaceIndex].id
    case .moveWindowToWorkspace(let workspaceID):
      try moveFocusedSelectionToWorkspace(
        .named(workspaceID.rawValue),
        movesWholeColumn: false,
        follow: true,
        sourceMonitorIndex: monitorIndex,
        viewports: viewports,
        state: &state
      )
    case .sendWindowToWorkspace(let workspaceID):
      try moveFocusedSelectionToWorkspace(
        .named(workspaceID.rawValue),
        movesWholeColumn: false,
        follow: false,
        sourceMonitorIndex: monitorIndex,
        viewports: viewports,
        state: &state
      )
    case .moveColumnToWorkspace(let target, let follow):
      try moveFocusedSelectionToWorkspace(
        target,
        movesWholeColumn: true,
        follow: follow,
        sourceMonitorIndex: monitorIndex,
        viewports: viewports,
        state: &state
      )
    case .moveWindowToWorkspaceTarget(let target, let follow):
      try moveFocusedSelectionToWorkspace(
        target,
        movesWholeColumn: false,
        follow: follow,
        sourceMonitorIndex: monitorIndex,
        viewports: viewports,
        state: &state
      )
    case .reorderWorkspace(let direction):
      try reorderActiveWorkspace(
        direction,
        monitorIndex: monitorIndex,
        state: &state
      )
    case .moveWorkspaceToMonitor(let direction):
      try moveActiveWorkspaceToMonitor(
        direction,
        sourceMonitorIndex: monitorIndex,
        monitorFrames: monitorFrames,
        viewports: viewports,
        state: &state
      )
    case .focusMonitor:
      break
    case .joinWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let workspace = state.monitors[monitorIndex].workspaces[index]
      if !workspace.columns.isEmpty,
        !joinTargetsNativeFullscreenColumn(
          direction,
          workspace: workspace,
          nativeFullscreenWindowIDs: state.nativeFullscreenWindowIDs
        )
      {
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
    case .toggleOverview:
      break
    case .runStartupCommands:
      break
    }
  } catch let error as LayoutError {
    throw ReducerError.layout(error)
  }
  state.maintainWorkspaceLifecycle()
  normalizeNativeFullscreenColumns(state: &state)
}

private func joinTargetsNativeFullscreenColumn(
  _ direction: Direction,
  workspace: Workspace,
  nativeFullscreenWindowIDs: Set<WindowID>
) -> Bool {
  let targetColumnIndex: Int?
  switch direction {
  case .left, .previous:
    targetColumnIndex = workspace.focusedColumn > 0 ? workspace.focusedColumn - 1 : nil
  case .right, .next:
    targetColumnIndex =
      workspace.focusedColumn + 1 < workspace.columns.count
      ? workspace.focusedColumn + 1
      : nil
  case .up, .down, .first, .last:
    return false
  }
  guard let targetColumnIndex else { return false }
  return workspace.columns[targetColumnIndex].windows.contains {
    nativeFullscreenWindowIDs.contains($0)
  }
}

private func commandMutatesNativeFullscreenSelection(_ command: Command) -> Bool {
  switch command {
  case .moveColumn, .moveWindow, .moveColumnToMonitor, .moveWindowToMonitor,
    .moveWindowToWorkspace, .sendWindowToWorkspace, .cycleWidth,
    .moveColumnToWorkspace, .moveWindowToWorkspaceTarget,
    .reorderWorkspace, .moveWorkspaceToMonitor,
    .maximizeColumn, .toggleFloating, .joinWindow, .unjoinWindows:
    true
  case .focusColumn, .focusFloating, .focusWindow, .switchWorkspace,
    .focusWorkspace, .focusMonitor,
    .activateFloating, .toggleOverview, .runStartupCommands:
    false
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
  guard
    let targetMonitorID = spatialMonitor(
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
    )
  else { return }

  try moveFocusedSelection(
    movesWholeColumn: movesWholeColumn,
    follow: true,
    preservesUserFloatingPlacement: true,
    sourceMonitorIndex: sourceMonitorIndex,
    sourceWorkspaceIndex: sourceWorkspaceIndex,
    targetMonitorIndex: targetMonitorIndex,
    targetWorkspaceIndex: targetWorkspaceIndex,
    monitorFrames: monitorFrames,
    viewports: viewports,
    state: &state
  )
}

private func moveFocusedSelectionToWorkspace(
  _ target: WorkspaceTarget,
  movesWholeColumn: Bool,
  follow: Bool,
  sourceMonitorIndex: Int,
  viewports: [MonitorID: Rect],
  state: inout RuntimeState
) throws {
  guard
    let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[sourceMonitorIndex].activeWorkspace }
    )
  else {
    throw ReducerError.unknownWorkspace(state.monitors[sourceMonitorIndex].activeWorkspace)
  }
  guard let destination = state.resolveWorkspaceTarget(target, on: sourceMonitorIndex) else {
    throw ReducerError.unknownWorkspace(workspaceID(for: target))
  }
  guard
    sourceMonitorIndex != destination.monitorIndex
      || sourceWorkspaceIndex != destination.workspaceIndex
  else { return }
  try moveFocusedSelection(
    movesWholeColumn: movesWholeColumn,
    follow: follow,
    preservesUserFloatingPlacement: false,
    sourceMonitorIndex: sourceMonitorIndex,
    sourceWorkspaceIndex: sourceWorkspaceIndex,
    targetMonitorIndex: destination.monitorIndex,
    targetWorkspaceIndex: destination.workspaceIndex,
    monitorFrames: viewports,
    viewports: viewports,
    state: &state
  )
}

private func moveFocusedSelection(
  movesWholeColumn: Bool,
  follow: Bool,
  preservesUserFloatingPlacement: Bool,
  sourceMonitorIndex: Int,
  sourceWorkspaceIndex: Int,
  targetMonitorIndex: Int,
  targetWorkspaceIndex: Int,
  monitorFrames: [MonitorID: Rect],
  viewports: [MonitorID: Rect],
  state: inout RuntimeState
) throws {
  let sourceMonitorID = state.monitors[sourceMonitorIndex].id
  let targetMonitorID = state.monitors[targetMonitorIndex].id

  let sourceWorkspace = state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex]
  guard
    let selectedWindowID = movesWholeColumn
      ? state.selectedTiledWindowID(on: sourceMonitorID)
      : state.selectedWindowID(on: sourceMonitorID)
  else { return }
  let rootWindowID = transientRootWindowID(selectedWindowID, windows: state.windows)
  let rootColumnIndex = sourceWorkspace.columns.firstIndex {
    $0.windows.contains(rootWindowID)
  }
  let movedColumnIndex =
    movesWholeColumn
    ? sourceWorkspace.columns.firstIndex {
      $0.windows.contains(selectedWindowID)
    }
    : nil
  let primaryWindowIDs: Set<WindowID>
  var transferredColumn: Column?
  if let movedColumnIndex {
    transferredColumn = sourceWorkspace.columns[movedColumnIndex]
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
  let ownerWindowIDs = Set(
    primaryWindowIDs.map {
      transientRootWindowID($0, windows: state.windows)
    }
  )
  let chainWindowIDs = primaryWindowIDs.union(ownerWindowIDs)
  let movedWindowIDs = transientDescendants(
    of: chainWindowIDs,
    windows: state.windows
  ).union(chainWindowIDs)
  let auxiliaryTiledColumns = groupedTiledColumns(
    moving: movedWindowIDs,
    excluding: primaryWindowIDs,
    from: sourceWorkspace
  )
  let topologyWindowIDs = state.monitors.flatMap(\.workspaces).flatMap {
    $0.columns.flatMap(\.windows) + $0.floatingWindows
  }
  let orderedMovedWindowIDs =
    topologyWindowIDs.filter(movedWindowIDs.contains)
      + movedWindowIDs.subtracting(topologyWindowIDs).sorted {
        $0.rawValue < $1.rawValue
      }

  if let movedColumnIndex {
    state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex]
      .columns.remove(at: movedColumnIndex)
    let remainingColumnCount = state.monitors[sourceMonitorIndex]
      .workspaces[sourceWorkspaceIndex].columns.count
    state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex]
      .focusedColumn =
      remainingColumnCount == 0
        ? 0
        : min(
          state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex]
            .focusedColumn,
          remainingColumnCount - 1
        )
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
  for windowID in orderedMovedWindowIDs where !primaryWindowIDs.contains(windowID) {
    removeWindowFromEveryWorkspace(windowID, state: &state)
  }

  let sourceViewport = viewports[sourceMonitorID] ?? monitorFrames[sourceMonitorID]
  let targetViewport = viewports[targetMonitorID] ?? monitorFrames[targetMonitorID]
  let widthScale =
    sourceViewport.flatMap { source in
      targetViewport.map { $0.width / max(source.width, 1) }
    } ?? 1
  var transferredColumnIndex: Int?
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
    transferredColumnIndex = insertionIndex
  }

  let transferredWindowIDs = transferredColumn.map { Set($0.windows) } ?? []
  let auxiliaryWindowIDs = orderedMovedWindowIDs.filter {
    !transferredWindowIDs.contains($0)
  }
  var auxiliaryColumnInsertionIndex = transferredColumnIndex.map { $0 + 1 }
  for windowID in auxiliaryWindowIDs {
    if state.windows[windowID]?.floating == true
      && state.windows[windowID]?.forceTiling != true
    {
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .floatingWindows.append(windowID)
    } else if var column = auxiliaryTiledColumns.byFirstWindowID[windowID] {
      scalePixelWidths(in: &column, by: widthScale)
      let insertionIndex = min(
        auxiliaryColumnInsertionIndex
          ?? state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
            .focusedColumn + 1,
        state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
          .columns.count
      )
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .columns.insert(column, at: insertionIndex)
      auxiliaryColumnInsertionIndex = insertionIndex + 1
      if column.windows.contains(selectedWindowID) {
        state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
          .focusedColumn = insertionIndex
      }
    } else if auxiliaryTiledColumns.windowIDs.contains(windowID) {
      continue
    } else {
      insertNewWindow(
        windowID,
        into: &state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex],
        settings: state.layout,
        focusInsertedWindow: windowID == selectedWindowID
      )
    }
  }
  if auxiliaryWindowIDs.contains(selectedWindowID),
    let selectedIndex = state.monitors[targetMonitorIndex]
      .workspaces[targetWorkspaceIndex].floatingWindows.firstIndex(of: selectedWindowID)
  {
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .focusedFloatingWindow = selectedIndex
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .focusedLayer = .floating
  } else if auxiliaryWindowIDs.contains(selectedWindowID) {
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .focusedLayer = .tiled
  }
  if follow {
    state.monitors[targetMonitorIndex].activeWorkspace =
      state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].id
  }
  repairWorkspaceScroll(
    &state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex],
    settings: state.layout
  )
  for windowID in orderedMovedWindowIDs {
    if let placement = state.suspendedTiledPlacements[windowID] {
      if preservesUserFloatingPlacement
        || state.windows[windowID]?.floatingOrigin == .automatic
      {
        var column = placement.column
        scalePixelWidths(in: &column, by: widthScale)
        state.suspendedTiledPlacements[windowID] = SuspendedTiledPlacement(
          monitorID: targetMonitorID,
          workspaceID: state.monitors[targetMonitorIndex]
            .workspaces[targetWorkspaceIndex].id,
          columnIndex: transferredColumnIndex ?? placement.columnIndex,
          windowIndex: placement.windowIndex,
          column: column
        )
      } else {
        state.suspendedTiledPlacements[windowID] = nil
      }
    }
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
  state.maintainWorkspaceLifecycle()
}

private func workspaceID(for target: WorkspaceTarget) -> WorkspaceID {
  switch target {
  case .named(let name):
    WorkspaceID(rawValue: name)
  case .position(let position):
    WorkspaceID(rawValue: "position-\(position)")
  case .relative(let direction):
    WorkspaceID(rawValue: direction.rawValue)
  }
}

private func reorderActiveWorkspace(
  _ direction: Direction,
  monitorIndex: Int,
  state: inout RuntimeState
) throws {
  guard
    let sourceIndex = state.monitors[monitorIndex].workspaces.firstIndex(where: {
      $0.id == state.monitors[monitorIndex].activeWorkspace
    })
  else {
    throw ReducerError.unknownWorkspace(state.monitors[monitorIndex].activeWorkspace)
  }
  guard state.monitors[monitorIndex].workspaces[sourceIndex].kind != .trailing else { return }
  let targetIndex: Int
  switch direction {
  case .up:
    targetIndex = sourceIndex - 1
  case .down:
    targetIndex = sourceIndex + 1
  default:
    return
  }
  guard targetIndex >= 0,
    targetIndex < state.monitors[monitorIndex].workspaces.count,
    state.monitors[monitorIndex].workspaces[targetIndex].kind != .trailing
  else { return }
  state.monitors[monitorIndex].workspaces.swapAt(sourceIndex, targetIndex)
  state.refreshAffinityPositions(on: monitorIndex)
}

private func moveActiveWorkspaceToMonitor(
  _ direction: Direction,
  sourceMonitorIndex: Int,
  monitorFrames: [MonitorID: Rect],
  viewports: [MonitorID: Rect],
  state: inout RuntimeState
) throws {
  let sourceMonitorID = state.monitors[sourceMonitorIndex].id
  guard
    let targetMonitorID = spatialMonitor(
      from: sourceMonitorID,
      toward: direction,
      frames: monitorFrames
    ),
    let targetMonitorIndex = state.monitors.firstIndex(where: {
      $0.id == targetMonitorID
    }),
    let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(where: {
      $0.id == state.monitors[sourceMonitorIndex].activeWorkspace
    }),
    state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex].kind != .trailing
  else { return }

  var workspace = state.monitors[sourceMonitorIndex].workspaces.remove(
    at: sourceWorkspaceIndex
  )
  let scale =
    (viewports[targetMonitorID] ?? monitorFrames[targetMonitorID]).flatMap {
      target in
      (viewports[sourceMonitorID] ?? monitorFrames[sourceMonitorID]).map {
        target.width / max($0.width, 1)
      }
    } ?? 1
  for columnIndex in workspace.columns.indices {
    scalePixelWidths(in: &workspace.columns[columnIndex], by: scale)
  }
  workspace.affinity = targetMonitorID
  workspace.affinityPosition = state.monitors[targetMonitorIndex].workspaces.count - 1
  let targetWorkspaceIndex =
    state.monitors[targetMonitorIndex].workspaces.firstIndex(where: {
      $0.kind == .trailing
    }) ?? state.monitors[targetMonitorIndex].workspaces.count
  state.monitors[targetMonitorIndex].workspaces.insert(workspace, at: targetWorkspaceIndex)
  state.monitors[targetMonitorIndex].activeWorkspace = workspace.id
  if !state.monitors[sourceMonitorIndex].workspaces.isEmpty {
    state.monitors[sourceMonitorIndex].activeWorkspace =
      state.monitors[sourceMonitorIndex].workspaces[
        min(sourceWorkspaceIndex, state.monitors[sourceMonitorIndex].workspaces.count - 1)
      ].id
  }
  let movedWindowIDs = workspace.columns.flatMap(\.windows) + workspace.floatingWindows
  for windowID in movedWindowIDs {
    state.windows[windowID]?.monitorID = targetMonitorID
    if let placement = state.suspendedTiledPlacements[windowID] {
      var column = placement.column
      scalePixelWidths(in: &column, by: scale)
      state.suspendedTiledPlacements[windowID] = SuspendedTiledPlacement(
        monitorID: targetMonitorID,
        workspaceID: workspace.id,
        columnIndex: placement.columnIndex,
        windowIndex: placement.windowIndex,
        column: column
      )
    }
    if let placement = state.nativeFullscreenTiledPlacements[windowID] {
      var column = placement.column
      scalePixelWidths(in: &column, by: scale)
      state.nativeFullscreenTiledPlacements[windowID] = SuspendedTiledPlacement(
        monitorID: targetMonitorID,
        workspaceID: workspace.id,
        columnIndex: placement.columnIndex,
        windowIndex: placement.windowIndex,
        column: column
      )
    }
  }
  state.refreshAffinityPositions(on: sourceMonitorIndex)
  state.refreshAffinityPositions(on: targetMonitorIndex)
  state.maintainWorkspaceLifecycle()
}

func transientRootWindowID(
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

func transientDescendants(
  of ownerWindowIDs: Set<WindowID>,
  windows: [WindowID: Window]
) -> Set<WindowID> {
  var descendants = Set<WindowID>()
  var owners = ownerWindowIDs
  while true {
    let next = Set(
      windows.compactMap { windowID, window in
        window.transientOwnerID.map(owners.contains) == true
          && !ownerWindowIDs.contains(windowID)
          && !descendants.contains(windowID)
          ? windowID
          : nil
      }
    )
    guard !next.isEmpty else { return descendants }
    descendants.formUnion(next)
    owners = next
  }
}

func groupedTiledColumns(
  moving movedWindowIDs: Set<WindowID>,
  excluding excludedWindowIDs: Set<WindowID> = [],
  from workspace: Workspace
) -> (byFirstWindowID: [WindowID: Column], windowIDs: Set<WindowID>) {
  var columns: [WindowID: Column] = [:]
  var tiledWindowIDs = Set<WindowID>()
  for column in workspace.columns {
    let windows = column.windows.filter {
      movedWindowIDs.contains($0) && !excludedWindowIDs.contains($0)
    }
    guard let firstWindowID = windows.first else { continue }
    let focusedWindowID =
      column.windows.indices.contains(column.focusedWindow)
        ? column.windows[column.focusedWindow]
        : nil
    columns[firstWindowID] = Column(
      windows: windows,
      focusedWindow: focusedWindowID.flatMap(windows.firstIndex(of:))
        ?? min(column.focusedWindow, windows.count - 1),
      width: column.width,
      preMaximizedWidth: column.preMaximizedWidth
    )
    tiledWindowIDs.formUnion(windows)
  }
  return (columns, tiledWindowIDs)
}

func removeWindowFromEveryWorkspace(
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
