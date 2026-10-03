import AppKit
import DefiCore
import DefiModel
import ImageIO

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
  private var desktopImageTask: Task<Void, Never>?

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
    desktopImageTask?.cancel()
    desktopImageTask = nil
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
    loadWallpaperIfNeeded()
  }

  // Decoded ahead of the first open so the panel never shows black while the wallpaper loads.
  func loadWallpaperIfNeeded() {
    guard !view.hasDesktopImage, desktopImageTask == nil else { return }
    desktopImageTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let screen = self?.window.screen,
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
      else { return }
      let maximumSize = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
      let image = await Task.detached(priority: .utility) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maximumSize,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
      }.value
      guard !Task.isCancelled, let self else { return }
      self.desktopImageTask = nil
      guard !self.view.hasDesktopImage, let image else { return }
      self.setDesktopImage(NSImage(cgImage: image, size: screen.frame.size))
    }
  }

  func hide() {
    cancelSurfaceTransition()
    orderOut()
    discardImages()
  }

  func showSurfaceScene(_ scene: OverviewSurfaceScene, windowIDs: Set<WindowID>, duration: TimeInterval) {
    cancelSurfaceTransition()
    surfaceScene = scene
    let generation = surfaceGeneration
    view.suppressedSurfaceWindowIDs = windowIDs
    glassView.alphaValue = 0
    rootView.layer?.addSublayer(scene.layer)
    window.alphaValue = 1
    window.orderFrontRegardless()
    scene.animate(opening: true, duration: duration)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      glassView.animator().alphaValue = 1
    }
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      glassView.alphaValue = 1
      surfaceTask = nil
    }
  }

  func hideSurfaceSceneIfUnchanged(duration: TimeInterval) -> Bool {
    guard let surfaceScene, let screen = window.screen,
      surfaceScene.matchesNativeFrames(screen: screen) else { return false }
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
    rootView.layer?.addSublayer(scene.layer)
    scene.animate(duration: duration)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      glassView.animator().alphaValue = 0
    }
    surfaceTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      guard !Task.isCancelled, let self, surfaceGeneration == generation else { return }
      hide()
    }
  }

  private func cancelSurfaceTransition() {
    surfaceGeneration &+= 1
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

  @discardableResult
  func invalidateSurfaceScene(ifProjectionChanged projection: OverviewProjection) -> Set<WindowID> {
    var ids = invalidatedSurfaceWindowIDs
    invalidatedSurfaceWindowIDs = []
    if let surfaceScene, surfaceScene.projection != projection {
      ids.formUnion(surfaceScene.nativeFrames.keys)
      cancelSurfaceTransition()
    }
    return ids
  }

  func discardImages() {
    cancelSurfaceTransition()
    desktopImageTask?.cancel()
    desktopImageTask = nil
    desktopView.layer?.contents = nil
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
    desktopImageTask?.cancel()
    desktopImageTask = nil
    view.discardPreviewImages()
    window.orderOut(nil)
  }
}
