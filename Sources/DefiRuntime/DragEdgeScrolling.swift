import DefiCore
import DefiModel

/// A native translation's speculative scroll. The daemon owns its lifetime; all
/// workspace mutations, including rollback, stay in the runtime.
public struct DragEdgeScrolling: Sendable {
  public let windowID: WindowID
  public let generation: UInt64
  public let initialAnchor: WorkspaceScrollAnchor
  public private(set) var hasScrolled = false
  private let viewports: [MonitorID: Rect]
  private let monitorFrames: [MonitorID: Rect]
  private let activeWorkspaces: [MonitorID: WorkspaceID]
  private let activeColumns: [WorkspaceID: [Column]]
  private var direction = 0
  private var enteredAt = 0.0
  private var lastTick: Double?

  public init?(windowID: WindowID, generation: UInt64, state: RuntimeState,
    viewports: [MonitorID: Rect], monitorFrames: [MonitorID: Rect])
  {
    guard state.windows[windowID]?.floating == false,
      !state.nativeFullscreenWindowIDs.contains(windowID),
      let anchor = workspaceScrollAnchor(containing: windowID, state: state),
      let monitor = state.monitors.first(where: { $0.id == anchor.monitorID }),
      monitor.activeWorkspace == anchor.workspaceID,
      monitor.workspaces.contains(where: { $0.id == anchor.workspaceID }),
      let viewport = viewports[anchor.monitorID], viewport.width > 0
    else { return nil }
    self.windowID = windowID
    self.generation = generation
    initialAnchor = anchor
    self.viewports = viewports
    self.monitorFrames = monitorFrames
    activeWorkspaces = Dictionary(uniqueKeysWithValues: state.monitors.map { ($0.id, $0.activeWorkspace) })
    activeColumns = Dictionary(uniqueKeysWithValues: state.monitors.compactMap { monitor in
      monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }).map { ($0.id, $0.columns) }
    })
  }

  public func isCurrent(generation: UInt64, state: RuntimeState,
    viewports: [MonitorID: Rect], monitorFrames: [MonitorID: Rect]) -> Bool
  {
    self.generation == generation && self.viewports == viewports && self.monitorFrames == monitorFrames
      && state.windows[windowID]?.floating == false
      && !state.nativeFullscreenWindowIDs.contains(windowID)
      && state.monitors.count == activeWorkspaces.count
      && state.monitors.allSatisfy { monitor in
        monitor.activeWorkspace == activeWorkspaces[monitor.id]
          && monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }).map {
            $0.columns == activeColumns[$0.id]
          } == true
      }
  }

  public func currentAnchor(state: RuntimeState) -> WorkspaceScrollAnchor {
    workspaceScrollAnchor(containing: windowID, state: state) ?? initialAnchor
  }

  public func cancel(state: inout RuntimeState) {
    restoreWorkspaceScroll(initialAnchor, state: &state)
  }

  @discardableResult
  public mutating func advance(pointer: (x: Double, y: Double), now: Double,
    refreshRate: Double, state: inout RuntimeState) -> Bool
  {
    guard now.isFinite, refreshRate.isFinite, refreshRate > 0,
      pointer.x.isFinite, pointer.y.isFinite,
      isCurrent(generation: generation, state: state, viewports: viewports, monitorFrames: monitorFrames),
      let viewport = viewports[initialAnchor.monitorID]
    else { return false }
    let zone = min(48.0, viewport.width / 4)
    let inside = pointer.x >= viewport.x && pointer.x <= viewport.x + viewport.width
      && pointer.y >= viewport.y && pointer.y <= viewport.y + viewport.height
    let onNeighbor = monitorFrames.contains { id, frame in
      id != initialAnchor.monitorID && pointer.x >= frame.x && pointer.x < frame.x + frame.width
        && pointer.y >= frame.y && pointer.y < frame.y + frame.height
    }
    let left = pointer.x - viewport.x
    let right = viewport.x + viewport.width - pointer.x
    let nextDirection: Int
    if !inside || onNeighbor { nextDirection = 0 }
    else if left <= zone + (direction == -1 ? 12 : 0) { nextDirection = -1 }
    else if right <= zone + (direction == 1 ? 12 : 0) { nextDirection = 1 }
    else { nextDirection = 0 }
    let elapsed = max(0, now - (lastTick ?? now))
    lastTick = now
    if nextDirection != direction {
      direction = nextDirection
      enteredAt = now
      return false
    }
    guard direction != 0, now >= enteredAt + 0.2 else { return false }
    let proximity = max(0, min(1, 1 - (direction < 0 ? left : right) / zone))
    let speed = 0.15 + 0.75 * proximity
    // Never repay missed frames after a stalled callback or a slow application.
    let delta = Double(direction) * speed * min(elapsed, 1 / min(max(refreshRate, 30), 120))
    guard let mi = state.monitors.firstIndex(where: { $0.id == initialAnchor.monitorID }),
      let wi = state.monitors[mi].workspaces.firstIndex(where: { $0.id == initialAnchor.workspaceID })
    else { return false }
    let workspace = state.monitors[mi].workspaces[wi]
    let windows = workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] }
    let widths = columnLayoutWidths(workspace.columns, viewport: viewport,
      windowsByID: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }), settings: state.layout)
    let maximum = max(0, widths.reduce(0, +) / stripViewport(viewport, settings: state.layout).width - 1)
    let offset = min(max(workspace.scrollOffset + delta, 0), maximum)
    guard offset != workspace.scrollOffset else { return false }
    hasScrolled = true
    restoreWorkspaceScroll(WorkspaceScrollAnchor(monitorID: initialAnchor.monitorID,
      workspaceID: initialAnchor.workspaceID, scrollOffset: offset), state: &state)
    return true
  }
}
