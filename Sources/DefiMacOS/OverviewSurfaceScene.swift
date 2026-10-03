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
  private let entries: [(WindowID, CALayer, CGRect, CGRect)]
  private let frames: [WindowID: OverviewSurfaceFrame]
  let nativeFrames: [WindowID: CGRect]
  let projection: OverviewProjection
  private let nativeOwners: [WindowID: Int32]
  private let cornerRadius: CGFloat

  init?(
    projection: OverviewProjection, workspaceID: WorkspaceID, screen: NSScreen,
    surfaces: [WindowID: OverviewSurfaceFrame], windows: [WindowID: Window], cornerRadius: Double = 12
  ) {
    guard let workspace = projection.workspaces.first(where: { $0.workspaceID == workspaceID }),
      !workspace.windows.isEmpty, !surfaces.isEmpty,
      surfaces.keys.allSatisfy({ OverviewSurfaceCapture.shared.displayLayer(for: $0) != nil })
    else { return nil }
    let workspaceIDs = Set(workspace.windows.map(\.windowID)).intersection(surfaces.keys)
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
      guard workspaceIDs.contains(id), surfaces[id] != nil,
        let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
        windows[id]?.processID == owner.int32Value else { continue }
      owners[id] = owner.int32Value
      frames[id] = rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
      order[id] = index
    }
    guard workspaceIDs.allSatisfy({ frames[$0] != nil }) else { return nil }
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
    // Public CGWindow order is front to back; preserve floating/native stacking.
    for card in workspace.windows.sorted(by: {
      order[$0.windowID, default: 0] > order[$1.windowID, default: 0]
    }) {
      guard let frame = surfaces[card.windowID], let source = frames[card.windowID] else { continue }
      let target = CGRect(x: card.frame.x, y: card.frame.y,
        width: card.frame.width, height: card.frame.height)
      guard let item = OverviewSurfaceCapture.shared.displayLayer(for: card.windowID) else { return nil }
      item.removeFromSuperlayer(); item.removeAllAnimations()
      _ = enqueueWindowSurface(frame, on: item)
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
    self.entries = entries
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
