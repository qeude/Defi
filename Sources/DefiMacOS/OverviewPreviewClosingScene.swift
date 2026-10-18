import AppKit
import DefiCore
import DefiModel
import QuartzCore

// Reuse the compact images already displayed when navigation discarded the
// opening surface scene; cards stand in for windows without one. No capture,
// encoding, or native mutation at closing.
@MainActor
final class OverviewPreviewClosingScene {
  let layer = CALayer()
  private let entries: [(CALayer, CGRect, CGRect)]
  private let cornerRadius: CGFloat
  // An empty workspace zooms its wallpaper card to the full, square-cornered screen.
  private let endsSquare: Bool
  // Matches the overview's wallpaper dimming, then fades with the glass.
  private var dim: CALayer?
  var zoomsWallpaper: Bool { endsSquare }

  init?(projection: OverviewProjection, workspaceID: WorkspaceID, screen: NSScreen,
    previews: [WindowID: NSImage], wallpaper: NSImage? = nil, cornerRadius: Double = 12,
    targets: [FrameAssignment], windows: [WindowID: Window]) {
    guard let workspace = projection.workspaces.first(where: { $0.workspaceID == workspaceID })
    else { return nil }
    self.cornerRadius = max(cornerRadius, 0)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    let viewport = CGRect(origin: origin, size: screen.frame.size)
    let desired = Dictionary(uniqueKeysWithValues: targets.map { assignment in
      (assignment.windowID, CGRect(x: assignment.frame.x, y: assignment.frame.y,
        width: assignment.frame.width, height: assignment.frame.height))
    }).filter { $0.value.intersects(viewport) }
    endsSquare = workspace.windows.isEmpty
      && workspace.hiddenTiledWindowCountBefore + workspace.hiddenTiledWindowCountAfter == 0
    if endsSquare {
      let card = workspace.visibleFrame
      guard let image = wallpaper?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        card.width > 0, card.height > 0 else { return nil }
      let source = CGRect(x: card.x, y: card.y, width: card.width, height: card.height)
      let item = CALayer()
      item.contents = image
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      layer.frame = CGRect(origin: .zero, size: screen.frame.size)
      layer.isGeometryFlipped = true
      layer.masksToBounds = true
      Self.place(item, source: source, scale: screen.backingScaleFactor, cornerRadius: self.cornerRadius)
      let dim = CALayer()
      dim.frame = item.bounds
      dim.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
      item.addSublayer(dim)
      self.dim = dim
      layer.addSublayer(item)
      entries = [(item, source, layer.bounds)]
      return
    }
    guard !desired.isEmpty else { return nil }
    let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    var observed: [WindowID: CGRect] = [:]
    for info in infos {
      guard let number = info[kCGWindowNumber as String] as? NSNumber,
        let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
      let id = WindowID(rawValue: number.uint64Value)
      if windows[id]?.processID == owner.int32Value { observed[id] = rect }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    layer.frame = CGRect(origin: .zero, size: screen.frame.size)
    layer.isGeometryFlipped = true
    layer.masksToBounds = true
    var entries: [(CALayer, CGRect, CGRect)] = []
    for card in workspace.windows where desired[card.windowID] != nil {
      guard let target = desired[card.windowID], let actual = observed[card.windowID],
        abs(actual.minX - target.minX) <= 2, abs(actual.minY - target.minY) <= 2,
        abs(actual.width - target.width) <= 2, abs(actual.height - target.height) <= 2,
        card.frame.width > 0, card.frame.height > 0 else { return nil }
      let source = CGRect(x: card.frame.x, y: card.frame.y,
        width: card.frame.width, height: card.frame.height)
      // Windows without a captured image zoom back as cards from verified native frames.
      let item = overviewCardLayer(
        image: previews[card.windowID]?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        size: source.size)
      Self.place(item, source: source, scale: screen.backingScaleFactor, cornerRadius: self.cornerRadius)
      layer.addSublayer(item)
      entries.append((item, source, target.offsetBy(dx: -origin.x, dy: -origin.y)))
    }
    guard entries.count == desired.count else { return nil }
    self.entries = entries
  }

  private static func place(_ item: CALayer, source: CGRect, scale: CGFloat, cornerRadius: CGFloat) {
    item.anchorPoint = .zero
    item.bounds = CGRect(origin: .zero, size: source.size)
    item.position = source.origin
    item.contentsGravity = .resizeAspectFill
    item.contentsScale = scale
    item.cornerRadius = cornerRadius
    item.cornerCurve = .continuous
    item.masksToBounds = true
  }

  func animate(duration: TimeInterval) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (item, source, target) in entries {
      item.position = target.origin
      item.transform = CATransform3DMakeScale(target.width / source.width, target.height / source.height, 1)
      let radius = CABasicAnimation(keyPath: "cornerRadius")
      radius.fromValue = cornerRadius
      item.cornerRadius = endsSquare ? 0 : cornerRadius * source.width / target.width
      radius.toValue = item.cornerRadius
      let position = CABasicAnimation(keyPath: "position")
      position.fromValue = NSValue(point: source.origin)
      position.toValue = NSValue(point: target.origin)
      let transform = CABasicAnimation(keyPath: "transform")
      transform.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
      transform.toValue = NSValue(caTransform3D: item.transform)
      let animation = CAAnimationGroup()
      animation.animations = [position, transform, radius]
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      item.add(animation, forKey: "overview-preview-close")
    }
    if let dim {
      dim.opacity = 0
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.duration = duration
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      dim.add(fade, forKey: "overview-preview-close")
    }
    CATransaction.commit()
  }
}
