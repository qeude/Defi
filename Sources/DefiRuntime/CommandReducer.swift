import DefiConfig
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
  case unknownWindow(WindowID)
  case layout(LayoutError)
  case stackConstraint(StackRejection)

  public var description: String {
    switch self {
    case .noMonitor: "no monitor"
    case .unknownMonitor(let monitorID): "unknown monitor: \(monitorID)"
    case .unknownWorkspace(let id): "unknown workspace: \(id)"
    case .noFocusedWindow: "no focused window"
    case .unknownWindow(let id): "unknown window: \(id.rawValue)"
    case .layout(let error): "layout error: \(error)"
    case .stackConstraint(let rejection): "cannot join: \(rejection)"
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

/// Binds a command whose meaning depends on the selection to the concrete command it
/// is in `state`. The daemon calls this before it classifies a command, because the
/// workspace transition and focus machinery read the concrete command. Idempotent.
public func resolvedCommand(
  _ command: Command,
  on monitorID: MonitorID?,
  state: RuntimeState,
  monitorFrames: [MonitorID: Rect] = [:]
) -> Command {
  switch command {
  case .focusColumnOrMonitor(let direction):
    return columnOrMonitorCommand(
      inStrip: .focusColumn(direction), acrossMonitors: .focusMonitor(direction),
      direction: direction, on: monitorID, state: state, monitorFrames: monitorFrames)
  case .moveColumnOrToMonitor(let direction):
    return columnOrMonitorCommand(
      inStrip: .moveColumn(direction), acrossMonitors: .moveColumnToMonitor(direction),
      direction: direction, on: monitorID, state: state, monitorFrames: monitorFrames)
  default:
    break
  }
  guard case .focusWindowOrWorkspace(let direction) = command,
    let monitor = state.monitors.first(where: { $0.id == monitorID }) ?? state.monitors.first
  else { return command }
  let crossesWorkspace = Command.focusWorkspace(.relative(direction))
  guard
    let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
    workspace.columns.indices.contains(workspace.focusedColumn)
  else { return crossesWorkspace }
  let column = workspace.columns[workspace.focusedColumn]
  let atStackEnd =
    direction == .up
    ? column.focusedWindow <= 0
    : column.focusedWindow >= column.windows.count - 1
  return atStackEnd && workspace.focusedLayer == .tiled ? crossesWorkspace : .focusWindow(direction)
}

/// Crosses to the neighbouring monitor on the desk only from the strip edge in
/// `direction`, or from an empty workspace; otherwise stays the in-strip command.
private func columnOrMonitorCommand(
  inStrip: Command,
  acrossMonitors: Command,
  direction: Direction,
  on monitorID: MonitorID?,
  state: RuntimeState,
  monitorFrames: [MonitorID: Rect]
) -> Command {
  guard
    let monitor = state.monitors.first(where: { $0.id == monitorID }) ?? state.monitors.first,
    spatialMonitor(from: monitor.id, toward: direction, frames: monitorFrames) != nil,
    let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace })
  else { return inStrip }
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return acrossMonitors }
  let atStripEdge =
    direction == .left
    ? workspace.focusedColumn == 0
    : workspace.focusedColumn == workspace.columns.count - 1
  return atStripEdge && workspace.focusedLayer == .tiled ? acrossMonitors : inStrip
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
  let layout = state.layout(on: state.monitors[monitorIndex].id)
  let command = resolvedCommand(
    command, on: state.monitors[monitorIndex].id, state: state, monitorFrames: monitorFrames)

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
        let stripWidth = viewports[state.monitors[monitorIndex].id].map {
          stripViewport($0, settings: state.layout).width
        }
        let (minimumFraction, maximumFraction) = columnWidthBounds(
          column, stripWidth: stripWidth, state: &state)
        var presets = layout.presetColumnWidths
        if column.windows.indices.contains(column.focusedWindow),
          let window = state.windows[column.windows[column.focusedWindow]]
        {
          let decision = Config.decision(
            appID: window.appID, title: window.title, role: window.role, rules: state.windowRules
          )
          if decision.includeInitialWidthInCycle,
            let width = decision.initialColumnWidth,
            !presets.contains(width)
          {
            presets.insert(width, at: presets.firstIndex(where: { $0 > width }) ?? presets.endIndex)
          }
        }
        cycleWidth(
          of: &state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
          direction: direction,
          presets: presets,
          minimumFraction: minimumFraction,
          maximumFraction: maximumFraction,
          viewportWidth: stripWidth
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
    case .setColumnWidth(let change):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex),
        let viewport = viewports[state.monitors[monitorIndex].id]
      {
        state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
        let stripWidth = stripViewport(viewport, settings: layout).width
        let (minimumFraction, maximumFraction) = columnWidthBounds(
          state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
          stripWidth: stripWidth, state: &state)
        setWidth(
          of: &state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
          change,
          stripWidth: stripWidth,
          gaps: horizontalGaps(settings: layout),
          minimumFraction: minimumFraction,
          maximumFraction: maximumFraction
        )
        state.monitors[monitorIndex].workspaces[index].targetScrollOffset =
          focusedColumnLeftScrollOffset(
            workspace: state.monitors[monitorIndex].workspaces[index]
          )
      }
    case .expandColumnToAvailableWidth:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex),
        let viewport = viewports[state.monitors[monitorIndex].id]
      {
        let column = state.monitors[monitorIndex].workspaces[index].columns[columnIndex]
        let (_, maximumFraction) = columnWidthBounds(
          column, stripWidth: stripViewport(viewport, settings: layout).width, state: &state)
        let workspace = state.monitors[monitorIndex].workspaces[index]
        if column.windows.indices.contains(column.focusedWindow),
          let available = focusedColumnAvailableWidth(
            workspace: workspace, viewport: viewport,
            windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
            settings: layout, excludingWindowIDs: state.nativeFullscreenWindowIDs,
            maximumWidth: maximumFraction)
        {
          state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
          state.monitors[monitorIndex].workspaces[index].columns[columnIndex].width =
            .fraction(available.width)
          state.monitors[monitorIndex].workspaces[index].columns[columnIndex].preMaximizedWidth = nil
          // The visible columns stay in view: a free scroll focus keeps the strip there
          // while the column remains in view, whatever the centring policy.
          state.monitors[monitorIndex].workspaces[index].scrollOffset = available.offset
          state.monitors[monitorIndex].workspaces[index].targetScrollOffset = available.offset
          state.monitors[monitorIndex].workspaces[index].scrollFocus = ScrollFocus(
            windowID: column.windows[column.focusedWindow], centered: false, free: true)
        }
      }
    case .setWindowHeight, .resetWindowHeight, .switchPresetWindowHeight:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      setFocusedWindowHeight(
        command,
        workspace: &state.monitors[monitorIndex].workspaces[index],
        viewport: viewports[state.monitors[monitorIndex].id],
        state: state
      )
    case .centerColumn:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let workspace = state.monitors[monitorIndex].workspaces[index]
      if workspace.columns.indices.contains(workspace.focusedColumn) {
        let column = workspace.columns[workspace.focusedColumn]
        if column.windows.indices.contains(column.focusedWindow) {
          let windowID = column.windows[column.focusedWindow]
          let recorded = workspace.scrollFocus
          state.monitors[monitorIndex].workspaces[index].scrollFocus = ScrollFocus(
            windowID: windowID,
            centered: recorded?.windowID == windowID && recorded?.centered == true,
            pinned: true
          )
        }
      }
    case .centerVisibleColumns:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let workspace = state.monitors[monitorIndex].workspaces[index]
      if workspace.columns.indices.contains(workspace.focusedColumn) {
        let column = workspace.columns[workspace.focusedColumn]
        if column.windows.indices.contains(column.focusedWindow),
          let offset = visibleColumnsCenteredOffset(
            workspace: workspace,
            viewport: viewports[state.monitors[monitorIndex].id]
              ?? Rect(x: 0, y: 0, width: 1_000, height: 1),
            windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
            settings: layout,
            excludingWindowIDs: state.nativeFullscreenWindowIDs
          )
        {
          state.monitors[monitorIndex].workspaces[index].targetScrollOffset = offset
          let windowID = column.windows[column.focusedWindow]
          let recorded = workspace.scrollFocus
          state.monitors[monitorIndex].workspaces[index].scrollFocus = ScrollFocus(
            windowID: windowID,
            centered: recorded?.windowID == windowID && recorded?.centered == true,
            heldOffset: offset
          )
        }
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
    case .focusWindowPrevious:
      if let windowID = state.previousFocusedWindowTarget {
        focusWindow(windowID, state: &state)
      }
    case .focusWindowID(let windowID):
      guard state.monitorID(containing: windowID) != nil else {
        throw ReducerError.unknownWindow(windowID)
      }
      focusWindow(windowID, state: &state)
    case .focusMonitor, .focusWindowOrWorkspace, .focusColumnOrMonitor, .moveColumnOrToMonitor:
      break
    case .joinWindow(let direction), .consumeOrExpelWindow(let direction),
      .swapWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let workspace = state.monitors[monitorIndex].workspaces[index]
      guard !workspace.columns.isEmpty else { break }
      let expels =
        command == .consumeOrExpelWindow(direction)
        && workspace.columns.indices.contains(workspace.focusedColumn)
        && workspace.columns[workspace.focusedColumn].windows.count > 1
      // Only an expel leaves the neighboring column untouched.
      if !expels,
        joinTargetsNativeFullscreenColumn(
          direction,
          workspace: workspace,
          nativeFullscreenWindowIDs: state.nativeFullscreenWindowIDs
        )
      {
        break
      }
      let windowsByID = state.windows
      let viewport = viewports[state.monitors[monitorIndex].id]
      let fit: ([WindowID]) -> StackFit = { windowIDs in
        viewport.map {
          stackFit(windowIDs, windowsByID: windowsByID, viewport: $0, settings: layout)
        } ?? .fits
      }
      switch command {
      case .consumeOrExpelWindow:
        try consumeOrExpelFocusedWindow(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout,
          stackFit: fit
        )
      case .swapWindow:
        try swapFocusedWindow(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout,
          stackFit: fit
        )
      default:
        try joinFocusedWindow(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout,
          stackFit: fit
        )
      }
      state.monitors[monitorIndex].workspaces[index].focusedLayer = .tiled
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
    case .toggleOverview, .toggleCheatsheet, .openSettings, .recentWindows:
      break
    case .runStartupCommands:
      break
    }
  } catch let error as LayoutError {
    throw ReducerError.layout(error)
  } catch let rejection as StackRejection {
    throw ReducerError.stackConstraint(rejection)
  }
  state.maintainWorkspaceLifecycle()
  normalizeNativeFullscreenColumns(state: &state)
}

/// The column's verified width bounds in strip widths, gaps included. Bounds a native
/// fullscreen exit left pending are dropped first, as the next explicit resize retries them.
private func columnWidthBounds(
  _ column: Column,
  stripWidth: Double?,
  state: inout RuntimeState
) -> (minimum: Double?, maximum: Double?) {
  for windowID in column.windows
  where state.pendingNativeFullscreenWidthResetWindowIDs.remove(windowID) != nil {
    state.windows[windowID]?.minimumTiledWidth = nil
    state.windows[windowID]?.maximumTiledWidth = nil
  }
  guard let stripWidth else { return (nil, nil) }
  let gaps = horizontalGaps(settings: state.layout)
  let minimum = column.windows.compactMap { state.windows[$0]?.minimumTiledWidth }.max()
  let maximumWidths = column.windows.compactMap { state.windows[$0]?.maximumTiledWidth }
  // One unbounded window leaves the column unbounded.
  let maximum = maximumWidths.count == column.windows.count ? maximumWidths.max() : nil
  return (minimum.map { ($0 + gaps) / stripWidth }, maximum.map { ($0 + gaps) / stripWidth })
}

/// Height commands act on the focused tiled window of a stack; a single window keeps
/// filling the column, so they change nothing there.
private func setFocusedWindowHeight(
  _ command: Command,
  workspace: inout Workspace,
  viewport: Rect?,
  state: RuntimeState
) {
  guard workspace.focusedLayer == .tiled,
    workspace.columns.indices.contains(workspace.focusedColumn)
  else { return }
  var column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else { return }
  let focusedID = column.windows[column.focusedWindow]
  // Native fullscreen windows leave the stack while fullscreen.
  let windowIDs = column.windows.filter { !state.nativeFullscreenWindowIDs.contains($0) }
  guard windowIDs.count > 1, let index = windowIDs.firstIndex(of: focusedID) else { return }
  let current = stackWindowShares(
    windowIDs, proportions: column.windowHeights,
    windowsByID: state.windows, viewport: viewport, settings: state.layout
  )
  let share: Double
  switch command {
  case .resetWindowHeight:
    column.windowHeights = nil
    workspace.columns[workspace.focusedColumn] = column
    return
  case .setWindowHeight(.share(let value)):
    share = value
  case .setWindowHeight(.adjust(let delta)):
    share = current[index] + delta
  case .setWindowHeight(.points(let points)):
    guard let viewport, viewport.height > 0 else { return }
    share = stackWindowShare(
      height: points, index: index, count: windowIDs.count,
      viewportHeight: viewport.height, settings: state.layout
    )
  case .switchPresetWindowHeight:
    let presets = state.layout.presetWindowHeights
    guard !presets.isEmpty else { return }
    // Match what was asked for, not what constraints allowed, and each preset as the
    // stack can hold it, so cycling never sticks.
    let requested = stackWindowShares(
      windowIDs, proportions: column.windowHeights,
      windowsByID: state.windows, viewport: nil, settings: state.layout
    )[index]
    let reachable = presets.map { clampedStackWindowShare($0, count: windowIDs.count) }
    let tolerance = 0.005
    if let match = reachable.firstIndex(where: { abs($0 - requested) < tolerance }) {
      share = reachable[(match + 1) % reachable.count]
    } else {
      share = reachable.filter { $0 > requested + tolerance }.min() ?? reachable[0]
    }
  default:
    return
  }
  let shares = stackShares(current, setting: index, to: share)
  column.windowHeights = Dictionary(uniqueKeysWithValues: zip(windowIDs, shares))
  workspace.columns[workspace.focusedColumn] = column
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
  case .moveColumn, .moveWindow, .moveColumnToMonitor, .moveColumnOrToMonitor, .moveWindowToMonitor,
    .moveWindowToWorkspace, .sendWindowToWorkspace, .cycleWidth,
    .moveColumnToWorkspace, .moveWindowToWorkspaceTarget,
    .reorderWorkspace, .moveWorkspaceToMonitor,
    .maximizeColumn, .setColumnWidth, .expandColumnToAvailableWidth, .centerColumn, .centerVisibleColumns,
    .toggleFloating, .joinWindow, .unjoinWindows, .consumeOrExpelWindow, .swapWindow,
    .setWindowHeight, .resetWindowHeight, .switchPresetWindowHeight:
    true
  case .focusColumn, .focusColumnOrMonitor, .focusFloating, .focusWindow, .focusWindowOrWorkspace,
    .focusWindowPrevious, .focusWindowID, .switchWorkspace, .focusWorkspace, .focusMonitor,
    .activateFloating, .toggleOverview, .toggleCheatsheet, .openSettings, .runStartupCommands,
    .recentWindows:
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
    insertNewWindow(
      windowID, into: &workspace, settings: state.layout(on: state.monitors[monitorIndex].id))
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
