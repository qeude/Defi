import AppKit
import DefiCore
import DefiModel

/// Chooses which windows the overview captures and keeps one desktop image per monitor.
@MainActor
final class OverviewSurfacePlanner {
  static let shared = OverviewSurfacePlanner()

  private struct Context {
    let monitorID: MonitorID
    let frames: [WindowID: Rect]
    let screen: NSScreen
  }
  private var contexts: [Context] = []
  private var backgrounds: [MonitorID: CGImage] = [:]
  private var backgroundTask: Task<Void, Never>?
  private(set) var requests: [OverviewSurfaceRequest] = []

  func backgroundImage(for monitorID: MonitorID) -> CGImage? { backgrounds[monitorID] }

  func disable() {
    contexts = []; requests = []; backgrounds = [:]
    backgroundTask?.cancel(); backgroundTask = nil
  }

  func capturedIDs(on monitorID: MonitorID) -> Set<WindowID> {
    Set(requests.map(\.windowID)).intersection(contexts.first {
      $0.monitorID == monitorID
    }?.frames.keys.map { $0 } ?? [])
  }

  func prepare(snapshot: OverviewSnapshot, layout: LayoutSettings, enabled: Bool) {
    guard enabled else {
      disable()
      return
    }
    var next: [Context] = []
    var candidates: [(request: OverviewSurfaceRequest, distance: Double)] = []
    for monitor in snapshot.monitors {
      guard let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint64Value == monitor.id.rawValue
      }), let viewport = snapshot.monitorFrames[monitor.id],
        let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
        workspace.floatingWindows.isEmpty,
        Set(workspace.columns.flatMap(\.windows)).isDisjoint(with: snapshot.nativeFullscreenWindowIDs)
      else { continue }
      let frames = Dictionary(uniqueKeysWithValues: computeLayout(workspace: workspace,
        viewport: viewport, windows: Array(snapshot.windows.values), settings: layout)
        .map { ($0.windowID, $0.frame) })
      let owners = snapshot.windows.compactMapValues(\.processID)
      next.append(Context(monitorID: monitor.id, frames: frames, screen: screen))
      let visible = frames.filter { $0.value.ribbonIntersects(viewport) }
      let offscreen = frames.filter { !visible.keys.contains($0.key) }
      let ordered = offscreen.sorted {
        let left = distance($0.value, viewport), right = distance($1.value, viewport)
        return left == right ? $0.key.rawValue < $1.key.rawValue : left < right
      }
      let neighbours = [ordered.first(where: { $0.value.x + $0.value.width <= viewport.x }),
        ordered.first(where: { $0.value.x >= viewport.x + viewport.width })].compactMap { $0 }
      for (id, frame) in Array(visible) + Array(neighbours) {
        guard let window = snapshot.windows[id], let owner = owners[id],
          frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0
        else { continue }
        // Keep visible windows and immediate neighbours sharp; NV12 reduces the
        // capture pool without reducing luma resolution.
        let scale = screen.backingScaleFactor
        let width = window.frame.width * scale, height = window.frame.height * scale
        guard width <= 16_384, height <= 16_384 else { continue }
        candidates.append((OverviewSurfaceRequest(windowID: id, appID: window.appID,
          processID: owner, width: max((Int(width.rounded(.up)) + 1) / 2 * 2, 2),
          height: max((Int(height.rounded(.up)) + 1) / 2 * 2, 2)), visible[id] == nil ? distance(frame, viewport) + 1 : 0))
      }
    }
    contexts = next
    let required = candidates.filter { $0.distance == 0 }.map(\.request)
    var selected = required
    for item in candidates.filter({ $0.distance > 0 }).sorted(by: { $0.distance < $1.distance }) {
      if overviewSurfaceRequestsFit(selected + [item.request]) { selected.append(item.request) }
    }
    requests = selected.sorted { $0.windowID.rawValue < $1.windowID.rawValue }
    let ids = Set(next.map(\.monitorID))
    backgrounds = backgrounds.filter { id, image in
      guard ids.contains(id), let context = next.first(where: { $0.monitorID == id }) else { return false }
      return image.width == Int(context.screen.frame.width) && image.height == Int(context.screen.frame.height)
    }
    guard CGPreflightScreenCaptureAccess(), backgroundTask == nil, next.contains(where: { backgrounds[$0.monitorID] == nil }) else { return }
    let desktopRequests = next.filter { backgrounds[$0.monitorID] == nil }.map {
      OverviewDesktopCaptureRequest(monitorID: $0.monitorID,
        displayID: UInt32($0.monitorID.rawValue), width: Int($0.screen.frame.width),
        height: Int($0.screen.frame.height))
    }
    backgroundTask = Task { [weak self] in
      let result = await captureOverviewImages(previews: [], desktops: desktopRequests, previewCompleted: { _ in })
      guard !Task.isCancelled, let self else { return }
      backgrounds.merge(result.desktops) { _, new in new }
      backgroundTask = nil
    }
  }

  private func distance(_ a: Rect, _ b: Rect) -> Double {
    max(b.x - a.x - a.width, a.x - b.x - b.width, 0)
  }
}

private extension Rect {
  func ribbonIntersects(_ other: Rect) -> Bool {
    x + width > other.x && other.x + other.width > x
      && y + height > other.y && other.y + other.height > y
  }
}
