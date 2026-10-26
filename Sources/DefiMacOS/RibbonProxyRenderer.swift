import AppKit
import CoreMedia
import CoreVideo
import DefiCore
import DefiModel
import DefiRuntime
import OSLog
import QuartzCore
import ScreenCaptureKit
import VideoToolbox

let ribbonProxyLogger = Logger(subsystem: "com.qeude.defi", category: "ribbon-proxy")

struct RibbonProxyWindow {
  let id: WindowID
  let appID: String
  let processID: Int32
  let from: Rect
  let to: Rect
  var appears = false
}

/// Pictures stay valid only for the native size they were captured at.
func ribbonProxyPictureMatches(captured: CGSize, native: Rect) -> Bool {
  abs(captured.width - native.width) < 3 && abs(captured.height - native.height) < 3
}

/// The overlay may lift once every visible native window sits on its target.
func ribbonProxyLanded(native: [WindowID: Rect], targets: [WindowID: Rect]) -> Bool {
  targets.allSatisfy { id, target in
    // Closed: nothing left to land, and its picture must not linger.
    guard let frame = native[id] else { return true }
    // Apps may snap their vertical extent (Ghostty sits 4 px lower on its cell grid);
    // the horizontal placement is what the ribbon controls exactly.
    return abs(frame.x - target.x) < 3 && abs(frame.width - target.width) < 3
      && abs(frame.y - target.y) < 12 && abs(frame.height - target.height) < 12
  }
}

/// The native targets a landing waits for. A target showing at most a sliver (an
/// offscreen column's anchor) is out of view like a leaving window, and macOS may keep
/// it a title bar higher than asked.
func ribbonProxyLandingTargets(_ targets: [WindowID: Rect], area: Rect) -> [WindowID: Rect] {
  targets.filter { windowProxyVisibleOverlap($0.value, area) > 2 }
}

/// A window leaving view, landing at most a sliver like the targets a landing skips: the
/// overlay waits until it is gone.
func ribbonProxyLeaves(from: Rect, to: Rect, area: Rect) -> Bool {
  from.ribbonIntersects(area) && windowProxyVisibleOverlap(to, area) <= 2
}

/// How an app adjusted a window Defi asked for at a target of `size` (its own clamp,
/// cell grid or minimum size): learned at each landing.
struct RibbonProxySettle: Sendable, Equatable {
  let size: CGSize
  let delta: Rect

  /// The adjustment, if small, between where a window was asked to go and where it went.
  init?(target: Rect, native: Rect) {
    let delta = Rect(x: native.x - target.x, y: native.y - target.y,
      width: native.width - target.width, height: native.height - target.height)
    guard [delta.x, delta.y, delta.width, delta.height].allSatisfy({ abs($0) < 40 }),
      [delta.x, delta.y, delta.width, delta.height].contains(where: { abs($0) >= 0.5 }) else { return nil }
    size = CGSize(width: target.width, height: target.height)
    self.delta = delta
  }

  /// A reflow rounding a column a point narrower keeps the app's placement.
  func matches(_ target: Rect) -> Bool {
    abs(target.width - size.width) < 3 && abs(target.height - size.height) < 3
  }

  /// Position always shifts; the size change only applies to the learned size.
  func apply(to frame: Rect) -> Rect {
    let sized = matches(frame)
    return Rect(x: frame.x + delta.x, y: frame.y + delta.y,
      width: frame.width + (sized ? delta.width : 0), height: frame.height + (sized ? delta.height : 0))
  }
}

/// Whether a layer frame shows more than a sliver: parked windows keep a 1-point strip
/// at the screen edge, which must not count as being on screen.
func ribbonProxyShows(_ frame: CGRect, in bounds: CGRect) -> Bool {
  let visible = frame.intersection(bounds)
  return visible.width > 4 && visible.height > 4
}

func ribbonProxyDistance(_ frame: Rect, _ area: Rect) -> Double {
  max(area.x - frame.x - frame.width, frame.x - area.x - area.width, 0)
}


struct RibbonProxyScreen: Sendable {
  let displayID: CGDirectDisplayID
  // Top-left global coordinates, matching Accessibility and CGWindowList.
  let frame: Rect
  let visibleFrame: Rect
  let scale: Double
}

struct RibbonProxyRefresh: Sendable {
  let id: WindowID
  let appID: String
  let processID: Int32
  let frame: Rect
  // Distance from the viewport along the ribbon; 0 means visible.
  let distance: Double
}

/// Screen and motion state shared between the main thread and the navigation
/// presenter, so a navigation never waits for the main thread.
final class RibbonProxyStore: @unchecked Sendable {
  static let shared = RibbonProxyStore()
  private let lock = NSLock()
  private var icons: [Int32: CGImage] = [:]
  private var screens: [RibbonProxyScreen] = []
  private var authorized = false
  private var reducesMotion = false
  private var motionTokens: [CGDirectDisplayID: UInt64] = [:]
  /// The presentation currently on each display; older landing checks stop reporting.
  func currentMotion(_ display: CGDirectDisplayID) -> UInt64 { locked { motionTokens[display] ?? 0 } }
  func setCurrentMotion(_ token: UInt64, _ display: CGDirectDisplayID) { locked { motionTokens[display] = token } }
  var reduceMotion: Bool {
    get { locked { reducesMotion } }
    set { locked { reducesMotion = newValue } }
  }
  private var movingDisplays: Set<CGDirectDisplayID> = []
  private var onScreenCache: [RibbonProxyOnScreenWindow] = []
  private var settles: [WindowID: RibbonProxySettle] = [:]
  var settled: [WindowID: RibbonProxySettle] { locked { settles } }
  func learnSettles(targets: [WindowID: Rect], native: [WindowID: Rect]) {
    locked {
      for (id, target) in targets {
        guard let frame = native[id] else { continue }
        settles[id] = RibbonProxySettle(target: target, native: frame)
      }
    }
  }
  /// The WindowServer list can stall for tens of milliseconds while it is busy, so
  /// navigation reads the last one, refreshed after each landing and every second.
  var onScreen: [RibbonProxyOnScreenWindow] {
    get { locked { onScreenCache } }
    set { locked { onScreenCache = newValue } }
  }
  /// Captures load the WindowServer, which also composites the motion: none run while
  /// any display moves.
  var isMoving: Bool { locked { !movingDisplays.isEmpty } }
  func setMoving(_ moving: Bool, _ display: CGDirectDisplayID) {
    locked { if moving { movingDisplays.insert(display) } else { movingDisplays.remove(display) } }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body()
  }

  func screen(containing area: Rect) -> RibbonProxyScreen? {
    let x = area.x + area.width / 2, y = area.y + area.height / 2
    return locked {
      screens.first {
        x >= $0.frame.x && x < $0.frame.x + $0.frame.width
          && y >= $0.frame.y && y < $0.frame.y + $0.frame.height
      }
    }
  }
  var isAuthorized: Bool { locked { authorized } }
  var allScreens: [RibbonProxyScreen] { locked { screens } }
  func update(screens: [RibbonProxyScreen], authorized: Bool) {
    let ids = Set(screens.map(\.displayID))
    locked {
      self.screens = screens; self.authorized = authorized
      movingDisplays.formIntersection(ids)
    }
    WindowCaptureStore.shared.retainBackgrounds(ids)
  }
}

struct RibbonProxyLayers: @unchecked Sendable {
  let root: CALayer
  let backdrop: CALayer
  let area: Rect
}

/// Main-thread side: owns the overlay window and keeps pictures warm.
@MainActor
final class RibbonProxyRenderer {
  static let shared = RibbonProxyRenderer()

  var enabled = false {
    didSet {
      guard !enabled else {
        refreshEnvironment()
        // No refresh at rest: pictures are taken on events only (a landing, a layout, a resize).
        return
      }
      if oldValue { WindowCaptureStore.shared.clear() }
      for panel in panels.values { panel.orderOut(nil) }
      panels = [:]
    }
  }
  /// One overlay per display, as each display moves on its own.
  private var panels: [CGDirectDisplayID: NSPanel] = [:]
  private var presentedDisplays: Set<CGDirectDisplayID> = []

  /// The overlay never blocks the pointer: Defi's hit test skips it.
  var surfaceWindowIDs: Set<CGWindowID> {
    Set(panels.values.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
  }

  /// Publishes screen geometry and permission for the navigation presenter.
  func refreshEnvironment() {
    // Verification only (`defaults write com.qeude.defi RibbonProxyCapturable -bool true`):
    // screen recordings then include the overlay.
    // Assigned only on change: every assignment is a synchronous WindowServer call that
    // re-evaluates the window, and this runs after every layout.
    let sharing: NSWindow.SharingType = UserDefaults.standard.bool(forKey: "RibbonProxyCapturable") ? .readOnly : .none
    for panel in panels.values where panel.sharingType != sharing { panel.sharingType = sharing }
    let authorized = CGPreflightScreenCaptureAccess()
    RibbonProxyStore.shared.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    RibbonProxyStore.shared.update(screens: NSScreen.screens.compactMap { screen in
      guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber)?.uint32Value else { return nil }
      return RibbonProxyScreen(displayID: id, frame: cgRect(screen.frame),
        visibleFrame: cgRect(screen.visibleFrame), scale: screen.backingScaleFactor)
    }, authorized: authorized)
    guard enabled else { return }
    let screens = RibbonProxyStore.shared.allScreens
    let live = Set(screens.map(\.displayID))
    for (display, panel) in panels where !live.contains(display) {
      panel.orderOut(nil); panels[display] = nil
    }
    if presentedDisplays != live {
      presentedDisplays = live
      NavigationActor.enqueue { RibbonProxyPresenter.retain(live) }
    }
    // Warm each new or reshaped display's overlay and wallpaper now: its first motion
    // must not fall back for want of either.
    for screen in screens where panels[screen.displayID]?.frame != appKitFrame(screen.frame) {
      if let prepared = prepareSurface(area: screen.frame, display: screen.displayID) {
        NavigationActor.enqueue { RibbonProxyPresenter.on(screen.displayID).adopt(prepared) }
      }
      WindowCaptureCache.shared.requestBackground(screen)
    }
  }

  private func appKitFrame(_ area: Rect) -> CGRect {
    // AppKit's origin is the bottom left of the primary display.
    CGRect(x: area.x, y: (NSScreen.screens.first?.frame.height ?? 0) - area.y - area.height,
      width: area.width, height: area.height)
  }

  /// Creates once, or reframes, the always-ordered transparent overlay. Its
  /// layers are then driven off the main thread with explicit transactions.
  func prepareSurface(area: Rect, display: CGDirectDisplayID) -> RibbonProxyLayers? {
    guard enabled else { return nil }
    let appKitFrame = appKitFrame(area)
    let panel = panels[display] ?? makePanel(frame: appKitFrame)
    panels[display] = panel
    if panel.frame != appKitFrame { panel.setFrame(appKitFrame, display: false) }
    guard let root = panel.contentView?.layer, let backdrop = root.sublayers?.first else { return nil }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    root.frame = CGRect(origin: .zero, size: appKitFrame.size)
    root.isHidden = true
    CATransaction.commit()
    if !panel.isVisible { panel.orderFrontRegardless() }
    return RibbonProxyLayers(root: root, backdrop: backdrop, area: area)
  }

  private func makePanel(frame: CGRect) -> NSPanel {
    let panel = NSPanel(contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
    panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    // Just above ordinary windows: floating panels, the Dock and the menu bar
    // stay visible above the motion instead of blinking out.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    // The default panel fade on orderOut produced the earlier handoff ghosting.
    panel.animationBehavior = .none
    // No .fullScreenAuxiliary: window pictures must never cover a fullscreen Space.
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.sharingType = .none
    panel.title = "Defi Ribbon"
    let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    let root = CALayer(); root.frame = view.bounds
    root.masksToBounds = true; root.isHidden = true
    let backdrop = CALayer(); backdrop.contentsGravity = .resize
    // Every presentation waits for the wallpaper, so the backdrop always covers the
    // screen: opaque, it spares the compositor the windows below (half its frame time).
    backdrop.isOpaque = true; backdrop.backgroundColor = .black
    // Below everything, including the landing zone.
    backdrop.zPosition = -1_000
    root.addSublayer(backdrop)
    view.layer = root
    panel.contentView = view
    return panel
  }

}

/// Navigation side: presents and lands the overlay without waiting for the main thread.
/// One presenter per display: each display moves, drags and lands on its own overlay,
/// exactly as a single display does.
@NavigationActor
final class RibbonProxyPresenter {
  private static var presenters: [CGDirectDisplayID: RibbonProxyPresenter] = [:]
  static func on(_ display: CGDirectDisplayID) -> RibbonProxyPresenter {
    if let presenter = presenters[display] { return presenter }
    let presenter = RibbonProxyPresenter(display: display)
    presenters[display] = presenter
    return presenter
  }
  static var all: Dictionary<CGDirectDisplayID, RibbonProxyPresenter>.Values { presenters.values }
  static var isCarrying: Bool { presenters.values.contains { $0.isCarrying } }
  static func picturesArrived() { for presenter in presenters.values { presenter.picturesArrived() } }
  static func cancelAll(_ reason: String = "external") { for presenter in presenters.values { presenter.cancel(reason) } }
  static func endDrag() { for presenter in presenters.values { presenter.endDrag() } }
  /// A display gone: its motion stops and its windows' borders come back.
  static func retain(_ displays: Set<CGDirectDisplayID>) {
    for (display, presenter) in presenters where !displays.contains(display) {
      presenter.cancel("display-removed")
      presenter.borderRestore?.cancel()
      setBordersHidden?(display, [])
      RibbonProxyStore.shared.setMoving(false, display)
      presenters[display] = nil
    }
  }

  static var enabled = false {
    didSet {
      guard oldValue != enabled else { return }
      if !enabled {
        for presenter in presenters.values {
          presenter.cancel(); presenter.layers = nil; presenter.windowLayers = [:]
        }
      }
      let enabled = enabled
      DispatchQueue.main.async { RibbonProxyRenderer.shared.enabled = enabled }
    }
  }
  static var borderStyle: WindowBorderStyle?
  /// Native corner radii, so each card and its ring match the real window's.
  static var cornerRadii: [WindowID: Double] = [:]
  /// Hides, on the main thread, the native borders of the windows a display's overlay
  /// draws (none: shown again); the overlay draws its own.
  static var setBordersHidden: (@Sendable (CGDirectDisplayID, Set<WindowID>) -> Void)?
  /// Whether the native ring of this focused window is on screen.
  static var nativeRingShown: (@Sendable (WindowID) async -> Bool)?

  let display: CGDirectDisplayID
  private init(display: CGDirectDisplayID) { self.display = display }
  private var borderStyle: WindowBorderStyle? { Self.borderStyle }
  private var cornerRadii: [WindowID: Double] {
    get { Self.cornerRadii }
    set { Self.cornerRadii = newValue }
  }
  private var nativeRingShown: (@Sendable (WindowID) async -> Bool)? { Self.nativeRingShown }
  private var hiddenBorderIDs: Set<WindowID> = []
  private func setBordersHidden(_ hidden: Bool) {
    Self.setBordersHidden?(display, hidden ? hiddenBorderIDs : [])
  }
  private var selectedID: WindowID?
  private(set) var lastFallback = "none"

  private var layers: RibbonProxyLayers?
  private var preparingArea: Rect?
  private var windowLayers: [WindowID: CALayer] = [:]
  /// Where the dragged window will land, shown under it for the whole drag.
  private var placeholder: CALayer?
  private var drag = RibbonProxyDrag.idle
  /// Resized windows whose fresh capture the landing waits for.
  private var awaitingFresh: Set<WindowID> = []
  /// Windows shown with a veil and icon, until a picture newer than `veiledSince` arrives.
  private var veiled: Set<WindowID> = []
  /// Native frames read when the motion landed; the fade starts from them.
  var landedNative: [WindowID: Rect] = [:]
  private var veiledSince: CFTimeInterval = 0
  /// Windows shown from an older picture, recaptured while the motion runs.
  private var refreshing: Set<WindowID> = []
  /// Windows shown from a reduced picture, sharpened once its full one is restored.
  private var standIns: Set<WindowID> = []
  /// The carried window's own slot in the ribbon, and a stacking slot that overrides it.
  private var ownSlot: Rect?
  private var previewSlot: Rect?
  /// Running slide of each proxy centre, so a retarget keeps its velocity.
  private var slides: [WindowID: (from: CGPoint, to: CGPoint, start: CFTimeInterval)] = [:]
  private var presenting = false
  /// Outgoing windows of earlier motions not yet seen off screen: a quick next motion
  /// (a focus change right after a switch) must still wait for them before lifting.
  private var unsettledLeaving: Set<WindowID> = []
  private var bordersHidden = false
  private var borderRestore: Task<Void, Never>?
  private var expectedTargets: [WindowID: Rect] = [:]
  /// What Defi asked each window for; expected targets add the app's placement.
  private var requestedTargets: [WindowID: Rect] = [:]
  private var presentedSubmission: UInt64 = 0
  private var generation: UInt64 = 0
  private var landedRefresh: [RibbonProxyRefresh] = []
  private var stills: [RibbonProxyRefresh] = []

  // Returns false when windows must move at once instead.
  func begin(windows: [RibbonProxyWindow], viewport nextViewport: Rect, generation submission: UInt64,
    nativeTargets: [WindowID: Rect], requestedTargets requested: [WindowID: Rect] = [:],
    duration: TimeInterval, selectedWindowID: WindowID?,
    keepsOffscreen: Bool = false,
    managedWindowIDs: Set<WindowID> = [], borderWindowIDs: Set<WindowID>? = nil) -> Bool {
    let began = CACurrentMediaTime()
    // Any layout landing mid-drag leaves the carried proxy to the pointer.
    let draggedWindowID = drag.heldWindowID
    func fallback(_ reason: String) -> Bool {
      lastFallback = reason
      ribbonProxyLogger.notice("fallback \(reason, privacy: .public)")
      cancel()
      return false
    }
    let store = RibbonProxyStore.shared, pictures = WindowCaptureStore.shared
    guard Self.enabled, duration > 0, !store.reduceMotion
    else { return fallback("disabled") }
    guard store.isAuthorized else {
      DispatchQueue.main.async { RibbonProxyRenderer.shared.refreshEnvironment() }
      return fallback("permission")
    }
    guard let screen = store.screen(containing: nextViewport) else {
      DispatchQueue.main.async { RibbonProxyRenderer.shared.refreshEnvironment() }
      return fallback("screen")
    }
    // The whole screen: a native window dragged under the Dock must stay hidden. The
    // Dock and the menu bar sit above the overlay's level anyway.
    let area = screen.frame
    guard let layers, layers.area == area else {
      prepareSurface(area)
      return fallback("surface")
    }
    guard let background = pictures.background(screen.displayID),
      background.width == Int(screen.frame.width * screen.scale)
    else {
      DispatchQueue.main.async { WindowCaptureCache.shared.requestBackground(screen) }
      return fallback("background")
    }
    var shown = windows.filter {
      $0.id != draggedWindowID
        && (keepsOffscreen || $0.from.ribbonIntersects(area) || $0.to.ribbonIntersects(area))
    }
    guard !shown.isEmpty else { return fallback("no-visible-window") }
    // Visible ordinary windows Defi does not manage stay still on the overlay,
    // drawn from their own picture so the handoff is invisible.
    let phaseScreen = CACurrentMediaTime()
    let cached = store.onScreen
    let onScreen = cached.isEmpty ? ribbonProxyOnScreenWindows() : cached
    // Managed windows outside this motion are never stills: the cached list can still
    // show one at the place it just left, which would cross the new workspace.
    let managed = Set(windows.map(\.id)).union(managedWindowIDs)
    // Radii arrive for visible windows only and are kept for later entries; closed ones go.
    if !managedWindowIDs.isEmpty { cornerRadii = cornerRadii.filter { managed.contains($0.key) } }
    // Whole frames: the capture returns the whole window and the root layer clips it.
    let unmanaged = onScreen.compactMap { window -> (id: WindowID, processID: Int32, frame: Rect)? in
      guard !managed.contains(window.id), window.processID != getpid(), window.layer == 0,
        windowProxyVisibleOverlap(window.frame, area) > 1.01 else { return nil }
      return (window.id, window.processID, window.frame)
    }
    let missing = unmanaged.filter { window in
      guard let picture = pictures.picture(window.id) else { return true }
      return !ribbonProxyPictureMatches(captured: picture.size, native: window.frame)
    }
    // An uncapturable still must not cost the animation: it is briefly covered
    // instead, and captured for the next motion.
    let missingIDs = Set(missing.map(\.id))
    let unmanagedShown = unmanaged.filter { !missingIDs.contains($0.id) }
    shown += unmanagedShown.map {
      RibbonProxyWindow(id: $0.id, appID: "", processID: $0.processID, from: $0.frame, to: $0.frame)
    }
    stills = unmanaged.map {
      RibbonProxyRefresh(id: $0.id, appID: "", processID: $0.processID, frame: $0.frame, distance: 0)
    }
    // Stack like the screen: front-most windows on top, parked ones beneath.
    let depth = Dictionary(onScreen.enumerated().map { ($0.element.id, Double(onScreen.count - $0.offset)) }) {
      first, _ in first
    }

    let previous = presenting ? windowLayers.mapValues { ($0.presentation() ?? $0).frame } : [:]
    generation &+= 1
    selectedID = selectedWindowID
    borderRestore?.cancel(); borderRestore = nil
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layers.backdrop.frame = layers.root.bounds
    // Same surface every time: reassigning or cropping would re-upload a 5K
    // texture to the compositor right when the motion starts.
    setContents(layers.backdrop, background)
    // Unit content space starts at the bottom, like the layer tree.
    layers.backdrop.contentsRect = CGRect(x: (area.x - screen.frame.x) / screen.frame.width,
      y: (screen.frame.y + screen.frame.height - area.y - area.height) / screen.frame.height,
      width: area.width / screen.frame.width, height: area.height / screen.frame.height)
    let shownIDs = Set(shown.map(\.id))
    // One command can submit twice (layout, then scroll) with a narrower window set;
    // mid-motion, a window left out keeps travelling instead of vanishing.
    for (id, layer) in windowLayers where !shownIDs.contains(id) && previous[id] == nil {
      layer.removeFromSuperlayer(); windowLayers[id] = nil
    }
    let phaseLayers = CACurrentMediaTime()
    var pictured = 0, badged = 0
    var travel = 0.0
    for window in shown {
      let layer = windowLayers[window.id] ?? makeLayer()
      windowLayers[window.id] = layer
      if layer.superlayer == nil { layers.root.addSublayer(layer) }
      // Mid-flight windows continue from where they are drawn. A layer left off screen
      // by an earlier motion starts from the planned place instead: continuing it came
      // in diagonally from a corner.
      let current = previous[window.id].flatMap { ribbonProxyShows($0, in: layers.root.bounds) ? $0 : nil }
      var from = current ?? local(window.from, area)
      var to = local(window.to, area)
      // Already leaving the screen (a switch cut short by a focus change): it keeps its
      // course. Retargeting it to its native parking slot sent it across the screen.
      if current != nil, !ribbonProxyShows(to, in: layers.root.bounds),
        !ribbonProxyShows(layer.frame, in: layers.root.bounds) {
        to = layer.frame
      }
      // Off screen at both ends across two edges: the straight path would cut through
      // the screen, so it jumps instead. A ribbon sweep (horizontal) still passes by.
      if abs(to.minY - from.minY) > 4, !ribbonProxyShows(from, in: layers.root.bounds),
        !ribbonProxyShows(to, in: layers.root.bounds) {
        from = to
      }
      let now = CACurrentMediaTime()
      // Rapid commands retarget mid-flight: carry the current velocity, as Niri does,
      // instead of restarting the spring from rest.
      let velocity = current == nil ? .zero : slides[window.id].map {
        ribbonProxySpringVelocity(from: $0.from, to: $0.to, elapsed: now - $0.start)
      } ?? .zero
      slides[window.id] = (CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY), now)
      travel = max(travel, hypot(to.midX - from.midX, to.midY - from.midY)
        + hypot(velocity.x, velocity.y) / 800.0.squareRoot()
        + abs(to.width - from.width) + abs(to.height - from.height))
      layer.removeAllAnimations()
      layer.isHidden = false
      for sublayer in layer.sublayers ?? [] { sublayer.removeAllAnimations() }
      let styled = style(layer, for: window, selected: window.id == selectedWindowID)
      if styled.pictured { pictured += 1 }
      if styled.badged { badged += 1; veiled.insert(window.id) } else { veiled.remove(window.id) }
      if pictures.picture(window.id)?.isReduced == true { standIns.insert(window.id) } else { standIns.remove(window.id) }
      // The active window travels above the windows it crosses, as in Niri.
      layer.zPosition = window.id == selectedWindowID ? 100_000 : depth[window.id] ?? 0
      ribbonProxyMove(layer, from: from, to: to, velocity: velocity)
      if window.appears {
        // A new window grows in at its place, like Niri's open animation.
        let grow = ribbonProxySpringAnimation("transform.scale")
        grow.fromValue = 0.86; grow.toValue = 1
        ribbonProxyStartNow(grow, on: layer)
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0; reveal.toValue = 1; reveal.duration = 0.18
        ribbonProxyStartNow(reveal, on: layer)
      }
      let starts = Dictionary(sublayerFrames(layer, size: from.size).map { (ObjectIdentifier($0.0), $0.1) }) { a, _ in a }
      for (sublayer, end) in sublayerFrames(layer, size: to.size) {
        ribbonProxyMove(sublayer, from: starts[ObjectIdentifier(sublayer)] ?? end, to: end)
      }
    }
    if case .dropping = drag { drag = .idle }
    if draggedWindowID != nil {
      showSlot(in: layers)
    } else if let placeholder {
      placeholder.removeFromSuperlayer(); self.placeholder = nil
    }
    layers.root.removeAnimation(forKey: "fade")
    layers.root.opacity = 1
    layers.root.isHidden = false
    layers.root.mask = nil
    let committing = CACurrentMediaTime()
    // Commit now, from this thread: the overlay is on screen before any native write.
    ribbonProxyCommit(#line)
    let flushMS = Int((CACurrentMediaTime() - committing) * 1_000)
    presenting = true
    RibbonProxyStore.shared.setMoving(true, display)
    // This display's borders only: another display's stay as they are.
    let borders = borderWindowIDs.map { $0.union(shownIDs) } ?? managed
    if !bordersHidden || hiddenBorderIDs != borders {
      bordersHidden = true; hiddenBorderIDs = borders; setBordersHidden(true)
    }

    expectedTargets = ribbonProxyLandingTargets(nativeTargets.filter { $0.key != draggedWindowID }, area: area)
    requestedTargets = requested.filter { expectedTargets[$0.key] != nil }
    presentedSubmission = submission
    landedRefresh = windows.map {
      RibbonProxyRefresh(id: $0.id, appID: $0.appID, processID: $0.processID, frame: $0.to,
        distance: ribbonProxyDistance($0.to, area))
    }
    lastFallback = "none"
    // Captures load the compositor that draws this motion, so none start now: a
    // picture that arrives anyway (an urgent capture) replaces an old or veiled card.
    veiled.formIntersection(shownIDs)
    standIns.formIntersection(shownIDs)
    veiledSince = CACurrentMediaTime()
    refreshing = Set(windows.filter { window in
      window.appID != "" && !veiled.contains(window.id) && window.to.ribbonIntersects(area)
        && pictures.picture(window.id).map { veiledSince - $0.capturedAt > 1.5 } == true
    }.map(\.id))
    let unpictured = shown.filter { pictures.picture($0.id) == nil }.map(\.id.rawValue)
    // Pictures that do not match their window's size or are old: the landing shows the
    // live content reflowed or changed, which reads as a zoom or resize.
    let mismatched = shown.compactMap { window -> String? in
      guard let picture = pictures.picture(window.id) else { return nil }
      let age = Int(CACurrentMediaTime() - picture.capturedAt)
      guard !ribbonProxyPictureMatches(captured: picture.size, native: window.to) || age >= 10 else { return nil }
      return "\(window.id.rawValue):\(Int(picture.size.width))x\(Int(picture.size.height))->\(Int(window.to.width))x\(Int(window.to.height)),\(age)s"
    }
    ribbonProxyLogger.notice("present windows=\(shown.count) pictures=\(pictured) missing=\(unpictured, privacy: .public) stale=\(mismatched, privacy: .public) veiled=\(self.veiled.count) ms=\(Int((CACurrentMediaTime() - began) * 1_000)) flushMs=\(flushMS) preMs=\(Int((phaseScreen - began) * 1_000)) screenMs=\(Int((phaseLayers - phaseScreen) * 1_000)) layersMs=\(Int((committing - phaseLayers) * 1_000)) cold=\(cached.isEmpty)")
    let token = generation, expected = expectedTargets, requested = requestedTargets
    let display = display, presenter = self
    store.setCurrentMotion(token, display)
    pictures.markShown(shown.map(\.id))
    // Planned with the same recency as the budget: what it restores stays full.
    pictures.restore(Array(standIns))
    // Windows leaving the screen must be gone too, or a slow app's outgoing window
    // pops back into view when the overlay lifts.
    let leaving = Set(windows.filter {
      $0.id != draggedWindowID && ribbonProxyLeaves(from: $0.from, to: $0.to, area: area)
    }.map(\.id)).union(unsettledLeaving.subtracting(expected.keys).subtracting([draggedWindowID].compactMap { $0 }))
    unsettledLeaving = leaving
    let drawn = Set(shown.map(\.id) + [draggedWindowID].compactMap { $0 })
    let stop = ribbonProxyVisualStop(travel: travel)
    Task.detached(priority: .userInitiated) {
      // The spring decides how long the motion lasts; the overlay stays until it settles.
      do { try await Task.sleep(for: .seconds(stop)) } catch { return }
      NavigationActor.enqueue { presenter.stopped(token) }
      // Native windows move from the start, under the opaque overlay: they usually wait
      // here already, and apps that apply moves late still get a short grace.
      let deadline = CACurrentMediaTime() + 0.9
      var landed = false
      var native: [WindowID: Rect] = [:]
      func cleared(_ id: WindowID) -> Bool {
        native[id].map { windowProxyVisibleOverlap($0, area) <= 2 } ?? true
      }
      while CACurrentMediaTime() < deadline {
        native = ribbonProxyNativeFrames(Set(expected.keys).union(leaving))
        if ribbonProxyLanded(native: native, targets: expected), leaving.allSatisfy(cleared) {
          landed = true; break
        }
        try? await Task.sleep(for: .milliseconds(8))
      }
      var finished = landed
      if landed { RibbonProxyStore.shared.learnSettles(targets: requested, native: native) }
      guard RibbonProxyStore.shared.currentMotion(display) == token else { return }
      // A slow app has not moved its window yet (arriving or leaving): lifting would
      // show it sliding into place later, so the overlay keeps covering it alone, over
      // where it is and where it goes, until it gets there.
      // Position only: an app refusing the asked size is in place, not late.
      func arrived(_ id: WindowID) -> Bool {
        guard let target = expected[id] else { return cleared(id) }
        return native[id].map { abs($0.x - target.x) < 3 && abs($0.y - target.y) < 12 } ?? true
      }
      let late = Set(expected.keys).union(leaving).filter { !arrived($0) }
      if !landed, !late.isEmpty {
        let covered = late.compactMap { native[$0] } + late.compactMap { expected[$0] }
        NavigationActor.enqueue { presenter.cover(covered, generation: token) }
        let coverDeadline = CACurrentMediaTime() + 2
        while CACurrentMediaTime() < coverDeadline, !late.allSatisfy(arrived) {
          try? await Task.sleep(for: .milliseconds(16))
          guard RibbonProxyStore.shared.currentMotion(display) == token else { return }
          let frames = ribbonProxyNativeFrames(late)
          for id in late { native[id] = frames[id] }
        }
        finished = late.allSatisfy(arrived)
        ribbonProxyLogger.notice("landing-cover ids=\(late.map(\.rawValue), privacy: .public) arrived=\(finished)")
      }
      if !finished {
        // Placed but not at the asked size: the app's own limit, landed from now on.
        let placed = requested.filter { id, _ in
          native[id].flatMap { frame in expected[id].map { abs(frame.x - $0.x) < 3 && abs(frame.y - $0.y) < 12 } } == true
        }
        RibbonProxyStore.shared.learnSettles(targets: placed, native: native)
        let late = expected.filter { id, target in !ribbonProxyLanded(native: native.filter { $0.key == id }, targets: [id: target]) }
          .map(\.key) + leaving.filter { !cleared($0) }
        let detail = late.map { id in
          let n = native[id].map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.width))x\(Int($0.height))" } ?? "none"
          let t = expected[id].map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.width))x\(Int($0.height))" } ?? "offscreen"
          return "\(id.rawValue):\(n)->\(t)"
        }
        ribbonProxyLogger.notice("landing-timeout late=\(detail, privacy: .public)")
      }
      // Anything on screen the overlay did not draw appears abruptly when it lifts.
      let onScreen = ribbonProxyOnScreenWindows()
      RibbonProxyStore.shared.onScreen = onScreen
      let stray = onScreen.filter {
        $0.layer == 0 && $0.processID != getpid() && !drawn.contains($0.id)
          && windowProxyVisibleOverlap($0.frame, area) > 2
      }
      if !stray.isEmpty {
        ribbonProxyLogger.notice("landing-stray ids=\(stray.map(\.id.rawValue), privacy: .public)")
      }
      let observed = native
      NavigationActor.enqueue {
        // Waited for (and covered) once: a window that never leaves must not hold
        // every later landing.
        presenter.unsettledLeaving.subtract(leaving)
        presenter.landedNative = observed
        presenter.land(token, timedOut: !finished)
      }
    }
    return true
  }

  /// The spring has stopped: a still overlay costs the compositor nothing, so reads and
  /// captures (a close, a new window) no longer wait for slow apps to land.
  private func stopped(_ token: UInt64) {
    guard generation == token, presenting, drag == .idle else { return }
    RibbonProxyStore.shared.setMoving(false, display)
  }

  /// Lifts the overlay everywhere but over `frames` (native, slow apps' outgoing windows).
  func cover(_ frames: [Rect], generation token: UInt64) {
    guard generation == token, presenting, let layers else { return }
    let path = CGMutablePath()
    for frame in frames { path.addRect(local(frame, layers.area)) }
    let mask = CAShapeLayer()
    mask.frame = layers.root.bounds; mask.path = path
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layers.root.mask = mask
    ribbonProxyCommit(#line)
  }

  private func land(_ token: UInt64, timedOut: Bool) {
    guard generation == token, presenting else { return }
    if timedOut { lastFallback = "landing-timeout" }
    // The carried window and the reflowed neighbours stay on the overlay until the
    // drop layout (or its timeout) takes over.
    guard drag == .idle else { return }
    // A window whose size changed shows a cropped picture while the app has reflowed:
    // recapture it first, so the fade joins two matching
    // images. A fresh capture lands once the app has redrawn at its new size; at most
    // 0.9 s, and a timed-out landing does not wait again.
    let resized = landedRefresh.filter { window in
      window.distance == 0 && WindowCaptureStore.shared.picture(window.id).map {
        !ribbonProxyPictureMatches(captured: $0.size, native: window.frame)
      } == true
    }
    if !timedOut, awaitingFresh.isEmpty, !resized.isEmpty {
      awaitingFresh = Set(resized.map(\.id))
      ribbonProxyLogger.debug("await-fresh ids=\(resized.map { "\($0.id.rawValue):\(Int($0.frame.width))x\(Int($0.frame.height))" }, privacy: .public)")
      RibbonProxyStore.shared.setMoving(false, display)
      DispatchQueue.main.async { WindowCaptureCache.shared.captureSoon(resized) }
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(900))
        guard let self, generation == token, !awaitingFresh.isEmpty else { return }
        awaitingFresh = []
        land(token, timedOut: true)
      }
      return
    }
    awaitingFresh = []
    // Always a cross-fade, never a cut: stale or stretched pictures dissolve into
    // the live windows already in place below. Cards take a little longer.
    if let layers {
      generation &+= 1
      let fadeToken = generation
      // Pictures sit exactly on their windows: a few frames hide the swap without
      // lingering once the ribbon stops.
      let duration = veiled.isEmpty ? 0.06 : 0.18
      CATransaction.begin(); CATransaction.setDisableActions(true)
      // Landing tolerates a few points (an app's own clamp or rounding): the pictures
      // glide onto the real windows while they fade, so nothing shifts in the dissolve.
      for (id, layer) in windowLayers {
        guard let native = landedNative[id] else { continue }
        let to = local(native, layers.area), from = layer.frame
        guard from != to, abs(to.minX - from.minX) < 40, abs(to.minY - from.minY) < 40,
          abs(to.width - from.width) < 40, abs(to.height - from.height) < 40 else { continue }
        let starts = Dictionary(sublayerFrames(layer, size: from.size).map { (ObjectIdentifier($0.0), $0.1) }) { a, _ in a }
        ribbonProxyMove(layer, from: from, to: to)
        for (sublayer, end) in sublayerFrames(layer, size: to.size) {
          ribbonProxyMove(sublayer, from: starts[ObjectIdentifier(sublayer)] ?? end, to: end)
        }
      }
      ribbonProxyLogger.notice("fade ms=\(Int((CACurrentMediaTime() - self.veiledSince) * 1_000))")
      ribbonProxyCommit(#line)
      // The real rings come back under the cards. The focused one waits for native
      // focus, so the cards stay until it shows: fading first left it without a ring.
      borderRestore?.cancel(); borderRestore = nil
      if bordersHidden { bordersHidden = false; setBordersHidden(false) }
      // The ribbon is still: border tracking goes back to full rate.
      RibbonProxyStore.shared.setMoving(false, display)
      let ringID = selectedID.flatMap { id in
        windowLayers[id]?.sublayers?.contains { $0.name == "border" && !$0.isHidden } == true ? id : nil
      }
      let nativeRingShown = nativeRingShown, easing = veiled.isEmpty ? CAMediaTimingFunctionName.easeOut : .easeInEaseOut
      Task {
        if let ringID, let nativeRingShown {
          // shortcut: a slow app's focus beyond 300 ms still leaves a short gap.
          let held = CACurrentMediaTime(), deadline = held + 0.3
          while generation == fadeToken, CACurrentMediaTime() < deadline, await !nativeRingShown(ringID) {
            try? await Task.sleep(for: .milliseconds(8))
          }
          ribbonProxyLogger.notice("ring-handoff ms=\(Int((CACurrentMediaTime() - held) * 1_000))")
          // A few frames: the native ring is set, and can reach the screen a frame or two late.
          try? await Task.sleep(for: .milliseconds(40))
        }
        guard generation == fadeToken, let layers = self.layers else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: easing)
        layers.root.opacity = 0
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        fade.beginTime = layers.root.convertTime(CACurrentMediaTime(), from: nil)
        layers.root.add(fade, forKey: "fade")
        ribbonProxyCommit(#line)
        try? await Task.sleep(for: .milliseconds(Int(duration * 1_000) + 10))
        guard generation == fadeToken else { return }
        cancel("landed")
      }
    } else {
      cancel()
    }
    let windows = landedRefresh, stills = stills
    DispatchQueue.main.async {
      WindowCaptureCache.shared.noteWindows(windows, afterLanding: true)
      WindowCaptureCache.shared.noteStills(stills)
    }
  }

  /// Late pictures fade in over the cards of a running motion; recaptured resized
  /// windows replace their cropped picture before the overlay lifts.
  func picturesArrived() {
    guard presenting else { return }
    if !awaitingFresh.isEmpty {
      // The reflowed content dissolves in rather than jumping.
      CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
      for id in awaitingFresh {
        guard let layer = windowLayers[id],
          let content = layer.sublayers?.first(where: { $0.name == "content" }),
          let picture = WindowCaptureStore.shared.picture(id),
          abs(picture.size.width - content.bounds.width) < 3, abs(picture.size.height - content.bounds.height) < 3
        else { continue }
        content.contents = picture.contents
        content.contentsScale = picture.pixelScale
        content.backgroundColor = picture.edge
        awaitingFresh.remove(id)
      }
      ribbonProxyCommit(#line)
      if awaitingFresh.isEmpty {
        land(generation, timedOut: false)
      } else {
        // The app had not redrawn at its new size yet: capture again shortly.
        let again = landedRefresh.filter { awaitingFresh.contains($0.id) }
        Task {
          try? await Task.sleep(for: .milliseconds(60))
          DispatchQueue.main.async { WindowCaptureCache.shared.captureSoon(again) }
        }
      }
    }
    // Restored stand-ins sharpen in place, without a dissolve: one blended with the new
    // contentsScale drew the reduced picture at a quarter of its size.
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for id in standIns {
      guard let layer = windowLayers[id], let picture = WindowCaptureStore.shared.picture(id), !picture.isReduced,
        let content = layer.sublayers?.first(where: { $0.name == "content" }) else { continue }
      content.contents = picture.contents
      content.contentsScale = picture.pixelScale
      content.backgroundColor = picture.edge
      standIns.remove(id)
    }
    CATransaction.commit()
    // A fresh picture lifts the veil and icon in one smooth dissolve.
    CATransaction.begin(); CATransaction.setAnimationDuration(0.22)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
    for id in veiled.union(refreshing) {
      guard let layer = windowLayers[id], let picture = WindowCaptureStore.shared.picture(id),
        picture.capturedAt > veiledSince else { continue }
      for sublayer in layer.sublayers ?? [] {
        switch sublayer.name {
        case "content":
          sublayer.contents = picture.contents
          sublayer.contentsScale = picture.pixelScale
          sublayer.backgroundColor = picture.edge
        case "veil", "icon": sublayer.opacity = 0
        default: break
        }
      }
      refreshing.remove(id)
      guard veiled.remove(id) != nil else { continue }
      ribbonProxyLogger.notice("veil-lift id=\(id.rawValue) ms=\(Int((CACurrentMediaTime() - self.veiledSince) * 1_000))")
    }
    CATransaction.commit()
    CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
    for (id, layer) in windowLayers {
      guard let content = layer.sublayers?.first(where: { $0.name == "content" }),
        content.contents == nil, let picture = WindowCaptureStore.shared.picture(id) else { continue }
      content.contents = picture.contents
      content.contentsScale = picture.pixelScale
      content.backgroundColor = picture.edge
    }
    ribbonProxyCommit(#line)
  }

  /// Whether a newer layout moves windows the running motion is still carrying.
  func isRetargeted(by assignments: [FrameAssignment], generation submission: UInt64) -> Bool {
    // Only x: native clamping makes the logical vertical extent differ by design.
    presenting && submission > presentedSubmission && assignments.contains { assignment in
      requestedTargets[assignment.windowID].map { abs($0.x - assignment.frame.x) >= 3 } ?? false
    }
  }

  func supersedeIfTargetsChanged(_ assignments: [FrameAssignment], generation submission: UInt64) {
    if isRetargeted(by: assignments, generation: submission) { cancel("superseded") }
  }

  func cancel(_ reason: String = "external") {
    generation &+= 1
    expectedTargets = [:]; requestedTargets = [:]
    releasePointerTrack()
    drag = .idle; ownSlot = nil; previewSlot = nil; awaitingFresh = []; veiled = []; refreshing = []; standIns = []
    guard presenting, let layers else { return }
    removePlaceholder()
    if reason != "landed" { ribbonProxyLogger.notice("cancel \(reason, privacy: .public)") }
    presenting = false
    RibbonProxyStore.shared.setMoving(false, display)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layers.root.isHidden = true
    layers.root.mask = nil
    // The next motion styles fresh layers: kept ones pinned pictures the store had let go.
    for layer in windowLayers.values { layer.removeFromSuperlayer() }
    windowLayers = [:]
    ribbonProxyCommit(#line)
    // Rapid navigation keeps borders hidden instead of toggling them per step.
    borderRestore = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self, !presenting, bordersHidden else { return }
      bordersHidden = false; setBordersHidden(false); borderRestore = nil
    }
  }

  /// Holds the pointer's window (a carry or a stretch), not a preview of another display's.
  var isCarrying: Bool {
    if case .hosting = drag { return false }
    return drag.heldWindowID != nil
  }
  var hostedWindowID: WindowID? {
    if case .hosting(let id) = drag { return id }
    return nil
  }

  /// A tiled window started moving under the pointer: from here its proxy follows the
  /// pointer on the overlay, lifted, while the native window moves unseen below.
  func carry(_ id: WindowID, stretches: Bool, widths: ClosedRange<Double> = 240...Double.infinity,
    windows: [RibbonProxyWindow], viewport: Rect, slot: Rect?, generation submission: UInt64) {
    guard case .idle = drag, begin(windows: windows, viewport: viewport, generation: submission,
      nativeTargets: [:], duration: ribbonProxySpringDuration, selectedWindowID: id,
      keepsOffscreen: true),
      let layer = windowLayers[id], let layers
    else { return }
    if stretches {
      drag = .stretching(id)
      if let held = windows.first(where: { $0.id == id }) {
        RibbonProxyPointerTrack.shared.set(.stretch(RibbonProxyStretch(
          // Its ribbon place: a fast drag has resized the native window before the overlay starts.
          id: id, layer: layer, area: layers.area, base: slot ?? held.to, widths: widths,
          ribbon: windows.compactMap { window in
            window.id == id ? nil : windowLayers[window.id].map { ($0, window.to) }
          },
          borderStyle: borderStyle)))
      }
      layer.zPosition = 200_000
      // The picture keeps its start width: narrowed, it spilled into the gap.
      layer.sublayers?.first { $0.name == "content" }?.masksToBounds = true
      ribbonProxyLogger.notice("stretch id=\(id.rawValue)")
      return
    }
    drag = .carrying(id)
    ribbonProxyLogger.notice("carry id=\(id.rawValue)")
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.zPosition = 200_000
    // Lifted by its shadow only: scaling the picture made the edges jump on grab.
    if let shadow = layer.sublayers?.first(where: { $0.name == "shadow" }) {
      shadow.opacity = 1
      let lift = CABasicAnimation(keyPath: "opacity")
      lift.fromValue = ribbonProxyRestingShadowOpacity; lift.toValue = 1; lift.duration = 0.18
      ribbonProxyStartNow(lift, on: shadow)
    }
    ownSlot = slot; previewSlot = nil
    showSlot(in: layers)
    ribbonProxyCommit(#line)
    RibbonProxyPointerTrack.shared.set(.carry(id: id, layer: layer, area: layers.area, grab: nil))
  }

  /// Another display's carried window entered this one: this ribbon goes on the overlay
  /// to preview the drop, and a copy of the carried proxy follows the pointer here too,
  /// above the native window hidden below. `windows` include the carried one.
  func host(_ id: WindowID, windows: [RibbonProxyWindow], viewport: Rect,
    generation submission: UInt64) -> Bool {
    guard case .idle = drag, begin(windows: windows, viewport: viewport, generation: submission,
      nativeTargets: [:], duration: ribbonProxySpringDuration, selectedWindowID: id,
      keepsOffscreen: true),
      let layer = windowLayers[id], let layers
    else { return false }
    drag = .hosting(id)
    ownSlot = nil; previewSlot = nil
    ribbonProxyLogger.notice("host id=\(id.rawValue)")
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.zPosition = 200_000
    layer.sublayers?.first { $0.name == "shadow" }?.opacity = 1
    ribbonProxyCommit(#line)
    RibbonProxyPointerTrack.shared.addGuest(layer, area: layers.area)
    return true
  }

  /// Lays every other window out as the drop at the pointer would, on the overlay only,
  /// and marks the carried window's place in that layout.
  func preview(_ frames: [WindowID: Rect], heldWindowID: WindowID) {
    guard drag == .carrying(heldWindowID) || drag == .hosting(heldWindowID), let layers else { return }
    let now = CACurrentMediaTime()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for (id, layer) in windowLayers where id != heldWindowID {
      guard let target = frames[id] else { continue }
      let current = (layer.presentation() ?? layer).frame
      var to = local(target, layers.area)
      // Same height: keep the app's own vertical placement (some snap a few points).
      if abs(to.height - current.height) < 40 { to.origin.y = current.minY; to.size.height = current.height }
      // Logical and native frames differ by a point or two: not a move.
      guard abs(to.minX - current.minX) >= 3 || abs(to.width - current.width) >= 3
        || abs(to.minY - current.minY) >= 3 || abs(to.height - current.height) >= 3 else { continue }
      let velocity = slides[id].map {
        ribbonProxySpringVelocity(from: $0.from, to: $0.to, elapsed: now - $0.start)
      } ?? .zero
      slides[id] = (CGPoint(x: current.midX, y: current.midY), CGPoint(x: to.midX, y: to.midY), now)
      layer.removeAllAnimations()
      ribbonProxyMove(layer, from: current, to: to, velocity: velocity)
      // Stacking shrinks the window in place: its picture is cropped to the new frame
      // instead of overflowing it at full height.
      if let content = layer.sublayers?.first(where: { $0.name == "content" }),
        let picture = WindowCaptureStore.shared.picture(id) {
        content.masksToBounds = picture.size.width > to.width + 0.5 || picture.size.height > to.height + 0.5
      }
      let starts = Dictionary(sublayerFrames(layer, size: current.size).map { (ObjectIdentifier($0.0), $0.1) }) { a, _ in a }
      for (sublayer, end) in sublayerFrames(layer, size: to.size) {
        sublayer.removeAllAnimations()
        ribbonProxyMove(sublayer, from: starts[ObjectIdentifier(sublayer)] ?? end, to: end)
      }
    }
    previewSlot = frames[heldWindowID]
    showSlot(in: layers)
    ribbonProxyCommit(#line)
  }

  /// Mouse released: the carried proxy glides into its slot. The daemon's drop layout
  /// takes over from wherever it is; without one, the overlay lands on its own.
  func endDrag() {
    guard let id = drag.heldWindowID else { return }
    let carried = drag == .carrying(id) || drag == .hosting(id)
    releasePointerTrack()
    drag = .dropping(id)
    ribbonProxyLogger.notice("drop id=\(id.rawValue) slot=\(self.placeholder.map { Int($0.frame.minX) } ?? -1)")
    if carried, let layer = windowLayers[id], let slot = placeholder?.frame {
      let current = layer.presentation() ?? layer
      let from = CGRect(x: current.position.x - layer.bounds.width / 2,
        y: current.position.y - layer.bounds.height / 2, width: layer.bounds.width, height: layer.bounds.height)
      CATransaction.begin(); CATransaction.setDisableActions(true)
      layer.removeAllAnimations()
      ribbonProxyMove(layer, from: from, to: slot)
      layer.sublayers?.first { $0.name == "shadow" }?.opacity = ribbonProxyRestingShadowOpacity
      ribbonProxyCommit(#line)
    }
    let token = generation
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard let self, generation == token else { return }
      landDrop()
    }
  }

  /// The window dropped from this display now belongs to another one: its picture and
  /// landing zone leave at once instead of gliding back to its old slot as a ghost.
  /// Returns whether this display was holding it.
  func release(_ id: WindowID) -> Bool {
    guard drag == .dropping(id) else { return false }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    windowLayers.removeValue(forKey: id)?.removeFromSuperlayer()
    CATransaction.commit()
    slides[id] = nil
    removePlaceholder()
    return true
  }

  /// No drop layout took over: the overlay lands on its own.
  func landDrop() {
    guard case .dropping = drag else { return }
    drag = .idle
    land(generation, timedOut: false)
  }

  /// The pointer track belongs to the display holding the window; a hosting display
  /// only lets go of its copy.
  private func releasePointerTrack() {
    if case .hosting(let id) = drag {
      RibbonProxyPointerTrack.shared.removeGuest(windowLayers[id])
    } else if drag.heldWindowID != nil {
      RibbonProxyPointerTrack.shared.set(nil)
    }
  }

  /// The landing zone, on the display the drop lands on only.
  private func showSlot(in layers: RibbonProxyLayers) {
    if let slot = previewSlot ?? ownSlot, slot.ribbonIntersects(layers.area) {
      showPlaceholder(at: local(slot, layers.area), in: layers)
    } else {
      removePlaceholder()
    }
  }

  private func showPlaceholder(at slot: CGRect, in layers: RibbonProxyLayers) {
    if placeholder?.frame != slot {
      ribbonProxyLogger.notice("placeholder x=\(Int(slot.minX)) width=\(Int(slot.width)) carrying=\(self.isCarrying)")
    }
    let layer: CALayer
    if let placeholder {
      layer = placeholder
      if layer.frame != slot {
        let current = (layer.presentation() ?? layer).frame
        layer.removeAllAnimations()
        ribbonProxyMove(layer, from: current, to: slot)
      }
    } else {
      layer = CALayer()
      layer.cornerRadius = 12
      layer.borderWidth = 3
      layer.zPosition = -1
      layers.root.addSublayer(layer)
      placeholder = layer
      layer.frame = slot
      let grow = ribbonProxySpringAnimation("transform.scale")
      grow.fromValue = 0.94; grow.toValue = 1
      ribbonProxyStartNow(grow, on: layer)
      let reveal = CABasicAnimation(keyPath: "opacity")
      reveal.fromValue = 0; reveal.toValue = 1; reveal.duration = 0.15
      ribbonProxyStartNow(reveal, on: layer)
    }
    // The landing zone glows in the border colour, or the system accent.
    let accent = borderStyle.flatMap { overviewWindowBorderAppearance(isSelected: true, style: $0, scale: 1) }
      .map { CGColor(srgbRed: CGFloat(($0.color >> 16) & 255) / 255,
        green: CGFloat(($0.color >> 8) & 255) / 255, blue: CGFloat($0.color & 255) / 255, alpha: 1) }
      ?? NSColor.controlAccentColor.cgColor
    layer.borderColor = accent.copy(alpha: 1)
    layer.backgroundColor = accent.copy(alpha: 0.4)
    layer.borderWidth = 4
  }

  private func removePlaceholder() {
    guard let placeholder else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    placeholder.removeFromSuperlayer()
    CATransaction.commit()
    self.placeholder = nil
  }

  private func prepareSurface(_ area: Rect) {
    guard preparingArea != area else { return }
    preparingArea = area
    let display = display
    DispatchQueue.main.async {
      let prepared = RibbonProxyRenderer.shared.prepareSurface(area: area, display: display)
      NavigationActor.enqueue {
        let presenter = RibbonProxyPresenter.on(display)
        presenter.preparingArea = nil
        if let prepared { presenter.adopt(prepared) }
      }
    }
  }

  func adopt(_ prepared: RibbonProxyLayers) {
    guard Self.enabled, !presenting, layers?.area != prepared.area || layers?.root !== prepared.root else { return }
    layers = prepared
    windowLayers.values.forEach { $0.removeFromSuperlayer() }
    windowLayers = [:]
  }

  private func makeLayer() -> CALayer {
    let layer = CALayer()
    // A stretched, pre-blurred image: a live layer shadow cost the compositor a blur
    // per window per frame, enough to miss 120 Hz on a 5K display.
    let shadow = CALayer()
    shadow.name = "shadow"; shadow.contents = ribbonProxyShadowImage; shadow.contentsScale = 2
    shadow.contentsCenter = ribbonProxyShadowCenter; shadow.opacity = ribbonProxyRestingShadowOpacity
    // Fill, never stretch: a resized window shows its picture cropped, not distorted.
    let content = CALayer()
    // Never scaled: a smaller frame crops it like the real window, a larger one shows
    // the edge colour beyond it.
    content.name = "content"; content.contentsGravity = .topLeft
    // Captures already carry the window's transparent rounded corners: the content is
    // only clipped while a larger picture is cropped by a smaller frame.
    content.cornerRadius = 12
    // A light veil under the icon says "this picture stands in for the window"
    // while keeping it readable.
    let veil = CALayer()
    veil.name = "veil"; veil.cornerRadius = 12
    veil.backgroundColor = CGColor(gray: 0, alpha: 0.16)
    let icon = CALayer()
    icon.name = "icon"; icon.contentsGravity = .resizeAspect
    icon.shadowColor = CGColor(gray: 0, alpha: 1); icon.shadowOpacity = 0.4
    icon.shadowRadius = 10; icon.shadowOffset = CGSize(width: 0, height: -3)
    let border = CALayer()
    border.name = "border"
    for sublayer in [shadow, content, veil, icon, border] { layer.addSublayer(sublayer) }
    return layer
  }

  /// Styles the proxy; returns whether it shows a picture and whether the app
  /// icon is laid over it.
  private func style(_ layer: CALayer, for window: RibbonProxyWindow,
    selected: Bool) -> (pictured: Bool, badged: Bool) {
    let sublayers = Dictionary((layer.sublayers ?? []).compactMap { sublayer in
      sublayer.name.map { ($0, sublayer) } }) { first, _ in first }
    let picture = WindowCaptureStore.shared.picture(window.id)
    // A cropped picture still reads as the window: only a missing picture, or an old one
    // arriving vertically from another workspace, gets the icon over a veil.
    let badged = window.appID != "" && picture.map { picture in
      abs(window.from.y - window.to.y) > window.to.height / 2 && CACurrentMediaTime() - picture.capturedAt > 10
    } ?? true
    let radius = cornerRadii[window.id] ?? 12
    layer.setValue(radius, forKey: ribbonProxyRadiusKey)
    sublayers["content"]?.cornerRadius = radius
    sublayers["veil"]?.cornerRadius = radius
    setContents(sublayers["content"], picture?.contents)
    sublayers["content"]?.masksToBounds = picture.map {
      $0.size.width > window.to.width + 0.5 || $0.size.height > window.to.height + 0.5
        || $0.size.width > window.from.width + 0.5 || $0.size.height > window.from.height + 0.5
    } ?? false
    sublayers["content"]?.contentsScale = picture?.pixelScale ?? 1
    sublayers["content"]?.backgroundColor = picture.map { $0.edge } ?? CGColor(gray: 0.16, alpha: 1)
    setContents(sublayers["icon"], badged ? WindowCaptureStore.shared.icon(window.processID) : nil)
    sublayers["veil"]?.isHidden = !(badged && picture != nil)
    sublayers["veil"]?.opacity = 1
    sublayers["icon"]?.opacity = 1
    if let border = sublayers["border"] {
      if let borderStyle, let appearance = overviewWindowBorderAppearance(isSelected: selected,
        style: borderStyle, scale: 1) {
        let color = appearance.color
        border.borderColor = CGColor(srgbRed: CGFloat((color >> 16) & 255) / 255,
          green: CGFloat((color >> 8) & 255) / 255, blue: CGFloat(color & 255) / 255,
          alpha: CGFloat(windowBorderAlpha(of: color)) / 255)
        border.borderWidth = appearance.width
        border.isHidden = false
      } else {
        border.isHidden = true
      }
    }
    return (picture != nil, badged)
  }

  private func sublayerFrames(_ layer: CALayer, size: CGSize) -> [(CALayer, CGRect)] {
    ribbonProxySublayerFrames(layer, size: size, borderStyle: borderStyle)
  }

  private func setContents(_ layer: CALayer?, _ contents: AnyObject?) {
    guard let layer, (layer.contents as AnyObject?) !== contents else { return }
    layer.contents = contents
  }

  private func local(_ frame: Rect, _ area: Rect) -> CGRect {
    ribbonProxyLocal(frame, in: area)
  }
}

private func cgRect(_ rect: CGRect) -> Rect {
  Rect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY,
    width: rect.width, height: rect.height)
}

@MainActor
func ribbonProxyFullyOnScreen(_ frame: Rect) -> Bool {
  NSScreen.screens.contains {
    let screen = cgRect($0.frame)
    return frame.x >= screen.x && frame.x + frame.width <= screen.x + screen.width
      && frame.y >= screen.y && frame.y + frame.height <= screen.y + screen.height
  }
}

// Private, read-only and optional: SkyLight's window capture reads the window's
// own buffer in tens of milliseconds where a ScreenCaptureKit screenshot costs
// about a second here. Missing symbols leave ScreenCaptureKit as the only path.
let ribbonProxyWindowServerCapture: (@Sendable ([CGWindowID]) -> [CGImage]?)? = {
  typealias Connection = @convention(c) () -> Int32
  typealias Capture = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32)
    -> Unmanaged<CFArray>?
  guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
    let connection = dlsym(skyLight, "SLSMainConnectionID") ?? dlsym(skyLight, "CGSMainConnectionID"),
    let symbol = dlsym(skyLight, "CGSHWCaptureWindowList") ?? dlsym(skyLight, "SLSHWCaptureWindowList")
  else { return nil }
  let connectionID = unsafeBitCast(connection, to: Connection.self)()
  let capture = unsafeBitCast(symbol, to: Capture.self)
  return { windowIDs in
    var windowIDs = windowIDs
    // Ignore the global clip shape; bit 15 keeps the parts beyond the display, so a
    // parked window comes whole rather than as its one-point strip.
    // Full backing resolution (no nominal-resolution flag): crisp text on Retina.
    return capture(connectionID, &windowIDs, UInt32(windowIDs.count), 1 << 11 | 1 << 15)?
      .takeRetainedValue() as? [CGImage]
  }
}()

/// The wallpaper and desktop icons of a display (`area` in global top-left points),
/// one capture of its desktop-level windows.
func ribbonProxyDesktopImage(_ area: CGRect,
  _ capture: @Sendable ([CGWindowID]) -> [CGImage]?) -> CGImage? {
  let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
  let ids = infos.compactMap { info -> CGWindowID? in
    guard let id = info[kCGWindowNumber as String] as? NSNumber,
      let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue < 0,
      let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), area.contains(rect)
    else { return nil }
    return id.uint32Value
  }
  // The composite spans the windows given: anything but the whole screen falls back.
  guard !ids.isEmpty, let images = capture(ids), images.count == 1, let image = images.first
  else { return nil }
  let scale = (Double(image.width) / area.width).rounded()
  guard scale >= 1, image.width == Int(area.width * scale), image.height == Int(area.height * scale)
  else { return nil }
  return image
}

func ribbonProxyWindowDescriptions(_ numbers: [CGWindowID]) -> [[String: Any]] {
  // Raw window numbers, not boxed objects: bridging `as CFArray` matches no window.
  var pointers = numbers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
  guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil) else { return [] }
  return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
}

func ribbonProxyNativeFrames(_ ids: Set<WindowID>) -> [WindowID: Rect] {
  let infos = ribbonProxyWindowDescriptions(ids.compactMap { CGWindowID(exactly: $0.rawValue) })
  var result: [WindowID: Rect] = [:]
  for info in infos {
    guard let number = info[kCGWindowNumber as String] as? NSNumber,
      let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
    result[WindowID(rawValue: number.uint64Value)] = Rect(x: frame.minX, y: frame.minY,
      width: frame.width, height: frame.height)
  }
  return result
}

/// Front-to-back on-screen windows, for unmanaged stills and stacking order.
typealias RibbonProxyOnScreenWindow = (id: WindowID, processID: Int32, layer: Int, frame: Rect)

func ribbonProxyOnScreenWindows() -> [RibbonProxyOnScreenWindow] {
  let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID) as? [[String: Any]] ?? []
  return infos.compactMap { info in
    guard let id = info[kCGWindowNumber as String] as? NSNumber,
      let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
      let layer = info[kCGWindowLayer as String] as? NSNumber,
      let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      rect.width > 1, rect.height > 1
    else { return nil }
    return (WindowID(rawValue: id.uint64Value), owner.int32Value, layer.intValue,
      Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
  }
}

// Niri's default view-movement spring: critically damped, stiffness 800. It starts
// gently and settles without a long ease-out crawl, whatever the configured duration.
private func ribbonProxySpringAnimation(_ key: String) -> CASpringAnimation {
  let spring = CASpringAnimation(keyPath: key)
  spring.mass = 1; spring.stiffness = 800; spring.damping = 2 * 800.0.squareRoot()
  spring.duration = spring.settlingDuration
  return spring
}

let ribbonProxySpringDuration = ribbonProxySpringAnimation("position").settlingDuration

/// When a critically damped motion of `travel` points has less than two points left:
/// the ribbon visibly stops there, and the landing fade glides over the remainder.
func ribbonProxyVisualStop(travel: Double) -> TimeInterval {
  let omega = 800.0.squareRoot()
  var t = 0.0
  while t < ribbonProxySpringDuration, (1 + omega * t) * exp(-omega * t) * travel >= 2 { t += 1.0 / 240 }
  return min(max(t, 0.12), ribbonProxySpringDuration)
}

private func ribbonProxySpring(_ layer: CALayer, _ key: String, _ from: Any, _ to: Any) {
  let spring = ribbonProxySpringAnimation(key)
  spring.fromValue = from; spring.toValue = to
  ribbonProxyStartNow(spring, on: layer)
}

/// Layers are committed off the main thread, and the main run loop may commit the
/// tree again: an animation without an explicit start would restart from its
/// first frame, making windows jump back mid-motion.
func ribbonProxyStartNow(_ animation: CAAnimation, on layer: CALayer) {
  // ProMotion: without a preference the compositor may settle for 60 Hz.
  animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
  animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
  animation.fillMode = .backwards
  layer.add(animation, forKey: (animation as? CAPropertyAnimation)?.keyPath)
}

/// Velocity of the critically damped spring `from` → `to` after `elapsed` seconds.
func ribbonProxySpringVelocity(from: CGPoint, to: CGPoint, elapsed: TimeInterval) -> CGPoint {
  let omega = 800.0.squareRoot(), t = max(elapsed, 0)
  let factor = omega * omega * t * exp(-omega * t)
  return CGPoint(x: (to.x - from.x) * factor, y: (to.y - from.y) * factor)
}

private func ribbonProxyMove(_ layer: CALayer, from: CGRect, to: CGRect, velocity: CGPoint = .zero) {
  layer.frame = to
  let start = CGPoint(x: from.midX, y: from.midY), end = CGPoint(x: to.midX, y: to.midY)
  let position = ribbonProxySpringAnimation("position")
  position.fromValue = NSValue(point: start); position.toValue = NSValue(point: end)
  let distance = CGPoint(x: end.x - start.x, y: end.y - start.y)
  let squared = distance.x * distance.x + distance.y * distance.y
  // CASpringAnimation takes velocity as a fraction of the travel per second.
  if squared > 1 {
    position.initialVelocity = (velocity.x * distance.x + velocity.y * distance.y) / squared
    position.duration = position.settlingDuration
  }
  ribbonProxyStartNow(position, on: layer)
  // An unchanged size is not animated: the compositor then only translates the layer.
  if from.size != to.size {
    ribbonProxySpring(layer, "bounds.size", NSValue(size: from.size), NSValue(size: to.size))
  } else {
    layer.removeAnimation(forKey: "bounds.size")
  }
}


/// The pointer's carried window: lifted while carried, then released into its slot.
enum RibbonProxyDrag: Equatable {
  case idle
  case carrying(WindowID)
  /// A tiled window resized by the pointer: its proxy follows the native frame.
  case stretching(WindowID)
  /// Another display's carried window is over this one: it previews the drop here.
  case hosting(WindowID)
  case dropping(WindowID)

  var heldWindowID: WindowID? {
    switch self {
    case .carrying(let id), .stretching(let id), .hosting(let id): id
    case .idle, .dropping: nil
    }
  }
}


/// Global top-left coordinates to the overlay's layer space. The panel's layer tree
/// keeps AppKit's bottom-left origin (a layer-backed root is never geometry-flipped).
func ribbonProxyLocal(_ frame: Rect, in area: Rect) -> CGRect {
  CGRect(x: frame.x - area.x, y: area.y + area.height - frame.y - frame.height,
    width: frame.width, height: frame.height)
}

func ribbonProxyLocal(_ point: CGPoint, in area: Rect) -> CGPoint {
  CGPoint(x: point.x - area.x, y: area.y + area.height - point.y)
}

let ribbonProxyShadowPad: CGFloat = 36
let ribbonProxyRestingShadowOpacity: Float = 0.67
private let ribbonProxyShadowCorner: CGFloat = 12
/// A blurred rounded rectangle, nine-sliced over each window: drawn once, then only
/// stretched by the compositor.
let ribbonProxyShadowImage: CGImage? = {
  let side = 2 * (ribbonProxyShadowPad + ribbonProxyShadowCorner) + 2, scale: CGFloat = 2
  guard let context = CGContext(data: nil, width: Int(side * scale), height: Int(side * scale),
    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  context.scaleBy(x: scale, y: scale)
  // The shape sits outside the canvas; only its shadow lands inside.
  let shape = CGRect(x: ribbonProxyShadowPad, y: ribbonProxyShadowPad,
    width: side - 2 * ribbonProxyShadowPad, height: side - 2 * ribbonProxyShadowPad)
  context.setShadow(offset: CGSize(width: 1_000 * scale, height: 0), blur: 28,
    color: CGColor(gray: 0, alpha: 0.45))
  context.addPath(CGPath(roundedRect: shape.offsetBy(dx: -1_000, dy: 0),
    cornerWidth: ribbonProxyShadowCorner, cornerHeight: ribbonProxyShadowCorner, transform: nil))
  context.setFillColor(CGColor(gray: 0, alpha: 1))
  context.fillPath()
  return context.makeImage()
}()
private let ribbonProxyShadowCenter: CGRect = {
  let side = 2 * (ribbonProxyShadowPad + ribbonProxyShadowCorner) + 2
  let edge = (ribbonProxyShadowPad + ribbonProxyShadowCorner) / side
  return CGRect(x: edge, y: edge, width: 2 / side, height: 2 / side)
}()

/// Commits and flushes now; a commit slow enough to cost the compositor a frame is logged.
func ribbonProxyCommit(_ line: Int) {
  let start = CACurrentMediaTime()
  CATransaction.commit()
  CATransaction.flush()
  let ms = (CACurrentMediaTime() - start) * 1_000
  if ms > 2 { ribbonProxyLogger.notice("slow-commit line=\(line) ms=\(Int(ms))") }
}

private let ribbonProxyRadiusKey = "defiWindowRadius"

func ribbonProxySublayerFrames(_ layer: CALayer, size: CGSize,
  borderStyle: WindowBorderStyle?) -> [(CALayer, CGRect)] {
  (layer.sublayers ?? []).compactMap { sublayer in
    switch sublayer.name {
    case "content", "veil": return (sublayer, CGRect(origin: .zero, size: size))
    // The shadow falls 6 pt below the window, like the system's.
    case "shadow":
      let pad = ribbonProxyShadowPad
      return (sublayer, CGRect(x: -pad, y: -pad - 6, width: size.width + 2 * pad, height: size.height + 2 * pad))
    case "icon":
      return (sublayer, CGRect(x: size.width / 2 - 32, y: size.height / 2 - 32, width: 64, height: 64))
    case "border":
      guard let borderStyle else { return nil }
      // The native ring exactly: outside, it starts at the window edge and keeps its curve.
      let radius = layer.value(forKey: ribbonProxyRadiusKey) as? Double ?? 12
      let outset = borderStyle.placement == .outside ? sublayer.borderWidth : 0
      sublayer.cornerRadius = radius + outset
      return (sublayer, CGRect(x: -outset, y: -outset, width: size.width + 2 * outset,
        height: size.height + 2 * outset))
    default: return nil
    }
  }
}

struct RibbonProxyStretch {
  let id: WindowID
  let layer: CALayer
  let area: Rect
  /// The held window's frame when the gesture started, and every other ribbon window's.
  let base: Rect
  /// The window's own width bounds: the app refuses to go past them.
  let widths: ClosedRange<Double>
  let ribbon: [(CALayer, Rect)]
  let borderStyle: WindowBorderStyle?
  /// Fixed at the first event: the pointer's start, the native frame then, which edge moves.
  var anchor: (pointerX: Double, frame: Rect, movesLeft: Bool)?
}

/// Follows the pointer on the main thread at every display refresh. Mouse events
/// were not enough: while the WindowServer drags a window by its title bar they
/// arrive irregularly, and the proxy jumped between them.
final class RibbonProxyPointerTrack: @unchecked Sendable {
  enum Mode {
    /// The carried proxy keeps the native window's offset from the pointer.
    case carry(id: WindowID, layer: CALayer, area: Rect, grab: CGPoint?)
    /// The held edge follows the pointer; the ribbon shifts with it.
    case stretch(RibbonProxyStretch)
  }

  static let shared = RibbonProxyPointerTrack()
  private let lock = NSLock()
  private var mode: Mode?
  /// Copies of the carried window on the other displays previewing its drop.
  private var guests: [(layer: CALayer, area: Rect)] = []

  func set(_ mode: Mode?) {
    lock.withLock { self.mode = mode; if mode == nil { guests = [] } }
    let area: Rect? = switch mode {
    case .carry(_, _, let area, _): area
    case .stretch(let stretch): stretch.area
    case nil: nil
    }
    DispatchQueue.main.async { MainActor.assumeIsolated { RibbonProxyPointerTicker.shared.run(on: area) } }
  }

  var isStretching: Bool { lock.withLock { if case .stretch = mode { true } else { false } } }

  func addGuest(_ layer: CALayer, area: Rect) { lock.withLock { guests.append((layer, area)) } }
  func removeGuest(_ layer: CALayer?) { lock.withLock { guests.removeAll { $0.layer === layer } } }

  /// `point` is in global top-left coordinates.
  func move(to point: CGPoint) {
    guard let (current, guests) = lock.withLock({ self.mode.map { ($0, self.guests) } }) else { return }
    var mode = current
    CATransaction.begin(); CATransaction.setDisableActions(true)
    switch mode {
    case .carry(let id, let layer, let area, let grab):
      let local = ribbonProxyLocal(point, in: area)
      // Read with the pointer, at the same instant: the window kept moving since the
      // drag was detected, and an older position left the proxy trailing the cursor.
      let offset = grab ?? ribbonProxyNativeFrames([id])[id].map { native in
        let frame = ribbonProxyLocal(native, in: area)
        return CGPoint(x: frame.midX - local.x, y: frame.midY - local.y)
      } ?? CGPoint(x: layer.position.x - local.x, y: layer.position.y - local.y)
      layer.removeAnimation(forKey: "position")
      layer.position = CGPoint(x: local.x + offset.x, y: local.y + offset.y)
      for guest in guests {
        let there = ribbonProxyLocal(point, in: guest.area)
        guest.layer.removeAnimation(forKey: "position")
        guest.layer.position = CGPoint(x: there.x + offset.x, y: there.y + offset.y)
      }
      mode = .carry(id: id, layer: layer, area: area, grab: offset)
    case .stretch(var stretch):
      if stretch.anchor == nil, let start = ribbonProxyNativeFrames([stretch.id])[stretch.id] {
        // The pointer is on the held edge; a fast drag may already have resized the native frame.
        stretch.anchor = (Double(point.x), start, Double(point.x) < start.x + start.width / 2)
      }
      if let anchor = stretch.anchor {
        let delta = point.x - anchor.pointerX
        let width = min(max(anchor.frame.width + (anchor.movesLeft ? -delta : delta),
          stretch.widths.lowerBound), stretch.widths.upperBound)
        let held = Rect(x: anchor.movesLeft ? anchor.frame.x + anchor.frame.width - width : anchor.frame.x,
          y: anchor.frame.y, width: width, height: anchor.frame.height)
        let frame = ribbonProxyLocal(held, in: stretch.area)
        stretch.layer.removeAllAnimations()
        stretch.layer.frame = frame
        for (sublayer, subframe) in ribbonProxySublayerFrames(stretch.layer, size: frame.size,
          borderStyle: stretch.borderStyle) {
          sublayer.removeAllAnimations(); sublayer.frame = subframe
        }
        let left = held.x - stretch.base.x
        let right = held.x + held.width - stretch.base.x - stretch.base.width
        for (layer, base) in stretch.ribbon {
          let shift = base.x >= stretch.base.x + stretch.base.width - 1 ? right
            : base.x + base.width <= stretch.base.x + 1 ? left : 0
          let moved = ribbonProxyLocal(Rect(x: base.x + shift, y: base.y, width: base.width, height: base.height),
            in: stretch.area)
          layer.removeAnimation(forKey: "position")
          layer.position = CGPoint(x: moved.midX, y: moved.midY)
        }
      }
      mode = .stretch(stretch)
    }
    ribbonProxyCommit(#line)
    let updated = mode
    lock.withLock { if self.mode != nil { self.mode = updated } }
  }
}


/// A CGImage carrying the capture's colour space: an untagged IOSurface is read as
/// sRGB and Display P3 windows looked washed out next to the real ones.
func ribbonProxyTaggedImage(_ buffer: CVPixelBuffer) -> CGImage? {
  var image: CGImage?
  VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
  return image
}

/// Reads the cursor once per frame while a window is held.
@MainActor
final class RibbonProxyPointerTicker: NSObject {
  static let shared = RibbonProxyPointerTicker()
  private var link: CADisplayLink?
  private var area: Rect?

  /// Ticks at the refresh of the display holding the window, none without one.
  func run(on area: Rect?) {
    guard area != self.area else { return }
    link?.invalidate(); link = nil
    self.area = area
    guard let area, let screen = NSScreen.screens.first(where: { cgRect($0.frame) == area })
      ?? NSScreen.screens.first else { return }
    let link = screen.displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  @objc private func tick() {
    let location = NSEvent.mouseLocation
    let top = NSScreen.screens.first?.frame.height ?? 0
    RibbonProxyPointerTrack.shared.move(to: CGPoint(x: location.x, y: top - location.y))
  }
}

