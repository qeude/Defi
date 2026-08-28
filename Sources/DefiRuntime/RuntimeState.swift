import DefiConfig
import DefiCore
import DefiModel

public typealias WindowLocationMap = [WindowID: (monitorID: MonitorID, workspaceID: WorkspaceID)]

public struct DisconnectedMonitor: Equatable, Codable, Sendable {
  public var activeWorkspace: WorkspaceID

  public init(activeWorkspace: WorkspaceID) {
    self.activeWorkspace = activeWorkspace
  }
}

public struct WorkspaceTopology: Equatable, Codable, Sendable {
  public var monitors: [Monitor]
  public var windows: [WindowID: Window]
  public var nextOrdinaryWorkspaceNumber: UInt64
  public var disconnectedMonitors: [MonitorID: DisconnectedMonitor]
  public var nativeFullscreenWindowIDs: Set<WindowID>
  public var nativeFullscreenFloatingWindowIDs: Set<WindowID>
  public var nativeFullscreenTiledPlacements: [WindowID: SuspendedTiledPlacement]
  public var pendingNativeFullscreenWidthResetWindowIDs: Set<WindowID>
  public var suspendedTiledPlacements: [WindowID: SuspendedTiledPlacement]

  public init(state: RuntimeState) {
    monitors = state.monitors
    windows = state.windows
    nextOrdinaryWorkspaceNumber = state.nextOrdinaryWorkspaceNumber
    disconnectedMonitors = state.disconnectedMonitors
    nativeFullscreenWindowIDs = state.nativeFullscreenWindowIDs
    nativeFullscreenFloatingWindowIDs = state.nativeFullscreenFloatingWindowIDs
    nativeFullscreenTiledPlacements = state.nativeFullscreenTiledPlacements
    pendingNativeFullscreenWidthResetWindowIDs =
      state.pendingNativeFullscreenWidthResetWindowIDs
    suspendedTiledPlacements = state.suspendedTiledPlacements
  }
}

public struct RuntimeState: Equatable, Sendable {
  public var monitors: [Monitor]
  public var windows: [WindowID: Window]
  public var layout: LayoutSettings
  public var workspaceNames: [WorkspaceID]
  public var defaultWorkspace: WorkspaceID?
  public var workspaceMonitorPositions: [WorkspaceID: Int]
  public var nextOrdinaryWorkspaceNumber: UInt64
  public var disconnectedMonitors: [MonitorID: DisconnectedMonitor]
  public var nativeFullscreenWindowIDs: Set<WindowID>
  public var nativeFullscreenFloatingWindowIDs: Set<WindowID>
  public var nativeFullscreenTiledPlacements: [WindowID: SuspendedTiledPlacement]
  public var pendingNativeFullscreenWidthResetWindowIDs: Set<WindowID>
  public var suspendedTiledPlacements: [WindowID: SuspendedTiledPlacement]
  public var reservedEdgesByMonitor: [MonitorID: ReservedEdges]

  public init(config: Config) {
    let names = config.workspaces.names.map(WorkspaceID.init(rawValue:))
    self.monitors = []
    self.windows = [:]
    self.layout = LayoutSettings(config: config)
    self.workspaceNames = names
    self.defaultWorkspace = config.workspaces.defaultName.map(WorkspaceID.init(rawValue:))
    self.workspaceMonitorPositions = Dictionary(
      uniqueKeysWithValues: config.workspaces.monitors.map {
        (WorkspaceID(rawValue: $0.key), $0.value)
      }
    )
    self.nextOrdinaryWorkspaceNumber = 1
    self.disconnectedMonitors = [:]
    self.nativeFullscreenWindowIDs = []
    self.nativeFullscreenFloatingWindowIDs = []
    self.nativeFullscreenTiledPlacements = [:]
    self.pendingNativeFullscreenWidthResetWindowIDs = []
    self.suspendedTiledPlacements = [:]
    self.reservedEdgesByMonitor = [:]
  }

  public init(config: Config, topology: WorkspaceTopology?) {
    self.init(config: config)
    guard let topology else { return }
    monitors = topology.monitors
    windows = topology.windows
    nextOrdinaryWorkspaceNumber = topology.nextOrdinaryWorkspaceNumber
    disconnectedMonitors = topology.disconnectedMonitors
    nativeFullscreenWindowIDs = topology.nativeFullscreenWindowIDs
    nativeFullscreenFloatingWindowIDs = topology.nativeFullscreenFloatingWindowIDs
    nativeFullscreenTiledPlacements = topology.nativeFullscreenTiledPlacements
    pendingNativeFullscreenWidthResetWindowIDs =
      topology.pendingNativeFullscreenWidthResetWindowIDs
    suspendedTiledPlacements = topology.suspendedTiledPlacements
    reconcileConfiguredWorkspaces()
  }

  public var topology: WorkspaceTopology {
    WorkspaceTopology(state: self)
  }

  public mutating func attachMonitor(_ monitorID: MonitorID) {
    attachMonitor(monitorID, previousViewports: [:], nextViewports: [:])
  }

  private mutating func attachMonitor(
    _ monitorID: MonitorID,
    previousViewports: [MonitorID: Rect],
    nextViewports: [MonitorID: Rect]
  ) {
    guard !monitors.contains(where: { $0.id == monitorID }) else { return }
    let isPrimary = monitors.isEmpty
    var workspaces: [Workspace] = []
    if isPrimary {
      workspaces = workspaceNames.enumerated().map { index, id in
        Workspace(
          id: id,
          kind: .named,
          affinity: (workspaceMonitorPositions[id] ?? 1) == 1 ? monitorID : nil,
          affinityPosition: index
        )
      }
    }
    let trailing = makeOrdinaryWorkspace(
      kind: .trailing,
      affinity: monitorID,
      affinityPosition: workspaces.count
    )
    workspaces.append(trailing)
    monitors.append(
      Monitor(
        id: monitorID,
        workspaces: workspaces,
        activeWorkspace: defaultWorkspace.flatMap { defaultID in
          workspaces.contains(where: { $0.id == defaultID }) ? defaultID : nil
        } ?? trailing.id
      )
    )
    restoreAffinedWorkspaces(
      to: monitorID,
      previousViewports: previousViewports,
      nextViewports: nextViewports
    )
    redistributeConfiguredNamedWorkspaces()
    if let disconnected = disconnectedMonitors.removeValue(forKey: monitorID),
      monitors.last?.workspaces.contains(where: {
        $0.id == disconnected.activeWorkspace
      }) == true
    {
      monitors[monitors.count - 1].activeWorkspace = disconnected.activeWorkspace
    }
    maintainWorkspaceLifecycle()
  }

  public mutating func retainMonitors(
    _ monitorIDs: [MonitorID],
    previousViewports: [MonitorID: Rect] = [:],
    nextViewports: [MonitorID: Rect] = [:]
  ) {
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
    for monitor in removed {
      disconnectedMonitors[monitor.id] = DisconnectedMonitor(
        activeWorkspace: monitor.activeWorkspace
      )
    }
    if monitors.isEmpty, let firstMonitorID = monitorIDs.first {
      if removed.isEmpty {
        attachMonitor(
          firstMonitorID,
          previousViewports: previousViewports,
          nextViewports: nextViewports
        )
      } else {
        let trailing = makeOrdinaryWorkspace(
          kind: .trailing,
          affinity: firstMonitorID,
          affinityPosition: 0
        )
        monitors.append(
          Monitor(
            id: firstMonitorID,
            workspaces: [trailing],
            activeWorkspace: trailing.id
          )
        )
      }
    }
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
      for var workspace in monitor.workspaces {
        if workspace.kind == .trailing && workspace.isEmpty { continue }
        if workspace.affinity == nil { workspace.affinity = monitor.id }
        migrateSuspendedPlacements(
          from: monitor.id,
          to: monitors[fallbackIndex].id,
          workspaceID: workspace.id,
          columnOffset: 0,
          scale: migrationScale
        )
        insertBeforeTrailing(workspace, in: fallbackIndex)
        for windowID in workspace.columns.flatMap(\.windows) + workspace.floatingWindows {
          windows[windowID]?.monitorID = monitors[fallbackIndex].id
        }
      }
    }
    monitors.sort {
      (monitorIDs.firstIndex(of: $0.id) ?? .max)
        < (monitorIDs.firstIndex(of: $1.id) ?? .max)
    }
    for monitorID in monitorIDs where !monitors.contains(where: { $0.id == monitorID }) {
      attachMonitor(
        monitorID,
        previousViewports: previousViewports,
        nextViewports: nextViewports
      )
      }
    monitors.sort {
      (monitorIDs.firstIndex(of: $0.id) ?? .max)
        < (monitorIDs.firstIndex(of: $1.id) ?? .max)
    }
    redistributeConfiguredNamedWorkspaces()
    maintainWorkspaceLifecycle()
  }

  public mutating func maintainWorkspaceLifecycle() {
    for monitorIndex in monitors.indices {
      for workspaceIndex in monitors[monitorIndex].workspaces.indices
      where monitors[monitorIndex].workspaces[workspaceIndex].kind == .trailing
        && !monitors[monitorIndex].workspaces[workspaceIndex].isEmpty
      {
        monitors[monitorIndex].workspaces[workspaceIndex].kind = .ordinary
      }
      let activeWorkspace = monitors[monitorIndex].activeWorkspace
      monitors[monitorIndex].workspaces.removeAll {
        $0.kind == .ordinary && $0.isEmpty && $0.id != activeWorkspace
      }
      let trailingIndices = monitors[monitorIndex].workspaces.indices.filter {
        monitors[monitorIndex].workspaces[$0].kind == .trailing
      }
      if trailingIndices.isEmpty {
        monitors[monitorIndex].workspaces.append(
          makeOrdinaryWorkspace(
            kind: .trailing,
            affinity: monitors[monitorIndex].id,
            affinityPosition: monitors[monitorIndex].workspaces.count
          )
        )
      } else {
        let kept = trailingIndices.last!
        let trailing = monitors[monitorIndex].workspaces[kept]
        monitors[monitorIndex].workspaces.remove(at: kept)
        monitors[monitorIndex].workspaces.removeAll { $0.kind == .trailing }
        monitors[monitorIndex].workspaces.append(trailing)
      }
      if !monitors[monitorIndex].workspaces.contains(where: {
        $0.id == monitors[monitorIndex].activeWorkspace
      }) {
        monitors[monitorIndex].activeWorkspace = monitors[monitorIndex].workspaces.last!.id
      }
      updateAffinityPositions(on: monitorIndex)
    }
  }

  public func workspaceLocation(
    for workspaceID: WorkspaceID
  ) -> (monitorIndex: Int, workspaceIndex: Int)? {
    for monitorIndex in monitors.indices {
      if let workspaceIndex = monitors[monitorIndex].workspaces.firstIndex(where: {
        $0.id == workspaceID
      }) {
        return (monitorIndex, workspaceIndex)
      }
    }
    return nil
  }

  public func resolveWorkspaceTarget(
    _ target: WorkspaceTarget,
    on monitorIndex: Int
  ) -> (monitorIndex: Int, workspaceIndex: Int)? {
    switch target {
    case .named(let name):
      return workspaceLocation(for: WorkspaceID(rawValue: name))
    case .position(let position):
      guard position > 0,
        monitors.indices.contains(monitorIndex),
        !monitors[monitorIndex].workspaces.isEmpty
      else { return nil }
      return (monitorIndex, min(position - 1, monitors[monitorIndex].workspaces.count - 1))
    case .relative(let direction):
      guard monitors.indices.contains(monitorIndex),
        let active = monitors[monitorIndex].workspaces.firstIndex(where: {
          $0.id == monitors[monitorIndex].activeWorkspace
        })
      else { return nil }
      let targetIndex: Int
      switch direction {
      case .up:
        targetIndex = max(active - 1, 0)
      case .down:
        targetIndex = min(active + 1, monitors[monitorIndex].workspaces.count - 1)
      default:
        return nil
      }
      return (monitorIndex, targetIndex)
    }
  }

  public mutating func refreshAffinityPositions(on monitorIndex: Int) {
    guard monitors.indices.contains(monitorIndex) else { return }
    updateAffinityPositions(on: monitorIndex)
  }

  private mutating func makeOrdinaryWorkspace(
    kind: WorkspaceKind,
    affinity: MonitorID,
    affinityPosition: Int
  ) -> Workspace {
    let id = WorkspaceID(
      rawValue: "\(WorkspaceID.dynamicPrefix)\(nextOrdinaryWorkspaceNumber)"
    )
    nextOrdinaryWorkspaceNumber &+= 1
    return Workspace(
      id: id,
      kind: kind,
      affinity: affinity,
      affinityPosition: affinityPosition
    )
  }

  private mutating func insertBeforeTrailing(_ workspace: Workspace, in monitorIndex: Int) {
    let index =
      monitors[monitorIndex].workspaces.firstIndex(where: {
        $0.kind == .trailing
      }) ?? monitors[monitorIndex].workspaces.count
    monitors[monitorIndex].workspaces.insert(workspace, at: index)
  }

  private mutating func restoreAffinedWorkspaces(
    to monitorID: MonitorID,
    previousViewports: [MonitorID: Rect],
    nextViewports: [MonitorID: Rect]
  ) {
    guard let targetIndex = monitors.firstIndex(where: { $0.id == monitorID }) else { return }
    var returning: [(Workspace, MonitorID)] = []
    for sourceIndex in monitors.indices.reversed() where sourceIndex != targetIndex {
      for workspaceIndex in monitors[sourceIndex].workspaces.indices.reversed() {
        let workspace = monitors[sourceIndex].workspaces[workspaceIndex]
        guard workspace.affinity == monitorID, workspace.kind != .trailing else { continue }
        returning.append((workspace, monitors[sourceIndex].id))
        monitors[sourceIndex].workspaces.remove(at: workspaceIndex)
      }
    }
    for (var workspace, sourceID) in returning.sorted(by: {
      $0.0.affinityPosition < $1.0.affinityPosition
    }) {
      let scale = previousViewports[sourceID].flatMap { source in
        nextViewports[monitorID].map { $0.width / max(source.width, 1) }
      }
      if let scale { scalePixelWidths(in: &workspace, by: scale) }
      insertBeforeTrailing(workspace, in: targetIndex)
      for windowID in workspace.columns.flatMap(\.windows) + workspace.floatingWindows {
        windows[windowID]?.monitorID = monitorID
      }
      migrateSuspendedPlacements(
        from: sourceID,
        to: monitorID,
        workspaceID: workspace.id,
        columnOffset: 0,
        scale: scale
      )
    }
  }

  private mutating func redistributeConfiguredNamedWorkspaces() {
    for workspaceID in workspaceNames {
      guard let location = workspaceLocation(for: workspaceID) else { continue }
      let affinity = monitors[location.monitorIndex].workspaces[location.workspaceIndex].affinity
      let targetIndex: Int
      if let affinity {
        guard let connected = monitors.firstIndex(where: { $0.id == affinity }) else {
          continue
        }
        targetIndex = connected
      } else {
        let targetPosition = workspaceMonitorPositions[workspaceID] ?? 1
        guard monitors.indices.contains(targetPosition - 1) else { continue }
        targetIndex = targetPosition - 1
      }
      if location.monitorIndex != targetIndex {
        let wasActive = monitors[location.monitorIndex].activeWorkspace == workspaceID
        let workspace = monitors[location.monitorIndex].workspaces.remove(
          at: location.workspaceIndex
        )
        insertBeforeTrailing(workspace, in: targetIndex)
        if wasActive { monitors[targetIndex].activeWorkspace = workspaceID }
      }
      if let final = workspaceLocation(for: workspaceID) {
        monitors[final.monitorIndex].workspaces[final.workspaceIndex].affinity =
          monitors[targetIndex].id
      }
    }
  }

  private mutating func reconcileConfiguredWorkspaces() {
    let configured = Set(workspaceNames)
    for monitorIndex in monitors.indices {
      for workspaceIndex in monitors[monitorIndex].workspaces.indices.reversed() {
        let workspace = monitors[monitorIndex].workspaces[workspaceIndex]
        guard workspace.kind == .named, !configured.contains(workspace.id) else { continue }
        if workspace.isEmpty && workspace.id != monitors[monitorIndex].activeWorkspace {
          monitors[monitorIndex].workspaces.remove(at: workspaceIndex)
        } else {
          monitors[monitorIndex].workspaces[workspaceIndex].kind = .ordinary
          monitors[monitorIndex].workspaces[workspaceIndex].name = nil
        }
      }
    }
    if let primaryIndex = monitors.indices.first {
      for workspaceID in workspaceNames {
        if let location = workspaceLocation(for: workspaceID) {
          monitors[location.monitorIndex].workspaces[location.workspaceIndex].kind = .named
          monitors[location.monitorIndex].workspaces[location.workspaceIndex].name =
            workspaceID.rawValue
          continue
        }
        let workspace = Workspace(
          id: workspaceID,
          kind: .named,
          affinity: workspaceMonitorPositions[workspaceID] == nil
            || workspaceMonitorPositions[workspaceID] == 1
            ? monitors[primaryIndex].id
            : nil,
          affinityPosition: monitors[primaryIndex].workspaces.count
        )
        insertBeforeTrailing(workspace, in: primaryIndex)
      }
    }
    redistributeConfiguredNamedWorkspaces()
    maintainWorkspaceLifecycle()
  }

  private mutating func updateAffinityPositions(on monitorIndex: Int) {
    let monitorID = monitors[monitorIndex].id
    for workspaceIndex in monitors[monitorIndex].workspaces.indices
    where monitors[monitorIndex].workspaces[workspaceIndex].affinity == monitorID {
      monitors[monitorIndex].workspaces[workspaceIndex].affinityPosition = workspaceIndex
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
    for windowID in nativeFullscreenTiledPlacements.keys {
      guard let placement = nativeFullscreenTiledPlacements[windowID],
        placement.monitorID == monitorID
      else { continue }
      nativeFullscreenTiledPlacements[windowID] = placement.scaled(by: scale)
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
    for windowID in nativeFullscreenTiledPlacements.keys {
      guard let placement = nativeFullscreenTiledPlacements[windowID],
        placement.monitorID == sourceMonitorID,
        placement.workspaceID == workspaceID
      else { continue }
      let migrated = scale.map { placement.scaled(by: $0) } ?? placement
      nativeFullscreenTiledPlacements[windowID] = SuspendedTiledPlacement(
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

  public mutating func updateWindowFrame(_ frame: Rect, for windowID: WindowID) {
    windows[windowID]?.frame = frame
  }

  public func location(
    containing windowID: WindowID
  ) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
    windowLocationMap()[windowID]
  }

  public func windowLocationMap() -> WindowLocationMap {
    var locations = WindowLocationMap()
    locations.reserveCapacity(windows.count)
    for monitor in monitors {
      for workspace in monitor.workspaces {
        for column in workspace.columns {
          for windowID in column.windows where locations[windowID] == nil {
            locations[windowID] = (monitor.id, workspace.id)
          }
        }
        for windowID in workspace.floatingWindows where locations[windowID] == nil {
          locations[windowID] = (monitor.id, workspace.id)
        }
      }
    }
    return locations
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
    return focusedTiledWindowID(in: workspace)
  }

  public func selectedTiledWindowID(on monitorID: MonitorID) -> WindowID? {
    guard let monitor = monitors.first(where: { $0.id == monitorID }),
      let workspace = monitor.workspaces.first(
        where: { $0.id == monitor.activeWorkspace }
      )
    else {
      return nil
    }
    return focusedTiledWindowID(in: workspace)
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

public struct SuspendedTiledPlacement: Equatable, Codable, Sendable {
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

private func focusedTiledWindowID(in workspace: Workspace) -> WindowID? {
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  let column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else { return nil }
  return column.windows[column.focusedWindow]
}

public func commandShouldFocusWindow(
  _ command: Command,
  previousSelectedWindowID: WindowID?,
  selectedWindowID: WindowID,
  selectedFloatingWindowID: WindowID?,
  movesAcrossMonitors: Bool = false
) -> Bool {
  movesAcrossMonitors
    || selectedWindowID != previousSelectedWindowID
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

private func scalePixelWidths(in workspace: inout Workspace, by scale: Double) {
  guard scale.isFinite, scale > 0, abs(scale - 1) >= 0.001 else { return }
  for columnIndex in workspace.columns.indices {
    scalePixelWidths(in: &workspace.columns[columnIndex], by: scale)
  }
}

func scalePixelWidths(in column: inout Column, by scale: Double) {
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
  fileprivate init(config: Config) {
    let borderPadding =
      config.decorations.borders.enabled
        && config.decorations.borders.placement == "outside"
      ? config.decorations.borders.width
      : 0
    self.init(
      defaultColumnWidth: config.layout.defaultColumnWidth,
      presetColumnWidths: config.layout.presetColumnWidths,
      centerFocusedColumn: config.layout.centerFocusedColumn == .always ? .always : .never,
      innerHorizontalGap: config.layout.gaps / 2,
      innerVerticalGap: config.layout.gaps / 2,
      outerTopGap: max(config.layout.outerTopGap ?? config.layout.gaps, borderPadding),
      outerRightGap: max(config.layout.outerRightGap ?? config.layout.gaps, borderPadding),
      outerBottomGap: max(config.layout.outerBottomGap ?? config.layout.gaps, borderPadding),
      outerLeftGap: max(config.layout.outerLeftGap ?? config.layout.gaps, borderPadding),
      horizontalViewportPadding: borderPadding
    )
  }
}
