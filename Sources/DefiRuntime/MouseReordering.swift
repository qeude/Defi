import DefiCore
import DefiModel

public struct WorkspaceScrollAnchor: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let scrollOffset: Double

  public init(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    scrollOffset: Double
  ) {
    self.monitorID = monitorID
    self.workspaceID = workspaceID
    self.scrollOffset = scrollOffset
  }
}

public struct MouseGestureSettlement: Equatable, Sendable {
  public let generation: UInt64
  public let windowID: WindowID
  public let initialFrame: Rect
  public var lastObservedFrame: Rect
  public var observedPostReleaseChange: Bool
  public var stableSince: Double?
  public var nextCheckAt: Double
  public let expiresAt: Double

  public init(
    generation: UInt64,
    windowID: WindowID,
    initialFrame: Rect,
    releasedFrame: Rect,
    now: Double,
    maximumDuration: Double,
    pollInterval: Double = 0.05
  ) {
    self.generation = generation
    self.windowID = windowID
    self.initialFrame = initialFrame
    lastObservedFrame = releasedFrame
    observedPostReleaseChange = false
    stableSince = nil
    nextCheckAt = now + pollInterval
    expiresAt = now + maximumDuration
  }
}

public struct MouseGestureSettlementUpdate: Equatable, Sendable {
  public let settlement: MouseGestureSettlement
  public let shouldFinish: Bool

  public init(
    settlement: MouseGestureSettlement,
    shouldFinish: Bool
  ) {
    self.settlement = settlement
    self.shouldFinish = shouldFinish
  }
}

public func mouseGestureSettlementMaximumDuration(
  latencySensitive: Bool
) -> Double {
  latencySensitive ? 0.8 : 0.25
}

public func mouseGestureWidthLearningFrame(
  externallyChangedFrame: Rect?,
  actualFrame: Rect?,
  postReleaseSettlementActive: Bool,
  actualFrameMatchesRecentDefiWrite: Bool = false,
  overlayHoldsGesture: Bool = false,
  releasedResizeFrame: Rect? = nil
) -> Rect? {
  // The overlay stretches the ribbon at the pointer; a layout mid-drag would restart
  // its motion from the native frames, so the width is learned on release.
  if overlayHoldsGesture { return nil }
  return releasedResizeFrame ?? externallyChangedFrame
    ?? (postReleaseSettlementActive && !actualFrameMatchesRecentDefiWrite ? actualFrame : nil)
}

public func advanceMouseGestureSettlement(
  _ current: MouseGestureSettlement,
  actualFrame: Rect,
  now: Double,
  frameTolerance: Double = 1,
  pollInterval: Double = 0.05,
  quietDuration: Double = 0.05
) -> MouseGestureSettlementUpdate {
  var next = current
  let frameChanged =
    abs(actualFrame.x - current.lastObservedFrame.x) > frameTolerance
    || abs(actualFrame.y - current.lastObservedFrame.y) > frameTolerance
    || abs(actualFrame.width - current.lastObservedFrame.width) > frameTolerance
    || abs(actualFrame.height - current.lastObservedFrame.height) > frameTolerance
  if frameChanged {
    next.lastObservedFrame = actualFrame
    next.observedPostReleaseChange = true
    next.stableSince = now
  }
  let converged = next.observedPostReleaseChange
    && now >= (next.stableSince ?? now) + quietDuration
  let timedOut = now >= next.expiresAt
  let shouldFinish = converged || timedOut
  if shouldFinish {
    next.nextCheckAt = now
  } else if let stableSince = next.stableSince {
    next.nextCheckAt = min(stableSince + quietDuration, next.expiresAt)
  } else {
    next.nextCheckAt = min(now + pollInterval, next.expiresAt)
  }
  return MouseGestureSettlementUpdate(
    settlement: next,
    shouldFinish: shouldFinish
  )
}

public func workspaceScrollAnchor(
  containing windowID: WindowID,
  state: RuntimeState
) -> WorkspaceScrollAnchor? {
  guard let location = state.location(containing: windowID),
    let monitor = state.monitors.first(where: { $0.id == location.monitorID }),
    let workspace = monitor.workspaces.first(where: {
      $0.id == location.workspaceID
    })
  else {
    return nil
  }
  return WorkspaceScrollAnchor(
    monitorID: location.monitorID,
    workspaceID: location.workspaceID,
    scrollOffset: workspace.scrollOffset
  )
}

public func restoreWorkspaceScroll(
  _ anchor: WorkspaceScrollAnchor,
  state: inout RuntimeState
) {
  guard
    let monitorIndex = state.monitors.firstIndex(where: {
      $0.id == anchor.monitorID
    }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == anchor.workspaceID }
    )
  else {
    return
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset =
    anchor.scrollOffset
  state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
    anchor.scrollOffset
}

public func resolvedMouseGestureScrollAnchor(
  current: WorkspaceScrollAnchor?,
  gestureWindowID: WindowID?,
  mouseGestureActive: Bool,
  state: RuntimeState
) -> WorkspaceScrollAnchor? {
  guard mouseGestureActive else { return nil }
  return current ?? gestureWindowID.flatMap {
    workspaceScrollAnchor(containing: $0, state: state)
  }
}

public func mouseGestureTiledWindowID(
  translatedWindowID: WindowID?,
  activeWindowID: WindowID?,
  mouseFocusIntentWindowID: WindowID?,
  focusedWindowID: WindowID?,
  state: RuntimeState
) -> WindowID? {
  for candidate in [
    activeWindowID,
    mouseFocusIntentWindowID,
    translatedWindowID,
    focusedWindowID,
  ] {
    guard let candidate,
      state.windows[candidate]?.floating == false,
      let location = state.location(containing: candidate),
      state.monitors.first(where: { $0.id == location.monitorID })?
        .activeWorkspace == location.workspaceID
    else {
      continue
    }
    return candidate
  }
  return nil
}

public func resolvedMouseGestureInitialFrame(
  currentInitialFrame: Rect?,
  gestureWindowID: WindowID?,
  activeWindowID: WindowID?,
  translatedWindowID: WindowID?,
  leftMouseButtonDown: Bool,
  previousObservedFrames: [WindowID: Rect],
  actualFrame: Rect?
) -> Rect? {
  let startsMouseGesture =
    leftMouseButtonDown
    && gestureWindowID != activeWindowID
  let recoversReleaseOnlyGesture =
    currentInitialFrame == nil
    && gestureWindowID == translatedWindowID
  guard startsMouseGesture || recoversReleaseOnlyGesture,
    let gestureWindowID
  else {
    return currentInitialFrame
  }
  return previousObservedFrames[gestureWindowID] ?? actualFrame
}

public func resolvedMouseGestureOriginFrame(
  observedFrame: Rect,
  displayedX: Double?,
  displayedY: Double?,
  displayedWidth: Double? = nil,
  displayedHeight: Double? = nil
) -> Rect {
  return Rect(
    x: displayedX ?? observedFrame.x,
    y: displayedY ?? observedFrame.y,
    width: displayedWidth ?? observedFrame.width,
    height: displayedHeight ?? observedFrame.height
  )
}

public func mouseTranslatedTiledWindowID(
  candidateWindowIDs: [WindowID],
  externallyChangedFrames: [WindowID: Rect],
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect],
  sizeTolerance: Double = 2,
  positionTolerance: Double = 2
) -> WindowID? {
  for windowID in candidateWindowIDs {
    guard let location = state.location(containing: windowID),
      let monitor = state.monitors.first(where: { $0.id == location.monitorID }),
      location.workspaceID == monitor.activeWorkspace,
      let viewport = viewports[monitor.id],
      let workspace = monitor.workspaces.first(where: {
        $0.id == location.workspaceID
      }),
      workspace.columns.contains(where: { $0.windows.contains(windowID) })
    else {
      continue
    }
    let windows = workspace.columns
      .flatMap(\.windows)
      .compactMap { state.windows[$0] }
    let targets = Dictionary(
      uniqueKeysWithValues: computeLayout(
        workspace: workspace,
        viewport: viewport,
        windows: windows,
        settings: state.layout,
        excludingWindowIDs: state.nativeFullscreenWindowIDs
      ).map { ($0.windowID, $0.frame) }
    )
    guard let actual = externallyChangedFrames[windowID],
      let target = targets[windowID],
      (abs(actual.width - target.width) <= sizeTolerance
        && abs(actual.height - target.height) <= sizeTolerance)
        || (mouseDropMonitor(actual, monitorFrames: monitorFrames).map({ $0 != monitor.id }) == true
          && mouseFrameMovedBothEdges(from: target, to: actual, tolerance: positionTolerance)),
      abs(actual.x - target.x) > positionTolerance
        || abs(actual.y - target.y) > positionTolerance
    else {
      continue
    }
    return windowID
  }
  return nil
}

public func mouseFrameWasTranslated(
  from initialFrame: Rect,
  to actualFrame: Rect,
  sizeTolerance: Double = 2,
  positionTolerance: Double = 2
) -> Bool {
  abs(actualFrame.width - initialFrame.width) <= sizeTolerance
    && abs(actualFrame.height - initialFrame.height) <= sizeTolerance
    && (abs(actualFrame.x - initialFrame.x) > positionTolerance
      || abs(actualFrame.y - initialFrame.y) > positionTolerance)
}

private func mouseFrameMovedBothEdges(
  from initial: Rect,
  to actual: Rect,
  tolerance: Double = 2
) -> Bool {
  (abs(actual.x - initial.x) > tolerance
    && abs(actual.x + actual.width - initial.x - initial.width) > tolerance)
    || (abs(actual.y - initial.y) > tolerance
      && abs(actual.y + actual.height - initial.y - initial.height) > tolerance)
}

@discardableResult
public func reorderTiledWindowAfterMouseDrag(
  _ windowID: WindowID,
  actualFrame: Rect,
  initialFrame: Rect? = nil,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  guard
    let monitorIndex = state.monitors.firstIndex(where: { monitor in
      monitor.workspaces.contains(where: { workspace in
        workspace.id == monitor.activeWorkspace
          && workspace.columns.contains(where: { $0.windows.contains(windowID) })
      })
    }),
    let viewport = viewports[state.monitors[monitorIndex].id],
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
    ),
    let sourceColumnIndex = state.monitors[monitorIndex].workspaces[workspaceIndex]
      .columns.firstIndex(where: { $0.windows.contains(windowID) })
  else {
    return false
  }

  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let windows = workspace.columns
    .flatMap(\.windows)
    .compactMap { state.windows[$0] }
  let frames = Dictionary(
    uniqueKeysWithValues: computeLayout(
      workspace: workspace,
      viewport: viewport,
      windows: windows,
      settings: state.layout,
      excludingWindowIDs: state.nativeFullscreenWindowIDs
    ).map { ($0.windowID, $0.frame) }
  )

  guard let sourceFrame = frames[windowID]
  else {
    return false
  }
  let sizeReferenceFrame = initialFrame ?? sourceFrame
  guard abs(actualFrame.width - sizeReferenceFrame.width) <= 2,
    abs(actualFrame.height - sizeReferenceFrame.height) <= 2
  else {
    return false
  }
  let draggedCenterX = actualFrame.x + actualFrame.width / 2
  // Pulled sideways out of a stack, the window leaves it as its own column on that side.
  if workspace.columns[sourceColumnIndex].windows.count > 1,
    draggedCenterX < sourceFrame.x || draggedCenterX > sourceFrame.x + sourceFrame.width
  {
    let insertAt = draggedCenterX > sourceFrame.x + sourceFrame.width
      ? sourceColumnIndex + 1 : sourceColumnIndex
    removeStackedWindow(windowID, from: &workspace.columns[sourceColumnIndex])
    workspace.columns.insert(Column(window: windowID, width: workspace.columns[sourceColumnIndex].width),
      at: insertAt)
    workspace.focusedColumn = insertAt
    workspace.focusedLayer = .tiled
    state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
    synchronizeScrollOffsets(state: &state, viewports: viewports)
    return true
  }
  var horizontalTargetIndex = sourceColumnIndex
  if sourceColumnIndex + 1 < workspace.columns.count,
    let nextCenterX = centerX(
      for: workspace.columns[sourceColumnIndex + 1],
      frames: frames
    ),
    draggedCenterX > nextCenterX
  {
    horizontalTargetIndex += 1
  } else if sourceColumnIndex > 0,
    let previousCenterX = centerX(
      for: workspace.columns[sourceColumnIndex - 1],
      frames: frames
    ),
    draggedCenterX < previousCenterX
  {
    horizontalTargetIndex -= 1
  }
  if horizontalTargetIndex != sourceColumnIndex {
    var column = workspace.columns.remove(at: sourceColumnIndex)
    if let focusedWindow = column.windows.firstIndex(of: windowID) {
      column.focusedWindow = focusedWindow
    }
    workspace.columns.insert(column, at: horizontalTargetIndex)
    workspace.focusedColumn = horizontalTargetIndex
    workspace.focusedLayer = .tiled
    state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
    synchronizeScrollOffsets(state: &state, viewports: viewports)
    return true
  }

  guard
    let sourceWindowIndex = workspace.columns[sourceColumnIndex]
      .windows.firstIndex(of: windowID),
    workspace.columns[sourceColumnIndex].windows.count > 1
  else {
    return false
  }
  let draggedCenterY = actualFrame.y + actualFrame.height / 2
  let remainingWindows = workspace.columns[sourceColumnIndex].windows.enumerated().filter {
    $0.offset != sourceWindowIndex
  }
  let verticalInsertionIndex = insertionIndex(
    coordinate: draggedCenterY,
    centers: remainingWindows.compactMap { _, candidateID in
      frames[candidateID].map { $0.y + $0.height / 2 }
    }
  )
  guard verticalInsertionIndex != sourceWindowIndex else { return false }

  workspace.columns[sourceColumnIndex].windows.remove(at: sourceWindowIndex)
  workspace.columns[sourceColumnIndex].windows.insert(
    windowID,
    at: verticalInsertionIndex
  )
  workspace.columns[sourceColumnIndex].focusedWindow = verticalInsertionIndex
  workspace.focusedColumn = sourceColumnIndex
  workspace.focusedLayer = .tiled
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
  synchronizeScrollOffsets(state: &state, viewports: viewports)
  return true
}

@discardableResult
public func reorderTiledWindowAfterCompletedMouseDrag(
  _ windowID: WindowID,
  actualFrame: Rect,
  initialFrame: Rect? = nil,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect]
) -> Bool {
  if initialFrame != nil,
    mouseTranslatedTiledWindowID(
      candidateWindowIDs: [windowID],
      externallyChangedFrames: [windowID: actualFrame],
      state: state,
      viewports: viewports,
      monitorFrames: monitorFrames
    ) == windowID,
    let source = state.location(containing: windowID),
    state.windows[windowID]?.floating == false,
    !state.nativeFullscreenWindowIDs.contains(windowID),
    let sourceMonitor = state.monitors.first(where: { $0.id == source.monitorID }),
    sourceMonitor.activeWorkspace == source.workspaceID,
    let targetMonitorID = mouseDropMonitor(actualFrame, monitorFrames: monitorFrames),
    targetMonitorID != source.monitorID
  {
    // The native move can also clamp size on the destination display.
    // Transfer ownership before the same-monitor translation/resize check.
    _ = focusWindow(windowID, state: &state)
    guard
      let sourceMonitorIndex = state.monitors.firstIndex(where: { $0.id == source.monitorID }),
      let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(where: {
        $0.id == source.workspaceID
      }),
      let targetMonitorIndex = state.monitors.firstIndex(where: { $0.id == targetMonitorID }),
      let targetWorkspaceIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(where: {
        $0.id == state.monitors[targetMonitorIndex].activeWorkspace
      })
    else { return false }
    moveFocusedSelection(
      movesWholeColumn: false, follow: true, preservesUserFloatingPlacement: true,
      sourceMonitorIndex: sourceMonitorIndex, sourceWorkspaceIndex: sourceWorkspaceIndex,
      targetMonitorIndex: targetMonitorIndex, targetWorkspaceIndex: targetWorkspaceIndex,
      monitorFrames: monitorFrames, viewports: viewports, state: &state
    )
    synchronizeScrollOffsets(state: &state, viewports: viewports)
    return state.monitorID(containing: windowID) == targetMonitorID
  }
  let maximumReorders = state.monitors.lazy
    .flatMap(\.workspaces)
    .map(\.columns.count)
    .max() ?? 0
  var reordered = false
  for _ in 0..<maximumReorders {
    let sourceColumnIndex = activeColumnIndex(containing: windowID, state: state)
    let sourceColumnCount = state.monitors.lazy.flatMap(\.workspaces)
      .first { $0.columns.contains { $0.windows.contains(windowID) } }?.columns.count
    guard reorderTiledWindowAfterMouseDrag(
      windowID,
      actualFrame: actualFrame,
      initialFrame: initialFrame,
      state: &state,
      viewports: viewports
    ) else {
      break
    }
    reordered = true
    // Leaving a stack to the left keeps the index but adds a column: keep going.
    if activeColumnIndex(containing: windowID, state: state) == sourceColumnIndex,
      state.monitors.lazy.flatMap(\.workspaces)
        .first(where: { $0.columns.contains { $0.windows.contains(windowID) } })?.columns.count
        == sourceColumnCount
    {
      break
    }
  }
  return reordered
}

public func desktopSynchronizationIsReady(
  scrollAnimationActive: Bool,
  mouseGestureSyncPending: Bool,
  needsDesktopSync: Bool,
  periodicSyncDue: Bool,
  commandQuietPeriodElapsed: Bool,
  nativeFocusSyncPending: Bool = false,
  nativeFocusHasNewerHumanIntent: Bool = true,
  frameDebtPending: Bool = false,
  lifecycleEventPending: Bool = false
) -> Bool {
  let nativeFocusPreemptsAnimation =
    nativeFocusSyncPending && nativeFocusHasNewerHumanIntent
  return (!scrollAnimationActive || nativeFocusPreemptsAnimation)
    && (commandQuietPeriodElapsed || mouseGestureSyncPending || nativeFocusSyncPending
      || frameDebtPending || lifecycleEventPending)
    && (needsDesktopSync || periodicSyncDue)
}

private func activeColumnIndex(
  containing windowID: WindowID,
  state: RuntimeState
) -> Int? {
  for monitor in state.monitors {
    guard let workspace = monitor.workspaces.first(where: {
      $0.id == monitor.activeWorkspace
    }) else {
      continue
    }
    if let index = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }) {
      return index
    }
  }
  return nil
}

/// Keeps the same window focused in the stack it leaves.
private func removeStackedWindow(_ windowID: WindowID, from column: inout Column) {
  guard let row = column.windows.firstIndex(of: windowID) else { return }
  column.windows.remove(at: row)
  if row < column.focusedWindow { column.focusedWindow -= 1 }
  column.focusedWindow = max(min(column.focusedWindow, column.windows.count - 1), 0)
}

private func mouseDropMonitor(_ frame: Rect, monitorFrames: [MonitorID: Rect]) -> MonitorID? {
  return monitorFrames.keys.sorted { $0.rawValue < $1.rawValue }.first {
    monitorFrames[$0]!.contains(centerOf: frame)
  }
}

private func insertionIndex(coordinate: Double, centers: [Double]) -> Int {
  centers.firstIndex(where: { coordinate < $0 }) ?? centers.count
}

private func centerX(
  for column: Column,
  frames: [WindowID: Rect]
) -> Double? {
  column.windows.compactMap { windowID in
    frames[windowID].map { $0.x + $0.width / 2 }
  }.first
}

/// A dragged tiled window held over the middle half of another column joins that
/// column, above or below the window under the pointer.
public struct MouseStackTarget: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let columnIndex: Int
  public let row: Int
  /// Where the window will sit once stacked, in layout coordinates.
  public let preview: Rect
}

public func mouseStackTarget(
  _ windowID: WindowID,
  pointer: (x: Double, y: Double),
  state: RuntimeState,
  viewports: [MonitorID: Rect]
) -> MouseStackTarget? {
  mouseDropLayout(windowID, state: state, viewports: viewports).flatMap { mouseStackTarget($0, pointer: pointer) }
}

/// The dragged window's active workspace laid out once per pointer update.
private struct MouseDropLayout {
  let monitorID: MonitorID
  let viewport: Rect
  let workspace: Workspace
  let sourceColumnIndex: Int
  let frames: [WindowID: Rect]
}

private func mouseDropLayout(
  _ windowID: WindowID,
  state: RuntimeState,
  viewports: [MonitorID: Rect]
) -> MouseDropLayout? {
  guard
    let monitor = state.monitors.first(where: { monitor in
      monitor.workspaces.contains { $0.id == monitor.activeWorkspace && $0.columns.contains { $0.windows.contains(windowID) } }
    }),
    let viewport = viewports[monitor.id],
    let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
    let sourceColumnIndex = workspace.columns.firstIndex(where: { $0.windows.contains(windowID) })
  else { return nil }
  let frames = Dictionary(
    uniqueKeysWithValues: computeLayout(
      workspace: workspace, viewport: viewport,
      windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout, excludingWindowIDs: state.nativeFullscreenWindowIDs
    ).map { ($0.windowID, $0.frame) })
  return MouseDropLayout(monitorID: monitor.id, viewport: viewport, workspace: workspace,
    sourceColumnIndex: sourceColumnIndex, frames: frames)
}

private func mouseStackTarget(_ layout: MouseDropLayout, pointer: (x: Double, y: Double)) -> MouseStackTarget? {
  for (columnIndex, column) in layout.workspace.columns.enumerated() where columnIndex != layout.sourceColumnIndex {
    let columnFrames = column.windows.compactMap { layout.frames[$0] }
    guard let first = columnFrames.first, let top = columnFrames.map(\.y).min(),
      let bottom = columnFrames.map({ $0.y + $0.height }).max(),
      pointer.x > first.x + first.width / 4, pointer.x < first.x + first.width * 3 / 4,
      pointer.y >= top, pointer.y <= bottom
    else { continue }
    let row = insertionIndex(coordinate: pointer.y, centers: columnFrames.map { $0.y + $0.height / 2 })
    let height = (bottom - top) / Double(column.windows.count + 1)
    return MouseStackTarget(
      monitorID: layout.monitorID, workspaceID: layout.workspace.id, columnIndex: columnIndex, row: row,
      preview: Rect(x: first.x, y: top + Double(row) * height, width: first.width, height: height))
  }
  return nil
}

/// Moves `windowID` into the target column; an emptied source column disappears.
@discardableResult
public func stackTiledWindow(
  _ windowID: WindowID,
  into target: MouseStackTarget,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  guard
    let monitorIndex = state.monitors.firstIndex(where: { $0.id == target.monitorID }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(where: { $0.id == target.workspaceID })
  else { return false }
  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  guard let sourceColumnIndex = workspace.columns.firstIndex(where: { $0.windows.contains(windowID) }),
    sourceColumnIndex != target.columnIndex, workspace.columns.indices.contains(target.columnIndex)
  else { return false }
  removeStackedWindow(windowID, from: &workspace.columns[sourceColumnIndex])
  var targetIndex = target.columnIndex
  if workspace.columns[sourceColumnIndex].windows.isEmpty {
    workspace.columns.remove(at: sourceColumnIndex)
    if sourceColumnIndex < targetIndex { targetIndex -= 1 }
  }
  let row = min(target.row, workspace.columns[targetIndex].windows.count)
  workspace.columns[targetIndex].windows.insert(windowID, at: row)
  workspace.columns[targetIndex].focusedWindow = row
  workspace.focusedColumn = targetIndex
  workspace.focusedLayer = .tiled
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
  synchronizeScrollOffsets(state: &state, viewports: viewports)
  return true
}

/// Where a dragged tiled window would land if released at the pointer: a column of its
/// own at `index` (counted without the column it leaves empty) or a stack in a column.
public enum MouseDropTarget: Equatable, Sendable {
  case column(index: Int)
  case stack(MouseStackTarget)
  /// A gap in another display's active workspace, counted in its current columns.
  case display(MonitorID, workspaceID: WorkspaceID, gap: Int)
}

/// Keeps a pointer resting on a boundary from flipping the target, and the preview with it.
private let mouseDropHysteresis = 24.0

public func mouseDropTarget(
  _ windowID: WindowID,
  pointer: (x: Double, y: Double),
  previous: MouseDropTarget? = nil,
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect] = [:]
) -> MouseDropTarget? {
  let target = rawMouseDropTarget(
    windowID, pointer: pointer, state: state, viewports: viewports, monitorFrames: monitorFrames)
  // No target (the window's own stack, off every display) leaves the drop to the native path.
  guard let previous, let target, target != previous else { return target }
  // Both axes: displays can sit side by side or stacked.
  let offsets = [(-mouseDropHysteresis, 0.0), (mouseDropHysteresis, 0),
    (0, -mouseDropHysteresis), (0, mouseDropHysteresis)]
  let held = offsets.contains { dx, dy in
    rawMouseDropTarget(windowID, pointer: (pointer.x + dx, pointer.y + dy), state: state,
      viewports: viewports, monitorFrames: monitorFrames) == previous
  }
  return held ? previous : target
}

private func rawMouseDropTarget(
  _ windowID: WindowID,
  pointer: (x: Double, y: Double),
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect]
) -> MouseDropTarget? {
  guard let layout = mouseDropLayout(windowID, state: state, viewports: viewports) else { return nil }
  let viewport = layout.viewport
  let source = layout.workspace.columns[layout.sourceColumnIndex]
  guard pointer.x >= viewport.x, pointer.x <= viewport.x + viewport.width,
    pointer.y >= viewport.y, pointer.y <= viewport.y + viewport.height
  else {
    return mouseDisplayDropTarget(
      pointer: pointer, sourceMonitorID: layout.monitorID, state: state,
      viewports: viewports, monitorFrames: monitorFrames)
  }
  // Within its own stack, the native drop path decides: it reorders rows.
  let sourceFrame = source.windows.compactMap { layout.frames[$0] }.first
  guard source.windows.count == 1
    || sourceFrame.map({ pointer.x < $0.x || pointer.x > $0.x + $0.width }) ?? true
  else { return nil }
  if let stack = mouseStackTarget(layout, pointer: pointer) { return .stack(stack) }
  let leavesColumn = source.windows.count == 1
  let centers = layout.workspace.columns.enumerated().compactMap { index, column in
    leavesColumn && index == layout.sourceColumnIndex ? nil : centerX(for: column, frames: layout.frames)
  }
  return .column(index: centers.filter { $0 < pointer.x }.count)
}

/// Applies a drop target; returns false when the window already sits there.
@discardableResult
public func applyMouseDrop(
  _ windowID: WindowID,
  _ target: MouseDropTarget,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect] = [:]
) -> Bool {
  switch target {
  case .stack(let stack):
    return stackTiledWindow(windowID, into: stack, state: &state, viewports: viewports)
  case .display(let monitorID, let workspaceID, let gap):
    return dropTiledWindow(windowID, onto: monitorID, workspaceID: workspaceID, gap: gap,
      state: &state, viewports: viewports, monitorFrames: monitorFrames)
  case .column(let index):
    guard
      let monitorIndex = state.monitors.firstIndex(where: { monitor in
        monitor.workspaces.contains { $0.id == monitor.activeWorkspace && $0.columns.contains { $0.windows.contains(windowID) } }
      }),
      let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(where: {
        $0.id == state.monitors[monitorIndex].activeWorkspace
      })
    else { return false }
    var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
    guard let sourceColumnIndex = workspace.columns.firstIndex(where: { $0.windows.contains(windowID) })
    else { return false }
    let column: Column
    if workspace.columns[sourceColumnIndex].windows.count == 1 {
      guard index != sourceColumnIndex else { return false }
      column = workspace.columns.remove(at: sourceColumnIndex)
    } else {
      removeStackedWindow(windowID, from: &workspace.columns[sourceColumnIndex])
      column = Column(window: windowID, width: workspace.columns[sourceColumnIndex].width)
    }
    let insertAt = min(index, workspace.columns.count)
    workspace.columns.insert(column, at: insertAt)
    workspace.focusedColumn = insertAt
    workspace.focusedLayer = .tiled
    state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
    synchronizeScrollOffsets(state: &state, viewports: viewports)
    return true
  }
}

/// Every display's active-workspace layout in `state`, for the drop preview: a drop on
/// another display closes the gap on its own and opens the slot on the other.
public func mouseDropPreviewFrames(in state: RuntimeState, viewports: [MonitorID: Rect]) -> [WindowID: Rect] {
  var frames: [WindowID: Rect] = [:]
  for monitor in state.monitors {
    guard let viewport = viewports[monitor.id],
      var workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace })
    else { continue }
    // The drop scrolls to keep the window in view; the preview shows that final scroll.
    workspace.scrollOffset = workspace.targetScrollOffset
    for placement in computeLayout(
      workspace: workspace, viewport: viewport,
      windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout, excludingWindowIDs: state.nativeFullscreenWindowIDs
    ) where frames[placement.windowID] == nil {
      frames[placement.windowID] = placement.frame
    }
  }
  return frames
}

/// The gap under the pointer on another display; nil when the pointer is on none.
private func mouseDisplayDropTarget(
  pointer: (x: Double, y: Double),
  sourceMonitorID: MonitorID,
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect]
) -> MouseDropTarget? {
  guard
    let monitorID = mouseDropMonitor(
      Rect(x: pointer.x, y: pointer.y, width: 0, height: 0), monitorFrames: monitorFrames),
    monitorID != sourceMonitorID,
    let monitor = state.monitors.first(where: { $0.id == monitorID }),
    let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
    let viewport = viewports[monitorID]
  else { return nil }
  let frames = Dictionary(
    computeLayout(
      workspace: workspace, viewport: viewport,
      windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout, excludingWindowIDs: state.nativeFullscreenWindowIDs
    ).map { ($0.windowID, $0.frame) }) { first, _ in first }
  let gap = workspace.columns.firstIndex {
    centerX(for: $0, frames: frames).map { $0 >= pointer.x } ?? false
  } ?? workspace.columns.count
  return .display(monitorID, workspaceID: workspace.id, gap: gap)
}

/// Moves a tiled window into another display's active workspace at `gap`; false and no
/// change when the destination is no longer active or the gap is out of range.
private func dropTiledWindow(
  _ windowID: WindowID,
  onto monitorID: MonitorID,
  workspaceID: WorkspaceID,
  gap: Int,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect]
) -> Bool {
  guard state.windows[windowID]?.floating == false,
    !state.nativeFullscreenWindowIDs.contains(windowID),
    activeColumnIndex(containing: windowID, state: state) != nil,
    state.monitorID(containing: windowID) != monitorID,
    let destination = state.monitors.first(where: { $0.id == monitorID }),
    destination.activeWorkspace == workspaceID,
    let workspace = destination.workspaces.first(where: { $0.id == workspaceID }),
    (0...workspace.columns.count).contains(gap)
  else { return false }
  // Transient columns move along and shift indices: the gap follows the column after it.
  let anchorWindowID = workspace.columns.indices.contains(gap) ? workspace.columns[gap].windows.first : nil
  // Focus can prune empty workspaces, so indices resolve afterward.
  _ = focusWindow(windowID, state: &state)
  guard
    let sourceMonitorIndex = state.monitors.firstIndex(where: { monitor in
      monitor.workspaces.contains { $0.id == monitor.activeWorkspace && $0.columns.contains { $0.windows.contains(windowID) } }
    }),
    let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(where: {
      $0.id == state.monitors[sourceMonitorIndex].activeWorkspace
    }),
    let targetMonitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }),
    let targetWorkspaceIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(where: {
      $0.id == workspaceID
    })
  else { return false }
  moveFocusedSelection(
    movesWholeColumn: false, follow: true, preservesUserFloatingPlacement: true,
    sourceMonitorIndex: sourceMonitorIndex, sourceWorkspaceIndex: sourceWorkspaceIndex,
    targetMonitorIndex: targetMonitorIndex, targetWorkspaceIndex: targetWorkspaceIndex,
    monitorFrames: monitorFrames, viewports: viewports, state: &state
  )
  guard
    let landedIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(where: { $0.id == workspaceID }),
    let columnIndex = state.monitors[targetMonitorIndex].workspaces[landedIndex].columns.firstIndex(where: {
      $0.windows.contains(windowID)
    })
  else { return false }
  var landed = state.monitors[targetMonitorIndex].workspaces[landedIndex]
  let column = landed.columns.remove(at: columnIndex)
  let insertionIndex = anchorWindowID.flatMap { anchor in
    landed.columns.firstIndex { $0.windows.contains(anchor) }
  } ?? landed.columns.count
  landed.columns.insert(column, at: insertionIndex)
  landed.focusedColumn = insertionIndex
  landed.focusedLayer = .tiled
  state.monitors[targetMonitorIndex].workspaces[landedIndex] = landed
  synchronizeScrollOffsets(state: &state, viewports: viewports)
  return true
}
