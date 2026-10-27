import AppKit
import DefiCore
import DefiModel
import Metal

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

@MainActor
final class OverviewPanel {
  private static let wallpaperFadeDuration = 0.16
  let monitorID: MonitorID
  let usesCapturedDesktop: Bool
  let window: NSPanel
  let view: OverviewView
  private let desktopView: NSView
  private let rootView: NSView
  private let glassView: NSGlassEffectView
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
    glassView = NSGlassEffectView(
      frame: NSRect(origin: .zero, size: screen.frame.size)
    )
    glassView.style = .regular
    glassView.appearance = NSAppearance(named: .darkAqua)
    glassView.autoresizingMask = [.width, .height]
    view.frame = glassView.bounds
    view.wantsLayer = true
    view.autoresizingMask = [.width, .height]
    glassView.contentView = view
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
    cancelSurfaceTransition(reason: "hide")
    orderOut()
    discardImages()
  }

  /// Shows the zoom's first pose, which matches the desktop; `startSurfaceSceneWhenPresented` moves it.
  func presentSurfaceScene(_ scene: OverviewSurfaceScene, windowIDs: Set<WindowID>) {
    cancelSurfaceTransition()
    restoreWallpaperFade()
    surfaceScene = scene
    openingTransitionInProgress = true
    openingTransitionChanged?("started(\(scene.openingContentDescription))")
    view.suppressedSurfaceWindowIDs = windowIDs
    glassView.alphaValue = 0
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
    guard surfaceStartPending, surfaceGeneration == generation, let scene = surfaceScene else { return }
    surfaceStartPending = false
    surfaceTask?.cancel()
    openingTransitionChanged?("presented(ms:\(Int((CACurrentMediaTime() - requested) * 1_000)))")
    scene.animate(opening: true, duration: duration)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      glassView.animator().alphaValue = 1
    }
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
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

  func hideSurfaceSceneIfUnchanged(duration: TimeInterval) -> Bool {
    guard let surfaceScene, let screen = window.screen,
      surfaceScene.matchesNativeFrames(screen: screen) else { return false }
    if openingTransitionInProgress {
      openingTransitionInProgress = false
      openingTransitionChanged?("interrupted(exit)")
    }
    surfaceTask?.cancel()
    surfaceGeneration &+= 1
    let generation = surfaceGeneration
    view.suppressedSurfaceWindowIDs = Set(surfaceScene.nativeFrames.keys)
    rootView.layer?.addSublayer(surfaceScene.layer)
    surfaceScene.animate(opening: false, duration: duration)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      glassView.animator().alphaValue = 0
    }
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      hide()
    }
    return true
  }

  func hidePreviewScene(_ scene: OverviewPreviewClosingScene, duration: TimeInterval) {
    cancelSurfaceTransition()
    previewClosingScene = scene
    let generation = surfaceGeneration
    let zoomsWallpaper = scene.zoomsWallpaper
    rootView.layer?.addSublayer(scene.layer)
    scene.animate(duration: duration)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      glassView.animator().alphaValue = 0
    }
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      if zoomsWallpaper {
        // The panel covers the menu bar and Dock; cross-fade them in instead of popping.
        // Core Animation keeps the fade smooth while the main thread is busy.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.duration = Self.wallpaperFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The zoomed wallpaper covers the screen; drop the opaque black backing so
        // the fade reveals the real desktop instead of dipping through black.
        window.isOpaque = false
        window.backgroundColor = .clear
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        desktopView.isHidden = true
        rootView.layer?.opacity = 0
        rootView.layer?.add(fade, forKey: "overview-wallpaper-fade")
        CATransaction.commit()
        do { try await Task.sleep(for: .seconds(Self.wallpaperFadeDuration)) } catch { return }
        guard !Task.isCancelled, surfaceGeneration == generation else { return }
      }
      hide()
    }
  }

  private func cancelSurfaceTransition(reason: String = "replaced") {
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
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rootView.layer?.removeAnimation(forKey: "overview-wallpaper-fade")
    rootView.layer?.opacity = 1
    window.isOpaque = usesCapturedDesktop
    window.backgroundColor = usesCapturedDesktop ? .black : .clear
    rootView.layer?.backgroundColor = usesCapturedDesktop
      ? NSColor.black.cgColor
      : NSColor.clear.cgColor
    desktopView.isHidden = false
    CATransaction.commit()
  }

  @discardableResult
  func invalidateSurfaceScene(ifProjectionChanged projection: OverviewProjection) -> Set<WindowID> {
    var ids = invalidatedSurfaceWindowIDs
    invalidatedSurfaceWindowIDs = []
    if let surfaceScene, surfaceScene.projection != projection {
      ids.formUnion(surfaceScene.nativeFrames.keys)
      cancelSurfaceTransition(reason: "projection-changed")
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
