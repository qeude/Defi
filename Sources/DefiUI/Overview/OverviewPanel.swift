import AppKit
import DefiCore
import DefiModel
import Metal
import DefiMacOS

@MainActor
protocol OverviewViewDelegate: AnyObject {
  func overviewView(_ view: OverviewView, clickedAt point: NSPoint)
  func overviewView(_ view: OverviewView, beganDragging windowID: WindowID, at: NSPoint)
  func overviewView(_ view: OverviewView, draggedTo: NSPoint)
  func overviewView(_ view: OverviewView, endedDraggingAt: NSPoint)
  func overviewView(
    _ view: OverviewView,
    scrolled delta: NSPoint,
    hasPreciseScrollingDeltas: Bool,
    at: NSPoint
  )
  func overviewView(_ view: OverviewView, rightDraggedBy deltaX: Double, at: NSPoint)
  func overviewView(_ view: OverviewView, pageWorkspace: WorkspaceID, direction: Int)
}

/// ProMotion: without a preference the compositor may settle for 60 Hz.
let overviewAnimationFrameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

@MainActor
final class OverviewPanel {
  static let wallpaperFadeDuration = 0.16
  let monitorID: MonitorID
  let usesCapturedDesktop: Bool
  let window: NSPanel
  let view: OverviewView
  private let desktopView: NSView
  private let rootView: NSView
  private let glassView: NSView
  private var surfaceScene: OverviewSurfaceScene?
  private var previewClosingScene: OverviewPreviewClosingScene?
  var hasSurfaceScene: Bool { surfaceScene != nil || previewClosingScene != nil }
  var surfacePresentedFrameCount: Int { surfaceScene?.presentedFrameCount ?? 0 }
  private var surfaceTask: Task<Void, Never>?
  private var invalidatedSurfaceWindowIDs = Set<WindowID>()
  private var surfaceGeneration: UInt64 = 0
  var openingTransitionChanged: ((String) -> Void)?
  private var openingTransitionInProgress = false {
    // Captures and window reads load the WindowServer that composites the zoom.
    didSet {
      guard oldValue != openingTransitionInProgress else { return }
      RibbonProxyStore.shared.setOverviewZooming(openingTransitionInProgress, monitorID)
    }
  }
  private var surfaceStartPending = false
  /// The fingers hold the zoom: a newer layout waits for them to let go.
  var surfaceHeld = false
  /// While the zoom runs, the menu bar and Dock show through the panel as much as the desktop does.
  private var chromeMask: (mask: CALayer, strips: [CALayer])?
  private lazy var presentationProbe = OverviewPresentationProbe(host: rootView.layer)
  // The captured desktop shown, forgotten with the images so a reopen shows it again.
  var capturedDesktop: CGImage?

  init(
    monitorID: MonitorID,
    screen: NSScreen,
    usesCapturedDesktop: Bool,
    delegate: OverviewViewDelegate
  ) {
    self.monitorID = monitorID
    self.usesCapturedDesktop = usesCapturedDesktop
    view = OverviewView(monitorID: monitorID, delegate: delegate)
    desktopView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    window = NSPanel(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    window.setFrame(screen.frame, display: false)
    window.title = "Defi Overview"
    window.setAccessibilityLabel("Defi Overview")
    window.isOpaque = usesCapturedDesktop
    window.backgroundColor = usesCapturedDesktop ? .black : .clear
    window.hasShadow = false
    window.hidesOnDeactivate = false
    window.isReleasedWhenClosed = false
    window.isExcludedFromWindowsMenu = true
    window.animationBehavior = .none
    window.level = .statusBar
    window.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    window.sharingType = .readOnly
    rootView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = usesCapturedDesktop
      ? NSColor.black.cgColor
      : NSColor.clear.cgColor
    rootView.autoresizingMask = [.width, .height]
    desktopView.wantsLayer = true
    desktopView.layer?.backgroundColor = usesCapturedDesktop
      ? NSColor.black.cgColor
      : NSColor.clear.cgColor
    desktopView.layer?.contentsGravity = .resizeAspectFill
    desktopView.layer?.contentsScale = screen.backingScaleFactor
    desktopView.layer?.masksToBounds = true
    desktopView.autoresizingMask = [.width, .height]
    let glassFrame = NSRect(origin: .zero, size: screen.frame.size)
    view.frame = glassFrame
    view.wantsLayer = true
    view.autoresizingMask = [.width, .height]
    if #available(macOS 26, *) {
      let glass = NSGlassEffectView(frame: glassFrame)
      glass.style = .regular
      glass.contentView = view
      glassView = glass
    } else {
      let material = NSVisualEffectView(frame: glassFrame)
      material.material = .hudWindow
      material.blendingMode = usesCapturedDesktop ? .withinWindow : .behindWindow
      material.state = .active
      material.addSubview(view)
      glassView = material
    }
    glassView.appearance = NSAppearance(named: .darkAqua)
    glassView.autoresizingMask = [.width, .height]
    rootView.addSubview(desktopView)
    rootView.addSubview(glassView)
    window.contentView = rootView
    rootView.layoutSubtreeIfNeeded()
  }

  func setDesktopImage(_ image: NSImage, fadeDuration: TimeInterval = 0) {
    if usesCapturedDesktop {
      if fadeDuration > 0, desktopView.layer?.contents != nil {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = fadeDuration
        transition.preferredFrameRateRange = overviewAnimationFrameRate
        desktopView.layer?.add(transition, forKey: "desktopImage")
      }
      desktopView.layer?.contents = image
    }
    view.setDesktopImage(image, fadeDuration: fadeDuration)
  }

  func show(fadeDuration: TimeInterval = 0) {
    cancelSurfaceTransition()
    restoreWallpaperFade()
    view.wantsLayer = true
    if fadeDuration > 0 {
      window.alphaValue = 0
      window.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = fadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 1
      }
    } else {
      window.alphaValue = 1
      window.orderFrontRegardless()
    }
  }

  func hide() {
    orderOut()
    cancelSurfaceTransition(reason: "hide")
    discardImages()
  }

  /// Shows the zoom's first pose, which matches the desktop; `startSurfaceSceneWhenPresented` moves it.
  /// Only a swipe cross-fades the menu bar and Dock: the mask and a non-opaque panel cost the
  /// first moving frame of a keyboard zoom 33-58 ms, so it covers and uncovers them at once.
  func presentSurfaceScene(_ scene: OverviewSurfaceScene, windowIDs: Set<WindowID>, fadesChrome: Bool) {
    cancelSurfaceTransition()
    restoreWallpaperFade()
    surfaceScene = scene
    openingTransitionInProgress = true
    openingTransitionChanged?("started(\(scene.openingContentDescription))")
    view.suppressedSurfaceWindowIDs = windowIDs
    // Not 0: the glass and its cards render once during the still first pose, so the first
    // moving frame of the zoom does not pay for them. The tint is invisible at this alpha.
    glassView.alphaValue = 0.002
    if fadesChrome { coverChrome(0, duration: 0) }
    rootView.layer?.addSublayer(scene.layer)
    window.alphaValue = 1
    window.orderFrontRegardless()
    window.displayIfNeeded()
    surfaceStartPending = true
  }

  /// Starts the zoom once its first pose is on screen. A cold panel can take several
  /// frames to appear, and a zoom whose clock ran meanwhile would show only its end.
  func startSurfaceSceneWhenPresented(duration: TimeInterval) {
    let generation = surfaceGeneration, requested = CACurrentMediaTime()
    surfaceTask = Task { [weak self] in
      // A late or missing report never holds the zoom longer than this.
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      self?.startSurfaceScene(duration: duration, generation: generation, requested: requested)
    }
    let reported = presentationProbe?.notifyWhenPresented { [weak self] in
      Task { @MainActor in
        self?.startSurfaceScene(duration: duration, generation: generation, requested: requested)
      }
    } ?? false
    if !reported { startSurfaceScene(duration: duration, generation: generation, requested: requested) }
  }

  private func startSurfaceScene(duration: TimeInterval, generation: UInt64, requested: CFTimeInterval) {
    guard surfaceStartPending, surfaceGeneration == generation else { return }
    openingTransitionChanged?("presented(ms:\(Int((CACurrentMediaTime() - requested) * 1_000)))")
    finishSurfaceOpening(duration: duration, lead: zoomLead)
  }

  /// How long a zoom from rest waits before it moves, unlike one the fingers already moved. The
  /// compositor takes about 60 ms to take in the new panel, and a zoom started sooner showed
  /// those 60 ms in three frames. On a display with adaptive refresh a still lead that long made
  /// the compositor run ribbon motions at 80 Hz, so the zoom waits two frames there.
  private var zoomLead: CFTimeInterval {
    let frames = 2 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 1))
    guard let screen = window.screen,
      screen.minimumRefreshInterval == screen.maximumRefreshInterval else { return frames }
    return max(frames, 0.06)
  }

  /// Holds the zoom where the fingers put it, `progress` of the way into the Overview.
  func setSurfaceProgress(_ progress: Double) {
    guard let scene = surfaceScene else { return }
    surfaceHeld = true
    surfaceStartPending = false
    surfaceTask?.cancel()
    surfaceTask = nil
    // About two trackpad samples: smooth at 120 Hz without trailing the fingers.
    let glide = 0.05
    scene.setProgress(progress, glide: glide)
    fadeGlass(to: progress, duration: glide)
    coverChrome(progress, duration: glide)
  }

  /// Plays the rest of the opening from the pose on screen.
  func finishSurfaceOpening(duration: TimeInterval, lead: CFTimeInterval = 0) {
    guard openingTransitionInProgress, let scene = surfaceScene else { return }
    let generation = surfaceGeneration
    surfaceStartPending = false
    surfaceTask?.cancel()
    scene.animate(opening: true, duration: duration, lead: lead)
    MotionSignpost.span("overview-zoom", duration, after: lead)
    fadeGlass(to: 1, duration: duration, lead: lead)
    if chromeMask != nil { coverChrome(1, duration: duration) }
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration + lead)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      uncoverChrome()
      openingTransitionInProgress = false
      openingTransitionChanged?("completed")
      glassView.alphaValue = 1
      view.suppressedSurfaceWindowIDs.subtract(scene.finishOpening())
      if scene.nativeFrames.isEmpty {
        scene.layer.removeFromSuperlayer()
        surfaceScene = nil
      }
      surfaceTask = nil
    }
  }

  func setFilterDimmed(_ ids: Set<WindowID>, animated: Bool) {
    surfaceScene?.setFilterDimmed(ids, animated: animated)
  }

  /// Lifts the open Overview's windows above its cards, so the fingers can zoom them back.
  func beginSurfaceClosing() -> Bool {
    guard !openingTransitionInProgress, let surfaceScene, let screen = window.screen,
      surfaceScene.matchesNativeFrames(screen: screen) else { return false }
    view.suppressedSurfaceWindowIDs = Set(surfaceScene.nativeFrames.keys)
    rootView.layer?.addSublayer(surfaceScene.layer)
    coverChrome(1, duration: 0)
    return true
  }

  /// Returns a zoom the fingers took back toward the desktop to the open Overview.
  func restoreSurfaceScene(duration: TimeInterval) {
    guard !openingTransitionInProgress, let surfaceScene else { return }
    surfaceScene.animate(opening: true, duration: duration)
    MotionSignpost.span("overview-zoom", duration)
    fadeGlass(to: 1, duration: duration)
    coverChrome(1, duration: duration)
    let generation = surfaceGeneration
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      uncoverChrome()
    }
  }

  func hideSurfaceSceneIfUnchanged(duration: TimeInterval, focusedWindowID: WindowID?, fromRest: Bool) -> Bool {
    guard let surfaceScene, let screen = window.screen,
      surfaceScene.matchesNativeFrames(screen: screen) else { return false }
    surfaceScene.focusedWindowID = focusedWindowID
    // After a few seconds open, the compositor held a zoom started at once on its first frame
    // for 40 to 70 ms: it starts after that instead, unless the scene is already moving.
    let lead = fromRest && !openingTransitionInProgress ? zoomLead : 0
    if openingTransitionInProgress {
      openingTransitionInProgress = false
      openingTransitionChanged?("interrupted(exit)")
    }
    surfaceTask?.cancel()
    surfaceGeneration &+= 1
    let generation = surfaceGeneration
    view.suppressedSurfaceWindowIDs = Set(surfaceScene.nativeFrames.keys)
    rootView.layer?.addSublayer(surfaceScene.layer)
    surfaceScene.animate(opening: false, duration: duration, lead: lead)
    MotionSignpost.span("overview-zoom", duration, after: lead)
    fadeGlass(to: 0, duration: duration, lead: lead)
    if chromeMask != nil { coverChrome(0, duration: duration) }
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration + lead)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      hide()
    }
    return true
  }

  func hidePreviewScene(_ scene: OverviewPreviewClosingScene, duration: TimeInterval, fromRest: Bool) {
    // The same compositor hold as the surface zoom's, unless a swipe already moved the scene.
    let lead = fromRest && !openingTransitionInProgress ? zoomLead : 0
    cancelSurfaceTransition()
    previewClosingScene = scene
    let generation = surfaceGeneration
    let zoomsWallpaper = scene.zoomsWallpaper
    rootView.layer?.addSublayer(scene.layer)
    scene.animate(duration: duration, lead: lead)
    MotionSignpost.span("overview-zoom", duration, after: lead)
    fadeGlass(to: 0, duration: duration, lead: lead)
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration + lead)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      if zoomsWallpaper { await fadeRevealingDesktop(generation: generation) } else { hide() }
    }
  }

  /// Fades the whole panel out, wallpaper included, ahead of a macOS Space slide it must not ride.
  func fadeOut() {
    cancelSurfaceTransition(reason: "fade-out")
    let generation = surfaceGeneration
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.duration = Self.wallpaperFadeDuration
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    fade.preferredFrameRateRange = overviewAnimationFrameRate
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window.isOpaque = false
    window.backgroundColor = .clear
    rootView.layer?.opacity = 0
    rootView.layer?.add(fade, forKey: "overview-wallpaper-fade")
    CATransaction.commit()
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(Self.wallpaperFadeDuration)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      hide()
    }
  }

  /// The panel covers the menu bar and Dock; cross-fade them in instead of popping.
  /// Core Animation keeps the fade smooth while the main thread is busy.
  private func fadeRevealingDesktop(generation: UInt64) async {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.duration = Self.wallpaperFadeDuration
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    fade.preferredFrameRateRange = overviewAnimationFrameRate
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Drop the opaque black backing so the fade reveals the real desktop instead of
    // dipping through black.
    window.isOpaque = false
    window.backgroundColor = .clear
    rootView.layer?.backgroundColor = NSColor.clear.cgColor
    desktopView.isHidden = true
    rootView.layer?.opacity = 0
    rootView.layer?.add(fade, forKey: "overview-wallpaper-fade")
    CATransaction.commit()
    do { try await Task.sleep(for: .seconds(Self.wallpaperFadeDuration)) } catch { return }
    guard !Task.isCancelled, surfaceGeneration == generation else { return }
    hide()
  }

  /// Compositor-driven with a 120 Hz preference: an AppKit animator stays on the main
  /// thread's clock and never asks ProMotion for more than 60 Hz.
  private func fadeGlass(to alpha: CGFloat, duration: TimeInterval, lead: CFTimeInterval = 0) {
    guard let layer = glassView.layer else { glassView.alphaValue = alpha; return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = (layer.presentation() ?? layer).opacity
    fade.duration = duration
    fade.preferredFrameRateRange = overviewAnimationFrameRate
    if lead > 0 {
      fade.beginTime = layer.convertTime(CACurrentMediaTime() + lead, from: nil)
      fade.fillMode = .backwards
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glassView.alphaValue = alpha
    layer.add(fade, forKey: "overview-glass-fade")
    CATransaction.commit()
  }

  /// Covers the menu bar and Dock `coverage` of the way, from 0 where they show as on the desktop.
  private func coverChrome(_ coverage: Double, duration: TimeInterval) {
    guard let rootLayer = rootView.layer, let screen = window.screen else { return }
    // A shown opaque panel, after a keyboard zoom: turning it non-opaque would flash the windows beneath.
    if chromeMask == nil, window.isVisible, window.isOpaque { return }
    let chrome = chromeMask ?? {
      let frame = screen.frame, visible = screen.visibleFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
      let bounds = CGRect(origin: .zero, size: frame.size)
      let strips = [
        CGRect(x: 0, y: visible.maxY, width: bounds.width, height: bounds.maxY - visible.maxY),
        CGRect(x: 0, y: 0, width: bounds.width, height: visible.minY),
        CGRect(x: 0, y: visible.minY, width: visible.minX, height: visible.height),
        CGRect(x: visible.maxX, y: visible.minY, width: bounds.maxX - visible.maxX, height: visible.height),
      ].filter { $0.width > 0 && $0.height > 0 }.map { rect in
        let strip = CALayer()
        strip.frame = rect
        strip.backgroundColor = NSColor.black.cgColor
        return strip
      }
      let mask = CALayer()
      mask.frame = bounds
      let body = CALayer()
      body.frame = visible
      body.backgroundColor = NSColor.black.cgColor
      mask.addSublayer(body)
      strips.forEach(mask.addSublayer)
      return (mask, strips)
    }()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if chromeMask == nil {
      chromeMask = chrome
      // The menu bar and Dock show only through a window that is not opaque.
      window.isOpaque = false
      window.backgroundColor = .clear
      rootLayer.mask = chrome.mask
    }
    for strip in chrome.strips {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = (strip.presentation() ?? strip).opacity
      fade.duration = duration
      fade.preferredFrameRateRange = overviewAnimationFrameRate
      strip.opacity = Float(coverage)
      if duration > 0 { strip.add(fade, forKey: "overview-chrome") } else { strip.removeAllAnimations() }
    }
    CATransaction.commit()
  }

  /// Drops the mask once the panel covers the menu bar and Dock again, or before it shows.
  private func uncoverChrome() {
    guard let chromeMask else { return }
    self.chromeMask = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if rootView.layer?.mask === chromeMask.mask { rootView.layer?.mask = nil }
    // The window stays non-opaque: turning it opaque and back while shown lets one frame
    // show the windows beneath, seen at closing over a full-screen window.
    CATransaction.commit()
  }

  private func cancelSurfaceTransition(reason: String = "replaced") {
    surfaceHeld = false
    if openingTransitionInProgress {
      openingTransitionInProgress = false
      openingTransitionChanged?("interrupted(\(reason))")
    }
    surfaceGeneration &+= 1
    surfaceStartPending = false
    surfaceTask?.cancel()
    surfaceTask = nil
    surfaceScene?.layer.removeFromSuperlayer()
    surfaceScene = nil
    previewClosingScene?.layer.removeFromSuperlayer()
    previewClosingScene = nil
    view.suppressedSurfaceWindowIDs = []
    glassView.layer?.removeAllAnimations()
    glassView.alphaValue = 1
  }

  // Reset only before ordering front; resetting while visible would flash the panel.
  private func restoreWallpaperFade() {
    uncoverChrome()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rootView.layer?.removeAnimation(forKey: "overview-wallpaper-fade")
    rootView.layer?.opacity = 1
    // No wallpaper captured yet: the real desktop shows through, not a black first frame.
    let hasWallpaper = usesCapturedDesktop && desktopView.layer?.contents != nil
    window.isOpaque = hasWallpaper
    window.backgroundColor = hasWallpaper ? .black : .clear
    let backing = (hasWallpaper ? NSColor.black : NSColor.clear).cgColor
    rootView.layer?.backgroundColor = backing
    desktopView.layer?.backgroundColor = backing
    desktopView.isHidden = false
    CATransaction.commit()
  }

  @discardableResult
  func invalidateSurfaceScene(ifProjectionChanged projection: OverviewProjection) -> Set<WindowID> {
    guard !surfaceHeld else { return [] }
    var ids = invalidatedSurfaceWindowIDs
    invalidatedSurfaceWindowIDs = []
    if let surfaceScene, surfaceScene.projection != projection {
      ids.formUnion(surfaceScene.nativeFrames.keys)
      let sceneLayer = surfaceScene.layer
      // Without the scene, the closing zoom falls back to the Overview's pictures.
      if !openingTransitionInProgress { openingTransitionChanged?("dropped(projection-changed)") }
      cancelSurfaceTransition(reason: "projection-changed")
      // The cards gain their titles below: the zoom's pictures dissolve instead of popping.
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.duration = 0.1
      fade.preferredFrameRateRange = overviewAnimationFrameRate
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      rootView.layer?.addSublayer(sceneLayer)
      sceneLayer.opacity = 0
      sceneLayer.add(fade, forKey: "overview-scene-fade")
      CATransaction.commit()
      Task {
        try? await Task.sleep(for: .seconds(fade.duration))
        sceneLayer.removeFromSuperlayer()
      }
    }
    return ids
  }

  func discardImages() {
    cancelSurfaceTransition()
    desktopView.layer?.contents = nil
    capturedDesktop = nil
    view.discardPreviewImages()
    view.setDesktopImage(nil)
  }

  func localPoint(fromScreen point: NSPoint) -> NSPoint {
    let windowPoint = window.convertPoint(fromScreen: point)
    return view.convert(windowPoint, from: nil)
  }

  func close() {
    cancelSurfaceTransition()
    orderOut()
    discardImages()
    window.close()
  }

  private func orderOut() {
    view.discardPreviewImages()
    window.orderOut(nil)
  }
}

/// Reports when the panel's next frame reaches the screen, through a one-pixel drawable.
@MainActor
final class OverviewPresentationProbe {
  private static let device = MTLCreateSystemDefaultDevice()
  private static let queue = device?.makeCommandQueue()
  private let layer = CAMetalLayer()

  init?(host: CALayer?) {
    guard let host, let device = Self.device else { return nil }
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.isOpaque = false
    layer.drawableSize = CGSize(width: 1, height: 1)
    layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    host.addSublayer(layer)
  }

  func notifyWhenPresented(_ handler: @escaping @Sendable () -> Void) -> Bool {
    guard let drawable = layer.nextDrawable(), let buffer = Self.queue?.makeCommandBuffer() else { return false }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    drawable.addPresentedHandler { _ in handler() }
    buffer.present(drawable)
    buffer.commit()
    return true
  }
}
