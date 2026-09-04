import DefiCore
import DefiModel

func moveFocusedSelectionToMonitor(
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

func moveFocusedSelectionToWorkspace(
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

func workspaceID(for target: WorkspaceTarget) -> WorkspaceID {
  switch target {
  case .named(let name):
    WorkspaceID(rawValue: name)
  case .position(let position):
    WorkspaceID(rawValue: "position-\(position)")
  case .relative(let direction):
    WorkspaceID(rawValue: direction.rawValue)
  }
}

func reorderActiveWorkspace(
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

func moveActiveWorkspaceToMonitor(
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

