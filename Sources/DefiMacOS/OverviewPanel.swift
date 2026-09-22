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
    let rootView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
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
    let glassView = NSGlassEffectView(
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

  func setDesktopImage(_ image: NSImage) {
    desktopImageTask?.cancel()
    desktopImageTask = nil
    desktopView.layer?.contents = image
    view.setDesktopImage(image)
  }

  func show() {
    window.alphaValue = 1
    view.wantsLayer = true
    window.orderFrontRegardless()
    guard desktopView.layer?.contents == nil else { return }
    desktopImageTask?.cancel()
    desktopImageTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let screen = self?.window.screen,
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
      else { return }
      let maximumSize = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
      let image = await Task.detached(priority: .utility) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maximumSize,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
      }.value
      guard !Task.isCancelled, let self, self.window.isVisible, let image else { return }
      self.setDesktopImage(NSImage(cgImage: image, size: screen.frame.size))
    }
  }

  func hide() {
    orderOut()
  }

  func discardImages() {
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
