import AppKit
import Darwin
import DefiCore
import DefiModel

// Public setFrame cannot keep borders within a frame of their windows during
// Defi animations (measured p95 up to 97 pt vs 19 pt). Private mutation is
// therefore limited to Defi-owned border surfaces; third-party windows are
// only observed.

enum WindowServerWindowEvent: Equatable {
  case moved(WindowID)
  case resized(WindowID)
  case reordered(WindowID)
  case closed(WindowID)

  init?(code: UInt32, windowID: WindowID) {
    switch code {
    case 806: self = .moved(windowID)
    case 807: self = .resized(windowID)
    case 808: self = .reordered(windowID)
    case 804: self = .closed(windowID)
    default: return nil
    }
  }
}

enum BorderSyncBackend: Equatable {
  case windowServer
  case fallback(String)
}

struct BorderSurfaceMove: Equatable {
  let windowNumber: UInt32
  /// Global top-left coordinates, like AX and SLSGetWindowBounds.
  let origin: CGPoint
}

@MainActor
protocol WindowServerWindowEventSource: AnyObject {
  /// Registers the event handler once. Returns false when unavailable.
  func start(_ handler: @escaping @MainActor (WindowServerWindowEvent) -> Void) -> Bool
  func requestNotifications(for windowIDs: [UInt32]) -> Bool
}

@MainActor
protocol BorderSurfaceMoving: AnyObject {
  /// Moves all surfaces in one transaction. Returns false on failure.
  func move(_ moves: [BorderSurfaceMove]) -> Bool
}

/// Drives border geometry from WindowServer window notifications.
/// Sticky downgrade: any backend failure selects the public path for the session.
@MainActor
final class WindowBorderSync {
  private let events: WindowServerWindowEventSource
  private let mover: BorderSurfaceMoving
  private let schedule: (@escaping @MainActor () -> Void) -> Void
  private(set) var backend: BorderSyncBackend
  private(set) var eventCount = 0
  private(set) var moveCount = 0
  private(set) var fallbackCount = 0
  private(set) var reconcileCount = 0
  private(set) var subscribedWindowIDs = Set<WindowID>()
  private var started = false
  private var dirty = Set<WindowID>()
  private var reorderPending = false
  private var flushScheduled = false

  /// Receives the coalesced dirty windows once per run-loop turn.
  var onFlush: (Set<WindowID>) -> Void = { _ in }
  var onReordered: () -> Void = {}
  var onClosed: (WindowID) -> Void = { _ in }

  init(
    events: WindowServerWindowEventSource,
    mover: BorderSurfaceMoving,
    available: Bool = true,
    schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
      DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
  ) {
    self.events = events
    self.mover = mover
    self.schedule = schedule
    backend = available ? .windowServer : .fallback("unavailable")
  }

  var isWindowServer: Bool { backend == .windowServer }

  var backendDescription: String {
    switch backend {
    case .windowServer: "windowserver"
    case .fallback(let reason): "fallback:\(reason)"
    }
  }

  var statusDescription: String {
    "borderSync=\(backendDescription) borderSyncEvents=\(eventCount) borderSyncMoves=\(moveCount)"
      + " borderSyncFallbacks=\(fallbackCount) borderSyncReconciles=\(reconcileCount)"
  }

  func downgrade(_ reason: String) {
    fallbackCount += 1
    guard isWindowServer else { return }
    backend = .fallback(reason)
    dirty.removeAll()
    reorderPending = false
  }

  /// Requests notifications only when the overlay set changes.
  func subscribe(_ windowIDs: Set<WindowID>) {
    guard isWindowServer, windowIDs != subscribedWindowIDs else { return }
    if !started {
      guard !windowIDs.isEmpty else { return }
      guard events.start({ [weak self] in self?.receive($0) }) else {
        return downgrade("notify")
      }
      started = true
    }
    let raw = windowIDs.compactMap { UInt32(exactly: $0.rawValue) }.sorted()
    guard events.requestNotifications(for: raw) else { return downgrade("request") }
    subscribedWindowIDs = windowIDs
  }

  func receive(_ event: WindowServerWindowEvent) {
    guard isWindowServer else { return }
    eventCount += 1
    switch event {
    case .moved(let windowID), .resized(let windowID):
      guard subscribedWindowIDs.contains(windowID) else { return }
      dirty.insert(windowID)
    case .reordered(let windowID):
      guard subscribedWindowIDs.contains(windowID) else { return }
      reorderPending = true
    case .closed(let windowID):
      dirty.remove(windowID)
      onClosed(windowID)
      return
    }
    guard !flushScheduled else { return }
    flushScheduled = true
    schedule { [weak self] in self?.flush() }
  }

  func flush() {
    flushScheduled = false
    let windowIDs = dirty
    dirty.removeAll(keepingCapacity: true)
    if !windowIDs.isEmpty { onFlush(windowIDs) }
    if reorderPending {
      reorderPending = false
      onReordered()
    }
  }

  /// Recovers a coalesced or missed final move once Defi's animation ends.
  func reconcile(_ windowIDs: Set<WindowID>) {
    guard isWindowServer, !windowIDs.isEmpty else { return }
    reconcileCount += 1
    onFlush(windowIDs)
  }

  func move(_ moves: [BorderSurfaceMove]) -> Bool {
    guard isWindowServer else { return false }
    guard mover.move(moves) else {
      downgrade("move")
      return false
    }
    moveCount += moves.count
    return true
  }
}

/// After a reorder or front-app change WindowServer z-order settles over a few
/// frames; re-resolve stacking at fixed delays after the latest trigger.
@MainActor
final class WindowBorderStackingSettle {
  static let delaysMS = [16, 40, 80]
  private let schedule: (Int, @escaping @MainActor () -> Void) -> () -> Void
  private var cancels: [() -> Void] = []
  var onPass: () -> Void = {}

  init(schedule: @escaping (Int, @escaping @MainActor () -> Void) -> () -> Void) {
    self.schedule = schedule
  }

  /// A newer trigger replaces pending passes, so at most three are ever queued.
  func trigger() {
    for cancel in cancels { cancel() }
    cancels = Self.delaysMS.map { schedule($0) { [weak self] in self?.onPass() } }
  }
}

/// AppKit caches window frames and SkyLight moves bypass that cache; a stale
/// cache makes a later setFrame to that cached frame a no-op.
@MainActor
enum AppKitWindowFrameCache {
  private typealias Refresh = @convention(c) (AnyObject, Selector) -> Void
  private static let selector = NSSelectorFromString("_getPositionFromServer")
  private static let refreshImplementation: Refresh? = {
    guard NSPanel.instancesRespond(to: selector),
      let implementation = class_getMethodImplementation(NSPanel.self, selector)
    else { return nil }
    return unsafeBitCast(implementation, to: Refresh.self)
  }()

  static var isAvailable: Bool { refreshImplementation != nil }

  /// Rereads the window position from WindowServer without moving it.
  static func refresh(_ window: NSWindow) {
    refreshImplementation?(window, selector)
  }
}

let windowBorderAuditTolerance = 2.0

func windowBorderFrameError(_ expected: Rect, _ actual: Rect) -> Double {
  max(
    abs(expected.x - actual.x), abs(expected.y - actual.y),
    abs(expected.width - actual.width), abs(expected.height - actual.height))
}

/// Compares each border's expected edge frames (from the target's WindowServer
/// bounds) with the edges' WindowServer bounds, keyed by edge window number.
func windowBorderAuditReport(
  expected: [WindowID: [UInt32: Rect]],
  actual: [UInt32: Rect],
  backend: String
) -> String {
  var compared = 0
  var mismatches = 0
  var worst = 0.0
  var worstWindowID: WindowID?
  for windowID in expected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
    let errors = expected[windowID, default: [:]].compactMap { number, frame in
      actual[number].map { windowBorderFrameError(frame, $0) }
    }
    guard let error = errors.max() else { continue }
    compared += 1
    if error > windowBorderAuditTolerance { mismatches += 1 }
    if error > worst {
      worst = error
      worstWindowID = windowID
    }
  }
  guard compared > 0 else { return "backend=\(backend) no-comparable-borders" }
  var result = "backend=\(backend) compared=\(compared) mismatches>2pt=\(mismatches)"
  result += " worst=\(String(format: "%.2f", worst))pt"
  if let worstWindowID { result += " wid=\(worstWindowID.rawValue)" }
  return result
}

private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

private func resolveSkyLight<T>(_ symbol: String, as _: T.Type) -> T? {
  guard let handle = dlopen(skyLightPath, RTLD_LAZY | RTLD_LOCAL),
    let pointer = dlsym(handle, symbol)
  else { return nil }
  return unsafeBitCast(pointer, to: T.self)
}

private typealias SkyLightMainConnectionID = @convention(c) () -> Int32
private typealias SkyLightNotifyProc =
  @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

@MainActor
final class SkyLightWindowEventSource: WindowServerWindowEventSource {
  private typealias RegisterNotifyProc =
    @convention(c) (SkyLightNotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
  private typealias RequestNotifications =
    @convention(c) (Int32, UnsafePointer<UInt32>?, Int32) -> Int32

  // SkyLight keeps notify procs for the process lifetime, so the source is a singleton.
  static let shared = SkyLightWindowEventSource()

  private let mainConnectionID = resolveSkyLight("SLSMainConnectionID", as: SkyLightMainConnectionID.self)
  private let register = resolveSkyLight("SLSRegisterNotifyProc", as: RegisterNotifyProc.self)
  private let request = resolveSkyLight(
    "SLSRequestNotificationsForWindows", as: RequestNotifications.self)
  private var handler: (@MainActor (WindowServerWindowEvent) -> Void)?

  var isAvailable: Bool { mainConnectionID != nil && register != nil && request != nil }

  func start(_ handler: @escaping @MainActor (WindowServerWindowEvent) -> Void) -> Bool {
    guard let register, isAvailable else { return false }
    guard self.handler == nil else {
      self.handler = handler
      return true
    }
    self.handler = handler
    let proc: SkyLightNotifyProc = { code, data, length, _ in
      guard let data, length >= MemoryLayout<UInt32>.size else { return }
      let windowID = WindowID(rawValue: UInt64(data.loadUnaligned(as: UInt32.self)))
      guard let event = WindowServerWindowEvent(code: code, windowID: windowID) else { return }
      // WindowServer delivers through the main run loop; never block there otherwise.
      if Thread.isMainThread {
        MainActor.assumeIsolated { SkyLightWindowEventSource.shared.handler?(event) }
      } else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { SkyLightWindowEventSource.shared.handler?(event) }
        }
      }
    }
    for code: UInt32 in [804, 806, 807, 808] where register(proc, code, nil) != 0 {
      self.handler = nil
      return false
    }
    return true
  }

  func requestNotifications(for windowIDs: [UInt32]) -> Bool {
    guard let mainConnectionID, let request else { return false }
    return windowIDs.withUnsafeBufferPointer {
      request(mainConnectionID(), $0.baseAddress, Int32($0.count))
    } == 0
  }
}

@MainActor
final class SkyLightBorderSurfaceMover: BorderSurfaceMoving {
  private typealias TransactionCreate = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
  private typealias TransactionMove = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Int32
  private typealias TransactionCommit = @convention(c) (CFTypeRef, Int32) -> Int32

  private let mainConnectionID = resolveSkyLight("SLSMainConnectionID", as: SkyLightMainConnectionID.self)
  private let create = resolveSkyLight("SLSTransactionCreate", as: TransactionCreate.self)
  private let moveWindow = resolveSkyLight(
    "SLSTransactionMoveWindowWithGroup", as: TransactionMove.self)
  private let commit = resolveSkyLight("SLSTransactionCommit", as: TransactionCommit.self)
  private let readBounds: (UInt32) -> Rect?
  private var verified = false

  init(readBounds: @escaping (UInt32) -> Rect?) {
    self.readBounds = readBounds
  }

  var isAvailable: Bool {
    mainConnectionID != nil && create != nil && moveWindow != nil && commit != nil
  }

  func move(_ moves: [BorderSurfaceMove]) -> Bool {
    guard !moves.isEmpty else { return true }
    guard let mainConnectionID, let create, let moveWindow, let commit,
      let transaction = create(mainConnectionID())?.takeRetainedValue()
    else { return false }
    // Return codes of these calls are not meaningful CGErrors; verify by readback instead.
    for move in moves { _ = moveWindow(transaction, move.windowNumber, move.origin) }
    _ = commit(transaction, 0)
    guard !verified else { return true }
    // Probe once on the first Defi-owned surface we move.
    let probe = moves[0]
    guard let bounds = readBounds(probe.windowNumber),
      abs(bounds.x - probe.origin.x) <= 0.5, abs(bounds.y - probe.origin.y) <= 0.5
    else { return false }
    verified = true
    return true
  }
}

/// WindowServer-driven borders read only real bounds, falling back to the plan
/// before a window has bounds; AX-displayed frames apply only to the public path.
func windowBorderGeometryFrame(
  windowServerDriven: Bool,
  windowServerFrame: Rect?,
  displayedFrame: Rect?,
  plannedFrame: Rect?
) -> Rect? {
  windowServerDriven
    ? windowServerFrame ?? plannedFrame
    : resolvedWindowBorderFrame(
      nativeFrame: nil, observedFrame: displayedFrame, plannedFrame: plannedFrame)
}
