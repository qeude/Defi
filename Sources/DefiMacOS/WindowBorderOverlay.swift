import AppKit
import DefiCore
import DefiModel
import QuartzCore

/// Collects pure origin moves so all edges of all overlays move in one transaction.
@MainActor
final class BorderSurfaceMoveBatch {
  struct Commit: Equatable {
    let targetWindowNumber: Int
    let windowNumber: UInt32
    let frame: Rect
  }

  private(set) var moves: [BorderSurfaceMove] = []
  private var completions: [(Bool) -> Void] = []
  /// Every edge committed this pass, by either path.
  private(set) var commits: [Commit] = []

  func append(_ move: BorderSurfaceMove, completion: @escaping (Bool) -> Void) {
    moves.append(move)
    completions.append(completion)
  }

  func recordCommit(_ commit: Commit) {
    commits.append(commit)
  }

  func complete(moved: Bool) {
    for completion in completions { completion(moved) }
  }
}

@MainActor
final class BorderOverlay {
  private let segments: [WindowBorderSegmentKind: BorderSegment]
  private var windowFrame: Rect?
  private var width = -1.0
  private var color: UInt32 = 0
  private var radius = -1.0
  private var captureEnabled = false
  private var placement: WindowBorderPlacement = .inside
  private var visible = false
  private var opacityValue: Float = 0
  private var pendingOpacityReveal: Float?
  private var geometryNeedsRefresh = false

  var isVisible: Bool { visible }

  var estimatedSurfacePixels: Int {
    segments.values.reduce(0) { $0 + $1.estimatedSurfacePixels }
  }

  var opacity: Double { Double(opacityValue) }

  var orderingCount: Int { segments.values.reduce(0) { $0 + $1.orderingCount } }

  var windowLevelRawValues: [Int] {
    segments.values.map(\.windowLevelRawValue)
  }

  var upperBoundWindowNumbers: [Int?] {
    segments.values.map(\.upperBoundWindowNumber)
  }

  var windowIDs: Set<CGWindowID> {
    Set(
      segments.values.compactMap { panel in
        guard panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
      })
  }

  var ownedSurfaceWindowID: WindowID? {
    for segment in segments.values {
      guard let frame = segment.frame, frame.width > 0, frame.height > 0,
        segment.windowNumber > 0 else { continue }
      return WindowID(rawValue: UInt64(segment.windowNumber))
    }
    return nil
  }

  init(windowID: WindowID, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    let targetWindowNumber = Int(windowID.rawValue)
    segments = Dictionary(
      uniqueKeysWithValues: WindowBorderSegmentKind.allCases.map {
        ($0, BorderSegment(targetWindowNumber: targetWindowNumber, now: now))
      }
    )
  }

  private(set) var isPresentationHidden = false
  func setPresentationHidden(_ hidden: Bool) {
    isPresentationHidden = hidden
    for segment in segments.values { segment.setPresentationHidden(hidden) }
  }

  func retarget(to windowID: WindowID, preservingBacking: Bool = false) {
    if preservingBacking {
      // Reuse only during a synchronous selection handoff, never as a hidden cache.
      for segment in segments.values { segment.makeTransparent() }
      opacityValue = 0
      pendingOpacityReveal = nil
      visible = false
      geometryNeedsRefresh = true
    } else {
      compactBacking()
    }
    let targetWindowNumber = Int(windowID.rawValue)
    for segment in segments.values {
      segment.retarget(to: targetWindowNumber)
    }
  }

  func sync(
    frame: Rect,
    width: Double,
    color: UInt32,
    windowRadius: Double,
    captureEnabled: Bool,
    placement: WindowBorderPlacement
  ) {
    _ = syncGeometry(
      frame: frame,
      width: width,
      windowRadius: windowRadius,
      captureEnabled: captureEnabled,
      placement: placement
    )
    updateAppearance(to: color)
  }

  func syncGeometry(
    frame: Rect,
    width: Double,
    windowRadius: Double,
    captureEnabled: Bool,
    placement: WindowBorderPlacement = .inside,
    moveBatch: BorderSurfaceMoveBatch? = nil
  ) -> Bool {
    let baseRadius = borderCornerRadius(windowRadius: windowRadius)
    // The outside ring renders against a frame expanded by the stroke width;
    // its corner radius grows by the same outset so the stroke keeps hugging
    // the real window curvature.
    let radius = placement == .outside ? baseRadius + width : baseRadius
    let drawingChanged =
      windowFrame?.width != frame.width
      || windowFrame?.height != frame.height || self.width != width
      || self.radius != radius || self.placement != placement
    guard
      windowFrame != frame || self.width != width || self.radius != radius
        || self.captureEnabled != captureEnabled || self.placement != placement
        || geometryNeedsRefresh
    else {
      return false
    }
    let outset = placement == .outside ? width : 0
    let ringFrame = Rect(
      x: frame.x - outset,
      y: frame.y - outset,
      width: frame.width + outset * 2,
      height: frame.height + outset * 2
    )
    let geometries = windowBorderSegmentGeometries(
      windowFrame: ringFrame,
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
        windowFrame: ringFrame,
        width: width,
        radius: radius,
        captureEnabled: captureEnabled,
        drawingChanged: drawingChanged,
        moveBatch: moveBatch
      )
    }
    windowFrame = frame
    self.width = width
    self.radius = radius
    self.captureEnabled = captureEnabled
    self.placement = placement
    geometryNeedsRefresh = false
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

  /// Takes the compacted panels off screen before the overlay is released.
  func close() {
    for segment in segments.values { segment.close() }
  }

  func applyCompositorFallback() {
    guard visible else { return }
    for segment in segments.values where segment.frame != nil {
      segment.applyCompositorFallback()
    }
  }

  func setStacking(_ stacking: WindowBorderStacking) {
    for segment in segments.values {
      segment.setStacking(stacking)
    }
  }

  /// Edge frames this overlay would commit for `windowFrame` with its current style.
  func expectedEdgeFrames(for windowFrame: Rect) -> [UInt32: Rect] {
    guard visible, width > 0 else { return [:] }
    return windowBorderSegmentGeometries(
      windowFrame: windowFrame, width: width, radius: radius, placement: placement
    ).reduce(into: [:]) { result, geometry in
      guard let segment = segments[geometry.kind], segment.frame != nil,
        let number = UInt32(exactly: segment.windowNumber)
      else { return }
      result[number] = geometry.frame
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
  private var targetWindowNumber: Int
  private let panel: NSPanel
  private let rootView: NSView
  private let shapeLayer = CAShapeLayer()
  private(set) var frame: Rect?
  private var backingScale = 1.0
  private var orderedIn = false
  private let now: () -> TimeInterval
  private var lastOrderedAt = -TimeInterval.infinity
  private(set) var orderingCount = 0
  private(set) var upperBoundWindowNumber: Int?

  var windowNumber: Int { panel.windowNumber }
  var windowLevelRawValue: Int { panel.level.rawValue }

  var estimatedSurfacePixels: Int {
    guard let frame else { return 0 }
    let pixelWidth = max(Int((frame.width * backingScale).rounded(.up)), 1)
    let pixelHeight = max(Int((frame.height * backingScale).rounded(.up)), 1)
    return pixelWidth * pixelHeight
  }

  init(targetWindowNumber: Int, now: @escaping () -> TimeInterval) {
    self.targetWindowNumber = targetWindowNumber
    self.now = now
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
    // No .fullScreenAuxiliary: borders of other windows must stay off fullscreen Spaces.
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .stationary,
      .ignoresCycle,
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

  func setPresentationHidden(_ hidden: Bool) {
    // Both: AppKit rewrites a layer-backed view's layer visibility on its next update,
    // which brought the ring back mid-drag, while the view alone reached the screen
    // frames late, after the overlay that stood in for it had faded.
    rootView.isHidden = hidden
    rootView.layer?.isHidden = hidden
  }

  func retarget(to targetWindowNumber: Int) {
    self.targetWindowNumber = targetWindowNumber
    lastOrderedAt = -.infinity
  }

  func syncGeometry(
    _ geometry: WindowBorderSegmentGeometry,
    windowFrame: Rect,
    width: Double,
    radius: Double,
    captureEnabled: Bool,
    drawingChanged: Bool,
    moveBatch: BorderSurfaceMoveBatch? = nil
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
    if previousFrame != geometry.frame || scaleChanged {
      let target = geometry.frame
      if let moveBatch, previousFrame != nil, !sizeChanged, !scaleChanged,
        let windowNumber = UInt32(exactly: panel.windowNumber), windowNumber > 0
      {
        moveBatch.append(
          BorderSurfaceMove(windowNumber: windowNumber, origin: CGPoint(x: target.x, y: target.y))
        ) { [weak self] moved in
          self?.completeWindowServerMove(moved: moved)
        }
      } else {
        panel.setFrame(appKitRect(for: target), display: false)
      }
      if let windowNumber = UInt32(exactly: panel.windowNumber), windowNumber > 0 {
        moveBatch?.recordCommit(
          .init(targetWindowNumber: targetWindowNumber, windowNumber: windowNumber, frame: target))
      }
    }

    if drawingChanged || previousFrame == nil || sizeChanged || scaleChanged {
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
    }

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
    guard shapeLayer.opacity != opacity else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shapeLayer.opacity = opacity
    CATransaction.commit()
  }

  func ensureOrderedIn() {
    guard !orderedIn else { return }
    panel.alphaValue = 0
    orderForCurrentStacking()
    orderedIn = true
  }

  func setStacking(_ stacking: WindowBorderStacking) {
    let level = resolvedBorderWindowLevel(for: stacking)
    let upperBoundWindowNumber = stacking.upperBoundWindowID.flatMap {
      Int(exactly: $0.rawValue)
    }
    guard
      panel.level != level
        || self.upperBoundWindowNumber != upperBoundWindowNumber
    else {
      return
    }
    panel.level = level
    self.upperBoundWindowNumber = upperBoundWindowNumber
    if orderedIn {
      orderForCurrentStacking()
    }
  }

  /// Keeps AppKit's cached frame equal to WindowServer after a SkyLight move, so
  /// later setFrame calls and drift checks never act on a stale position.
  private func completeWindowServerMove(moved: Bool) {
    guard let frame else { return }
    if moved {
      AppKitWindowFrameCache.refresh(panel)
    } else {
      // Re-apply the authoritative frame, never a frame captured earlier.
      panel.setFrame(appKitRect(for: frame), display: false)
    }
  }

  func applyCompositorFallback() {
    guard let frame else { return }
    // The cache is coherent (see completeWindowServerMove); repair only external drift.
    let expectedFrame = appKitRect(for: frame)
    if !appKitFramesMatch(panel.frame, expectedFrame) {
      panel.setFrame(expectedFrame, display: false)
    }
    let wasOrderedIn = orderedIn
    ensureOrderedIn()
    if panel.alphaValue != 1 { panel.alphaValue = 1 }
    if wasOrderedIn, now() - lastOrderedAt >= 1 { orderForCurrentStacking() }
  }

  func orderOut() {
    makeTransparent()
    if orderedIn {
      panel.orderOut(nil)
    }
    orderedIn = false
  }

  func makeTransparent() {
    if panel.alphaValue != 0 { panel.alphaValue = 0 }
  }

  func close() {
    panel.orderOut(nil)
    orderedIn = false
  }

  func compactBacking() {
    guard frame != nil else { return }
    // Transparent and one point large, the panel can stay ordered in: ordering it out
    // waits for a WindowServer transaction, tens of milliseconds on the main thread.
    makeTransparent()
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
    // Still on screen, but ordered again against its next window once reused.
    orderedIn = false
  }

  private func orderForCurrentStacking() {
    lastOrderedAt = now()
    orderingCount += 1
    if let upperBoundWindowNumber {
      panel.order(.below, relativeTo: upperBoundWindowNumber)
    } else {
      panel.order(.above, relativeTo: targetWindowNumber)
    }
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

private func appKitFramesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
  abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5
    && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
}

private func resolvedBorderWindowLevel(
  for stacking: WindowBorderStacking
) -> NSWindow.Level {
  guard stacking.activeWindowIsFrontmost else { return .normal }
  return NSWindow.Level(
    rawValue: min(
      stacking.upperBoundLevel ?? NSWindow.Level.floating.rawValue,
      NSWindow.Level.floating.rawValue
    )
  )
}
