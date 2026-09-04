import AppKit
import DefiCore
import DefiModel

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
    if let url = NSWorkspace.shared.desktopImageURL(for: screen),
      let image = NSImage(contentsOf: url)
    {
      if usesCapturedDesktop {
        desktopView.layer?.contents = image
      }
      view.setDesktopImage(image)
    }
    let glassView = NSGlassEffectView(
      frame: NSRect(origin: .zero, size: screen.frame.size)
    )
    glassView.style = .regular
    glassView.appearance = NSAppearance(named: .darkAqua)
    glassView.autoresizingMask = [.width, .height]
    view.frame = glassView.bounds
    view.autoresizingMask = [.width, .height]
    glassView.contentView = view
    rootView.addSubview(desktopView)
    rootView.addSubview(glassView)
    window.contentView = rootView
  }

  func setDesktopImage(_ image: NSImage) {
    desktopView.layer?.contents = image
    view.setDesktopImage(image)
  }

  func show(animated: Bool) {
    window.alphaValue = animated ? 0.001 : 1
    view.wantsLayer = true
    view.layer?.setAffineTransform(animated ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity)
    window.orderFrontRegardless()
    guard animated else { return }
    window.displayIfNeeded()
    let displayInterval = 1 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 60))
    DispatchQueue.main.asyncAfter(deadline: .now() + displayInterval) { [weak self] in
      guard let self else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = overviewTransitionDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.window.animator().alphaValue = 1
        self.view.layer?.setAffineTransform(.identity)
      }
    }
  }

  func hide() {
    orderOut()
  }

  func localPoint(fromScreen point: NSPoint) -> NSPoint {
    let windowPoint = window.convertPoint(fromScreen: point)
    return view.convert(windowPoint, from: nil)
  }

  func close() {
    orderOut()
    desktopView.layer?.contents = nil
    window.close()
  }

  private func orderOut() {
    view.discardPreviewImages()
    window.orderOut(nil)
  }
}

