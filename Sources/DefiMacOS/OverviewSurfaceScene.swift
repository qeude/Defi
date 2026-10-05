import AppKit
import AVFoundation
import DefiCore
import DefiModel
import QuartzCore

// A short-lived layer scene: Core Animation moves existing textures rather than
// repainting the overview or sending frame writes to applications on every refresh.
@MainActor
final class OverviewSurfaceScene {
  let layer = CALayer()
  let presentedFrameCount = 1
  private(set) var openingContentDescription = "none"
  private var entries: [(WindowID, CALayer, CGRect, CGRect)]
  private var fallbackIDs: Set<WindowID> = []
  private let frames: [WindowID: OverviewSurfaceFrame]
  private(set) var nativeFrames: [WindowID: CGRect]
  let projection: OverviewProjection
  private let nativeOwners: [WindowID: Int32]
  private let cornerRadius: CGFloat

  init?(
    projection: OverviewProjection, workspaceID: WorkspaceID, screen: NSScreen,
    surfaces: [WindowID: OverviewSurfaceFrame], windows: [WindowID: Window], cornerRadius: Double = 12,
    previews: [WindowID: NSImage]? = nil
  ) {
    guard let workspace = projection.workspaces.first(where: { $0.workspaceID == workspaceID }),
      !workspace.windows.isEmpty, (!surfaces.isEmpty || previews != nil),
      surfaces.keys.allSatisfy({ OverviewSurfaceCapture.shared.displayLayer(for: $0) != nil })
    else { return nil }
    let workspaceIDs = previews == nil
      ? Set(workspace.windows.map(\.windowID)).intersection(surfaces.keys)
      : Set(workspace.windows.map(\.windowID))
    let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let screenOrigin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    var frames: [WindowID: CGRect] = [:]
    var order: [WindowID: Int] = [:]
    var owners: [WindowID: Int32] = [:]
    for (index, info) in infos.enumerated() {
      guard let number = info[kCGWindowNumber as String] as? NSNumber,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { continue }
      let id = WindowID(rawValue: number.uint64Value)
      guard workspaceIDs.contains(id),
        let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
        windows[id]?.processID == owner.int32Value else { continue }
      owners[id] = owner.int32Value
      frames[id] = rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
      order[id] = index
    }
    guard previews != nil || workspaceIDs.allSatisfy({ frames[$0] != nil }) else { return nil }
    self.frames = surfaces.filter { workspaceIDs.contains($0.key) }
    nativeFrames = frames
    nativeOwners = owners
    self.projection = projection
    self.cornerRadius = max(cornerRadius, 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    layer.frame = CGRect(origin: .zero, size: screen.frame.size)
    layer.isGeometryFlipped = true
    layer.masksToBounds = true
    var entries: [(WindowID, CALayer, CGRect, CGRect)] = []
    var cachedCount = 0
    // Public CGWindow order is front to back; preserve floating/native stacking.
    for card in workspace.windows.sorted(by: {
      order[$0.windowID, default: 0] > order[$1.windowID, default: 0]
    }) {
      guard let source = frames[card.windowID], source.width > 0, source.height > 0 else { continue }
      let target = CGRect(x: card.frame.x, y: card.frame.y,
        width: card.frame.width, height: card.frame.height)
      let item: CALayer
      if let frame = surfaces[card.windowID],
        let displayLayer = OverviewSurfaceCapture.shared.displayLayer(for: card.windowID) {
        item = displayLayer
        _ = enqueueWindowSurface(frame, on: displayLayer)
      } else {
        // Only visible native windows need the opening fallback. Parked columns
        // must not fly into the overview from their one-pixel strip anchors.
        guard previews != nil, source.intersects(layer.bounds) else { continue }
        item = CALayer()
        item.contents = previews?[card.windowID]?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if item.contents != nil { cachedCount += 1 }
        item.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        if item.contents == nil {
          // Keep the window's silhouette legible while its preview loads. Only
          // the small symbol is rasterized, never a window-sized placeholder.
          item.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
          item.borderWidth = 2
          let symbol = CALayer()
          let image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
              .applying(.init(paletteColors: [.white])))
          symbol.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
          symbol.contentsGravity = .resizeAspect
          symbol.frame = CGRect(x: (source.width - 64) / 2,
            y: (source.height - 64) / 2, width: 64, height: 64)
          item.addSublayer(symbol)
        }
        fallbackIDs.insert(card.windowID)
      }
      item.removeFromSuperlayer(); item.removeAllAnimations()
      item.contentsGravity = .resize
      item.contentsScale = screen.backingScaleFactor
      item.transform = CATransform3DIdentity
      item.anchorPoint = .zero
      item.bounds = CGRect(origin: .zero, size: source.size)
      item.position = source.origin
      item.cornerRadius = self.cornerRadius
      item.cornerCurve = .continuous
      item.masksToBounds = true
      layer.addSublayer(item)
      entries.append((card.windowID, item, source, target))
    }
    guard !entries.isEmpty else { return nil }
    self.entries = entries
    openingContentDescription = "surfaces:\(entries.count - fallbackIDs.count),cached:\(cachedCount),cards:\(fallbackIDs.count - cachedCount)"
    nativeFrames = frames.filter { id, _ in entries.contains { $0.0 == id } }
  }

  // Compact/placeholder layers only bridge the opening. The regular card owns
  // progressive image delivery afterward; never keep a stale fallback on top.
  func finishOpening() -> Set<WindowID> {
    let released = fallbackIDs
    for (id, item, _, _) in entries where released.contains(id) { item.removeFromSuperlayer() }
    entries.removeAll { released.contains($0.0) }
    nativeFrames = nativeFrames.filter { !released.contains($0.key) }
    fallbackIDs = []
    return released
  }

  func animate(opening: Bool, duration: TimeInterval) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (_, item, source, target) in entries {
      let start = opening ? source : target
      let end = opening ? target : source
      let presented = item.presentation()
      let startPosition = presented?.position ?? start.origin
      let startTransform = presented?.transform ?? CATransform3DMakeScale(
        start.width / source.width, start.height / source.height, 1
      )
      // Transform a fixed-size image; this retains one texture through the zoom.
      item.bounds = CGRect(origin: .zero, size: source.size)
      item.position = end.origin
      item.transform = CATransform3DMakeScale(
        end.width / source.width, end.height / source.height, 1
      )
      let radius = CABasicAnimation(keyPath: "cornerRadius")
      radius.fromValue = presented?.cornerRadius ?? cornerRadius * source.width / start.width
      item.cornerRadius = cornerRadius * source.width / end.width
      radius.toValue = item.cornerRadius
      let position = CABasicAnimation(keyPath: "position")
      position.fromValue = NSValue(point: startPosition)
      position.toValue = NSValue(point: end.origin)
      let transform = CABasicAnimation(keyPath: "transform")
      transform.fromValue = NSValue(caTransform3D: startTransform)
      transform.toValue = NSValue(caTransform3D: item.transform)
      let group = CAAnimationGroup()
      group.animations = [position, transform, radius]
      group.duration = duration
      group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      item.add(group, forKey: "overview-surface")
    }
    CATransaction.commit()
  }

  func matchesNativeFrames(screen: NSScreen) -> Bool {
    let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    var current: [WindowID: CGRect] = [:]
    for info in infos {
      guard let id = info[kCGWindowNumber as String] as? NSNumber,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { continue }
      let windowID = WindowID(rawValue: id.uint64Value)
      if nativeFrames[windowID] != nil {
        guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
          nativeOwners[windowID] == owner.int32Value else { return false }
        current[windowID] = rect.offsetBy(dx: -origin.x, dy: -origin.y)
      }
    }
    return current == nativeFrames
  }
}
