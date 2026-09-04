import DefiCore
import DefiModel

func reconcileNativeFullscreenWindows(
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

