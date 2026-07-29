import DefiModel

public func insertNewWindow(
  _ windowID: WindowID,
  into workspace: inout Workspace,
  settings: LayoutSettings
) {
  insertNewWindow(
    windowID,
    width: .fraction(settings.defaultColumnWidth),
    into: &workspace,
    settings: settings
  )
}

public func insertNewWindow(
  _ windowID: WindowID,
  width: ColumnWidth,
  into workspace: inout Workspace,
  settings: LayoutSettings
) {
  let column = Column(window: windowID, width: width)
  guard !workspace.columns.isEmpty else {
    workspace.columns.append(column)
    workspace.focusedColumn = 0
    return
  }

  let index = min(workspace.focusedColumn + 1, workspace.columns.count)
  workspace.columns.insert(column, at: index)
  workspace.focusedColumn = index
  repairWorkspaceScroll(&workspace, settings: settings)
}

public func focusColumn(
  _ direction: Direction,
  in workspace: inout Workspace,
  settings: LayoutSettings
) throws {
  guard !workspace.columns.isEmpty else {
    throw LayoutError.emptyWorkspace
  }

  switch direction {
  case .left, .previous:
    workspace.focusedColumn = max(workspace.focusedColumn - 1, 0)
  case .right, .next:
    workspace.focusedColumn = min(workspace.focusedColumn + 1, workspace.columns.count - 1)
  case .first:
    workspace.focusedColumn = 0
  case .last:
    workspace.focusedColumn = workspace.columns.count - 1
  case .up, .down:
    throw LayoutError.unsupportedDirection
  }
  repairWorkspaceScroll(&workspace, settings: settings)
}

public func moveFocusedWindow(
  _ direction: Direction,
  in workspace: inout Workspace,
  settings: LayoutSettings
) throws {
  guard !workspace.columns.isEmpty else {
    throw LayoutError.emptyWorkspace
  }
  let source = workspace.focusedColumn
  guard workspace.columns.indices.contains(source) else {
    throw LayoutError.focusOutOfBounds
  }

  if direction == .up || direction == .down {
    try moveFocusedWindowInStack(direction, workspace: &workspace)
    return
  }

  let target: Int
  switch direction {
  case .left, .previous:
    target = max(source - 1, 0)
  case .right, .next:
    target = min(source + 1, workspace.columns.count - 1)
  case .first:
    target = 0
  case .last:
    target = workspace.columns.count - 1
  case .up, .down:
    throw LayoutError.unsupportedDirection
  }
  guard source != target else { return }

  if direction == .first || direction == .last {
    let column = workspace.columns.remove(at: source)
    workspace.columns.insert(column, at: target)
  } else {
    workspace.columns.swapAt(source, target)
  }
  workspace.focusedColumn = target
  repairWorkspaceScroll(&workspace, settings: settings)
}

public func focusWindow(
  _ direction: Direction,
  in workspace: inout Workspace
) throws {
  guard workspace.columns.indices.contains(workspace.focusedColumn) else {
    throw LayoutError.emptyWorkspace
  }
  let index = workspace.focusedColumn
  guard !workspace.columns[index].windows.isEmpty else {
    throw LayoutError.emptyWorkspace
  }

  switch direction {
  case .up, .previous:
    workspace.columns[index].focusedWindow = max(workspace.columns[index].focusedWindow - 1, 0)
  case .down, .next:
    workspace.columns[index].focusedWindow = min(
      workspace.columns[index].focusedWindow + 1,
      workspace.columns[index].windows.count - 1
    )
  case .first:
    workspace.columns[index].focusedWindow = 0
  case .last:
    workspace.columns[index].focusedWindow = workspace.columns[index].windows.count - 1
  case .left, .right:
    throw LayoutError.unsupportedDirection
  }
}

@discardableResult
public func removeWindow(
  _ windowID: WindowID,
  from workspace: inout Workspace,
  settings: LayoutSettings
) -> Bool {
  if let index = workspace.floatingWindows.firstIndex(of: windowID) {
    workspace.floatingWindows.remove(at: index)
    workspace.focusedFloatingWindow =
      workspace.floatingWindows.isEmpty
      ? 0
      : min(workspace.focusedFloatingWindow, workspace.floatingWindows.count - 1)
    return true
  }

  guard let columnIndex = workspace.columns.firstIndex(where: { $0.windows.contains(windowID) }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
  else {
    return false
  }

  workspace.columns[columnIndex].windows.remove(at: windowIndex)
  if workspace.columns[columnIndex].windows.isEmpty {
    workspace.columns.remove(at: columnIndex)
    workspace.focusedColumn =
      workspace.columns.isEmpty
      ? 0
      : min(workspace.focusedColumn, workspace.columns.count - 1)
  } else {
    workspace.columns[columnIndex].focusedWindow = min(
      workspace.columns[columnIndex].focusedWindow,
      workspace.columns[columnIndex].windows.count - 1
    )
  }
  repairWorkspaceScroll(&workspace, settings: settings)
  return true
}

public func cycleWidth(
  of column: inout Column,
  direction: Direction,
  presets: [Double]
) {
  guard !presets.isEmpty else { return }
  guard case .fraction(let current) = column.width else {
    column.width = .fraction(presets[0])
    column.fullscreenPreviousWidth = nil
    return
  }

  let currentIndex =
    presets.firstIndex(where: { abs($0 - current) < .ulpOfOne })
    ?? nearestPresetIndex(current: current, presets: presets)
  let nextIndex: Int
  switch direction {
  case .next, .right:
    nextIndex = (currentIndex + 1) % presets.count
  case .previous, .left:
    nextIndex = currentIndex == 0 ? presets.count - 1 : currentIndex - 1
  case .first:
    nextIndex = 0
  case .last:
    nextIndex = presets.count - 1
  case .up, .down:
    nextIndex = currentIndex
  }
  column.width = .fraction(presets[nextIndex])
  column.fullscreenPreviousWidth = nil
}

public func toggleFullscreen(of column: inout Column, defaultWidth: Double) {
  if case .fraction(let value) = column.width, abs(value - 1) < .ulpOfOne {
    column.width = column.fullscreenPreviousWidth ?? .fraction(defaultWidth)
    column.fullscreenPreviousWidth = nil
  } else {
    column.fullscreenPreviousWidth = column.width
    column.width = .fraction(1)
  }
}

public func joinFocusedWindow(
  _ direction: Direction,
  in workspace: inout Workspace,
  settings: LayoutSettings
) throws {
  let sourceColumnIndex = workspace.focusedColumn
  guard workspace.columns.indices.contains(sourceColumnIndex) else {
    throw LayoutError.emptyWorkspace
  }

  let targetColumnIndex: Int?
  switch direction {
  case .left, .previous:
    targetColumnIndex = sourceColumnIndex > 0 ? sourceColumnIndex - 1 : nil
  case .right, .next:
    targetColumnIndex =
      sourceColumnIndex + 1 < workspace.columns.count
      ? sourceColumnIndex + 1
      : nil
  case .up, .down, .first, .last:
    throw LayoutError.unsupportedDirection
  }
  guard let targetColumnIndex else { return }

  let sourceWindowIndex = workspace.columns[sourceColumnIndex].focusedWindow
  guard workspace.columns[sourceColumnIndex].windows.indices.contains(sourceWindowIndex) else {
    throw LayoutError.emptyWorkspace
  }
  let windowID = workspace.columns[sourceColumnIndex].windows.remove(at: sourceWindowIndex)

  if workspace.columns[sourceColumnIndex].windows.isEmpty {
    workspace.columns.remove(at: sourceColumnIndex)
    let adjustedTarget =
      sourceColumnIndex < targetColumnIndex
      ? targetColumnIndex - 1
      : targetColumnIndex
    workspace.columns[adjustedTarget].windows.append(windowID)
    workspace.columns[adjustedTarget].focusedWindow =
      workspace.columns[adjustedTarget].windows.count - 1
    workspace.focusedColumn = adjustedTarget
  } else {
    workspace.columns[targetColumnIndex].windows.append(windowID)
    workspace.columns[targetColumnIndex].focusedWindow =
      workspace.columns[targetColumnIndex].windows.count - 1
    workspace.focusedColumn = targetColumnIndex
  }

  repairWorkspaceScroll(&workspace, settings: settings)
}

public func unjoinFocusedWindow(
  in workspace: inout Workspace,
  settings: LayoutSettings
) throws {
  let columnIndex = workspace.focusedColumn
  guard workspace.columns.indices.contains(columnIndex) else {
    throw LayoutError.emptyWorkspace
  }
  guard workspace.columns[columnIndex].windows.count > 1 else { return }

  let windowIndex = workspace.columns[columnIndex].focusedWindow
  guard workspace.columns[columnIndex].windows.indices.contains(windowIndex) else {
    throw LayoutError.emptyWorkspace
  }
  let windowID = workspace.columns[columnIndex].windows.remove(at: windowIndex)
  workspace.columns[columnIndex].focusedWindow = min(
    workspace.columns[columnIndex].focusedWindow,
    workspace.columns[columnIndex].windows.count - 1
  )
  workspace.columns.insert(
    Column(window: windowID, width: .fraction(settings.defaultColumnWidth)),
    at: columnIndex + 1
  )
  workspace.focusedColumn = columnIndex + 1
  repairWorkspaceScroll(&workspace, settings: settings)
}

private func moveFocusedWindowInStack(
  _ direction: Direction,
  workspace: inout Workspace
) throws {
  let columnIndex = workspace.focusedColumn
  guard workspace.columns.indices.contains(columnIndex),
    !workspace.columns[columnIndex].windows.isEmpty
  else {
    throw LayoutError.emptyWorkspace
  }
  let source = workspace.columns[columnIndex].focusedWindow
  let target: Int
  switch direction {
  case .up:
    target = max(source - 1, 0)
  case .down:
    target = min(source + 1, workspace.columns[columnIndex].windows.count - 1)
  default:
    throw LayoutError.unsupportedDirection
  }
  workspace.columns[columnIndex].windows.swapAt(source, target)
  workspace.columns[columnIndex].focusedWindow = target
}
