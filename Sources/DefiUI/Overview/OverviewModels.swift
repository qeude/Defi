import AppKit
import DefiConfig
import DefiCore
import DefiModel
import OSLog
import QuartzCore
import DefiMacOS

let overviewTransitionDuration: TimeInterval = 0.16
let overviewOpenFadeDuration: TimeInterval = 0.14
let overviewDesktopFadeDuration: TimeInterval = 0.25

struct OverviewViewportAnimation {
  let from: OverviewViewport
  let to: OverviewViewport
  let startedAt: TimeInterval
  let duration: TimeInterval
}

struct OverviewProjectionAnimation {
  let from: OverviewProjection
  let to: OverviewProjection
  let startedAt: TimeInterval
  let duration: TimeInterval
}



enum OverviewScrollAxis: Equatable {
  case horizontal
  case vertical
}

func overviewScrollAxis(for delta: NSPoint) -> OverviewScrollAxis? {
  guard delta.x != 0 || delta.y != 0 else { return nil }
  return abs(delta.y) >= abs(delta.x) ? .vertical : .horizontal
}

func overviewUsesWorkspaceParking(
  windowPreviewsEnabled: Bool,
  screenCaptureAccessGranted: Bool
) -> Bool {
  !windowPreviewsEnabled || !screenCaptureAccessGranted
}

func overviewShouldRequestCapturePermission(
  screenCaptureAccessGranted: Bool,
  hasRequestedPermission: Bool
) -> Bool {
  !screenCaptureAccessGranted && !hasRequestedPermission
}

/// The overview's look. Its defaults are the configuration's own, so the panel and the config
/// cannot disagree about the zoom, the corner radius, or the previews.
public struct OverviewStyle: Sendable {
  public var borders: BordersConfig
  public var animation: AnimationConfig
  public var zoom: Double
  public var cornerRadius: Double
  public var previewsEnabled: Bool

  public static let standard = OverviewStyle()

  public init(
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    overview: OverviewConfig = OverviewConfig(),
    previewsEnabled: Bool? = nil
  ) {
    self.borders = borders
    self.animation = animation
    self.zoom = overview.zoom
    self.cornerRadius = overview.windowCornerRadius
    self.previewsEnabled = previewsEnabled ?? overview.windowPreviews
  }

  var borderStyle: WindowBorderStyle { WindowBorderStyle(config: borders) }
  var animationsEnabled: Bool { animation.enabled }
}

func overviewViewportAfterScroll(
  _ viewport: OverviewViewport,
  delta: NSPoint,
  hasPreciseScrollingDeltas: Bool,
  viewSize: NSSize,
  zoom: Double = OverviewStyle.standard.zoom,
  activeWorkspaceIndex: Int,
  workspaceCount: Int,
  horizontalWorkspaceID: WorkspaceID?,
  maximumHorizontalOffset: Double?
) -> OverviewViewport {
  var viewport = viewport
  let deltaScale = hasPreciseScrollingDeltas ? 1.0 : 16.0
  switch overviewScrollAxis(for: delta) {
  case .vertical:
    let stride = overviewWorkspaceStride(boundsHeight: viewSize.height, zoom: zoom)
    viewport.workspaceOffset = min(
      max(
        viewport.workspaceOffset - delta.y * deltaScale / max(stride, 1),
        Double(-activeWorkspaceIndex)
      ),
      Double(workspaceCount - activeWorkspaceIndex - 1)
    )
  case .horizontal:
    guard let horizontalWorkspaceID, let maximumHorizontalOffset else {
      return viewport
    }
    let projectedPointsPerScrollUnit = overviewProjectedWidth(viewSize: viewSize, zoom: zoom)
    let start = viewport.horizontalOffsets[horizontalWorkspaceID, default: 0]
    viewport.horizontalOffsets[horizontalWorkspaceID] = overviewHorizontalOffset(
      start - delta.x * deltaScale / max(projectedPointsPerScrollUnit, 1),
      from: start,
      maximum: maximumHorizontalOffset
    )
  case nil:
    break
  }
  return viewport
}

/// The width a strip's viewport takes in the Overview.
func overviewProjectedWidth(viewSize: NSSize, zoom: Double) -> Double {
  let workspaceHeight = overviewWorkspaceStride(boundsHeight: viewSize.height, zoom: zoom) - 28
  return viewSize.width * workspaceHeight / max(viewSize.height, 1)
}

/// Overview scroll points for a strip swipe's travel: as many columns and workspaces as on the strip.
func overviewScrollDelta(travelX: Double, travelY: Double, viewSize: NSSize, zoom: Double) -> NSPoint {
  NSPoint(
    x: travelX * overviewProjectedWidth(viewSize: viewSize, zoom: zoom) / scrollPanWidthTravel,
    y: travelY * overviewWorkspaceStride(boundsHeight: viewSize.height, zoom: zoom) / scrollPanWorkspaceTravel)
}

/// Clamps a strip offset to `0...maximum`, except that a strip already outside that
/// range, as a centered column leaves it, may stay and may only move inward.
func overviewHorizontalOffset(_ offset: Double, from start: Double, maximum: Double) -> Double {
  min(max(offset, min(start, 0)), max(maximum, start))
}

func overviewViewportTransitionAfterSelectionAlignment(
  current: OverviewViewport,
  pendingTarget: OverviewViewport?,
  animationTarget: OverviewViewport?,
  workspaceID: WorkspaceID,
  scrollOffset: Double,
  sourceWorkspaceID: WorkspaceID?,
  sourceMaximumHorizontalOffset: Double?,
  movedSelection: Bool
) -> (current: OverviewViewport, target: OverviewViewport?) {
  var aligned = pendingTarget ?? animationTarget ?? current
  aligned.horizontalOffsets[workspaceID] = scrollOffset
  if let sourceWorkspaceID, let sourceMaximumHorizontalOffset {
    aligned.horizontalOffsets[sourceWorkspaceID] = min(
      aligned.horizontalOffsets[sourceWorkspaceID, default: 0],
      sourceMaximumHorizontalOffset
    )
  }
  return movedSelection
    ? (current: aligned, target: nil)
    : (current: current, target: aligned)
}


enum OverviewSelection: Equatable {
  case window(windowID: WindowID, monitorID: MonitorID, workspaceID: WorkspaceID)
  case workspace(monitorID: MonitorID, workspaceID: WorkspaceID)

  var location: (monitorID: MonitorID, workspaceID: WorkspaceID) {
    switch self {
    case .window(_, let monitorID, let workspaceID),
      .workspace(let monitorID, let workspaceID):
      (monitorID, workspaceID)
    }
  }

  var windowID: WindowID? {
    if case .window(let windowID, _, _) = self { return windowID }
    return nil
  }

  func isValid(in snapshot: OverviewSnapshot) -> Bool {
    guard let workspace = snapshot.monitors.first(where: {
        $0.id == location.monitorID
      })?.workspaces.first(where: { $0.id == location.workspaceID })
    else { return false }
    switch self {
    case .window(let windowID, _, _):
      return snapshot.windows[windowID] != nil
        && (workspace.columns.contains(where: { $0.windows.contains(windowID) })
          || workspace.floatingWindows.contains(windowID))
    case .workspace:
      return true
    }
  }
}

struct OverviewLocation: Equatable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
}

struct OverviewTiledPosition: Equatable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
  let columnIndex: Int
  let windowIndex: Int
}

extension OverviewSnapshot {
  func workspace(_ workspaceID: WorkspaceID, on monitorID: MonitorID) -> Workspace? {
    monitors.first { $0.id == monitorID }?.workspaces.first { $0.id == workspaceID }
  }

  func location(of windowID: WindowID) -> OverviewLocation? {
    for monitor in monitors {
      for workspace in monitor.workspaces
      where workspace.columns.contains(where: { $0.windows.contains(windowID) })
        || workspace.floatingWindows.contains(windowID)
      {
        return OverviewLocation(monitorID: monitor.id, workspaceID: workspace.id)
      }
    }
    return nil
  }

  func tiledPosition(of windowID: WindowID) -> OverviewTiledPosition? {
    for monitor in monitors {
      for workspace in monitor.workspaces {
        for (columnIndex, column) in workspace.columns.enumerated() {
          guard let windowIndex = column.windows.firstIndex(of: windowID) else { continue }
          return OverviewTiledPosition(
            monitorID: monitor.id,
            workspaceID: workspace.id,
            columnIndex: columnIndex,
            windowIndex: windowIndex
          )
        }
      }
    }
    return nil
  }
}

struct OverviewDrag {
  let windowID: WindowID
  let appID: String
  let sourceMonitorID: MonitorID
  let sourceWorkspaceID: WorkspaceID
  var screenPoint: NSPoint
  let cardSize: NSSize
  var target: OverviewDropTarget?
  var targetMonitorID: MonitorID?

  @MainActor
  func presentation(
    on monitorID: MonitorID,
    panel: OverviewPanel
  ) -> OverviewDragPresentation {
    let localPoint = targetMonitorID == monitorID
      ? panel.localPoint(fromScreen: screenPoint)
      : nil
    return OverviewDragPresentation(
      windowID: windowID,
      localPoint: localPoint,
      cardSize: cardSize,
      target: targetMonitorID == monitorID ? target : nil
    )
  }
}

struct OverviewDragPresentation: Equatable {
  let windowID: WindowID
  let localPoint: NSPoint?
  let cardSize: NSSize
  let target: OverviewDropTarget?
}

extension OverviewHit {
  var workspaceID: WorkspaceID {
    switch self {
    case .window(_, _, let workspaceID), .workspace(_, let workspaceID):
      workspaceID
    }
  }
}

extension OverviewDropTarget {
  var location: (monitorID: MonitorID, workspaceID: WorkspaceID) {
    switch self {
    case .newColumn(let monitorID, let workspaceID, _),
      .stack(let monitorID, let workspaceID, _, _),
      .floating(let monitorID, let workspaceID, _):
      (monitorID, workspaceID)
    }
  }
}
