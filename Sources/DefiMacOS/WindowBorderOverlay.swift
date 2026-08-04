import AppKit
import DefiCore
import DefiModel
import QuartzCore

enum WindowBorderSegmentKind: CaseIterable, Sendable {
  case top
  case bottom
  case left
  case right
}

struct WindowBorderSegmentGeometry: Equatable, Sendable {
  let kind: WindowBorderSegmentKind
  let frame: Rect
  let pathOriginFromWindowBottom: CGPoint
}

func windowBorderSegmentGeometries(
  windowFrame: Rect,
  width: Double,
  radius: Double
) -> [WindowBorderSegmentGeometry] {
  guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
  let requestedBand = ceil(max(width * 2, radius + width, 1))
  let band = min(
    requestedBand,
    floor(min(windowFrame.width, windowFrame.height) / 2)
  )
  guard band > 0 else { return [] }

  let middleHeight = max(windowFrame.height - band * 2, 0)
  var geometries = [
    WindowBorderSegmentGeometry(
      kind: .top,
      frame: Rect(
        x: windowFrame.x,
        y: windowFrame.y,
        width: windowFrame.width,
        height: band
      ),
      pathOriginFromWindowBottom: CGPoint(
        x: 0,
        y: windowFrame.height - band
      )
    ),
    WindowBorderSegmentGeometry(
      kind: .bottom,
      frame: Rect(
        x: windowFrame.x,
        y: windowFrame.y + windowFrame.height - band,
        width: windowFrame.width,
        height: band
      ),
      pathOriginFromWindowBottom: .zero
    ),
  ]
  if middleHeight > 0 {
    geometries.append(
      WindowBorderSegmentGeometry(
        kind: .left,
        frame: Rect(
          x: windowFrame.x,
          y: windowFrame.y + band,
          width: band,
          height: middleHeight
        ),
        pathOriginFromWindowBottom: CGPoint(x: 0, y: band)
      )
    )
    geometries.append(
      WindowBorderSegmentGeometry(
        kind: .right,
        frame: Rect(
          x: windowFrame.x + windowFrame.width - band,
          y: windowFrame.y + band,
          width: band,
          height: middleHeight
        ),
        pathOriginFromWindowBottom: CGPoint(
          x: windowFrame.width - band,
          y: band
        )
      )
    )
  }
  return geometries
}

@MainActor
final class BorderOverlay {
  private let targetWindowNumber: Int
  private let segments: [WindowBorderSegmentKind: BorderSegment]
  private var windowFrame: Rect?
  private var width = -1.0
  private var color: UInt32 = 0
  private var radius = -1.0
  private var captureEnabled = false
  private var visible = false
  private var opacityValue: Float = 0
  private var pendingOpacityReveal: Float?

  var isVisible: Bool { visible }

  var estimatedSurfacePixels: Int {
    segments.values.reduce(0) { $0 + $1.estimatedSurfacePixels }
  }

  var opacity: Double { Double(opacityValue) }

  var windowLevelRawValues: [Int] {
    segments.values.map(\.windowLevelRawValue)
  }

  init(windowID: WindowID) {
    targetWindowNumber = Int(windowID.rawValue)
    segments = Dictionary(
      uniqueKeysWithValues: WindowBorderSegmentKind.allCases.map {
        ($0, BorderSegment(targetWindowNumber: Int(windowID.rawValue)))
      }
    )
  }

  func sync(
    frame: Rect,
    width: Double,
    color: UInt32,
    windowRadius: Double,
    captureEnabled: Bool
  ) {
    _ = syncGeometry(
      frame: frame,
      width: width,
      windowRadius: windowRadius,
      captureEnabled: captureEnabled
    )
    updateAppearance(to: color)
  }

  func syncGeometry(
    frame: Rect,
    width: Double,
    windowRadius: Double,
    captureEnabled: Bool
  ) -> Bool {
    let radius = borderCornerRadius(windowRadius: windowRadius)
    guard
      windowFrame != frame || self.width != width || self.radius != radius
        || self.captureEnabled != captureEnabled
    else {
      return false
    }
    let geometries = windowBorderSegmentGeometries(
      windowFrame: frame,
      width: width,
      radius: radius
    )
    let geometryByKind = Dictionary(
      uniqueKeysWithValues: geometries.map { ($0.kind, $0) }
    )
    for kind in WindowBorderSegmentKind.allCases {
      guard let segment = segments[kind] else { continue }
      guard let geometry = geometryByKind[kind] else {
        segment.compactBacking()
        continue
      }
      segment.syncGeometry(
        geometry,
        windowFrame: frame,
        width: width,
        radius: radius,
        captureEnabled: captureEnabled,
        directMovementEnabled: false
      )
    }
    windowFrame = frame
    self.width = width
    self.radius = radius
    self.captureEnabled = captureEnabled
    return true
  }

  func updateAppearance(to color: UInt32) {
    let opacity = borderOpacity(color)
    updateColor(color)
    if orderInTransparentIfNeeded() {
      pendingOpacityReveal = opacity
      return
    }
    if pendingOpacityReveal != nil {
      self.pendingOpacityReveal = opacity
      return
    }
    setOpacityImmediately(opacity)
  }

  func prepareReveal(to color: UInt32) {
    updateColor(color)
    _ = orderInTransparentIfNeeded()
    pendingOpacityReveal = borderOpacity(color)
  }

  func revealPendingOpacity() {
    guard let pendingOpacityReveal else { return }
    self.pendingOpacityReveal = nil
    setOpacityImmediately(pendingOpacityReveal)
  }

  func hide() {
    compactBacking()
  }

  func applyCompositorFallback() {
    guard visible else { return }
    for segment in segments.values where segment.frame != nil {
      segment.applyCompositorFallback()
    }
  }

  func setFrontmost(_ frontmost: Bool) {
    for segment in segments.values {
      segment.setFrontmost(frontmost)
    }
  }

  private func updateColor(_ color: UInt32) {
    guard self.color != color else { return }
    for segment in segments.values {
      segment.setColor(color)
    }
    self.color = color
  }

  private func orderInTransparentIfNeeded() -> Bool {
    guard !visible else { return false }
    opacityValue = 0
    visible = true
    for segment in segments.values where segment.frame != nil {
      segment.setOpacityImmediately(0)
      segment.ensureOrderedIn()
    }
    return true
  }

  private func setOpacityImmediately(_ opacity: Float) {
    opacityValue = opacity
    for segment in segments.values where segment.frame != nil {
      segment.setOpacityImmediately(opacity)
    }
  }

  private func compactBacking() {
    for segment in segments.values {
      segment.compactBacking()
    }
    windowFrame = nil
    opacityValue = 0
    pendingOpacityReveal = nil
    visible = false
  }

}

@MainActor
private final class BorderSegment {
  private let targetWindowNumber: Int
  private let panel: NSPanel
  private let rootView: NSView
  private let shapeLayer = CAShapeLayer()
  private(set) var frame: Rect?
  private var backingScale = 1.0
  private var orderedIn = false

  var windowNumber: Int { panel.windowNumber }
  var windowLevelRawValue: Int { panel.level.rawValue }

  var estimatedSurfacePixels: Int {
    guard let frame else { return 0 }
    let pixelWidth = max(Int((frame.width * backingScale).rounded(.up)), 1)
    let pixelHeight = max(Int((frame.height * backingScale).rounded(.up)), 1)
    return pixelWidth * pixelHeight
  }

  init(targetWindowNumber: Int) {
    self.targetWindowNumber = targetWindowNumber
    panel = NSPanel(
      contentRect: .zero,
      styleMask: [.nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    rootView = NSView(frame: .zero)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.sharingType = .none
    panel.level = .normal
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .stationary,
      .ignoresCycle,
      .fullScreenAuxiliary,
      .transient,
    ]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.alphaValue = 0
    rootView.wantsLayer = true
    rootView.layer?.masksToBounds = true
    rootView.layer?.addSublayer(shapeLayer)
    shapeLayer.fillColor = NSColor.clear.cgColor
    shapeLayer.lineCap = .butt
    shapeLayer.lineJoin = .round
    panel.contentView = rootView
  }

  func syncGeometry(
    _ geometry: WindowBorderSegmentGeometry,
    windowFrame: Rect,
    width: Double,
    radius: Double,
    captureEnabled: Bool,
    directMovementEnabled: Bool
  ) {
    let previousFrame = frame
    let sizeChanged =
      previousFrame?.width != geometry.frame.width
      || previousFrame?.height != geometry.frame.height
    let scale = screenScale(for: geometry.frame)
    let scaleChanged = backingScale != scale
    let localBounds = CGRect(
      x: 0,
      y: 0,
      width: geometry.frame.width,
      height: geometry.frame.height
    )
    if previousFrame == nil || sizeChanged || scaleChanged
      || !directMovementEnabled
    {
      panel.setFrame(appKitRect(for: geometry.frame), display: false)
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rootView.layer?.contentsScale = scale
    shapeLayer.contentsScale = scale
    if previousFrame == nil || sizeChanged {
      rootView.frame = localBounds
      rootView.layer?.frame = localBounds
      shapeLayer.frame = localBounds
    }
    let strokeInset = width / 2
    let pathRect = CGRect(
      x: strokeInset - geometry.pathOriginFromWindowBottom.x,
      y: strokeInset - geometry.pathOriginFromWindowBottom.y,
      width: max(windowFrame.width - width, 0),
      height: max(windowFrame.height - width, 0)
    )
    let strokeRadius = max(radius - strokeInset, 0)
    shapeLayer.path = CGPath(
      roundedRect: pathRect,
      cornerWidth: strokeRadius,
      cornerHeight: strokeRadius,
      transform: nil
    )
    shapeLayer.lineWidth = width
    CATransaction.commit()

    if panel.sharingType != (captureEnabled ? .readOnly : .none) {
      panel.sharingType = captureEnabled ? .readOnly : .none
    }
    frame = geometry.frame
    backingScale = scale
  }

  func setColor(_ value: UInt32) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shapeLayer.strokeColor =
      NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: 1
      ).cgColor
    CATransaction.commit()
  }

  func setOpacityImmediately(_ opacity: Float) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shapeLayer.opacity = opacity
    CATransaction.commit()
  }

  func ensureOrderedIn() {
    guard !orderedIn else { return }
    panel.alphaValue = 0
    panel.order(.above, relativeTo: targetWindowNumber)
    orderedIn = true
  }

  func setFrontmost(_ frontmost: Bool) {
    let level: NSWindow.Level = frontmost ? .floating : .normal
    guard panel.level != level else { return }
    panel.level = level
    if frontmost == false, orderedIn {
      panel.order(.above, relativeTo: targetWindowNumber)
    }
  }

  func applyCompositorFallback() {
    guard let frame else { return }
    panel.setFrame(appKitRect(for: frame), display: false)
    ensureOrderedIn()
    panel.alphaValue = 1
    panel.order(.above, relativeTo: targetWindowNumber)
  }

  func compactBacking() {
    panel.alphaValue = 0
    if orderedIn {
      panel.orderOut(nil)
    }
    let compactBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shapeLayer.opacity = 0
    rootView.frame = compactBounds
    rootView.layer?.frame = compactBounds
    shapeLayer.frame = compactBounds
    shapeLayer.path = nil
    CATransaction.commit()
    panel.setFrame(compactBounds, display: false)
    frame = nil
    backingScale = 1
    orderedIn = false
  }

  private func appKitRect(for frame: Rect) -> CGRect {
    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(
      x: frame.x,
      y: mainTop - frame.y - frame.height,
      width: frame.width,
      height: frame.height
    )
  }

  private func screenScale(for frame: Rect) -> CGFloat {
    let center = CGPoint(
      x: frame.x + frame.width / 2,
      y: frame.y + frame.height / 2
    )
    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
    let appKitCenter = CGPoint(x: center.x, y: mainTop - center.y)
    return NSScreen.screens.first {
      $0.frame.contains(appKitCenter)
    }?.backingScaleFactor ?? 1
  }
}
