import DefiConfig
import DefiCore
import DefiModel

public struct RuntimeState: Equatable, Sendable {
  public var monitors: [Monitor]
  public var windows: [WindowID: Window]
  public var layout: LayoutSettings
  public var workspaceNames: [WorkspaceID]
  public var defaultWorkspace: WorkspaceID

  public init(config: Config) {
    let names = config.workspaces.names.map(WorkspaceID.init(rawValue:))
    self.monitors = []
    self.windows = [:]
    self.layout = LayoutSettings(config: config.layout)
    self.workspaceNames = names
    self.defaultWorkspace = WorkspaceID(rawValue: config.workspaces.defaultName)
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
    }
    let removed = monitors.filter { !monitorIDs.contains($0.id) }
    monitors.removeAll { !monitorIDs.contains($0.id) }
    guard let fallbackIndex = monitors.indices.first else { return }
    let fallbackWidth = nextViewports[monitors[fallbackIndex].id]?.width
    for var monitor in removed {
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
        monitors[fallbackIndex].workspaces[target].columns.append(contentsOf: workspace.columns)
        monitors[fallbackIndex].workspaces[target].floatingWindows.append(
          contentsOf: workspace.floatingWindows.filter {
            !monitors[fallbackIndex].workspaces[target].floatingWindows.contains($0)
          }
        )
      }
    }
  }

  public func monitorID(containing windowID: WindowID) -> MonitorID? {
    for monitor in monitors {
      for workspace in monitor.workspaces
      where workspace.columns.contains(where: { $0.windows.contains(windowID) })
        || workspace.floatingWindows.contains(windowID)
      {
        return monitor.id
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
    if workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow) {
      return workspace.floatingWindows[workspace.focusedFloatingWindow]
    }
    guard workspace.columns.indices.contains(workspace.focusedColumn) else {
      return nil
    }
    let column = workspace.columns[workspace.focusedColumn]
    guard column.windows.indices.contains(column.focusedWindow) else {
      return nil
    }
    return column.windows[column.focusedWindow]
  }
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
        .fullscreenPreviousWidth
      {
        scalePixelWidth(&previous, by: scale)
        monitor.workspaces[workspaceIndex]
          .columns[columnIndex]
          .fullscreenPreviousWidth = previous
      }
    }
  }
}

private func scalePixelWidth(_ width: inout ColumnWidth, by scale: Double) {
  guard case .pixels(let pixels) = width else { return }
  width = .pixels(max(pixels * scale, 80))
}

public enum ReducerError: Error, Equatable, CustomStringConvertible, Sendable {
  case noMonitor
  case unknownWorkspace(WorkspaceID)
  case noFocusedWindow
  case layout(LayoutError)

  public var description: String {
    switch self {
    case .noMonitor: "no monitor"
    case .unknownWorkspace(let id): "unknown workspace: \(id)"
    case .noFocusedWindow: "no focused window"
    case .layout(let error): "layout error: \(error)"
    }
  }
}

public func discoverWindow(
  _ original: Window,
  decision: RuleDecision,
  state: inout RuntimeState
) throws {
  guard !state.monitors.isEmpty else {
    throw ReducerError.noMonitor
  }
  if state.windows[original.id] != nil {
    state.windows[original.id] = original
    return
  }

  var window = original
  window.floating = decision.floating
  window.forceTiling = decision.forceTiling
  window.intrinsicSize = decision.intrinsicSize
  let monitorID = window.monitorID ?? state.monitors[0].id
  let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }) ?? 0
  let workspaceID = decision.workspace ?? state.monitors[monitorIndex].activeWorkspace
  guard
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == workspaceID }
    )
  else {
    throw ReducerError.unknownWorkspace(workspaceID)
  }

  if window.floating && !window.forceTiling {
    state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.append(window.id)
  } else {
    insertNewWindow(
      window.id,
      into: &state.monitors[monitorIndex].workspaces[workspaceIndex],
      settings: state.layout
    )
  }
  if decision.followFocus {
    state.monitors[monitorIndex].activeWorkspace = workspaceID
  }
  state.windows[window.id] = window
}

public func reconcileWindows(
  _ discovered: [Window],
  config: Config,
  state: inout RuntimeState
) {
  let discoveredIDs = Set(discovered.map(\.id))
  for existingID in Array(state.windows.keys) where !discoveredIDs.contains(existingID) {
    removeWindowEverywhere(existingID, state: &state)
    state.windows[existingID] = nil
  }

  for window in discovered {
    if state.windows[window.id] == nil {
      try? discoverWindow(window, decision: config.decision(for: window), state: &state)
    } else {
      var updated = window
      if let existing = state.windows[window.id] {
        updated.floating = existing.floating
        updated.forceTiling = existing.forceTiling
        updated.intrinsicSize = existing.intrinsicSize
        if existing.intrinsicSize {
          updated.frame.width = existing.frame.width
          updated.frame.height = existing.frame.height
        }
      }
      state.windows[window.id] = updated
    }
  }
}

public func reduce(
  _ command: Command,
  on requestedMonitorID: MonitorID?,
  state: inout RuntimeState
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
        try focusColumn(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .moveColumn(let direction), .moveWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        try moveFocusedWindow(
          direction,
          in: &state.monitors[monitorIndex].workspaces[index],
          settings: layout
        )
      }
    case .focusWindow(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      if !state.monitors[monitorIndex].workspaces[index].columns.isEmpty {
        try focusWindow(direction, in: &state.monitors[monitorIndex].workspaces[index])
      }
    case .cycleWidth(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex) {
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
    case .toggleFullscreen:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      let columnIndex = state.monitors[monitorIndex].workspaces[index].focusedColumn
      if state.monitors[monitorIndex].workspaces[index].columns.indices.contains(columnIndex) {
        toggleFullscreen(
          of: &state.monitors[monitorIndex].workspaces[index].columns[columnIndex],
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
      try joinFocusedWindow(
        direction,
        in: &state.monitors[monitorIndex].workspaces[index],
        settings: layout
      )
    case .unjoinWindows:
      let index = try workspaceIndex(state.monitors[monitorIndex])
      try unjoinFocusedWindow(
        in: &state.monitors[monitorIndex].workspaces[index],
        settings: layout
      )
    case .toggleFloating:
      try toggleFocusedFloating(monitorIndex: monitorIndex, state: &state)
    case .focusFloating(let direction):
      let index = try workspaceIndex(state.monitors[monitorIndex])
      focusFloating(direction, workspace: &state.monitors[monitorIndex].workspaces[index])
    case .runStartupCommands:
      break
    }
  } catch let error as LayoutError {
    throw ReducerError.layout(error)
  }
}

public func focusWindow(
  _ windowID: WindowID,
  state: inout RuntimeState
) {
  for monitorIndex in state.monitors.indices {
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      for columnIndex in state.monitors[monitorIndex].workspaces[workspaceIndex].columns.indices {
        if let windowIndex = state.monitors[monitorIndex]
          .workspaces[workspaceIndex]
          .columns[columnIndex]
          .windows
          .firstIndex(of: windowID)
        {
          state.monitors[monitorIndex].workspaces[workspaceIndex].focusedColumn = columnIndex
          state.monitors[monitorIndex].activeWorkspace =
            state.monitors[monitorIndex].workspaces[workspaceIndex].id
          state.monitors[monitorIndex]
            .workspaces[workspaceIndex]
            .columns[columnIndex]
            .focusedWindow = windowIndex
          return
        }
      }
    }
  }
}

public func nativeFocusChangesSelection(
  _ windowID: WindowID,
  activeMonitorID: MonitorID?,
  state: RuntimeState
) -> Bool {
  guard let focusedMonitorID = state.monitorID(containing: windowID) else {
    return false
  }
  return activeMonitorID != focusedMonitorID
    || state.selectedWindowID(on: focusedMonitorID) != windowID
}

public func synchronizeScrollOffsets(
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) {
  for monitorIndex in state.monitors.indices {
    let monitorID = state.monitors[monitorIndex].id
    guard let viewport = viewports[monitorID] else { continue }
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
      let windows = workspace.columns
        .flatMap(\.windows)
        .compactMap { state.windows[$0] }
      state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
        focusedColumnTargetScrollOffset(
          workspace: workspace,
          viewport: viewport,
          windows: windows,
          centerFocusedColumn: state.layout.centerFocusedColumn
        )
    }
  }
}

public func alignFocusedColumnLeft(
  on monitorID: MonitorID,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) {
  guard let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }),
    let viewport = viewports[monitorID],
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
    )
  else {
    return
  }
  let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let windows = workspace.columns
    .flatMap(\.windows)
    .compactMap { state.windows[$0] }
  state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
    focusedColumnRevealScrollOffset(
      workspace: workspace,
      viewport: viewport,
      windows: windows
    )
}

@discardableResult
public func learnTiledWindowWidth(
  _ windowID: WindowID,
  actualFrame: Rect,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  guard state.windows[windowID]?.intrinsicSize != true else { return false }

  for monitorIndex in state.monitors.indices {
    let monitorID = state.monitors[monitorIndex].id
    guard let viewport = viewports[monitorID] else { continue }
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
      guard
        let columnIndex = workspace.columns.firstIndex(
          where: { $0.windows.contains(windowID) }
        )
      else {
        continue
      }
      guard workspace.id == state.monitors[monitorIndex].activeWorkspace,
        workspace.columns[columnIndex].fullscreenPreviousWidth == nil
      else {
        return false
      }

      let windows = workspace.columns
        .flatMap(\.windows)
        .compactMap { state.windows[$0] }
      let target = computeLayout(
        workspace: workspace,
        viewport: viewport,
        windows: windows,
        settings: state.layout
      ).frames.first(where: { $0.windowID == windowID })?.frame
      guard let target else { return false }

      let currentSlotWidth: Double
      switch workspace.columns[columnIndex].width {
      case .fraction(let fraction):
        currentSlotWidth = viewport.width * fraction
      case .pixels(let width):
        currentSlotWidth = width
      }
      let learnedWidth = max(currentSlotWidth + actualFrame.width - target.width, 80)
      guard abs(learnedWidth - currentSlotWidth) >= 1 else { return false }

      state.monitors[monitorIndex].workspaces[workspaceIndex]
        .columns[columnIndex].width = .pixels(learnedWidth)
      synchronizeScrollOffsets(state: &state, viewports: viewports)
      return true
    }
  }
  return false
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
  if workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow) {
    let windowID = workspace.floatingWindows.remove(at: workspace.focusedFloatingWindow)
    insertNewWindow(windowID, into: &workspace, settings: state.layout)
    state.windows[windowID]?.floating = false
  } else if workspace.columns.indices.contains(workspace.focusedColumn) {
    let column = workspace.columns[workspace.focusedColumn]
    guard column.windows.indices.contains(column.focusedWindow) else {
      throw ReducerError.noFocusedWindow
    }
    let windowID = column.windows[column.focusedWindow]
    removeWindow(windowID, from: &workspace, settings: state.layout)
    workspace.floatingWindows.append(windowID)
    workspace.focusedFloatingWindow = workspace.floatingWindows.count - 1
    state.windows[windowID]?.floating = true
  } else {
    throw ReducerError.noFocusedWindow
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
}

private func focusFloating(_ direction: Direction, workspace: inout Workspace) {
  guard !workspace.floatingWindows.isEmpty else { return }
  switch direction {
  case .left, .up, .previous:
    workspace.focusedFloatingWindow = max(workspace.focusedFloatingWindow - 1, 0)
  case .right, .down, .next:
    workspace.focusedFloatingWindow = min(
      workspace.focusedFloatingWindow + 1,
      workspace.floatingWindows.count - 1
    )
  case .first:
    workspace.focusedFloatingWindow = 0
  case .last:
    workspace.focusedFloatingWindow = workspace.floatingWindows.count - 1
  }
}

private func removeWindowEverywhere(_ windowID: WindowID, state: inout RuntimeState) {
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
