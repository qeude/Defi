import DefiCore
import DefiModel

public struct OverviewWindowIntent: Equatable, Sendable {
  public let windowID: WindowID
  public let expectedAppID: String
  public let sourceMonitorID: MonitorID
  public let sourceWorkspaceID: WorkspaceID

  public init(
    windowID: WindowID,
    expectedAppID: String,
    sourceMonitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID
  ) {
    self.windowID = windowID
    self.expectedAppID = expectedAppID
    self.sourceMonitorID = sourceMonitorID
    self.sourceWorkspaceID = sourceWorkspaceID
  }
}

public struct OverviewDropResult: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let focusedWindowID: WindowID
  public let floatingFrameUpdates: [WindowID: Rect]

  public init(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    focusedWindowID: WindowID,
    floatingFrameUpdates: [WindowID: Rect] = [:]
  ) {
    self.monitorID = monitorID
    self.workspaceID = workspaceID
    self.focusedWindowID = focusedWindowID
    self.floatingFrameUpdates = floatingFrameUpdates
  }
}

public enum OverviewRuntimeError: Error, Equatable, Sendable {
  case staleWindow(WindowID)
  case staleSource(WindowID)
  case transientWindow(WindowID)
  case nativeFullscreen(WindowID)
  case unknownMonitor(MonitorID)
  case unknownWorkspace(WorkspaceID)
  case invalidDropTarget
  case classificationChanged(WindowID)
}

@discardableResult
public func focusOverviewWindow(
  _ intent: OverviewWindowIntent,
  state: inout RuntimeState
) throws -> MonitorID {
  let location = try validateOverviewWindow(intent, state: state)
  _ = focusWindow(intent.windowID, state: &state)
  return location.monitorID
}

@discardableResult
public func focusOverviewWorkspace(
  monitorID: MonitorID,
  workspaceID: WorkspaceID,
  state: inout RuntimeState
) throws -> WindowID? {
  guard let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID })
  else { throw OverviewRuntimeError.unknownMonitor(monitorID) }
  guard
    state.monitors[monitorIndex].workspaces.contains(where: {
    $0.id == workspaceID
    })
  else { throw OverviewRuntimeError.unknownWorkspace(workspaceID) }
  state.monitors[monitorIndex].activeWorkspace = workspaceID
  state.maintainWorkspaceLifecycle()
  return state.selectedWindowID(on: monitorID)
}

public func applyOverviewDrop(
  _ intent: OverviewWindowIntent,
  target: OverviewDropTarget,
  viewports: [MonitorID: Rect],
  floatingFrames: [WindowID: Rect] = [:],
  state: inout RuntimeState
) throws -> OverviewDropResult {
  let sourceLocation = try validateOverviewWindow(intent, state: state)
  guard state.windows[intent.windowID]?.transientOwnerID == nil else {
    throw OverviewRuntimeError.transientWindow(intent.windowID)
  }
  let rootWindowID = transientRootWindowID(intent.windowID, windows: state.windows)
  guard rootWindowID == intent.windowID else {
    throw OverviewRuntimeError.transientWindow(intent.windowID)
  }
  let movedWindowIDs = transientDescendants(
    of: [rootWindowID],
    windows: state.windows
  ).union([rootWindowID])
  if let fullscreenID = movedWindowIDs.first(where: {
    state.nativeFullscreenWindowIDs.contains($0)
  }) {
    throw OverviewRuntimeError.nativeFullscreen(fullscreenID)
  }

  let destination = try validatedDestination(target, state: state)
  let sourceFloatingWindowIDs = Set(
    state.monitors.flatMap(\.workspaces).flatMap(\.floatingWindows)
  )
  let sourceIsFloating = sourceFloatingWindowIDs.contains(intent.windowID)
  if sourceIsFloating {
    guard case .floating = target else {
      throw OverviewRuntimeError.classificationChanged(intent.windowID)
    }
  } else if case .floating = target {
    throw OverviewRuntimeError.classificationChanged(intent.windowID)
  }

  var next = state
  guard let sourceMonitorIndex = next.monitors.firstIndex(where: {
    $0.id == sourceLocation.monitorID
  }),
    let sourceWorkspaceIndex = next.monitors[sourceMonitorIndex].workspaces.firstIndex(
      where: { $0.id == sourceLocation.workspaceID }
    )
  else { throw OverviewRuntimeError.staleSource(intent.windowID) }
  let sourceWorkspace = next.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex]
  let sourceColumnIndex = sourceWorkspace.columns.firstIndex {
    $0.windows.contains(intent.windowID)
  }
  let sourceWindowIndex = sourceColumnIndex.flatMap {
    sourceWorkspace.columns[$0].windows.firstIndex(of: intent.windowID)
  }
  let sourceColumn = sourceColumnIndex.map { sourceWorkspace.columns[$0] }
  let orderedMovedWindowIDs = next.monitors.flatMap(\.workspaces).flatMap {
    $0.columns.flatMap(\.windows) + $0.floatingWindows
  }.filter(movedWindowIDs.contains)
  let movedTiledColumns = groupedTiledColumns(
    moving: movedWindowIDs,
    excluding: [intent.windowID],
    from: sourceWorkspace
  )

  for windowID in orderedMovedWindowIDs {
    removeWindowFromEveryWorkspace(windowID, state: &next)
  }

  guard let targetMonitorIndex = next.monitors.firstIndex(where: {
    $0.id == destination.monitorID
  }),
    let targetWorkspaceIndex = next.monitors[targetMonitorIndex].workspaces.firstIndex(
      where: { $0.id == destination.workspaceID }
    )
  else { throw OverviewRuntimeError.invalidDropTarget }

  let sameWorkspace = sourceLocation.monitorID == destination.monitorID
    && sourceLocation.workspaceID == destination.workspaceID
  let sourceColumnWasRemoved = sourceColumn?.windows.count == 1
  let sourceViewport = viewports[sourceLocation.monitorID]
  let targetViewport = viewports[destination.monitorID]
  let widthScale = sourceViewport.flatMap { source in
    targetViewport.map { $0.width / max(source.width, 1) }
  } ?? 1
  var floatingFrameUpdates: [WindowID: Rect] = [:]

  switch target {
  case .newColumn(_, _, let requestedIndex):
    var insertionIndex = requestedIndex
    if sameWorkspace, sourceColumnWasRemoved,
      let sourceColumnIndex, sourceColumnIndex < insertionIndex
    {
      insertionIndex -= 1
    }
    guard (0...next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .columns.count).contains(insertionIndex)
    else { throw OverviewRuntimeError.invalidDropTarget }
    var column = Column(
      window: intent.windowID,
      width: sourceColumn?.width ?? .fraction(next.layout.defaultColumnWidth),
      preMaximizedWidth: sourceColumn?.preMaximizedWidth
    )
    scalePixelWidths(in: &column, by: widthScale)
    next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .columns.insert(column, at: insertionIndex)
  case .stack(_, _, let requestedColumnIndex, let requestedWindowIndex):
    if sameWorkspace, sourceColumnWasRemoved,
      sourceColumnIndex == requestedColumnIndex, let sourceColumn
    {
      guard (0...next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .columns.count).contains(requestedColumnIndex)
      else { throw OverviewRuntimeError.invalidDropTarget }
      next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .columns.insert(sourceColumn, at: requestedColumnIndex)
      break
    }
    var columnIndex = requestedColumnIndex
    if sameWorkspace, sourceColumnWasRemoved,
      let sourceColumnIndex, sourceColumnIndex < columnIndex
    {
      columnIndex -= 1
    }
    guard next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .columns.indices.contains(columnIndex)
    else { throw OverviewRuntimeError.invalidDropTarget }
    var windowIndex = requestedWindowIndex
    if sameWorkspace, sourceColumnWasRemoved == false,
      sourceColumnIndex == requestedColumnIndex,
      let sourceWindowIndex, sourceWindowIndex < windowIndex
    {
      windowIndex -= 1
    }
    guard (0...next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .columns[columnIndex].windows.count).contains(windowIndex)
    else { throw OverviewRuntimeError.invalidDropTarget }
    next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .columns[columnIndex].windows.insert(intent.windowID, at: windowIndex)
  case .floating(_, _, let relativeFrame):
    guard let viewport = targetViewport,
      relativeFrame.x.isFinite,
      relativeFrame.y.isFinite,
      relativeFrame.width.isFinite,
      relativeFrame.height.isFinite,
      relativeFrame.width > 0,
      relativeFrame.height > 0
    else { throw OverviewRuntimeError.invalidDropTarget }
    let width = min(relativeFrame.width * viewport.width, viewport.width)
    let height = min(relativeFrame.height * viewport.height, viewport.height)
    let frame = Rect(
      x: min(
        max(viewport.x + relativeFrame.x * viewport.width, viewport.x),
        viewport.x + viewport.width - width
      ),
      y: min(
        max(viewport.y + relativeFrame.y * viewport.height, viewport.y),
        viewport.y + viewport.height - height
      ),
      width: width,
      height: height
    )
    next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
      .floatingWindows.append(intent.windowID)
    floatingFrameUpdates[intent.windowID] = frame
    next.windows[intent.windowID]?.frame = frame
  }

  var auxiliaryColumnInsertionIndex = next.monitors[targetMonitorIndex]
    .workspaces[targetWorkspaceIndex].columns.count
  for windowID in orderedMovedWindowIDs where windowID != intent.windowID {
    if sourceFloatingWindowIDs.contains(windowID) {
      next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .floatingWindows.append(windowID)
      if let previousFrame = floatingFrames[windowID] ?? state.windows[windowID]?.frame,
        let sourceViewport,
        let targetViewport
      {
        let frame = rebasedFloatingFrame(
          previousFrame,
          from: sourceViewport,
          to: targetViewport
        )
        next.windows[windowID]?.frame = frame
        floatingFrameUpdates[windowID] = frame
      }
    } else if var column = movedTiledColumns.byFirstWindowID[windowID] {
      scalePixelWidths(in: &column, by: widthScale)
      next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .columns.insert(column, at: auxiliaryColumnInsertionIndex)
      auxiliaryColumnInsertionIndex += 1
    } else if !movedTiledColumns.windowIDs.contains(windowID) {
      next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex]
        .columns.insert(
          Column(window: windowID, width: .fraction(next.layout.defaultColumnWidth)),
          at: auxiliaryColumnInsertionIndex
        )
      auxiliaryColumnInsertionIndex += 1
    }
  }

  for windowID in orderedMovedWindowIDs {
    next.windows[windowID]?.monitorID = destination.monitorID
    if let placement = next.suspendedTiledPlacements[windowID] {
      if next.windows[windowID]?.floatingOrigin == .automatic {
        var column = placement.column
        scalePixelWidths(in: &column, by: widthScale)
        next.suspendedTiledPlacements[windowID] = SuspendedTiledPlacement(
          monitorID: destination.monitorID,
          workspaceID: destination.workspaceID,
          columnIndex: placement.columnIndex,
          windowIndex: placement.windowIndex,
          column: column
        )
      } else {
        next.suspendedTiledPlacements[windowID] = nil
      }
    }
  }
  repairWorkspaceScroll(
    &next.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex],
    settings: next.layout
  )
  repairWorkspaceScroll(
    &next.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex],
    settings: next.layout
  )
  _ = focusWindow(intent.windowID, state: &next)
  next.monitors[targetMonitorIndex].activeWorkspace = destination.workspaceID
  next.maintainWorkspaceLifecycle()
  state = next
  return OverviewDropResult(
    monitorID: destination.monitorID,
    workspaceID: destination.workspaceID,
    focusedWindowID: intent.windowID,
    floatingFrameUpdates: floatingFrameUpdates
  )
}

private func validateOverviewWindow(
  _ intent: OverviewWindowIntent,
  state: RuntimeState
) throws -> (monitorID: MonitorID, workspaceID: WorkspaceID) {
  guard let window = state.windows[intent.windowID],
    window.appID == intent.expectedAppID
  else { throw OverviewRuntimeError.staleWindow(intent.windowID) }
  guard let location = state.location(containing: intent.windowID),
    location.monitorID == intent.sourceMonitorID,
    location.workspaceID == intent.sourceWorkspaceID
  else { throw OverviewRuntimeError.staleSource(intent.windowID) }
  return location
}

private func validatedDestination(
  _ target: OverviewDropTarget,
  state: RuntimeState
) throws -> (monitorID: MonitorID, workspaceID: WorkspaceID) {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
  switch target {
  case .newColumn(let monitor, let workspace, _),
    .stack(let monitor, let workspace, _, _),
    .floating(let monitor, let workspace, _):
    monitorID = monitor
    workspaceID = workspace
  }
  guard let monitor = state.monitors.first(where: { $0.id == monitorID })
  else { throw OverviewRuntimeError.unknownMonitor(monitorID) }
  guard monitor.workspaces.contains(where: { $0.id == workspaceID })
  else { throw OverviewRuntimeError.unknownWorkspace(workspaceID) }
  return (monitorID, workspaceID)
}
