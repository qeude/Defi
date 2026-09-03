import DefiModel

public func insertNewWindow(
  _ windowID: WindowID,
  into workspace: inout Workspace,
  settings: LayoutSettings,
  focusInsertedWindow: Bool = true
) {
  insertNewWindow(
    windowID,
    width: .fraction(settings.defaultColumnWidth),
    into: &workspace,
    settings: settings,
    focusInsertedWindow: focusInsertedWindow
  )
}

public func insertNewWindow(
  _ windowID: WindowID,
  width: ColumnWidth,
  into workspace: inout Workspace,
  settings: LayoutSettings,
  focusInsertedWindow: Bool = true
) {
  let column = Column(window: windowID, width: width)
  guard !workspace.columns.isEmpty else {
    workspace.columns.append(column)
    workspace.focusedColumn = 0
    return
  }

  let index = min(workspace.focusedColumn + 1, workspace.columns.count)
  workspace.columns.insert(column, at: index)
  guard focusInsertedWindow else { return }
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
    if workspace.floatingWindows.isEmpty {
      workspace.focusedFloatingWindow = 0
      workspace.focusedLayer = .tiled
    } else {
      workspace.focusedFloatingWindow = min(
        workspace.focusedFloatingWindow,
        workspace.floatingWindows.count - 1
      )
    }
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
  presets: [Double],
  minimumFraction: Double? = nil,
  maximumFraction: Double? = nil
) {
  guard !presets.isEmpty else { return }
  func effectiveWidth(_ preset: Double) -> Double {
    max(min(preset, maximumFraction ?? preset), minimumFraction ?? 0)
  }
  if column.preMaximizedWidth != nil {
    let boundaryIndex: Int?
    switch direction {
    case .next, .right, .first:
      boundaryIndex = presets.firstIndex {
        abs($0 - 1) >= .ulpOfOne
          && abs(effectiveWidth($0) - effectiveWidth(1)) >= .ulpOfOne
      }
    case .previous, .left, .last:
      boundaryIndex = presets.lastIndex {
        abs($0 - 1) >= .ulpOfOne
          && abs(effectiveWidth($0) - effectiveWidth(1)) >= .ulpOfOne
      }
    case .up, .down:
      boundaryIndex = nil
    }
    guard let boundaryIndex else { return }
    column.width = .fraction(presets[boundaryIndex])
    column.preMaximizedWidth = nil
    return
  }
  guard case .fraction(let current) = column.width else {
    column.width = .fraction(presets[0])
    column.preMaximizedWidth = nil
    return
  }

  let currentIndex =
    presets.firstIndex(where: { abs($0 - current) < .ulpOfOne })
    ?? nearestPresetIndex(current: current, presets: presets)
  var nextIndex = currentIndex
  let step: Int
  switch direction {
  case .next, .right:
    step = 1
  case .previous, .left:
    step = -1
  case .first:
    step = 0
    nextIndex = 0
  case .last:
    step = 0
    nextIndex = presets.count - 1
  case .up, .down:
    step = 0
  }
  if step != 0 {
    nextIndex = (currentIndex + step + presets.count) % presets.count
    let currentEffectiveWidth = effectiveWidth(current)
    for _ in presets.indices {
      guard abs(effectiveWidth(presets[nextIndex]) - currentEffectiveWidth)
        < .ulpOfOne
      else {
        break
      }
      nextIndex = (nextIndex + step + presets.count) % presets.count
    }
    guard abs(effectiveWidth(presets[nextIndex]) - currentEffectiveWidth)
      >= .ulpOfOne
    else {
      return
    }
  }
  column.width = .fraction(presets[nextIndex])
  column.preMaximizedWidth = nil
}

public func maximizeColumn(_ column: inout Column, defaultWidth: Double) {
  if case .fraction(let value) = column.width, abs(value - 1) < .ulpOfOne {
    column.width = column.preMaximizedWidth ?? .fraction(defaultWidth)
    column.preMaximizedWidth = nil
  } else {
    column.preMaximizedWidth = column.width
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
