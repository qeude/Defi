import AppKit
import CoreMedia
import CoreVideo
import DefiModel
import DefiRuntime
import QuartzCore
import ScreenCaptureKit

struct WindowPicture: @unchecked Sendable {
  // An IOSurface or CGImage; the buffer keeps a captured surface alive.
  let contents: AnyObject
  var buffer: CVPixelBuffer? = nil
  /// In points; `pixelScale` pixels per point (2 for Retina captures).
  let size: CGSize
  var capturedAt: TimeInterval
  var pixelScale: CGFloat = 1
  /// The colour along the right and bottom edges: fills a frame larger than the
  /// picture, which is never scaled up.
  let edge: CGColor?

  /// Set by the store from the capture request; consumers compare it with their window.
  var appID = ""
  var processID: Int32 = 0
  /// Scaled down to fit the byte cap; recaptured at full resolution once shown.
  var isReduced = false
  let byteCost: Int

  init(contents: AnyObject, buffer: CVPixelBuffer? = nil, size: CGSize, capturedAt: TimeInterval,
    pixelScale: CGFloat = 1) {
    self.contents = contents
    self.buffer = buffer
    self.size = size
    self.capturedAt = capturedAt
    self.pixelScale = pixelScale
    let image = CFGetTypeID(contents) == CGImage.typeID ? (contents as! CGImage) : nil
    edge = image.flatMap(ribbonProxyEdgeColor)
    byteCost = buffer.map(CVPixelBufferGetDataSize) ?? image.map { $0.bytesPerRow * $0.height }
      ?? Int(size.width * size.height * pixelScale * pixelScale * 4)
  }

  var image: CGImage? { CFGetTypeID(contents) == CGImage.typeID ? (contents as! CGImage) : nil }

  /// The bytes left after reduction, or nil when reducing would not save anything.
  var reducedByteCost: Int? {
    guard !isReduced, let size = windowPictureReducedPixels(image) else { return nil }
    return size.width * size.height * 4
  }

  /// The same point size at a lower pixel scale: every consumer draws it unchanged.
  func reduced() -> WindowPicture? {
    guard let image, let pixels = windowPictureReducedPixels(image),
      let small = windowPictureResized(image, width: pixels.width, height: pixels.height)
    else { return nil }
    var picture = WindowPicture(contents: small, size: size, capturedAt: capturedAt,
      pixelScale: CGFloat(pixels.width) / max(size.width, 1))
    picture.appID = appID; picture.processID = processID; picture.isReduced = true
    return picture
  }
}

let windowPictureReducedLongSide = 512

func windowPictureReducedPixels(_ image: CGImage?) -> (width: Int, height: Int)? {
  guard let image else { return nil }
  let scale = Double(windowPictureReducedLongSide) / Double(max(image.width, image.height))
  guard scale < 1 else { return nil }
  return (max(Int(Double(image.width) * scale), 1), max(Int(Double(image.height) * scale), 1))
}

func windowPictureResized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
  guard let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return nil }
  context.interpolationQuality = .medium
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()
}

/// Average colour of the picture's right and bottom borders.
func ribbonProxyEdgeColor(_ image: CGImage) -> CGColor? {
  let strip = max(image.width / 50, 2)
  // The context writes through this pointer after its initializer returns.
  let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
  pixel.initialize(repeating: 0, count: 4)
  defer { pixel.deallocate() }
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(data: pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
    let right = image.cropping(to: CGRect(x: image.width - strip, y: 0, width: strip, height: image.height)),
    let bottom = image.cropping(to: CGRect(x: 0, y: image.height - strip, width: image.width, height: strip))
  else { return nil }
  context.interpolationQuality = .medium
  // Opaque, then half over it: both borders weigh the same.
  context.draw(right, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  context.setAlpha(0.5)
  context.draw(bottom, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  // Premultiplied: transparent corners leave alpha below 1.
  let alpha = max(CGFloat(pixel[3]), 1)
  return CGColor(srgbRed: CGFloat(pixel[0]) / alpha, green: CGFloat(pixel[1]) / alpha,
    blue: CGFloat(pixel[2]) / alpha, alpha: 1)
}

/// A single-window capture as a picture, or nil when it does not match the window.
/// Kept as the CGImage: an IOSurface copy ignores contentsScale and showed Retina
/// pictures at twice their size.
func windowPicture(_ images: [CGImage]?, native: Rect) -> WindowPicture? {
  guard let images, images.count == 1, let image = images.first,
    let points = ribbonProxyCapturedPoints(image, native: native) else { return nil }
  return WindowPicture(contents: image, size: points.size, capturedAt: CACurrentMediaTime(),
    pixelScale: points.scale)
}

/// The point size of a capture of a window `native` points large, at 1× or Retina.
func ribbonProxyCapturedPoints(_ image: CGImage, native: Rect) -> (size: CGSize, scale: CGFloat)? {
  for scale in [2.0, 1.0, 3.0] {
    let size = CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale)
    if ribbonProxyPictureMatches(captured: size, native: native) { return (size, CGFloat(scale)) }
  }
  return nil
}

extension Notification.Name {
  static let windowCapturesArrived = Notification.Name("com.qeude.defi.window-captures-arrived")
}

func announceWindowCaptures() {
  NavigationActor.enqueue { RibbonProxyPresenter.picturesArrived() }
  NotificationCenter.default.post(name: .windowCapturesArrived, object: nil)
}

struct WindowCaptureBudgetEntry {
  let id: WindowID
  let bytes: Int
  /// Nil when the picture is already reduced or too small to shrink.
  let reducedBytes: Int?
  let shownAt: TimeInterval
}

/// Most recently shown first: full resolution until the cap, then reduced, then dropped.
/// Once one picture is reduced every older one is too, so recency alone decides.
func windowCaptureBudgetPlan(_ entries: [WindowCaptureBudgetEntry], limit: Int)
  -> (reduce: [WindowID], drop: [WindowID]) {
  var remaining = limit, full = true
  var reduce: [WindowID] = [], drop: [WindowID] = []
  for entry in entries.sorted(by: {
    $0.shownAt != $1.shownAt ? $0.shownAt > $1.shownAt : $0.id.rawValue < $1.id.rawValue
  }) {
    if (full || entry.reducedBytes == nil) && entry.bytes <= remaining {
      remaining -= entry.bytes
    } else if let reduced = entry.reducedBytes, reduced <= remaining {
      full = false
      remaining -= reduced
      reduce.append(entry.id)
    } else {
      full = false
      drop.append(entry.id)
    }
  }
  return (reduce, drop)
}

/// One picture per window for every consumer (ribbon motion, Overview cards and zoom),
/// under one byte cap. Thread-safe so a navigation never waits for the main thread.
final class WindowCaptureStore: @unchecked Sendable {
  static let shared = WindowCaptureStore()
  static let byteLimit = 512 * 1_024 * 1_024
  private let lock = NSLock()
  private var pictures: [WindowID: WindowPicture] = [:]
  private var shown: [WindowID: TimeInterval] = [:]
  private var reducing: Set<WindowID> = []
  private var backgrounds: [CGDirectDisplayID: CGImage] = [:]
  private var icons: [Int32: CGImage] = [:]
  private var limit: Int
  private let fullLimit: Int

  init(byteLimit: Int = WindowCaptureStore.byteLimit) {
    fullLimit = byteLimit
    limit = byteLimit
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body()
  }

  func picture(_ id: WindowID) -> WindowPicture? { locked { pictures[id] } }
  var pictureIDs: Set<WindowID> { locked { Set(pictures.keys) } }
  var byteCount: Int { locked { pictures.values.reduce(0) { $0 + $1.byteCost } } }
  var reducedCount: Int { locked { pictures.values.filter(\.isReduced).count } }
  var count: Int { locked { pictures.count } }

  func setPicture(_ picture: WindowPicture, for window: RibbonProxyRefresh) {
    var picture = picture
    picture.appID = window.appID; picture.processID = window.processID
    locked { pictures[window.id] = picture }
    enforceBudget()
  }

  /// A consumer displayed these windows: they keep full resolution longest.
  func markShown(_ ids: [WindowID]) {
    let now = CACurrentMediaTime()
    locked { for id in ids { shown[id] = now } }
  }

  /// Every picture becomes stale (kept as a stand-in until recaptured).
  func expirePictures() { locked { pictures = pictures.mapValues { var picture = $0; picture.capturedAt = 0; return picture } } }
  func retainPictures(_ ids: Set<WindowID>) {
    locked {
      pictures = pictures.filter { ids.contains($0.key) }
      shown = shown.filter { ids.contains($0.key) }
    }
  }
  func background(_ id: CGDirectDisplayID) -> CGImage? { locked { backgrounds[id] } }
  func setBackground(_ image: CGImage, for id: CGDirectDisplayID) { locked { backgrounds[id] = image } }
  func retainBackgrounds(_ ids: Set<CGDirectDisplayID>) { locked { backgrounds = backgrounds.filter { ids.contains($0.key) } } }
  func icon(_ processID: Int32) -> CGImage? { locked { icons[processID] } }
  func setIcon(_ icon: CGImage, for processID: Int32) { locked { icons[processID] = icon } }
  func clear() { locked { pictures = [:]; backgrounds = [:]; reducing = [] } }

  /// Warning quarters the cap; critical drops every picture; normal restores the cap.
  func applyMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
    if events.contains(.critical) { clear() }
    locked { limit = events.contains(.normal) ? fullLimit : fullLimit / 4 }
    enforceBudget()
  }

  private func enforceBudget() {
    let work: [(WindowID, WindowPicture)] = locked {
      let plan = windowCaptureBudgetPlan(pictures.map { id, picture in
        WindowCaptureBudgetEntry(id: id, bytes: picture.byteCost,
          reducedBytes: picture.reducedByteCost, shownAt: shown[id] ?? 0)
      }, limit: limit)
      for id in plan.drop { pictures[id] = nil }
      return plan.reduce.compactMap { id in
        reducing.insert(id).inserted ? pictures[id].map { (id, $0) } : nil
      }
    }
    guard !work.isEmpty else { return }
    // shortcut: a one-time CPU downscale per demoted picture; the GPU draws every consumer.
    DispatchQueue.global(qos: .utility).async { [self] in
      var replaced = false
      for (id, picture) in work {
        let reduced = picture.reduced()
        replaced = locked {
          reducing.remove(id)
          // A newer capture replaced it meanwhile: plan again once this batch ends.
          guard let current = pictures[id], current.contents === picture.contents else { return true }
          // Keeps an expiry (appearance change) made while reducing.
          var replacement = reduced
          replacement?.capturedAt = current.capturedAt
          pictures[id] = replacement
          return false
        } || replaced
      }
      if replaced { enforceBudget() }
      // Consumers holding the full pictures swap to the reduced ones and release them.
      DispatchQueue.main.async { announceWindowCaptures() }
    }
  }
}

/// Main-thread side: decides what to capture and when, for every consumer.
@MainActor
final class WindowCaptureCache {
  static let shared = WindowCaptureCache()
  private var appearanceObserver: NSObjectProtocol?
  private(set) var failureCount = 0
  var isCapturing: Bool { refreshing || slowCapturesRunning }
  private var refresh: Task<Void, Never>?
  private var refreshDue: CFTimeInterval = 0
  private var refreshQueuedSoon = false
  /// The last pass found a motion running: retry shortly, never in a tight loop.
  private var refreshBlockedByMotion = false
  private var slowCapturesRunning = false
  /// Overview cards in view: without the WindowServer capture, ScreenCaptureKit refreshes
  /// them once per opening, as it refreshes nothing else that is merely old.
  private var overviewRefreshes: Set<WindowID> = []
  /// ScreenCaptureKit failures by the frame they failed at: skipped until the window
  /// changes or an Overview opening retries it, so a backlog never stalls behind them.
  private var fallbackFailures: [WindowID: Rect] = [:]
  /// Windows a running presentation waits for: captured first, reported at once.
  private var urgent: Set<WindowID> = []
  private var refreshing = false
  private var refreshQueued = false
  private var refreshAfterLanding = false
  private var pendingRefresh: [RibbonProxyRefresh] = []
  private var pendingStills: [RibbonProxyRefresh] = []
  private var pendingDisplays: [CGDirectDisplayID: RibbonProxyScreen] = [:]
  private var forcedBackgrounds: Set<CGDirectDisplayID> = []

  private init() {
    // Light and dark mode redraw every window and may swap the wallpaper: pictures
    // stay as stand-ins but are recaptured as soon as each window is in view.
    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        let cache = WindowCaptureCache.shared
        guard !WindowCaptureStore.shared.pictureIDs.isEmpty else { return }
        ribbonProxyLogger.notice("appearance-changed pictures expired")
        WindowCaptureStore.shared.expirePictures()
        for screen in RibbonProxyStore.shared.allScreens { cache.requestBackground(screen, force: true) }
        cache.scheduleRefresh(after: 0.3, afterLanding: false)
      }
    }
  }

  /// Keeps pictures warm for the next navigation. Missing or resized pictures are
  /// captured promptly; others refresh rarely.
  func noteWindows(_ windows: [RibbonProxyRefresh], afterLanding: Bool) {
    RibbonProxyRenderer.shared.refreshEnvironment()
    guard RibbonProxyRenderer.shared.enabled, RibbonProxyStore.shared.isAuthorized else { return }
    WindowCaptureStore.shared.markShown(windows.filter { $0.distance == 0 }.map(\.id))
    // Layouts carry only the windows they move: merge, so every window stays known
    // (and warm) until it closes.
    let ids = Set(windows.map(\.id))
    pendingRefresh = windows + pendingRefresh.filter { !ids.contains($0.id) }
    for window in windows where window.distance == 0 {
      if let screen = RibbonProxyStore.shared.screen(containing: window.frame) {
        pendingDisplays[screen.displayID] = screen
      }
    }
    for processID in Set(windows.map(\.processID)) { prepareIcon(processID) }
    // Right after a landing: rapid navigation would otherwise start the next motion
    // first, and pictures aged until every arrival showed an old one under a veil.
    scheduleRefresh(after: afterLanding ? 0.05 : 0.5, afterLanding: afterLanding)
  }

  /// The Overview opening counts as a landing: the cards it shows (distance 0) are
  /// refreshed like windows in view, the others like offscreen ribbon windows.
  /// Without a landing (idle warming) only missing, resized or expired pictures are taken.
  func refreshForOverview(_ windows: [RibbonProxyRefresh], displays: [CGDirectDisplayID], landing: Bool) {
    RibbonProxyRenderer.shared.refreshEnvironment()
    guard RibbonProxyStore.shared.isAuthorized else { return }
    WindowCaptureStore.shared.markShown(windows.filter { $0.distance == 0 }.map(\.id))
    if landing, ribbonProxyWindowServerCapture == nil {
      let shown = windows.filter { $0.distance == 0 }.map(\.id)
      overviewRefreshes.formUnion(shown)
      for id in shown { fallbackFailures[id] = nil }
    }
    let ids = Set(windows.map(\.id))
    pendingRefresh = windows + pendingRefresh.filter { !ids.contains($0.id) }
    for screen in RibbonProxyStore.shared.allScreens where displays.contains(screen.displayID) {
      pendingDisplays[screen.displayID] = screen
    }
    scheduleRefresh(after: landing ? 0 : 0.5, afterLanding: landing)
  }

  /// Unmanaged windows shown still on the overlay; refreshed with each landing.
  func noteStills(_ windows: [RibbonProxyRefresh]) {
    guard RibbonProxyRenderer.shared.enabled else { return }
    pendingStills = windows
    guard !windows.isEmpty else { return }
    scheduleRefresh(after: 0, afterLanding: true)
  }

  func captureSoon(_ windows: [RibbonProxyRefresh]) {
    guard RibbonProxyStore.shared.isAuthorized else { return }
    let ids = Set(windows.map(\.id))
    urgent.formUnion(ids)
    pendingRefresh = windows + pendingRefresh.filter { !ids.contains($0.id) }
    for processID in Set(windows.map(\.processID)) { prepareIcon(processID) }
    scheduleRefresh(after: 0.03, afterLanding: false)
  }

  /// The few windows a running motion shows veiled or empty, captured as soon as their
  /// native window sits fully on screen below the overlay. One small capture each,
  /// off the main thread; the usual refresh stays paused while moving.
  func requestBackground(_ screen: RibbonProxyScreen, force: Bool = false) {
    pendingDisplays[screen.displayID] = screen
    if force { forcedBackgrounds.insert(screen.displayID) }
    scheduleRefresh(after: 0, afterLanding: false)
  }

  private func prepareIcon(_ processID: Int32) {
    guard WindowCaptureStore.shared.icon(processID) == nil else { return }
    Task.detached(priority: .utility) {
      var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
      guard let icon = NSRunningApplication(processIdentifier: processID)?.icon?
        .cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
      WindowCaptureStore.shared.setIcon(icon, for: processID)
    }
  }

  // Throttled, not debounced: rapid navigation must not postpone captures
  // forever. A running batch is never cancelled; it reruns once.
  private func scheduleRefresh(after delay: TimeInterval, afterLanding: Bool) {
    refreshAfterLanding = refreshAfterLanding || afterLanding
    guard !refreshing else {
      refreshQueued = true
      refreshQueuedSoon = refreshQueuedSoon || delay < 0.1
      return
    }
    let due = CACurrentMediaTime() + delay
    // A sooner request (a landing waiting for a fresh picture) replaces a pass that
    // is still only waiting to start.
    if refresh != nil {
      guard due < refreshDue else { return }
      refresh?.cancel()
    }
    refreshDue = due
    refresh = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self else { return }
      refreshing = true
      let afterLanding = refreshAfterLanding
      refreshAfterLanding = false
      await refreshPictures(afterLanding: afterLanding)
      // A pass skipped for a running motion captured nothing: no overlay commit.
      if !refreshBlockedByMotion { announceWindowCaptures() }
      refreshing = false
      refresh = nil
      if refreshQueued {
        let soon = refreshQueuedSoon, blocked = refreshBlockedByMotion
        refreshQueued = false; refreshQueuedSoon = false; refreshBlockedByMotion = false
        // A landing's fade still counts as moving: 50 ms later, not 0.5 s, or rapid
        // navigation postpones every refresh.
        scheduleRefresh(after: blocked ? 0.05 : soon ? 0 : 0.5, afterLanding: false)
      }
    }
  }

  /// A pass blocked by a running motion retries shortly, keeping its landing refresh.
  private func deferForMotion(afterLanding: Bool) {
    refreshQueued = true; refreshBlockedByMotion = true
    refreshAfterLanding = refreshAfterLanding || afterLanding
  }

  private func refreshPictures(afterLanding: Bool) async {
    let store = WindowCaptureStore.shared, ribbon = RibbonProxyStore.shared
    guard !ribbon.isMoving else { return deferForMotion(afterLanding: afterLanding) }
    // One WindowServer list per pass, off the main thread (which also drives the
    // drag ticker): it gives native frames, stacking and liveness at once.
    let known = store.pictureIDs.union(pendingRefresh.map(\.id))
    let (onScreen, alive) = await Task.detached(priority: .utility) {
      let onScreen = ribbonProxyOnScreenWindows()
      let shown = Set(onScreen.map(\.id))
      // Hidden and minimized windows are alive but absent from the on-screen list.
      return (onScreen, shown.union(ribbonProxyNativeFrames(known.subtracting(shown)).keys))
    }.value
    guard !ribbon.isMoving else { return deferForMotion(afterLanding: afterLanding) }
    ribbon.onScreen = onScreen
    store.retainPictures(alive)
    pendingRefresh.removeAll { !alive.contains($0.id) }
    let now = CACurrentMediaTime()
    // Missing or resized windows are captured at once; after a landing, windows in view
    // are recaptured too, others when older than a minute.
    // shortcut: unchanged windows are recaptured too; a per-window damage signal would skip them.
    var requests = pendingRefresh.filter { window in
      guard let picture = store.picture(window.id),
        ribbonProxyPictureMatches(captured: picture.size, native: window.frame)
      else { return true }
      // Expired by an appearance change: recaptured at once.
      if picture.capturedAt == 0 { return true }
      // Reduced to fit the byte cap: recaptured once shown, not on every landing.
      if picture.isReduced && window.distance > 0 { return false }
      // Aged pictures refresh only with a landing: a layout at rest captures nothing.
      // Outstanding Overview refreshes stay selected across passes until attempted.
      return overviewRefreshes.contains(window.id)
        || (afterLanding && now - picture.capturedAt > (window.distance == 0 ? 0.45 : 60))
    }.sorted { $0.distance < $1.distance }
    // The wallpaper gates every presentation, so it is captured first, once per
    // display geometry. A display gone or reshaped since its request uses its current geometry.
    let screens = Dictionary(ribbon.allScreens.map { ($0.displayID, $0) }) { first, _ in first }
    pendingDisplays = pendingDisplays.compactMapValues { screens[$0.displayID] }
    var displays = pendingDisplays.values.filter { display in
      forcedBackgrounds.contains(display.displayID) || store.background(display.displayID)?.width
        != Int(display.frame.width * display.scale)
    }
    forcedBackgrounds.subtract(displays.map(\.displayID))
    // ScreenCaptureKit lights the recording indicator and pays a privacy check (tccd,
    // systemstatusd) per call: the WindowServer capture covers the wallpaper and every
    // window, parked ones included, and ScreenCaptureKit is only its fallback.
    if let capture = ribbonProxyWindowServerCapture {
      for shown in displays {
        guard let image = await Task.detached(priority: .userInitiated, operation: {
          ribbonProxyDesktopImage(CGRect(x: shown.frame.x, y: shown.frame.y,
            width: shown.frame.width, height: shown.frame.height), capture)
        }).value, image.width == Int(shown.frame.width * shown.scale) else { continue }
        store.setBackground(image, for: shown.displayID)
        displays.removeAll { $0.displayID == shown.displayID }
      }
    }
    // Native frames, not targets: a window still resizing is captured, and cropped,
    // at its real size.
    let native = Dictionary(onScreen.map { ($0.id, $0.frame) }) { first, _ in first }
    let owners = Dictionary(onScreen.map { ($0.id, $0.processID) }) { first, _ in first }
    let visible = requests.compactMap { request -> RibbonProxyRefresh? in
      // A reused window number must never show another app's picture.
      guard owners[request.id].map({ $0 == request.processID }) != false else { return nil }
      guard ribbonProxyWindowServerCapture != nil
        || native[request.id].map(ribbonProxyFullyOnScreen) == true else { return nil }
      return RibbonProxyRefresh(id: request.id, appID: request.appID, processID: request.processID,
        frame: native[request.id] ?? request.frame, distance: request.distance)
    }
    let visibleIDs = Set(visible.map(\.id))
    // ScreenCaptureKit fallback: only windows never captured, resized since (a display
    // change), or expired by an appearance change; a cropped picture made each landing wait.
    requests = requests.filter { request in
      if fallbackFailures[request.id] == request.frame { return false }
      if ribbonProxyWindowServerCapture == nil, overviewRefreshes.contains(request.id) { return true }
      return (ribbonProxyWindowServerCapture == nil || !visibleIDs.contains(request.id)) && store.picture(request.id).map {
        $0.capturedAt == 0 || !ribbonProxyPictureMatches(captured: $0.size, native: native[request.id] ?? request.frame)
      } ?? true
    }
    // Short passes keep stills and visible windows from queueing behind slow
    // ScreenCaptureKit captures of parked windows; the rest follows next pass.
    let backlog = requests.count > 3
    if backlog { requests = Array(requests.prefix(3)); refreshQueued = true }
    guard !displays.isEmpty || !visible.isEmpty || !requests.isEmpty || !pendingStills.isEmpty
    else { return }
    // One call per window: a multi-window call returns a single composite whose
    // extent did not reliably match the requested frames, losing every picture.
    if let capture = ribbonProxyWindowServerCapture {
      // A landing waits for these: capture them together, report each at once.
      let pressing = visible.filter { urgent.contains($0.id) }
      await withTaskGroup(of: (RibbonProxyRefresh, WindowPicture?).self) { group in
        for request in pressing {
          guard let id = CGWindowID(exactly: request.id.rawValue) else { continue }
          group.addTask(priority: .userInitiated) { (request, windowPicture(capture([id]), native: request.frame)) }
        }
        for await (request, picture) in group {
          urgent.remove(request.id)
          if let picture { store.setPicture(picture, for: request) }
          // Reported even when the app had not redrawn yet: the presenter asks again.
          announceWindowCaptures()
        }
      }
      let pressed = Set(pressing.map(\.id))
      for request in visible where !ribbon.isMoving && !pressed.contains(request.id) {
        guard let id = CGWindowID(exactly: request.id.rawValue) else { continue }
        let started = CACurrentMediaTime()
        let picture = await Task.detached(priority: .utility) {
          windowPicture(capture([id]), native: request.frame)
        }.value
        ribbonProxyLogger.debug("capture-fast id=\(id) ok=\(picture != nil) expected=\(Int(request.frame.width))x\(Int(request.frame.height)) ms=\(Int((CACurrentMediaTime() - started) * 1_000))")
        if let picture { store.setPicture(picture, for: request) } else { failureCount += 1 }
      }
    }
    // Unmanaged windows may overlap managed ones, so each gets its own call.
    if let capture = ribbonProxyWindowServerCapture {
      for still in pendingStills {
        if let picture = store.picture(still.id), !afterLanding || now - picture.capturedAt < 2,
          ribbonProxyPictureMatches(captured: picture.size, native: still.frame) { continue }
        guard let id = CGWindowID(exactly: still.id.rawValue) else { continue }
        let picture = await Task.detached(priority: .utility) {
          windowPicture(capture([id]), native: still.frame)
        }.value
        ribbonProxyLogger.notice("capture-still id=\(still.id.rawValue) ok=\(picture != nil) expected=\(Int(still.frame.width))x\(Int(still.frame.height))")
        if let picture {
          store.setPicture(picture, for: still)
        } else {
          // Gone or no longer capturable: the next presentation reports it again if still visible.
          pendingStills.removeAll { $0.id == still.id }
        }
      }
    }
    // ScreenCaptureKit (wallpaper, never-seen windows) can stall for seconds, e.g.
    // while macOS asks for permission: it runs apart, so visible windows above keep
    // refreshing every pass and a landing never waits behind it.
    if (!displays.isEmpty || !requests.isEmpty) && !slowCapturesRunning {
      slowCapturesRunning = true
      let slowRequests = requests, slowDisplays = displays
      Task { [weak self] in
        let attempted = await self?.slowCaptures(displays: slowDisplays, requests: slowRequests) ?? 0
        self?.slowCapturesRunning = false
        // A pass queued meanwhile skipped the backlog; failures are skipped next, so it ends.
        if backlog && attempted > 0 { self?.scheduleRefresh(after: 0, afterLanding: false) }
        announceWindowCaptures()
      }
    }
  }

  /// Returns the number of windows attempted, captured or failed.
  @discardableResult
  private func slowCaptures(displays: [RibbonProxyScreen], requests: [RibbonProxyRefresh]) async -> Int {
    let store = WindowCaptureStore.shared, ribbon = RibbonProxyStore.shared
    var content: SCShareableContent?
    if !displays.isEmpty || !requests.isEmpty {
      guard await overviewCaptureLimiter.acquire() else { return 0 }
      do {
        content = try await withOverviewCaptureTimeout {
          try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        await overviewCaptureLimiter.release()
      } catch {
        await overviewCaptureLimiter.release(error: error as NSError)
      }
    }
    for display in displays {
      guard let content,
        let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else { continue }
      let filter = SCContentFilter(display: scDisplay,
        including: content.windows.filter { $0.windowLayer < 0 })
      filter.includeMenuBar = false
      if let buffer = await capture(filter, width: display.frame.width * display.scale,
        height: display.frame.height * display.scale), let image = ribbonProxyTaggedImage(buffer) {
        store.setBackground(image, for: display.displayID)
      }
    }
    guard let content, !requests.isEmpty else { return 0 }
    var attempted = 0
    let windows = Dictionary(content.windows.map { ($0.windowID, $0) }) { first, _ in first }
    for request in requests where !Task.isCancelled && !ribbon.isMoving {
      // One attempt per opening, captured or not.
      overviewRefreshes.remove(request.id)
      attempted += 1
      guard let id = CGWindowID(exactly: request.id.rawValue), let window = windows[id],
        window.owningApplication?.bundleIdentifier == request.appID
      else {
        fallbackFailures[request.id] = request.frame
        continue
      }
      let scale = CGFloat(ribbon.screen(containing: request.frame)?.scale ?? 2)
      // Backing resolution like the WindowServer captures: a 1× picture swapped for a 2×
      // one mid-dissolve was drawn at the wrong scale, the content visibly zooming.
      let buffer = await capture(SCContentFilter(desktopIndependentWindow: window),
        width: window.frame.width * scale, height: window.frame.height * scale)
      ribbonProxyLogger.notice("capture-sck id=\(request.id.rawValue) ok=\(buffer != nil)")
      if let buffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
        store.setPicture(WindowPicture(contents: ribbonProxyTaggedImage(buffer) ?? surface, buffer: buffer,
          size: window.frame.size, capturedAt: CACurrentMediaTime(), pixelScale: scale), for: request)
        fallbackFailures[request.id] = nil
      } else {
        failureCount += 1
        fallbackFailures[request.id] = request.frame
      }
    }
    return attempted
  }

  // IOSurface-backed BGRA: layers display it without a CPU copy or re-upload.
  private func capture(_ filter: SCContentFilter, width: CGFloat, height: CGFloat) async -> CVPixelBuffer? {
    let configuration = SCStreamConfiguration()
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.width = max(Int(width.rounded()), 2)
    configuration.height = max(Int(height.rounded()), 2)
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.ignoreShadowsSingleWindow = true
    guard await overviewCaptureLimiter.acquire() else { return nil }
    do {
      let sample = try await withOverviewCaptureTimeout {
        try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
      }
      await overviewCaptureLimiter.release()
      guard let buffer = CMSampleBufferGetImageBuffer(sample),
        CVPixelBufferGetIOSurface(buffer) != nil else { return nil }
      return buffer
    } catch {
      await overviewCaptureLimiter.release(error: error as NSError)
      return nil
    }
  }
}

extension WindowPicture: Equatable {
  static func == (lhs: WindowPicture, rhs: WindowPicture) -> Bool {
    lhs.contents === rhs.contents && lhs.capturedAt == rhs.capturedAt
  }
}

extension Rect {
  func ribbonIntersects(_ other: Rect) -> Bool {
    x + width > other.x && other.x + other.width > x
      && y + height > other.y && other.y + other.height > y
  }
}
