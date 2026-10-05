import AppKit
import DefiCore
import DefiModel
import QuartzCore

// Reuse the compact images already displayed when navigation discarded the
// opening surface scene. No capture, encoding, or native mutation at closing.
@MainActor
final class OverviewPreviewClosingScene {
  let layer = CALayer()
  private let entries: [(CALayer, CGRect, CGRect)]
  private let cornerRadius: CGFloat

  init?(projection: OverviewProjection, workspaceID: WorkspaceID, screen: NSScreen,
    previews: [WindowID: NSImage], cornerRadius: Double = 12,
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
        let image = previews[card.windowID]?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        card.frame.width > 0, card.frame.height > 0 else { return nil }
      let source = CGRect(x: card.frame.x, y: card.frame.y,
        width: card.frame.width, height: card.frame.height)
      let item = CALayer()
      item.anchorPoint = .zero
      item.bounds = CGRect(origin: .zero, size: source.size)
      item.position = source.origin
      item.contents = image
      item.contentsGravity = .resizeAspectFill
      item.contentsScale = screen.backingScaleFactor
      item.cornerRadius = self.cornerRadius
      item.cornerCurve = .continuous
      item.masksToBounds = true
      layer.addSublayer(item)
      entries.append((item, source, target.offsetBy(dx: -origin.x, dy: -origin.y)))
    }
    guard entries.count == desired.count else { return nil }
    self.entries = entries
  }

  func animate(duration: TimeInterval) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (item, source, target) in entries {
      item.position = target.origin
      item.transform = CATransform3DMakeScale(target.width / source.width, target.height / source.height, 1)
      let radius = CABasicAnimation(keyPath: "cornerRadius")
      radius.fromValue = cornerRadius
      item.cornerRadius = cornerRadius * source.width / target.width
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
    CATransaction.commit()
  }
}
