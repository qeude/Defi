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
  /// One window-sized fill under the ring, made on first use: the inactive dim.
  private var dimSurface: BorderSegment?
  private var dimOpacity: Float = 0
  /// Above every normal window while no other window overlaps this one; nil until known.
  private var dimElevated: Bool?
  var dimElevation: Bool? { dimElevated }
  private var hasRing = true
  private var targetWindowNumber: Int
  private let now: () -> TimeInterval
  private var stacking: WindowBorderStacking?
  private var surfaces: [BorderSegment] { Array(segments.values) + (dimSurface.map { [$0] } ?? []) }
  private var dimStacking: WindowBorderStacking? {
    guard dimElevated == true else { return stacking }
    return WindowBorderStacking(
      targetWindowID: WindowID(rawValue: UInt64(targetWindowNumber)), activeWindowIsFrontmost: true,
      upperBoundWindowID: nil, upperBoundLevel: elevatedWindowDimLevel)
  }
  private var windowFrame: Rect?
  private var width = -1.0
  private var color: UInt32 = 0
  private var radius = -1.0
  /// The window's own corner radius, which the dim follows.
  private var baseRadius = 0.0
  private var captureEnabled = false
  private var placement: WindowBorderPlacement = .inside
  private var visible = false
  private var opacityValue: Float = 0
  private var pendingOpacityReveal: Float?
  private var geometryNeedsRefresh = false

  var isVisible: Bool { visible }

  var estimatedSurfacePixels: Int {
    surfaces.reduce(0) { $0 + $1.estimatedSurfacePixels }
  }

  /// The ring's opacity: 0 while the overlay holds only a dim.
  var opacity: Double { hasRing ? Double(opacityValue) : 0 }

  var orderingCount: Int { surfaces.reduce(0) { $0 + $1.orderingCount } }

  var dim: Double { Double(dimOpacity) }

  var showsDim: Bool { visible && !isPresentationHidden && dimOpacity > 0 && dimSurface?.isShown == true }

  var windowLevelRawValues: [Int] {
    segments.values.map(\.windowLevelRawValue)
  }

  var upperBoundWindowNumbers: [Int?] {
    segments.values.map(\.upperBoundWindowNumber)
  }

  var windowIDs: Set<CGWindowID> {
    Set(
      surfaces.compactMap { panel in
        guard panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
      })
  }

  var ownedSurfaceWindowID: WindowID? {
    for segment in surfaces {
      guard let frame = segment.frame, frame.width > 0, frame.height > 0,
        segment.windowNumber > 0 else { continue }
      return WindowID(rawValue: UInt64(segment.windowNumber))
    }
    return nil
  }

  init(windowID: WindowID, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    let targetWindowNumber = Int(windowID.rawValue)
    self.targetWindowNumber = targetWindowNumber
    self.now = now
    segments = Dictionary(
      uniqueKeysWithValues: WindowBorderSegmentKind.allCases.map {
        ($0, BorderSegment(targetWindowNumber: targetWindowNumber, now: now))
      }
    )
  }

  private(set) var isPresentationHidden = false
  func setPresentationHidden(_ hidden: Bool) {
    isPresentationHidden = hidden
    for segment in surfaces { segment.setPresentationHidden(hidden) }
  }

  func retarget(to windowID: WindowID, preservingBacking: Bool = false) {
    if preservingBacking {
      // Reuse only during a synchronous selection handoff, never as a hidden cache.
      for segment in surfaces { segment.makeTransparent() }
      opacityValue = 0
      pendingOpacityReveal = nil
      visible = false
      geometryNeedsRefresh = true
    } else {
      compactBacking()
    }
    targetWindowNumber = Int(windowID.rawValue)
    for segment in surfaces {
      segment.retarget(to: targetWindowNumber)
    }
    setDimElevated(nil)
  }

  /// A nil color draws no ring, leaving only the dim.
  func sync(
    frame: Rect,
    width: Double,
    color: UInt32?,
    windowRadius: Double,
    captureEnabled: Bool,
    placement: WindowBorderPlacement
  ) {
    setRing(color != nil)
    _ = syncGeometry(
      frame: frame,
      width: width,
      windowRadius: windowRadius,
      captureEnabled: captureEnabled,
      placement: placement
    )
    if let color {
      updateAppearance(to: color)
    } else {
      _ = orderInTransparentIfNeeded()
    }
  }

  /// Takes the ring away and keeps the overlay, and its dim, on screen.
  func removeRing() {
    setRing(false)
    pendingOpacityReveal = nil
    opacityValue = 0
  }

  private func setRing(_ shown: Bool) {
    guard hasRing != shown else { return }
    hasRing = shown
    geometryNeedsRefresh = true
    guard let windowFrame else { return }
    _ = syncGeometry(
      frame: windowFrame, width: max(width, 0), windowRadius: baseRadius,
      captureEnabled: captureEnabled, placement: placement)
  }

  /// Fades a dim in when `animated`, and drops one at once, so the focused window brightens at once.
  func setDim(_ opacity: Float, animated: Bool) {
    guard opacity != dimOpacity else { return }
    let fades = animated && opacity > dimOpacity
    dimOpacity = opacity
    if opacity > 0, dimSurface == nil {
      let surface = BorderSegment(targetWindowNumber: targetWindowNumber, now: now, fills: true)
      surface.setPresentationHidden(isPresentationHidden)
      if let dimStacking { surface.setStacking(dimStacking) }
      dimSurface = surface
      syncDimGeometry(drawingChanged: true)
      if visible, surface.frame != nil { surface.ensureOrderedIn() }
    }
    if fades {
      dimSurface?.fadeOpacity(to: opacity, duration: windowDimFadeDuration)
    } else {
      dimSurface?.setOpacityImmediately(opacity)
    }
  }

  /// Closes the dim's panel once the dim is off, rather than keeping a clear one.
  func releaseDim() {
    guard let dimSurface else { return }
    dimSurface.close()
    self.dimSurface = nil
    dimOpacity = 0
  }

  private func syncDimGeometry(drawingChanged: Bool, moveBatch: BorderSurfaceMoveBatch? = nil) {
    guard let dimSurface, let windowFrame else { return }
    dimSurface.syncGeometry(
      WindowBorderSegmentGeometry(kind: .top, frame: windowFrame, pathOriginFromWindowBottom: .zero),
      windowFrame: windowFrame, width: 0, radius: baseRadius, captureEnabled: captureEnabled,
      drawingChanged: drawingChanged, moveBatch: moveBatch)
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
    let geometries =
      hasRing
      ? windowBorderSegmentGeometries(windowFrame: ringFrame, width: width, radius: radius) : []
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
    self.baseRadius = baseRadius
    self.captureEnabled = captureEnabled
    self.placement = placement
    syncDimGeometry(drawingChanged: drawingChanged || geometryNeedsRefresh, moveBatch: moveBatch)
    geometryNeedsRefresh = false
    return true
  }

  func updateAppearance(to color: UInt32) {
    setRing(true)
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
    setRing(true)
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
    for segment in surfaces { segment.close() }
  }

  func applyCompositorFallback() {
    guard visible else { return }
    for segment in surfaces where segment.frame != nil {
      segment.applyCompositorFallback()
    }
  }

  func setStacking(_ stacking: WindowBorderStacking) {
    self.stacking = stacking
    for segment in segments.values {
      segment.setStacking(stacking)
    }
    if let dimStacking { dimSurface?.setStacking(dimStacking) }
  }

  func setDimElevated(_ elevated: Bool?) {
    guard dimElevated != elevated else { return }
    dimElevated = elevated
    dimSurface?.setStacking(dimStacking ?? .inactive(for: WindowID(rawValue: UInt64(targetWindowNumber))))
  }

  /// Lowers an elevated dim the moment another window moves over this one.
  func lowerDim(ifOverlapping frame: Rect) {
    guard dimElevated == true, let windowFrame, targetIntersects(frame, monitor: windowFrame) else { return }
    setDimElevated(false)
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
    // After the ring: each surface orders just above the window, so the dim lies under the ring.
    if let dimSurface, dimSurface.frame != nil { dimSurface.ensureOrderedIn() }
    return true
  }

  private func setOpacityImmediately(_ opacity: Float) {
    opacityValue = opacity
    for segment in segments.values where segment.frame != nil {
      segment.setOpacityImmediately(opacity)
    }
  }

  private func compactBacking() {
    for segment in surfaces {
      segment.compactBacking()
    }
    dimOpacity = 0
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
  /// The dim's solid fill: a plain layer the compositor draws without a backing bitmap.
  private let fillLayer: CALayer?
  private var drawnLayer: CALayer { fillLayer ?? shapeLayer }
  private(set) var frame: Rect?
  private var backingScale = 1.0
  private var orderedIn = false
  private let now: () -> TimeInterval
  private var lastOrderedAt = -TimeInterval.infinity
  private(set) var orderingCount = 0
  private(set) var upperBoundWindowNumber: Int?

  var windowNumber: Int { panel.windowNumber }
  var windowLevelRawValue: Int { panel.level.rawValue }
  var isShown: Bool { orderedIn && frame != nil && panel.alphaValue > 0 && !rootView.isHidden }

  var estimatedSurfacePixels: Int {
    guard let frame else { return 0 }
    let pixelWidth = max(Int((frame.width * backingScale).rounded(.up)), 1)
    let pixelHeight = max(Int((frame.height * backingScale).rounded(.up)), 1)
    return pixelWidth * pixelHeight
  }

  init(targetWindowNumber: Int, now: @escaping () -> TimeInterval, fills: Bool = false) {
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
    if fills {
      let fill = CALayer()
      fill.backgroundColor = CGColor(gray: 0, alpha: 1)
      // A fade starts from the drawn opacity: a fresh fill must start clear, not black.
      fill.opacity = 0
      fillLayer = fill
      rootView.layer?.addSublayer(fill)
    } else {
      fillLayer = nil
      rootView.layer?.addSublayer(shapeLayer)
    }
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
        fillLayer?.frame = localBounds
      }
      if let fillLayer {
        fillLayer.cornerRadius = radius
        fillLayer.cornerCurve = .continuous
        CATransaction.commit()
        return finishSync(geometry: geometry, captureEnabled: captureEnabled, scale: scale)
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
    finishSync(geometry: geometry, captureEnabled: captureEnabled, scale: scale)
  }

  private func finishSync(geometry: WindowBorderSegmentGeometry, captureEnabled: Bool, scale: CGFloat) {
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
    // An unfinished fade would otherwise keep drawing its old target.
    stopFade()
    guard drawnLayer.opacity != opacity else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    drawnLayer.opacity = opacity
    CATransaction.commit()
  }

  private var fade: BorderOpacityFade?
  func fadeOpacity(to opacity: Float, duration: CFTimeInterval) {
    stopFade()
    fade = BorderOpacityFade(layer: drawnLayer, to: opacity, duration: duration, view: rootView)
  }

  private func stopFade() {
    fade?.stop()
    fade = nil
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
    stopFade()
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
    stopFade()
    drawnLayer.opacity = 0
    rootView.frame = compactBounds
    rootView.layer?.frame = compactBounds
    shapeLayer.frame = compactBounds
    fillLayer?.frame = compactBounds
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

let windowDimFadeDuration: CFTimeInterval = 0.15

/// Steps an opacity once per refresh: on these panels a Core Animation fade first drew its
/// end value, a dark flash.
@MainActor
private final class BorderOpacityFade: NSObject {
  private let layer: CALayer
  private let from: Float
  private let to: Float
  private let start = CACurrentMediaTime()
  private let duration: CFTimeInterval
  private var link: CADisplayLink?

  init(layer: CALayer, to: Float, duration: CFTimeInterval, view: NSView) {
    self.layer = layer
    from = layer.opacity
    self.to = to
    self.duration = max(duration, 0.001)
    super.init()
    let link = view.displayLink(target: self, selector: #selector(step))
    link.add(to: .main, forMode: .common)
    self.link = link
    // A panel off screen gets no refresh: the fade still ends.
    DispatchQueue.main.asyncAfter(deadline: .now() + self.duration + 0.1) { [weak self] in
      guard let self, self.link != nil else { return }
      self.apply(1)
    }
  }

  @objc private func step(_ link: CADisplayLink) {
    apply(Float(min((CACurrentMediaTime() - start) / duration, 1)))
  }

  private func apply(_ t: Float) {
    let eased = t < 0.5 ? 2 * t * t : 1 - (2 - 2 * t) * (2 - 2 * t) / 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = from + (to - from) * eased
    CATransaction.commit()
    if t >= 1 { stop() }
  }

  func stop() {
    link?.invalidate()
    link = nil
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
