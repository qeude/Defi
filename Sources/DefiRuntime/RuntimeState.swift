import DefiConfig
import DefiCore
import DefiModel

public struct RuntimeState: Equatable, Sendable {
  public var monitors: [Monitor]
  public var windows: [WindowID: Window]
  public var layout: LayoutSettings
  public var workspaceNames: [WorkspaceID]
  public var defaultWorkspace: WorkspaceID
  public var suspendedTiledPlacements: [WindowID: SuspendedTiledPlacement]

  public init(config: Config) {
    let names = config.workspaces.names.map(WorkspaceID.init(rawValue:))
    self.monitors = []
    self.windows = [:]
    self.layout = LayoutSettings(config: config.layout)
    self.workspaceNames = names
    self.defaultWorkspace = WorkspaceID(rawValue: config.workspaces.defaultName)
    self.suspendedTiledPlacements = [:]
  }

  public mutating func attachMonitor(_ monitorID: MonitorID) {
    guard !monitors.contains(where: { $0.id == monitorID }) else { return }
    let workspaces = workspaceNames.map { Workspace(id: $0) }
    monitors.append(
      Monitor(
        id: monitorID,
        workspaces: workspaces,
        activeWorkspace: workspaces.contains(where: { $0.id == defaultWorkspace })
          ? defaultWorkspace
          : workspaces[0].id
      )
    )
  }

  public mutating func retainMonitors(
    _ monitorIDs: [MonitorID],
    previousViewports: [MonitorID: Rect] = [:],
    nextViewports: [MonitorID: Rect] = [:]
  ) {
    for monitorID in monitorIDs {
      attachMonitor(monitorID)
    }
    guard !monitorIDs.isEmpty else { return }
    for monitorIndex in monitors.indices
    where monitorIDs.contains(monitors[monitorIndex].id) {
      let monitorID = monitors[monitorIndex].id
      guard let previousWidth = previousViewports[monitorID]?.width,
        let nextWidth = nextViewports[monitorID]?.width
      else {
        continue
      }
      scalePixelWidths(
        in: &monitors[monitorIndex],
        by: nextWidth / max(previousWidth, 1)
      )
      scaleSuspendedPlacements(
        on: monitorID,
        by: nextWidth / max(previousWidth, 1)
      )
    }
    let removed = monitors.filter { !monitorIDs.contains($0.id) }
    monitors.removeAll { !monitorIDs.contains($0.id) }
    guard let fallbackIndex = monitors.indices.first else { return }
    let fallbackWidth = nextViewports[monitors[fallbackIndex].id]?.width
    for var monitor in removed {
      let migrationScale = previousViewports[monitor.id].flatMap { previousViewport in
        fallbackWidth.map { $0 / max(previousViewport.width, 1) }
      }
      if let previousWidth = previousViewports[monitor.id]?.width,
        let fallbackWidth
      {
        scalePixelWidths(
          in: &monitor,
          by: fallbackWidth / max(previousWidth, 1)
        )
      }
      for workspace in monitor.workspaces {
        guard
          let target = monitors[fallbackIndex].workspaces.firstIndex(
            where: { $0.id == workspace.id }
          )
        else {
          continue
        }
        let columnOffset = monitors[fallbackIndex].workspaces[target].columns.count
        migrateSuspendedPlacements(
          from: monitor.id,
          to: monitors[fallbackIndex].id,
          workspaceID: workspace.id,
          columnOffset: columnOffset,
          scale: migrationScale
        )
        monitors[fallbackIndex].workspaces[target].columns.append(contentsOf: workspace.columns)
        monitors[fallbackIndex].workspaces[target].floatingWindows.append(
          contentsOf: workspace.floatingWindows.filter {
            !monitors[fallbackIndex].workspaces[target].floatingWindows.contains($0)
          }
        )
      }
    }
  }

  private mutating func scaleSuspendedPlacements(
    on monitorID: MonitorID,
    by scale: Double
  ) {
    for windowID in suspendedTiledPlacements.keys {
      guard let placement = suspendedTiledPlacements[windowID],
        placement.monitorID == monitorID
      else { continue }
      suspendedTiledPlacements[windowID] = placement.scaled(by: scale)
    }
  }

  private mutating func migrateSuspendedPlacements(
    from sourceMonitorID: MonitorID,
    to targetMonitorID: MonitorID,
    workspaceID: WorkspaceID,
    columnOffset: Int,
    scale: Double?
  ) {
    for windowID in suspendedTiledPlacements.keys {
      guard let placement = suspendedTiledPlacements[windowID],
        placement.monitorID == sourceMonitorID,
        placement.workspaceID == workspaceID
      else { continue }
      let migrated = scale.map { placement.scaled(by: $0) } ?? placement
      suspendedTiledPlacements[windowID] = SuspendedTiledPlacement(
        monitorID: targetMonitorID,
        workspaceID: migrated.workspaceID,
        columnIndex: columnOffset + migrated.columnIndex,
        windowIndex: migrated.windowIndex,
        column: migrated.column
      )
    }
  }

  public func monitorID(containing windowID: WindowID) -> MonitorID? {
    location(containing: windowID)?.monitorID
  }

  public func location(
    containing windowID: WindowID
  ) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
    for monitor in monitors {
      for workspace in monitor.workspaces
      where workspace.columns.contains(where: { $0.windows.contains(windowID) })
        || workspace.floatingWindows.contains(windowID)
      {
        return (monitor.id, workspace.id)
      }
    }
    return nil
  }

  public func selectedWindowID(on monitorID: MonitorID) -> WindowID? {
    guard let monitor = monitors.first(where: { $0.id == monitorID }),
      let workspace = monitor.workspaces.first(
        where: { $0.id == monitor.activeWorkspace }
      )
    else {
      return nil
    }
    let selectedFloatingWindowID = focusedFloatingWindowID(in: workspace)
    if workspace.focusedLayer == .floating { return selectedFloatingWindowID }
    guard workspace.columns.indices.contains(workspace.focusedColumn) else {
      return selectedFloatingWindowID
    }
    let column = workspace.columns[workspace.focusedColumn]
    guard column.windows.indices.contains(column.focusedWindow) else {
      return nil
    }
    return column.windows[column.focusedWindow]
  }

  public func selectedFloatingWindowID(on monitorID: MonitorID) -> WindowID? {
    guard let monitor = monitors.first(where: { $0.id == monitorID }),
      let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace })
    else {
      return nil
    }
    return focusedFloatingWindowID(in: workspace)
  }

  public func reboundFocusMonitorID(
    for windowID: WindowID,
    requestedWorkspaceID: WorkspaceID? = nil
  ) -> MonitorID? {
    guard let location = location(containing: windowID),
      requestedWorkspaceID.map({ $0 == location.workspaceID }) ?? true,
      monitors.contains(where: {
        $0.id == location.monitorID
          && $0.activeWorkspace == location.workspaceID
      }),
      selectedWindowID(on: location.monitorID) == windowID
    else {
      return nil
    }
    return location.monitorID
  }
}

public struct SuspendedTiledPlacement: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let columnIndex: Int
  public let windowIndex: Int
  public let column: Column

  fileprivate func scaled(by scale: Double) -> Self {
    var column = column
    scalePixelWidths(in: &column, by: scale)
    return Self(
      monitorID: monitorID,
      workspaceID: workspaceID,
      columnIndex: columnIndex,
      windowIndex: windowIndex,
      column: column
    )
  }
}

private func focusedFloatingWindowID(in workspace: Workspace) -> WindowID? {
  guard workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow) else {
    return nil
  }
  return workspace.floatingWindows[workspace.focusedFloatingWindow]
}

public func commandShouldFocusWindow(
  _ command: Command,
  previousSelectedWindowID: WindowID?,
  selectedWindowID: WindowID,
  selectedFloatingWindowID: WindowID?
) -> Bool {
  selectedWindowID != previousSelectedWindowID
    || (command.explicitlyFocusesFloating
      && selectedWindowID == selectedFloatingWindowID)
}

private func scalePixelWidths(in monitor: inout Monitor, by scale: Double) {
  guard scale.isFinite, scale > 0, abs(scale - 1) >= 0.001 else { return }
  for workspaceIndex in monitor.workspaces.indices {
    for columnIndex in monitor.workspaces[workspaceIndex].columns.indices {
      scalePixelWidth(
        &monitor.workspaces[workspaceIndex].columns[columnIndex].width,
        by: scale
      )
      if var previous =
        monitor.workspaces[workspaceIndex]
        .columns[columnIndex]
        .preMaximizedWidth
      {
        scalePixelWidth(&previous, by: scale)
        monitor.workspaces[workspaceIndex]
          .columns[columnIndex]
          .preMaximizedWidth = previous
      }
    }
  }
}

private func scalePixelWidths(in column: inout Column, by scale: Double) {
  guard scale.isFinite, scale > 0, abs(scale - 1) >= 0.001 else { return }
  scalePixelWidth(&column.width, by: scale)
  if var previous = column.preMaximizedWidth {
    scalePixelWidth(&previous, by: scale)
    column.preMaximizedWidth = previous
  }
}

private func scalePixelWidth(_ width: inout ColumnWidth, by scale: Double) {
  guard case .pixels(let pixels) = width else { return }
  width = .pixels(max(pixels * scale, 80))
}

extension LayoutSettings {
  fileprivate init(config: LayoutConfig) {
    self.init(
      defaultColumnWidth: config.defaultColumnWidth,
      presetColumnWidths: config.presetColumnWidths,
      centerFocusedColumn: config.centerFocusedColumn == .always ? .always : .never,
      innerHorizontalGap: config.gaps / 2,
      innerVerticalGap: config.gaps / 2,
      outerTopGap: config.gaps,
      outerRightGap: config.gaps,
      outerBottomGap: config.gaps,
      outerLeftGap: config.gaps
    )
  }
}
