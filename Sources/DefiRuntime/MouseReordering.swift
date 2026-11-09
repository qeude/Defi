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

/// Whether `windowID` lies wholly inside its display with the strip held at `anchor`.
public func windowStaysInView(
  _ windowID: WindowID, holding anchor: WorkspaceScrollAnchor, state: RuntimeState, viewports: [MonitorID: Rect]
) -> Bool {
  var held = state
  restoreWorkspaceScroll(anchor, state: &held)
  guard state.location(containing: windowID)?.workspaceID == anchor.workspaceID,
    let frame = mouseDropPreviewFrames(in: held, viewports: viewports)[windowID],
    let viewport = viewports[anchor.monitorID]
  else { return false }
  return frame.x >= viewport.x - 1 && frame.x + frame.width <= viewport.x + viewport.width + 1
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

/// A dragged tiled window dropped on the border between two windows of a column, or at
/// its top or bottom, joins that column there.
public struct MouseStackTarget: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let columnIndex: Int
  public let row: Int
}

public func mouseStackTarget(
  _ windowID: WindowID,
  pointer: (x: Double, y: Double),
  state: RuntimeState,
  viewports: [MonitorID: Rect]
) -> MouseStackTarget? {
  guard case .stack(let target) = mouseDropTarget(windowID, pointer: pointer, state: state, viewports: viewports)
  else { return nil }
  return target
}

/// The dragged window's active workspace as the overlay shows it while held: the window
/// out of its column, and a column it leaves empty gone.
private struct MouseDropLayout {
  let monitorID: MonitorID
  let viewport: Rect
  let workspace: Workspace
  let sourceColumnIndex: Int
  let leavesColumn: Bool
  /// The workspace's columns without the held window.
  let columns: [Column]
  let frames: [WindowID: Rect]

  /// A column counted without the held window back among the workspace's columns.
  func workspaceColumnIndex(_ index: Int) -> Int { leavesColumn && index >= sourceColumnIndex ? index + 1 : index }
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
  let closed = mouseDropClosedWorkspace(workspace, without: windowID)
  let frames = Dictionary(
    computeLayout(
      workspace: closed, viewport: viewport,
      windows: closed.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout, excludingWindowIDs: state.nativeFullscreenWindowIDs
    ).map { ($0.windowID, $0.frame) }) { first, _ in first }
  return MouseDropLayout(monitorID: monitor.id, viewport: viewport, workspace: workspace,
    sourceColumnIndex: sourceColumnIndex, leavesColumn: workspace.columns[sourceColumnIndex].windows == [windowID],
    columns: closed.columns, frames: frames)
}

/// `workspace` without `windowID`: its column closes when it was the only window.
private func mouseDropClosedWorkspace(_ workspace: Workspace, without windowID: WindowID) -> Workspace {
  var closed = workspace
  for index in closed.columns.indices { removeStackedWindow(windowID, from: &closed.columns[index]) }
  closed.columns.removeAll { $0.windows.isEmpty }
  closed.focusedColumn = min(closed.focusedColumn, max(closed.columns.count - 1, 0))
  return closed
}

/// The state the overlay draws while a window is held: that window out of its strip.
public func mouseDropHeldState(_ windowID: WindowID, state: RuntimeState) -> RuntimeState {
  var held = state
  for monitorIndex in held.monitors.indices {
    for workspaceIndex in held.monitors[monitorIndex].workspaces.indices
    where held.monitors[monitorIndex].workspaces[workspaceIndex].columns.contains(where: { $0.windows.contains(windowID) }) {
      held.monitors[monitorIndex].workspaces[workspaceIndex] =
        mouseDropClosedWorkspace(held.monitors[monitorIndex].workspaces[workspaceIndex], without: windowID)
    }
  }
  return held
}

/// A column's horizontal span and its windows' frames, top to bottom.
private func mouseDropColumnTiles(_ column: Column, frames: [WindowID: Rect]) -> [Rect] {
  column.windows.compactMap { frames[$0] }
}

/// The x of each gap a new column can open in, centred between columns and just past either
/// end; the spacing between columns comes from the layout.
private func mouseDropGapCenters(_ columns: [Column], frames: [WindowID: Rect], settings: LayoutSettings) -> [Double] {
  let spans = columns.compactMap { mouseDropColumnTiles($0, frames: frames).first }
  guard let last = spans.last else { return [] }
  let spacing = zip(spans, spans.dropFirst()).map { $1.x - $0.x - $0.width }.first ?? horizontalGaps(settings: settings)
  return spans.map { $0.x - spacing / 2 } + [last.x + last.width + spacing / 2]
}

/// The y of each border a window can join a column at: its top, between windows, its bottom.
private func mouseDropRowBorders(_ tiles: [Rect], spacing: Double) -> [Double] {
  guard let last = tiles.last else { return [] }
  let between = zip(tiles, tiles.dropFirst()).map { $1.y - $0.y - $0.height }.first ?? spacing
  return tiles.map { $0.y - between / 2 } + [last.y + last.height + between / 2]
}

private func closestIndex(_ values: [Double], to value: Double) -> Int? {
  values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) }
}

/// Moves `windowID` into the target column, or to another row of its own; an emptied
/// source column disappears.
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
    workspace.columns.indices.contains(target.columnIndex)
  else { return false }
  var targetIndex = target.columnIndex
  if sourceColumnIndex == targetIndex {
    guard workspace.columns[targetIndex].windows.firstIndex(of: windowID) != target.row else { return false }
    workspace.columns[targetIndex].windows.removeAll { $0 == windowID }
  } else {
    removeStackedWindow(windowID, from: &workspace.columns[sourceColumnIndex])
    if workspace.columns[sourceColumnIndex].windows.isEmpty {
      workspace.columns.remove(at: sourceColumnIndex)
      if sourceColumnIndex < targetIndex { targetIndex -= 1 }
    }
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
  /// A stack the window's constraints forbid: the drop changes nothing.
  case rejectedStack(MouseStackTarget)
  /// A gap in another display's active workspace, counted in its current columns.
  case display(MonitorID, workspaceID: WorkspaceID, gap: Int)
}

/// Keeps a pointer resting on a boundary from flipping the target, and the preview with it.
private let mouseDropHysteresis = 8.0


public func mouseDropTarget(
  _ windowID: WindowID,
  pointer: (x: Double, y: Double),
  previous: MouseDropTarget? = nil,
  allowsStacking: Bool = true,
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect] = [:]
) -> MouseDropTarget? {
  let target = rawMouseDropTarget(windowID, pointer: pointer, allowsStacking: allowsStacking,
    state: state, viewports: viewports, monitorFrames: monitorFrames)
  // No target (off every display) leaves the drop to the native path.
  guard let previous, let target, target != previous else { return target }
  // Both axes: displays can sit side by side or stacked.
  let offsets = [(-mouseDropHysteresis, 0.0), (mouseDropHysteresis, 0),
    (0, -mouseDropHysteresis), (0, mouseDropHysteresis)]
  let held = offsets.contains { dx, dy in
    rawMouseDropTarget(windowID, pointer: (pointer.x + dx, pointer.y + dy), allowsStacking: allowsStacking,
      state: state, viewports: viewports, monitorFrames: monitorFrames) == previous
  }
  return held ? previous : target
}

/// Whether a target change moves the drop slot shown during a drag: either target, old or
/// new, sits away from the window's own place. The first target of a drag is usually that
/// place, and leaving it for no target changes nothing either.
public func mouseDropSlotMoved(
  _ windowID: WindowID,
  from previous: MouseDropTarget?,
  to target: MouseDropTarget?,
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect] = [:]
) -> Bool {
  guard previous != target else { return false }
  return [previous, target].contains { candidate in
    var moved = state
    return candidate.map {
      applyMouseDrop(windowID, $0, state: &moved, viewports: viewports, monitorFrames: monitorFrames)
    } ?? false
  }
}

/// The drop under the pointer, on the strip as the overlay shows it while the window is
/// held: the closest edge wins, a gap between two columns or a border between two windows of
/// the column under the pointer, its top and bottom included.
private func rawMouseDropTarget(
  _ windowID: WindowID,
  pointer: (x: Double, y: Double),
  allowsStacking: Bool,
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  monitorFrames: [MonitorID: Rect]
) -> MouseDropTarget? {
  guard let layout = mouseDropLayout(windowID, state: state, viewports: viewports) else { return nil }
  let viewport = layout.viewport
  // Under the menu bar or beside the Dock the pointer is still on this display's strip: a
  // title bar dragged across drifts up there, and a hand pushes up there to mean above.
  let reportedY = pointer.y
  var pointer = pointer
  if let screen = monitorFrames[layout.monitorID],
    screen.contains(centerOf: Rect(x: pointer.x, y: pointer.y, width: 0, height: 0)) {
    pointer = (min(max(pointer.x, viewport.x), viewport.x + viewport.width),
      min(max(pointer.y, viewport.y), viewport.y + viewport.height))
  }
  guard pointer.x >= viewport.x, pointer.x <= viewport.x + viewport.width,
    pointer.y >= viewport.y, pointer.y <= viewport.y + viewport.height
  else {
    return mouseDisplayDropTarget(
      pointer: pointer, sourceMonitorID: layout.monitorID, state: state,
      viewports: viewports, monitorFrames: monitorFrames)
  }
  let gaps = mouseDropGapCenters(layout.columns, frames: layout.frames, settings: state.layout)
  guard let gap = closestIndex(gaps, to: pointer.x) else { return .column(index: 0) }
  // At a strip's edge every column passes under the pointer: only new columns are offered.
  guard allowsStacking,
    let index = gaps.indices.dropLast().first(where: { pointer.x >= gaps[$0] && pointer.x <= gaps[$0 + 1] })
  else { return .column(index: gap) }
  let tiles = mouseDropColumnTiles(layout.columns[index], frames: layout.frames)
  let borders = mouseDropRowBorders(tiles, spacing: horizontalGaps(settings: state.layout))
  // A held title bar runs along every other column's top while it crosses: that top counts
  // only once the hand pushes the window above it. In its own stack it counts as any border.
  // Pushed above, the pointer's own height measures how far: a crossing hand drifts a few
  // points, a hand meaning above pushes well past.
  let ownColumn = !layout.leavesColumn && layout.workspaceColumnIndex(index) == layout.sourceColumnIndex
  // The whole menu bar is above the strip, and the screen's top edge, where a thrown pointer
  // stops, counts even with the menu bar hidden.
  let screenTop = monitorFrames[layout.monitorID]?.y ?? viewport.y
  let pushedAbove = reportedY < viewport.y || reportedY <= screenTop + 1
  let rows = borders.indices.filter { $0 > 0 || ownColumn || pushedAbove }
  func distance(_ row: Int) -> Double { abs(borders[row] - (row == 0 && pushedAbove ? reportedY : pointer.y)) }
  guard let row = rows.min(by: { distance($0) < distance($1) }), distance(row) < abs(pointer.x - gaps[gap])
  else { return .column(index: gap) }
  let target = MouseStackTarget(monitorID: layout.monitorID, workspaceID: layout.workspace.id,
    columnIndex: layout.workspaceColumnIndex(index), row: row)
  var stacked = layout.columns[index].windows
  stacked.insert(windowID, at: row)
  let fits = stackFit(stacked, windowsByID: state.windows, viewport: viewport, settings: state.layout) == .fits
  return fits ? .stack(target) : .rejectedStack(target)
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
  case .rejectedStack:
    return false
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

/// The layout the overlay draws while a window is held: every other window where the strip
/// closes up without it, still until the drop, and the held window at its landing slot.
public func mouseDropHeldFrames(
  _ windowID: WindowID, _ target: MouseDropTarget?, state: RuntimeState,
  viewports: [MonitorID: Rect], monitorFrames: [MonitorID: Rect] = [:]
) -> [WindowID: Rect] {
  var frames = mouseDropPreviewFrames(in: mouseDropHeldState(windowID, state: state), viewports: viewports)
  var landed = state
  if let target {
    applyMouseDrop(windowID, target, state: &landed, viewports: viewports, monitorFrames: monitorFrames)
  }
  frames[windowID] = mouseDropPreviewFrames(in: landed, viewports: viewports)[windowID]
  return frames
}

/// Points across the hint that marks a new column's gap.
private let mouseDropColumnHintWidth = 300.0
/// Points down the hint at a column's top or bottom; between two windows it is twice that.
private let mouseDropRowHintHeight = 150.0

/// Where the overlay marks a drop on the held strip: a band across the gap a new column opens,
/// or across the column at the border the window joins it.
public func mouseDropHintFrame(
  _ windowID: WindowID, _ target: MouseDropTarget, state: RuntimeState, viewports: [MonitorID: Rect]
) -> Rect? {
  let held = mouseDropHeldState(windowID, state: state)
  let frames = mouseDropPreviewFrames(in: held, viewports: viewports)
  func columns(_ monitorID: MonitorID, _ workspaceID: WorkspaceID) -> [Column] {
    held.monitors.first { $0.id == monitorID }?.workspaces.first { $0.id == workspaceID }?.columns ?? []
  }
  func gapBand(_ columns: [Column], _ gap: Int) -> Rect? {
    let gaps = mouseDropGapCenters(columns, frames: frames, settings: state.layout)
    let tiles = columns.flatMap { mouseDropColumnTiles($0, frames: frames) }
    guard gaps.indices.contains(gap), let top = tiles.map(\.y).min(),
      let bottom = tiles.map({ $0.y + $0.height }).max()
    else { return nil }
    // Past either end the band lies outside the strip, as the column it opens will.
    let x = gap == 0 ? gaps[gap] - mouseDropColumnHintWidth
      : gap == gaps.count - 1 ? gaps[gap] : gaps[gap] - mouseDropColumnHintWidth / 2
    return Rect(x: x, y: top, width: mouseDropColumnHintWidth, height: bottom - top)
  }
  switch target {
  case .rejectedStack:
    return nil
  case .stack(let stack):
    guard let location = state.location(containing: windowID) else { return nil }
    var index = stack.columnIndex
    // Counted among the held strip's columns, without one the window leaves empty.
    if let sourceIndex = state.monitors.first(where: { $0.id == location.monitorID })?.workspaces
      .first(where: { $0.id == location.workspaceID })?.columns.firstIndex(where: { $0.windows == [windowID] }),
      stack.monitorID == location.monitorID, stack.workspaceID == location.workspaceID, index > sourceIndex {
      index -= 1
    }
    let target = columns(stack.monitorID, stack.workspaceID)
    guard target.indices.contains(index) else { return nil }
    let tiles = mouseDropColumnTiles(target[index], frames: frames)
    let borders = mouseDropRowBorders(tiles, spacing: horizontalGaps(settings: state.layout))
    guard let first = tiles.first, let last = tiles.last, borders.indices.contains(stack.row) else { return nil }
    let y: Double, height: Double
    if stack.row == 0 {
      (y, height) = (first.y, mouseDropRowHintHeight)
    } else if stack.row == tiles.count {
      (y, height) = (last.y + last.height - mouseDropRowHintHeight, mouseDropRowHintHeight)
    } else {
      (y, height) = (borders[stack.row] - mouseDropRowHintHeight, mouseDropRowHintHeight * 2)
    }
    return Rect(x: first.x, y: y, width: first.width, height: height)
  case .column(let index):
    guard let location = state.location(containing: windowID) else { return nil }
    return gapBand(columns(location.monitorID, location.workspaceID), index)
  case .display(let monitorID, let workspaceID, let gap):
    return gapBand(columns(monitorID, workspaceID), gap)
  }
}

/// The column a rejected drop points at, as the preview draws it.
public func mouseDropRejectedFrame(
  _ target: MouseDropTarget?, state: RuntimeState, viewports: [MonitorID: Rect]
) -> Rect? {
  guard case .rejectedStack(let stack) = target,
    let monitor = state.monitors.first(where: { $0.id == stack.monitorID }),
    let workspace = monitor.workspaces.first(where: { $0.id == stack.workspaceID }),
    workspace.columns.indices.contains(stack.columnIndex)
  else { return nil }
  let frames = mouseDropPreviewFrames(in: state, viewports: viewports)
  let column = workspace.columns[stack.columnIndex].windows.compactMap { frames[$0] }
  guard let first = column.first, let top = column.map(\.y).min(),
    let bottom = column.map({ $0.y + $0.height }).max()
  else { return nil }
  return Rect(x: first.x, y: top, width: first.width, height: bottom - top)
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
