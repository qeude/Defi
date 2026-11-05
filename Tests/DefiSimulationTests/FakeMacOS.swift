import ApplicationServices
import DefiModel
import Foundation
import Synchronization

@testable import DefiMacOS

/// Every behavior the fake macOS may show. The fake does nothing outside this list, and
/// each entry names its source. A harness failure stays a suspect until it reproduces on
/// the VM or the real desktop.
enum FakeMacBehavior: String, CaseIterable, Sendable {
  /// AXUIElement.h, AXUIElementSetMessagingTimeout: an AX call waits for the app up to
  /// its timeout, 16 ms then 50 ms for focus writes (AXFocusWriterExecution). Input and
  /// commands keep arriving meanwhile. Used whenever a step runs while the writer waits.
  case axCallTakesUpToItsTimeout
  /// AXError.h, kAXErrorCannotComplete: messaging fails "because the application with
  /// which the function is communicating is busy or unresponsive". Defi bounds focus
  /// writes to 16 ms then 50 ms (AXFocusWriterExecution), so a busy app can fail any of
  /// them, any number of times in a row.
  case busyAppTimesOut
  /// AXUIElement.h, AXUIElementPerformAction: kAXErrorCannotComplete "does not
  /// necessarily mean that the function has failed". A busy app may apply the write
  /// once it responds again.
  case timedOutWriteLandsLater
  /// Defi architecture: the event tap callback and the AX focus queue run on different
  /// threads, so the focus writer may read UserInputTracker between two steps of
  /// InputMonitor.handle. Modelled at each callout the tap makes.
  case writerRunsDuringTapCallout
  /// AGENTS.md, "AX notifications drive discovery, with bounded delayed reads for apps
  /// that report late": Defi learns a native focus change only when its notification
  /// is delivered, after the change itself.
  case focusNotificationArrivesLate
  /// AXError.h, kAXErrorAPIDisabled: "Assistive applications are not enabled in System
  /// Preferences". The user can revoke Defi's Accessibility grant at any time; every AX call
  /// then fails until it is granted again (AGENTS.md: navigation never depends on capture,
  /// and Defi must not spin while it waits).
  case accessibilityRevoked
}

/// Lets the harness advance the real AXFocusWriter one AX call at a time. The writer
/// thread parks before each call until the harness releases it.
final class WriterGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var parkedOperation: String?
  private var permits = 0
  private var open = false

  func arrive(_ operation: String) {
    condition.lock()
    defer { condition.unlock() }
    guard !open else { return }
    parkedOperation = operation
    condition.broadcast()
    while permits == 0 && !open { condition.wait() }
    if permits > 0 { permits -= 1 }
    parkedOperation = nil
  }

  /// Releases one AX call and waits until the writer parks again or goes idle.
  /// Returns the call it released, or nil when the writer was idle.
  @discardableResult
  func step(writerBusy: () -> Bool) -> String? {
    guard let operation = waitUntilParkedOrIdle(writerBusy: writerBusy) else { return nil }
    condition.lock()
    permits += 1
    condition.broadcast()
    condition.unlock()
    _ = waitUntilParkedOrIdle(writerBusy: writerBusy)
    return operation
  }

  func waitUntilParkedOrIdle(writerBusy: () -> Bool) -> String? {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      condition.lock()
      let parked = permits == 0 ? parkedOperation : nil
      condition.unlock()
      if let parked { return parked }
      if !writerBusy() {
        condition.lock()
        let late = permits == 0 ? parkedOperation : nil
        condition.unlock()
        return late
      }
      usleep(20)
    }
    fatalError("AX focus writer neither parked nor finished within 5 s")
  }

  /// Lets every later call through, so no writer thread stays parked after a run.
  func openPermanently() {
    condition.lock()
    open = true
    condition.broadcast()
    condition.unlock()
  }
}

/// A pessimistic but faithful macOS: native focus state for a few apps, reachable only
/// through the AXFocusOperations seam that AXFocusWriter calls.
final class FakeMacOS: @unchecked Sendable {
  struct App {
    var busy = false
    var focusedWindow: WindowID?
    var lateWrites: [WindowID] = []
  }

  let gate = WriterGate()
  let owners: [WindowID: pid_t]
  private let lock = NSLock()
  private var apps: [pid_t: App]
  private var frontmost: pid_t
  private var notificationPending = false
  private var used = Set<FakeMacBehavior>()
  /// Set by the harness while a key press should let the writer run during a tap callout.
  var writerStepsDuringTapCallout = false
  /// Every AX write attempted while Accessibility is revoked, since the last `takeDeniedAttempts()`.
  private var accessibilityGranted = true
  private var deniedAttempts = 0

  func setAccessibility(granted: Bool) {
    lock.withLock {
      accessibilityGranted = granted
      if !granted { used.insert(.accessibilityRevoked) }
    }
  }

  func takeDeniedAttempts() -> Int { lock.withLock { defer { deniedAttempts = 0 }; return deniedAttempts } }

  /// True while Accessibility is revoked; counts the refused call (caller holds the lock).
  private func refusedWithoutAccessibility() -> Bool {
    guard !accessibilityGranted else { return false }
    deniedAttempts += 1
    return true
  }
  var writerBusy: @Sendable () -> Bool = { false }

  init(space: Int32, owners: [WindowID: pid_t], focused: [pid_t: WindowID], frontmost: pid_t) {
    self.space = space
    self.owners = owners
    self.frontmost = frontmost
    apps = Dictionary(uniqueKeysWithValues: Set(owners.values).map {
      ($0, App(focusedWindow: focused[$0]))
    })
  }

  /// Each simulated macOS gets its own element space, so worlds running side by side in one
  /// process never share an Accessibility element or a cache keyed by one.
  private static let spaces = Mutex<Int32>(0)
  static func spaceForNextWorld() -> Int32 { spaces.withLock { $0 += 1; return $0 } }
  let space: Int32

  func windowElement(_ windowID: WindowID) -> AXUIElement {
    AXUIElementCreateApplication(-(1_000_000 + space * 1_000 + pid_t(windowID.rawValue)))
  }

  func applicationElement(_ processID: pid_t) -> AXUIElement {
    AXUIElementCreateApplication(processID)
  }

  var keyWindow: WindowID? { lock.withLock { apps[frontmost]?.focusedWindow } }

  /// Native frames, as Accessibility and the WindowServer report them.
  private var nativeFrames: [WindowID: Rect] = [:]
  /// Native moves per window since the last `takeMoves()`: one motion should move a window once.
  private var moves: [WindowID: Int] = [:]
  /// Every frame macOS applied since the last `takeWrites()`, in order.
  private var writes: [(window: WindowID, frame: Rect)] = []

  func frame(of windowID: WindowID) -> Rect? { lock.withLock { nativeFrames[windowID] } }

  func setFrame(_ frame: Rect, of windowID: WindowID) { lock.withLock { nativeFrames[windowID] = frame } }

  // Frame writes run on the frame coordinator's queues, outside the focus writer's gate.
  func moveWindow(_ element: AXUIElement, to point: CGPoint) -> Bool {
    guard let windowID = windowID(of: element) else { return false }
    return lock.withLock {
      guard !refusedWithoutAccessibility(), var frame = nativeFrames[windowID] else { return false }
      if let owner = owners[windowID], apps[owner]?.busy == true { noteBusyCall(element, owner) }
      frame.x = point.x
      frame.y = point.y
      nativeFrames[windowID] = frame
      moves[windowID, default: 0] += 1
      writes.append((windowID, frame))
      return true
    }
  }

  func resizeWindow(_ element: AXUIElement, to size: CGSize) -> Bool {
    guard let windowID = windowID(of: element) else { return false }
    return lock.withLock {
      guard !refusedWithoutAccessibility(), var frame = nativeFrames[windowID] else { return false }
      if let owner = owners[windowID], apps[owner]?.busy == true { noteBusyCall(element, owner) }
      frame.width = size.width
      frame.height = size.height
      nativeFrames[windowID] = frame
      writes.append((windowID, frame))
      return true
    }
  }

  /// Messaging timeouts Defi set, by element (AXUIElementSetMessagingTimeout).
  private var messagingTimeouts: [CFHashCode: Float] = [:]
  /// The longest a call to a busy app held its caller since the last take: the element's
  /// messaging timeout, else its application's, else the 6 s Accessibility default.
  private var slowestBusyCall: Float = 0

  /// Defi's own timeout bookkeeping, setting timeouts on this fake instead of macOS.
  lazy var timeoutAccess = AXMessagingTimeoutAccess { [unowned self] in self.setMessagingTimeout($0, $1) }

  func setMessagingTimeout(_ element: AXUIElement, _ timeout: Float) {
    lock.withLock { messagingTimeouts[CFHash(element)] = timeout > 0 ? timeout : nil }
  }

  func takeSlowestBusyCall() -> Float { lock.withLock { defer { slowestBusyCall = 0 }; return slowestBusyCall } }

  /// Called with `lock` held, for an Accessibility call that reached a busy app.
  private func noteBusyCall(_ element: AXUIElement, _ processID: pid_t) {
    used.insert(.busyAppTimesOut)
    let timeout = messagingTimeouts[CFHash(element)]
      ?? messagingTimeouts[CFHash(applicationElement(processID))] ?? 6
    slowestBusyCall = max(slowestBusyCall, timeout)
  }

  /// A frame read, as the window's app answers it: a busy app holds the read like any call.
  func readFrame(_ element: AXUIElement) -> Rect? {
    guard let windowID = windowID(of: element) else { return nil }
    return lock.withLock {
      if let owner = owners[windowID], apps[owner]?.busy == true { noteBusyCall(element, owner) }
      return nativeFrames[windowID]
    }
  }

  /// AXEnhancedUserInterface, which Defi turns off around frame writes; a busy app holds it too.
  func setEnhancedUserInterface(_ application: AXUIElement) -> Bool {
    let processID = processID(of: application)
    return lock.withLock {
      if apps[processID]?.busy == true { noteBusyCall(application, processID) }
      return true
    }
  }

  func takeMoves() -> [WindowID: Int] { lock.withLock { defer { moves = [:] }; return moves } }

  func takeWrites() -> [(window: WindowID, frame: Rect)] { lock.withLock { defer { writes = [] }; return writes } }
  var frontmostProcessID: pid_t { lock.withLock { frontmost } }
  var behaviorsUsed: Set<FakeMacBehavior> { lock.withLock { used } }

  func takeFocusNotification() -> Bool {
    lock.withLock {
      defer { notificationPending = false }
      if notificationPending { used.insert(.focusNotificationArrivesLate) }
      return notificationPending
    }
  }

  func setBusy(_ processID: pid_t, _ busy: Bool, landLateWrites: Bool) {
    lock.withLock {
      apps[processID]?.busy = busy
      guard !busy, var app = apps[processID] else { return }
      if landLateWrites, let window = app.lateWrites.last {
        used.insert(.timedOutWriteLandsLater)
        app.focusedWindow = window
        if frontmost == processID { notificationPending = true }
      }
      app.lateWrites.removeAll()
      apps[processID] = app
    }
  }

  func noteStepWhileWriterWaits() {
    if writerBusy() { lock.withLock { _ = used.insert(.axCallTakesUpToItsTimeout) } }
  }

  func tapCallout() {
    guard writerStepsDuringTapCallout else { return }
    writerStepsDuringTapCallout = false
    if gate.step(writerBusy: writerBusy) != nil {
      lock.withLock { _ = used.insert(.writerRunsDuringTapCallout) }
    }
  }

  var operations: AXFocusOperations {
    var operations = AXFocusOperations()
    operations.targetIsFocused = { [self] element, _ in
      gate.arrive("read-focus")
      let window = windowID(of: element)
      return lock.withLock {
        guard !refusedWithoutAccessibility(), let window, let processID = owners[window], let app = apps[processID] else {
          return false
        }
        // Production bounds this read itself (AXFocusOperations.targetIsFocused), outside
        // the operations this fake replaces, so it adds no cost here.
        if app.busy {
          used.insert(.busyAppTimesOut)
          return false
        }
        // Measured 2026-11-05 (desktop fidelity trace, GitHub macos-26): an app's focused
        // window reads as focused even while another app is frontmost.
        return app.focusedWindow == window
      }
    }
    operations.setMain = { [self] element in
      gate.arrive("set-main")
      return selectWindow(element)
    }
    operations.raise = { [self] element in
      gate.arrive("raise")
      return selectWindow(element)
    }
    // NSRunningApplication state comes from the window server, not from the app itself.
    operations.applicationIsActive = { [self] processID in
      lock.withLock { frontmost == processID }
    }
    operations.prepareActivation = { [self] in
      { application in
        self.gate.arrive("set-focused-application")
        let processID = self.processID(of: application)
        return self.lock.withLock {
          if self.refusedWithoutAccessibility() { return .apiDisabled }
          // The system-wide write is refused at once on the real desktop (fidelity trace), so it
          // never waits for the busy app.
          if self.apps[processID]?.busy == true {
            self.used.insert(.busyAppTimesOut)
            return .cannotComplete
          }
          // Measured 2026-11-05 (desktop fidelity trace, GitHub macos-26): setting the system-wide
          // focused application fails with kAXErrorInvalidUIElement; Defi then activates the app.
          return .invalidUIElement
        }
      }
    }
    operations.activateApplication = { [self] processID in
      gate.arrive("activate")
      lock.withLock { activate(processID) }
      return true
    }
    operations.withTimeout = { [self] timeout, elements, perform in
      timeoutAccess.withTimeout(timeout, elements: elements, perform: perform)
    }
    return operations
  }

  private func selectWindow(_ element: AXUIElement) -> AXError {
    guard let window = windowID(of: element) else { return .invalidUIElement }
    return lock.withLock {
      if refusedWithoutAccessibility() { return .apiDisabled }
      guard let processID = owners[window], var app = apps[processID] else {
        return .invalidUIElement
      }
      if app.busy {
        noteBusyCall(element, processID)
        app.lateWrites.append(window)
        apps[processID] = app
        return .cannotComplete
      }
      app.focusedWindow = window
      apps[processID] = app
      if frontmost == processID { notificationPending = true }
      return .success
    }
  }

  /// The user brings a window forward through Command-Tab, the Dock or a click: macOS
  /// changes the key window itself and reports it with a later focus notification.
  func userFocuses(_ windowID: WindowID) {
    lock.withLock {
      guard let processID = owners[windowID] else { return }
      apps[processID]?.focusedWindow = windowID
      frontmost = processID
      notificationPending = true
    }
  }

  private func activate(_ processID: pid_t) {
    guard apps[processID] != nil, frontmost != processID else { return }
    frontmost = processID
    notificationPending = true
  }

  // AXUIElementGetPid rejects these fake pids, so elements are matched by CFEqual.
  func windowID(of element: AXUIElement) -> WindowID? {
    owners.keys.first { CFEqual(windowElement($0), element) }
  }

  private func processID(of element: AXUIElement) -> pid_t {
    Set(owners.values).first { CFEqual(applicationElement($0), element) } ?? 0
  }
}
