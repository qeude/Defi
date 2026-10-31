import DefiRuntime
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import Synchronization
import ScreenCaptureKit
import XCTest
import class SwiftUI.NSHostingView

@testable import DefiMacOS

private struct DesktopPreflightFailure: Error, CustomStringConvertible {
  let description: String
}

/// Every test drives Defi-owned fixture windows only, never the user's windows.
@MainActor
final class DesktopE2ETests: XCTestCase {
  // MARK: Focus

  func testFocusFollowsLatestNativeIntent() throws {
    let platform = try preflight()
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let tiled = fixtures.tiledWindowID, floating = fixtures.floatingWindowID
    let tiledPID = fixtures.tiledProcess.processIdentifier
    func focused() -> WindowID? { platform.snapshot(config: Config()).focusedWindowID }

    platform.snapshotEngine.applications[tiledPID] = AXUIElementCreateApplication(-1)
    platform.requestWindowTopologyRefresh(processID: tiledPID)
    _ = platform.snapshot(config: Config())
    let renewed = try XCTUnwrap(platform.snapshotEngine.applications[tiledPID])
    var renewedPID: pid_t = 0
    XCTAssertEqual(AXUIElementGetPid(renewed, &renewedPID), .success)
    XCTAssertEqual(renewedPID, tiledPID, "A failed application connection must be renewed without a restart")
    platform.requestWindowTopologyRefresh(processID: tiledPID)
    XCTAssertTrue(platform.snapshot(config: Config()).windows.contains { $0.id == tiled })

    try activate(fixtures.floatingProcess, focusing: floating, platform)
    let result = DesktopValue<NativeFocusResult?>(nil)
    onNavigation { platform.focus(tiled, completion: { value in DispatchQueue.main.async { result.value = value } }) }
    XCTAssertTrue(pumpRunLoop(until: { result.value != nil }, timeout: 2))
    XCTAssertEqual(result.value, .completed)
    XCTAssertNotNil(try XCTUnwrap(platform.internalFocusSuppressions[tiled]).completedAt)
    // Normalized keyboard activation resolves its target through real AX.
    platform.userInputTracker.record(timestamp: ProcessInfo.processInfo.systemUptime, focusIntent: .keyboard)
    platform.userInputTracker.recordApplicationActivation(processID: tiledPID)
    let activation = platform.snapshot(config: Config())
    XCTAssertEqual(activation.focusedWindowID, tiled)
    XCTAssertTrue(activation.nativeFocusChanged)
    XCTAssertTrue(activation.nativeFocusIsApplicationActivation)
    XCTAssertNil(platform.internalFocusSuppressions[tiled], "Keyboard activation must consume the completed focus suppression")

    for id in [tiled, floating, tiled, floating] { onNavigation { platform.focus(id) } }
    XCTAssertTrue(pumpRunLoop(until: {
      !onNavigation { platform.hasPendingFocusWrite } && focused() == floating
    }, timeout: 2), "Stale focus recovery must not override the latest rapid focus intent")

    let events = DesktopValue(0)
    let activated = DesktopValue<[WindowID]>([])
    onNavigation { platform.startObserving({ DispatchQueue.main.async { events.value += 1 } },
      activatedWindowHandler: { id, _ in DispatchQueue.main.async { activated.value.append(id) } }) }
    // The monitor registers an unretained display callback; it must not outlive this platform.
    defer { platform.eventMonitor?.stop() }
    onNavigation { platform.focus(tiled) }
    XCTAssertTrue(pumpRunLoop(until: { events.value > 0 && focused() == tiled }, timeout: 2),
      "Native focus must emit a platform event and converge on the target")
    try activate(fixtures.floatingProcess, focusing: floating, platform)
    XCTAssertTrue(pumpRunLoop(until: { activated.value.last == floating }, timeout: 2),
      "An app activation must hand over its focused window, as Command-Tab moves the ribbon at once")

    let snapshot = platform.snapshot(config: Config())
    let monitor = try XCTUnwrap(snapshot.monitors.first { monitor in
      snapshot.windows.contains { $0.id == tiled && targetIntersects($0.frame, monitor: monitor.frame) }
    })
    let half = monitor.frame.width / 2
    let tiledFrame = Rect(x: monitor.frame.x, y: monitor.frame.y, width: half, height: 440)
    onNavigation { platform.apply([
      FrameAssignment(windowID: tiled, frame: tiledFrame),
      FrameAssignment(windowID: floating, frame: Rect(x: monitor.frame.x + half, y: monitor.frame.y, width: half, height: 440)),
    ]) }
    XCTAssertTrue(settleFrames(platform))
    // The user's own windows can cover the tiled fixture while another app is active.
    try activate(fixtures.tiledProcess, focusing: tiled, platform)
    let cursor = try XCTUnwrap(CGEvent(source: nil)?.location)
    defer { CGWarpMouseCursorPosition(cursor) }
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: Config(input: InputConfig(focusFollowsMouse: true, mouseFollowsFocus: true)),
      pointerMotionTracker: platform.pointerMotionTracker,
      pointerMotionHandler: { invocation in DispatchQueue.main.async { received.value.append(invocation) } }
    ) { _ in } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let center = CGPoint(x: tiledFrame.x + half / 2, y: tiledFrame.y + 20)
    XCTAssertEqual(CGWarpMouseCursorPosition(center), .success)
    let movement = try XCTUnwrap(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
      mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left))
    movement.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: {
      received.value.last.flatMap { $0.windowID ?? platform.managedWindowID(at: $0.location) } == tiled
    }, timeout: 1), "Pointer motion must resolve the fixture under the pointer: \(received.value), "
      + "windows there: \(windowsDescription(at: center))")
    let transitions = onNavigation { manager.pointerTransitionCount }
    onNavigation { platform.warpCursor(to: floating, unlessUserInputAfter: .greatestFiniteMagnitude) }
    XCTAssertTrue(pumpRunLoop(until: { onNavigation { platform.cursorWarpPerformance }.applied == 1 }, timeout: 1))
    // A warp posts no motion event; leave time for a feedback loop to appear.
    pumpRunLoop(for: 0.2)
    XCTAssertEqual(onNavigation { manager.pointerTransitionCount }, transitions,
      "A programmatic cursor warp must not emit pointer transitions")
  }

  func testTiledFocusKeepsFloatingWindowAboveIt() throws {
    let platform = try preflight()
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let config = Config(rules: [Rule(appID: fixtures.floatingAppID, floating: true)])
    let snapshot = platform.snapshot(config: config)
    let floating = try XCTUnwrap(snapshot.windows.first { $0.id == fixtures.floatingWindowID && $0.floating })
    let tiled = try XCTUnwrap(snapshot.windows.first { $0.id == fixtures.tiledWindowID })
    XCTAssertFalse(tiled.floating)
    XCTAssertTrue(targetIntersects(floating.frame, monitor: tiled.frame), "Fixture windows must overlap")
    func focusedTextField(in application: AXUIElement) throws -> AXUIElement {
      var field: CFTypeRef?
      guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &field) == .success,
        let field, CFGetTypeID(field) == AXUIElementGetTypeID()
      else { throw DesktopFocusFixturePair.Failure.unsupported("Fixture has no focused editable field") }
      return field as! AXUIElement
    }
    func textValue(of field: AXUIElement) -> String? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success else { return nil }
      return value as? String
    }
    func focusCompletes(_ id: WindowID) -> Bool {
      let result = DesktopValue<NativeFocusResult?>(nil)
      onNavigation { platform.focus(id, completion: { value in DispatchQueue.main.async { result.value = value } }) }
      return pumpRunLoop(until: { result.value == .completed || result.value == .completedWithoutMutation }, timeout: 1)
    }
    func order() -> [WindowID] {
      copyCGWindows(options: [.optionOnScreenOnly, .excludeDesktopElements]).map { WindowID(rawValue: UInt64($0.id)) }
    }
    XCTAssertTrue(focusCompletes(floating.id))
    let floatingField = try focusedTextField(in: try XCTUnwrap(platform.applications[fixtures.floatingProcess.processIdentifier]))
    XCTAssertEqual(textValue(of: floatingField), "Editable native focus fixture")
    let tiledElement = try XCTUnwrap(platform.elements[tiled.id])
    let tiledPID = fixtures.tiledProcess.processIdentifier
    let tiledApplication = try XCTUnwrap(platform.applications[tiledPID])
    XCTAssertTrue(focusCompletes(tiled.id))
    let tiledField = try focusedTextField(in: tiledApplication)
    let tiledText = try XCTUnwrap(textValue(of: tiledField))
    XCTAssertEqual(AXUIElementPerformAction(tiledElement, kAXRaiseAction as CFString), .success)
    XCTAssertTrue(pumpRunLoop(until: {
      let order = order()
      return order.firstIndex(of: tiled.id).flatMap { index in order.firstIndex(of: floating.id).map { index < $0 } } == true
    }, timeout: 1), "The tiled fixture must start above the floating fixture before refocus")
    _ = platform.snapshot(config: config)

    XCTAssertTrue(focusCompletes(tiled.id))
    // AX success acknowledges the request before WindowServer publishes the order.
    XCTAssertTrue(pumpRunLoop(until: {
      let order = order()
      var focusedWindow: CFTypeRef?
      guard let floatingIndex = order.firstIndex(of: floating.id),
        let tiledIndex = order.firstIndex(of: tiled.id) else { return false }
      return floatingIndex < tiledIndex
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == tiledPID
        && AXUIElementCopyAttributeValue(tiledApplication, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success
        && focusedWindow.map { CFEqual($0, tiledElement) } == true
    }, timeout: 1), "The floating fixture must remain above the focused tiled fixture; focus=\(platform.focusWriter.performance)")
    let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true))
    key.flags = []
    key.post(tap: .cghidEventTap)
    key.type = .keyUp
    key.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { textValue(of: tiledField).map { $0 != tiledText } == true }, timeout: 1),
      "A global ordinary key must reach the tiled fixture's editable field")
    XCTAssertEqual(textValue(of: floatingField), "Editable native focus fixture",
      "The floating fixture must not receive the global key")
  }

  // MARK: Parking

  func testParkingConvergesAndRepairs() throws {
    let platform = try preflight()
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let id = fixtures.tiledWindowID
    let snapshot = platform.snapshot(config: Config())
    let window = try XCTUnwrap(snapshot.windows.first { $0.id == id })
    let monitor = try XCTUnwrap(snapshot.monitors.first { targetIntersects(window.frame, monitor: $0.frame) })
    let others = snapshot.monitors.filter { $0.id != monitor.id }.map(\.physicalFrame)
    let element = try XCTUnwrap(platform.elements[id])
    func holds(_ target: Rect) -> Bool {
      platform.frame(of: element).map { abs($0.x - target.x) <= 2 && holdsParkedY($0.y, target.y) } == true
    }

    let staged = Rect(x: monitor.frame.x + (monitor.frame.width - window.frame.width) / 2,
      y: monitor.frame.y + (monitor.frame.height - window.frame.height) / 2,
      width: window.frame.width, height: window.frame.height)
    onNavigation { platform.apply([FrameAssignment(windowID: id, frame: staged)]) }
    XCTAssertTrue(settleFrames(platform))
    let anchor = parkedFrame(staged, display: monitor.physicalFrame, visibleFrame: monitor.frame, otherDisplays: others)
    onNavigation { platform.apply([FrameAssignment(windowID: id, frame: anchor)],
      asynchronousPositionTimeoutSeconds: 0.05, source: "test-strip-sliver") }
    XCTAssertTrue(settleFrames(platform))
    XCTAssertTrue(pumpRunLoop(until: { holds(anchor) }, timeout: 1), "An unhidden strip anchor must converge")
    XCTAssertEqual(onNavigation { platform.hiddenWindowCount }, 0)

    let parked = parkedFrame(window.frame, display: monitor.physicalFrame, visibleFrame: monitor.frame, otherDisplays: others)
    onNavigation { platform.apply([FrameAssignment(windowID: id, frame: parked)], hiddenWindowIDs: [id]) }
    XCTAssertTrue(pumpRunLoop(until: { holds(parked) }, timeout: 1.5),
      "Corner parking must converge, independently of the snapshot refresh budget")
    XCTAssertEqual(onNavigation { platform.hiddenWindowCount }, 1)

    // One delayed application write, without a second competing settlement coordinator.
    let repairs = onNavigation { platform.parkingPerformance }.repairs
    var rollback = CGPoint(x: window.frame.x + 40, y: window.frame.y)
    XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString,
      try XCTUnwrap(AXValueCreate(.cgPoint, &rollback))), .success)
    XCTAssertTrue(pumpRunLoop(until: {
      onNavigation { platform.parkingPerformance }.repairs > repairs && holds(parked)
    }, timeout: 1.6), "Parking repair must converge before its 1.4 second backstop")

    let offscreen = Rect(x: -10_000, y: -10_000, width: window.frame.width, height: window.frame.height)
    onNavigation { platform.apply([FrameAssignment(windowID: id, frame: offscreen)]) }
    XCTAssertTrue(settleFrames(platform))
    onNavigation { platform.focus(id) }
    XCTAssertTrue(pumpRunLoop(until: { platform.snapshot(config: Config()).focusedWindowID == id }, timeout: 2),
      "A focused window must remain resolvable while parked offscreen")
  }

  // MARK: Frame convergence

  func testFrameWritesConvergeOnRealWindows() throws {
    let platform = try preflight()
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let id = fixtures.tiledWindowID
    let snapshot = platform.snapshot(config: Config())
    let window = try XCTUnwrap(snapshot.windows.first { $0.id == id })
    let monitor = try XCTUnwrap(snapshot.monitors.first { targetIntersects(window.frame, monitor: $0.frame) })
    var actual: Rect?
    func converges(x: Double, width: Double) -> Bool {
      pumpRunLoop(until: {
        actual = platform.snapshot(config: Config()).windows.first { $0.id == id }?.frame
        return actual.map { abs($0.x - x) <= 2 && abs($0.width - width) <= 2 } == true
      }, timeout: 1)
    }

    let target = Rect(x: window.frame.x + 40, y: window.frame.y, width: window.frame.width - 80, height: window.frame.height)
    onNavigation { platform.apply([FrameAssignment(windowID: id, frame: target)]) }
    XCTAssertTrue(converges(x: target.x, width: target.width), "An applied target must converge; actual=\(String(describing: actual))")

    XCTAssertTrue(settleFrames(platform))
    let positionWrites = onNavigation { platform.successfulPositionWriteCount }
    let sizeWrites = onNavigation { platform.successfulSizeWriteCount }
    let shifted = Rect(x: target.x + 8, y: target.y, width: target.width, height: target.height)
    onNavigation { platform.apply([FrameAssignment(windowID: id, frame: shifted)]) }
    XCTAssertTrue(settleFrames(platform))
    XCTAssertTrue(converges(x: shifted.x, width: shifted.width))
    XCTAssertGreaterThan(onNavigation { platform.successfulPositionWriteCount }, positionWrites)
    XCTAssertEqual(onNavigation { platform.successfulSizeWriteCount }, sizeWrites,
      "A horizontal move must write position without size")

    let full = Rect(x: monitor.frame.x, y: window.frame.y, width: monitor.frame.width, height: window.frame.height)
    for fraction in [0.5, 0.0, 0.25] {
      let start = Rect(x: monitor.frame.x + monitor.frame.width * fraction, y: window.frame.y,
        width: monitor.frame.width / 2, height: window.frame.height)
      onNavigation { platform.apply([FrameAssignment(windowID: id, frame: start)]) }
      XCTAssertTrue(settleFrames(platform))
      _ = platform.snapshot(config: Config())
      onNavigation { platform.apply([FrameAssignment(windowID: id, frame: full)], source: "command-layout-animation") }
      XCTAssertTrue(settleFrames(platform))
      XCTAssertTrue(converges(x: full.x, width: full.width),
        "Full width from \(fraction) must converge; actual=\(String(describing: actual)) trace=\(onNavigation { platform.frameCoordinatorTrace })")
    }

    let observed = try XCTUnwrap(platform.snapshot(config: Config()).windows.first { $0.id == id }).frame
    onNavigation { platform.latestObservedFrames[id] = Rect(x: -20_000, y: -20_000, width: 1, height: 1) }
    let fresh = DesktopValue<[WindowID: Rect]?>(nil)
    Task { fresh.value = await platform.userAdjustedFrames(for: [id]) }
    XCTAssertTrue(pumpRunLoop(until: { fresh.value != nil }, timeout: 2))
    let read = try XCTUnwrap(fresh.value?[id], "User-adjusted frames must read fresh geometry off the navigation executor")
    XCTAssertEqual(read.x, observed.x, accuracy: 2)
    XCTAssertEqual(read.width, observed.width, accuracy: 2)

    let cursor = try XCTUnwrap(CGEvent(source: nil)?.location)
    defer { CGWarpMouseCursorPosition(cursor) }
    let half = Rect(x: monitor.frame.x, y: window.frame.y, width: monitor.frame.width / 2, height: window.frame.height)
    XCTAssertEqual(CGWarpMouseCursorPosition(CGPoint(x: monitor.frame.x + monitor.frame.width - 1,
      y: monitor.frame.y + monitor.frame.height - 1)), .success)
    onNavigation { platform.apply([FrameAssignment(windowID: id, frame: half)],
      cursorWarpWindowIDAfterCommit: id, cursorWarpInputTimestampAfterCommit: .greatestFiniteMagnitude,
      cursorWarpIsCurrentAfterCommit: { true }) }
    XCTAssertTrue(pumpRunLoop(until: { onNavigation { platform.cursorWarpPerformance }.applied == 1 }, timeout: 1),
      "The cursor must warp after the target frame commits; trace=\(onNavigation { platform.frameCoordinatorTrace })")
  }

  // MARK: Input intake

  func testInputTapsStayResponsive() throws {
    _ = try preflight()
    let tracker = UserInputTracker()
    let received = Mutex<[HotKeyInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: Config(modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"], keys: ["hyper-left": "focus-column left"]),
      userInputTracker: tracker
    ) { invocation in received.withLock { $0.append(invocation) } } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    DispatchQueue.global(qos: .userInteractive).async {
      Thread.sleep(forTimeInterval: 0.05)
      for _ in 0..<8 {
        guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: true),
          let release = CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: false)
        else { continue }
        event.flags = [.maskAlternate, .maskCommand, .maskControl]
        event.post(tap: .cghidEventTap)
        release.type = .flagsChanged
        release.flags = []
        release.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    // Block the main actor the way slow AX or layout work does.
    Thread.sleep(forTimeInterval: 0.35)
    XCTAssertEqual(onNavigation { manager.capturedKeyCount }, 8, "The event tap must keep capturing while the main actor is blocked")
    let invocations = received.withLock { $0 }
    XCTAssertEqual(invocations.map(\.command), Array(repeating: "focus-column left", count: 8),
      "Commands must be delivered before the main actor resumes")
    XCTAssertEqual(tracker.latestEventTimestamp, invocations.last?.timestamp)
    XCTAssertEqual(onNavigation { manager.tapReenableCount }, 0)

    let closed = DesktopValue(false)
    let overview = onNavigation { HotKeyManager(config: Config(),
      overviewCancelHandler: { DispatchQueue.main.async { closed.value = true } }) { _ in } }
    try onNavigation { try overview.start() }
    onNavigation { overview.setOverviewModeEnabled(true) }
    defer { onNavigation { overview.stop() } }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    NavigationActor.enqueue { entered.signal(); release.wait() }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global(qos: .userInteractive).async {
      CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    }
    let cancelled = pumpRunLoop(until: { closed.value }, timeout: 1)
    release.signal()
    XCTAssertTrue(cancelled, "Escape must reach the Overview without waiting for the navigation lane")

    let motions = DesktopValue(0)
    let pointer = onNavigation { HotKeyManager(
      config: Config(input: InputConfig(focusFollowsMouse: true), keys: ["unknown-no-such-key": "focus-column left"]),
      pointerMotionHandler: { _ in DispatchQueue.main.async { motions.value += 1 } }) { _ in } }
    XCTAssertEqual(onNavigation { pointer.bindingError }, .invalidAccelerator("unknown-no-such-key"))
    try startHotKeys(pointer)
    defer { onNavigation { pointer.stop() } }
    let location = try XCTUnwrap(CGEvent(source: nil)?.location)
    try XCTUnwrap(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
      mouseCursorPosition: location, mouseButton: .left)).post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { motions.value > 0 }, timeout: 1),
      "Pointer movement must survive invalid hotkey parsing")

    let recoveries = Mutex(0), dismissals = Mutex(0)
    let monitor = InputMonitor(
      bindings: [:], userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      deliverCheatsheet: { _ in dismissals.withLock { $0 += 1 } },
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in },
      tapReenabled: { _ in recoveries.withLock { $0 += 1 } })
    defer { monitor.stop() }
    for options in [CGEventTapOptions.defaultTap, .listenOnly] {
      let port = try monitor.installTap(options: options, mask: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: { _, _, event, _ in Unmanaged.passUnretained(event) })
      CGEvent.tapEnable(tap: port, enable: false)
    }
    let disabled = try XCTUnwrap(CGEvent(source: nil))
    XCTAssertFalse(monitor.isEnabled)
    _ = monitor.intercept(type: .tapDisabledByUserInput, event: disabled)
    XCTAssertTrue(monitor.isEnabled, "A disabled tap must be re-enabled")
    _ = monitor.handle(type: .tapDisabledByUserInput, event: disabled)
    XCTAssertEqual(monitor.tapReenableCount, 1)
    XCTAssertEqual(recoveries.withLock { $0 }, 1, "Duplicate disable notifications must recover only once")
    XCTAssertEqual(dismissals.withLock { $0 }, 1)
  }

  /// Moonlight and other SDL apps capture the keyboard with this exact call.
  func testKeyboardCaptureByAnotherAppSilencesShortcuts() throws {
    _ = try preflight()
    typealias MainConnection = @convention(c) () -> Int32
    typealias SetMode = @convention(c) (Int32, Int32) -> Int32
    let skyLight = try XCTUnwrap(dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL))
    let connection = unsafeBitCast(try XCTUnwrap(dlsym(skyLight, "CGSMainConnectionID")), to: MainConnection.self)()
    let setMode = unsafeBitCast(try XCTUnwrap(dlsym(skyLight, "CGSSetGlobalHotKeyOperatingMode")), to: SetMode.self)
    defer { _ = setMode(connection, 0) }

    let log = CommandLog()
    let manager = onNavigation { HotKeyManager(
      config: Config(modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"], keys: ["hyper-left": "focus-column left"])
    ) { log.append($0.command) } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    func pressShortcut() throws {
      let source = CGEventSource(stateID: .hidSystemState)
      let key = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: true))
      key.flags = [.maskAlternate, .maskCommand, .maskControl]
      key.post(tap: .cghidEventTap)
      key.type = .keyUp
      key.post(tap: .cghidEventTap)
    }

    try pressShortcut()
    XCTAssertTrue(pumpRunLoop(until: { log.count == 1 }, timeout: 2), "A shortcut fires while no app captures the keyboard")
    XCTAssertEqual(setMode(connection, 1), 0)
    try pressShortcut()
    pumpRunLoop(for: 0.3)
    XCTAssertEqual(log.all, ["focus-column left"], "A shortcut must not fire while another app captures the keyboard")
    XCTAssertEqual(setMode(connection, 0), 0)
    try pressShortcut()
    XCTAssertTrue(pumpRunLoop(until: { log.count == 2 }, timeout: 2), "Shortcuts resume when the capture ends")
    XCTAssertEqual(log.all, ["focus-column left", "focus-column left"])
  }

  func testShortcutsFollowKeyboardLayoutChanges() throws {
    _ = try preflight()
    func inputSource(_ id: String) throws -> TISInputSource {
      let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true)?
        .takeRetainedValue() as? [TISInputSource]
      return try XCTUnwrap(sources?.first, "\(id) must be installed")
    }
    func enabledSources() -> [TISInputSource] {
      TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }
    let enabledBefore = enabledSources()
    let inputMenuPreference = "visible" as CFString
    let inputMenuDomain = "com.apple.TextInputMenu" as CFString
    let inputMenuBefore = CFPreferencesCopyAppValue(inputMenuPreference, inputMenuDomain)
    let original = try XCTUnwrap(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
    let abc = try inputSource("com.apple.keylayout.ABC")
    let dvorak = try inputSource("com.apple.keylayout.Dvorak")
    let kana = try inputSource("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese")
    // A Japanese mode can be selected only while its parent input method is enabled.
    let japanese = try inputSource("com.apple.inputmethod.Kotoeri.RomajiTyping")
    defer {
      TISSelectInputSource(original)
      // Enabling Japanese also enables its palette and shows the Input menu, so restore by difference.
      enabledSources().filter { source in !enabledBefore.contains { CFEqual($0, source) } }
        .forEach { TISDisableInputSource($0) }
      CFPreferencesSetAppValue(inputMenuPreference, inputMenuBefore, inputMenuDomain)
      CFPreferencesAppSynchronize(inputMenuDomain)
    }
    [abc, dvorak, japanese, kana].forEach { TISEnableInputSource($0) }
    XCTAssertEqual(TISSelectInputSource(abc), noErr)
    pumpRunLoop(for: 0.5)

    let log = CommandLog()
    let manager = onNavigation { HotKeyManager(
      config: Config(modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"], keys: ["hyper-f": "maximize-column"]),
      followsKeyboardLayout: true
    ) { log.append($0.command) } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    func press(_ code: CGKeyCode) throws {
      let source = CGEventSource(stateID: .hidSystemState)
      let key = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true))
      key.flags = [.maskAlternate, .maskCommand, .maskControl]
      key.post(tap: .cghidEventTap)
      key.type = .keyUp
      key.post(tap: .cghidEventTap)
    }
    func assertFires(onlyOn expected: CGKeyCode, not other: CGKeyCode, _ message: String) throws {
      let before = log.count
      try press(other)
      pumpRunLoop(for: 0.3)
      XCTAssertEqual(log.count, before, "\(message): key code \(other) must be free")
      try press(expected)
      XCTAssertTrue(pumpRunLoop(until: { log.count == before + 1 }, timeout: 2), "\(message): key code \(expected) must fire")
    }

    try assertFires(onlyOn: 3, not: 16, "ABC prints F on the home row")
    XCTAssertEqual(TISSelectInputSource(dvorak), noErr)
    pumpRunLoop(for: 0.5)
    try assertFires(onlyOn: 16, not: 3, "Dvorak prints F on the top row")
    XCTAssertEqual(TISSelectInputSource(kana), noErr)
    pumpRunLoop(for: 0.5)
    try assertFires(onlyOn: 16, not: 3, "Japanese input keeps the ASCII layout in use")
    XCTAssertEqual(TISSelectInputSource(abc), noErr)
    pumpRunLoop(for: 0.5)
    try assertFires(onlyOn: 3, not: 16, "Returning to ABC moves the shortcut back")
  }

  func testCarbonReservationsReleaseForRecordingTextEditingAndStop() throws {
    let platform = try preflight()
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let key = try Key(accelerator: "ctrl-alt-cmd-slash", aliases: [:])
    func reservationIsFree() -> Bool {
      var reference: EventHotKeyRef?
      let status = RegisterEventHotKey(UInt32(key.code), key.carbonModifiers,
        EventHotKeyID(signature: 0x54657374, id: 3), GetApplicationEventTarget(),
        OptionBits(kEventHotKeyExclusive), &reference)
      if let reference { UnregisterEventHotKey(reference) }
      return status == noErr
    }
    XCTAssertTrue(reservationIsFree(), "No earlier hotkey manager may still hold the shortcut")

    let commands = CommandLog()
    let manager = onNavigation { HotKeyManager(config: Config(keys: ["ctrl-alt-cmd-slash": "focus-column right"])) {
      invocation in commands.append(invocation.command) } }
    try startHotKeys(manager)
    var managerStopped = false
    defer { if !managerStopped { onNavigation { manager.stop() } } }
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 150),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let recorded = DesktopValue<[String]>([])
    let recorder = ShortcutRecorderButton()
    recorder.frame = NSRect(x: 10, y: 10, width: 150, height: 30)
    recorder.shortcutLabel = "ctrl-alt-cmd-slash"
    recorder.onRecord = { recorded.value.append($0) }
    let text = NSTextView(frame: NSRect(x: 10, y: 50, width: 250, height: 60))
    window.contentView?.addSubview(recorder)
    window.contentView?.addSubview(text)
    let originalPolicy = NSApplication.shared.activationPolicy()
    defer {
      recorder.stopRecording()
      window.close()
      settingsTextInputFocused.withLock { $0 = false }
      NSApplication.shared.setActivationPolicy(originalPolicy)
      pumpApplicationEvents(until: { !window.isVisible }, timeout: 0.5)
    }
    try activateTestRunner(through: fixtures, platform)
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(pumpApplicationEvents(until: { window.isKeyWindow }, timeout: 2),
      "The test window must be key before foreground delivery is observed")
    let foreground = DesktopValue(0)
    let localMonitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == key.code { foreground.value += 1; return nil }
      return event
    })
    defer { NSEvent.removeMonitor(localMonitor) }
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true))
    event.flags = [.maskControl, .maskAlternate, .maskCommand]
    func press(repeating: Bool = false) {
      event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
      event.type = .keyDown
      event.post(tap: .cghidEventTap)
      event.type = .keyUp
      event.post(tap: .cghidEventTap)
    }
    func captureEnabled() -> Bool { onNavigation { manager.isHotKeyCaptureEnabled } }

    press()
    XCTAssertTrue(pumpApplicationEvents(until: { commands.count == 1 }, timeout: 1))
    pumpApplicationEvents(until: { foreground.value > 0 }, timeout: 0.1)
    XCTAssertEqual(foreground.value, 0, "Carbon must reserve the shortcut from the foreground app")
    // A posted repeat is not HID autorepeat; whether Carbon reserves it varies, so only delivery is asserted.
    press(repeating: true)
    XCTAssertTrue(pumpApplicationEvents(until: { commands.count == 2 }, timeout: 1))
    pumpApplicationEvents(until: { false }, timeout: 0.1)
    let leakedRepeats = foreground.value

    recorder.performClick(nil)
    XCTAssertTrue(pumpApplicationEvents(until: { !captureEnabled() }, timeout: 1))
    XCTAssertTrue(reservationIsFree(), "Recording must release the reservation")
    press()
    XCTAssertTrue(pumpApplicationEvents(until: { !recorder.isRecording }, timeout: 1))
    XCTAssertEqual(recorded.value, ["alt-cmd-ctrl-slash"])
    XCTAssertTrue(pumpApplicationEvents(until: captureEnabled, timeout: 1))
    recorder.performClick(nil)
    let escape = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 53, keyDown: true))
    escape.post(tap: .cghidEventTap)
    escape.type = .keyUp
    escape.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpApplicationEvents(until: { !recorder.isRecording }, timeout: 1))
    XCTAssertEqual(recorded.value, ["alt-cmd-ctrl-slash"], "Escape must cancel recording without recording a shortcut")
    XCTAssertTrue(pumpApplicationEvents(until: captureEnabled, timeout: 1))
    press()
    XCTAssertTrue(pumpApplicationEvents(until: { commands.count == 3 }, timeout: 1))

    window.makeFirstResponder(text)
    settingsTextInputFocused.withLock { $0 = true }
    XCTAssertTrue(pumpApplicationEvents(until: { !captureEnabled() }, timeout: 1))
    XCTAssertTrue(reservationIsFree(), "Text editing must release the reservation")
    press()
    XCTAssertTrue(pumpApplicationEvents(until: { foreground.value == leakedRepeats + 1 }, timeout: 1))
    window.makeFirstResponder(recorder)
    settingsTextInputFocused.withLock { $0 = false }
    XCTAssertTrue(pumpApplicationEvents(until: captureEnabled, timeout: 1))
    press()
    XCTAssertTrue(pumpApplicationEvents(until: { commands.count == 4 }, timeout: 1))

    onNavigation { manager.stop() }
    managerStopped = true
    XCTAssertTrue(pumpApplicationEvents(until: reservationIsFree, timeout: 1), "Stopping must release the reservation")
    press()
    XCTAssertTrue(pumpApplicationEvents(until: { foreground.value == leakedRepeats + 2 }, timeout: 1))
    XCTAssertEqual(commands.all, Array(repeating: "focus-column right", count: 4))

    var reference: EventHotKeyRef?
    XCTAssertEqual(RegisterEventHotKey(UInt32(key.code), key.carbonModifiers,
      EventHotKeyID(signature: 0x54657374, id: 1), GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &reference), noErr)
    let reserved = try XCTUnwrap(reference)
    defer { UnregisterEventHotKey(reserved) }
    // Slash is reserved by the test above: that one chord is lost, and the other registers.
    let config = Config(keys: ["ctrl-alt-cmd-a": "focus-column left", "ctrl-alt-cmd-slash": "focus-column right"])
    let partial = onNavigation { HotKeyManager(config: config) { invocation in commands.append(invocation.command) } }
    try onNavigation { try partial.start() }
    defer { onNavigation { partial.stop() } }
    XCTAssertTrue(pumpRunLoop(until: { onNavigation { partial.heldByAnotherApp == ["ctrl-alt-cmd-slash"] } }, timeout: 1))
    XCTAssertNil(onNavigation { partial.bindingError })
    XCTAssertTrue(onNavigation { partial.isEnabled })
    XCTAssertTrue(onNavigation { partial.isHotKeyCaptureEnabled }, "One held chord must not disable the others")
    let earlier = try Key(accelerator: "ctrl-alt-cmd-a", aliases: [:])
    var reservedByDefi: EventHotKeyRef?
    XCTAssertEqual(RegisterEventHotKey(UInt32(earlier.code), earlier.carbonModifiers,
      EventHotKeyID(signature: 0x54657374, id: 2), GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &reservedByDefi), OSStatus(eventHotKeyExistsErr), "A must stay reserved by Defi")
    if let reservedByDefi { UnregisterEventHotKey(reservedByDefi) }
    func press(_ key: Key) throws {
      let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true))
      event.flags = [.maskControl, .maskAlternate, .maskCommand]
      event.post(tap: .cghidEventTap)
      event.type = .keyUp
      event.post(tap: .cghidEventTap)
    }
    try press(key)
    try press(earlier)
    XCTAssertTrue(pumpRunLoop(until: { commands.count == 5 }, timeout: 1))
    pumpRunLoop(for: 0.2)
    XCTAssertEqual(commands.all.suffix(1), ["focus-column left"], "Only the chord Defi holds runs a command")
    XCTAssertEqual(commands.count, 5, "The chord another app holds must not run a command")
    onNavigation { partial.stop() }

    // When no chord registers, the whole set is unavailable but observation stays on.
    var blockers: [EventHotKeyRef] = []
    defer { blockers.forEach { UnregisterEventHotKey($0) } }
    for (index, chord) in try configuredHotKeys(config).keys.filter({ $0 != key }).enumerated() {
      XCTAssertTrue(pumpRunLoop(until: {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(chord.code), chord.carbonModifiers,
          EventHotKeyID(signature: 0x54657374, id: UInt32(10 + index)), GetApplicationEventTarget(),
          OptionBits(kEventHotKeyExclusive), &reference)
        if status == noErr, let reference { blockers.append(reference) }
        return status == noErr
      }, timeout: 1), "Defi must release \(chord) after stop")
    }
    let tracker = UserInputTracker()
    let failing = onNavigation { HotKeyManager(config: config, userInputTracker: tracker) { invocation in
      commands.append(invocation.command) } }
    try onNavigation { try failing.start() }
    defer { onNavigation { failing.stop() } }
    XCTAssertTrue(pumpRunLoop(until: { onNavigation { failing.bindingError != nil } }, timeout: 1))
    XCTAssertTrue(onNavigation { failing.isEnabled }, "Observation must survive a Carbon registration failure")
    XCTAssertFalse(onNavigation { failing.isHotKeyCaptureEnabled })
    guard case .registrationFailed(keyCode: _, status: _) = onNavigation({ failing.bindingError }) else {
      return XCTFail("Expected a Carbon reservation error when nothing registers")
    }
    let arrow = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
    arrow.flags = [.maskAlternate]
    arrow.post(tap: .cghidEventTap)
    arrow.type = .keyUp
    arrow.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { tracker.latestEventTimestamp > 0 }, timeout: 1))
    XCTAssertEqual(commands.count, 5)
  }

  // MARK: Settings

  func testSettingsSearchRevealsOffscreenOptionAgain() throws {
    let platform = try preflight()
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let originalPolicy = NSApplication.shared.activationPolicy()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configURL = directory.appendingPathComponent("config.toml")
    try "[layout]\nreserved_top = 321\n".write(to: configURL, atomically: true, encoding: .utf8)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: DefiSettingsView(configURL: configURL))
    defer {
      window.close()
      NSApplication.shared.setActivationPolicy(originalPolicy)
      try? FileManager.default.removeItem(at: directory)
    }
    try activateTestRunner(through: fixtures, platform)
    window.makeKeyAndOrderFront(nil)
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func descendants() -> [NSView] { window.contentView.map(views) ?? [] }
    func reservedTopField() -> NSTextField? {
      descendants().compactMap { $0 as? NSTextField }.first { $0.stringValue == "321" }
    }
    func targetIsVisible() -> Bool {
      guard let target = reservedTopField(), !target.isHiddenOrHasHiddenAncestor,
        !target.visibleRect.isEmpty, let scroll = target.enclosingScrollView else { return false }
      return !target.convert(target.visibleRect, to: scroll.contentView).intersection(scroll.contentView.bounds).isEmpty
    }
    XCTAssertTrue(pumpApplicationEvents(until: { window.isKeyWindow && descendants().contains { $0 is NSTableView } }, timeout: 2))
    let sidebar = try XCTUnwrap(descendants().compactMap { $0 as? NSTableView }.first)
    XCTAssertTrue(window.makeFirstResponder(sidebar))
    let down = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
      charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
    NSApplication.shared.sendEvent(down)
    XCTAssertTrue(pumpRunLoop(until: { sidebar.selectedRow == 1 && descendants().contains { $0 is NSStepper } }, timeout: 2),
      "Layout must be open before searching")
    let search = try XCTUnwrap(descendants().compactMap { $0 as? NSSearchField }.first)
    // Pumping leaves a stale window-less NSApp.currentEvent, which the field's focus guard refuses.
    search.selectText(nil)
    let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
    editor.insertText("RESERVED_TOP", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(pumpRunLoop(until: { sidebar.numberOfRows == 1 }, timeout: 2))
    NSApplication.shared.sendEvent(down)
    XCTAssertTrue(pumpRunLoop(until: targetIsVisible, timeout: 2), "Selecting RESERVED_TOP must reveal its control in the viewport")
    let scroll = try XCTUnwrap(reservedTopField()?.enclosingScrollView)
    try XCTUnwrap(scroll.documentView).scroll(.zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    XCTAssertTrue(pumpRunLoop(until: { !targetIsVisible() }, timeout: 2),
      "Scrolling to the top must move the reserved-area control out of the viewport")
    XCTAssertEqual(sidebar.selectedRow, 0)
    let row = sidebar.rect(ofRow: 0)
    let location = sidebar.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      NSApplication.shared.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
    }
    XCTAssertTrue(pumpRunLoop(until: targetIsVisible, timeout: 2),
      "Clicking the already-selected result must reveal the reserved-area control again")
    XCTAssertEqual(sidebar.selectedRow, 0)
  }

  // MARK: Overview

  func testOverviewOpensOnEveryDisplayAndZoomsWithOrWithoutPreviews() async throws {
    _ = try preflight()
    let screen = try XCTUnwrap(NSScreen.main)
    let screens = NSScreen.screens
    let primaryHeight = try XCTUnwrap(screens.first).frame.height
    let fixture = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    var nativeFrame = screen.visibleFrame
    nativeFrame.size.width = 640
    fixture.setFrame(nativeFrame, display: false)
    fixture.title = "Defi Overview Fixture"
    fixture.isReleasedWhenClosed = false
    fixture.animationBehavior = .none
    fixture.backgroundColor = .systemTeal
    fixture.orderFrontRegardless()
    fixture.displayIfNeeded()
    CATransaction.flush()
    defer { fixture.close() }
    let nativeBounds = CGRect(x: fixture.frame.minX, y: primaryHeight - fixture.frame.maxY,
      width: fixture.frame.width, height: fixture.frame.height)
    let settled = await waitUntil(timeout: 2) {
      let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(fixture.windowNumber)) as? [[String: Any]])?
        .first { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == fixture.windowNumber }
      return (info?[kCGWindowBounds as String] as? [String: Any])
        .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } == nativeBounds
    }
    XCTAssertTrue(settled, "Owned fixture must finish its native appearance before sampling")
    let fixtureFrame = fixture.frame
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let native = try XCTUnwrap(content.windows.first { $0.windowID == fixture.windowNumber })
    let appID = try XCTUnwrap(native.owningApplication?.bundleIdentifier)
    let processID = try XCTUnwrap(native.owningApplication?.processID)
    let windowID = WindowID(rawValue: UInt64(native.windowID))
    let monitorID = try XCTUnwrap(self.monitorID(of: screen))
    let workspace = Workspace(id: WorkspaceID(rawValue: "surface-fixture"),
      columns: [Column(window: windowID, width: .fraction(nativeBounds.width / screen.frame.width))])
    let otherMonitors = try screens.filter { $0 != screen }.map { other in
      let id = try XCTUnwrap(self.monitorID(of: other))
      let empty = Workspace(id: WorkspaceID(rawValue: "empty-\(id.rawValue)"), columns: [])
      return (Monitor(id: id, workspaces: [empty], activeWorkspace: empty.id),
        Rect(x: 0, y: 0, width: other.frame.width, height: other.frame.height))
    }
    var windows = [windowID: Window(id: windowID, appID: appID, title: fixture.title,
      frame: Rect(x: nativeBounds.minX, y: nativeBounds.minY, width: nativeBounds.width, height: nativeBounds.height),
      processID: processID)]
    let monitorFrames = [monitorID: Rect(x: screen.frame.minX, y: nativeBounds.minY,
      width: screen.frame.width, height: nativeBounds.height)].merging(otherMonitors.map { ($0.0.id, $0.1) }) { kept, _ in kept }
    func snapshot(_ workspaces: [Workspace], active: WorkspaceID) -> OverviewSnapshot {
      OverviewSnapshot(monitors: [Monitor(id: monitorID, workspaces: workspaces, activeWorkspace: active)] + otherMonitors.map(\.0),
        monitorFrames: monitorFrames, windows: windows, activeMonitorID: monitorID)
    }
    let fixtureSnapshot = snapshot([workspace], active: workspace.id)
    // No gap at all: every column carries the inner gap too, which would narrow the
    // target below the fixture's native frame and refuse the verified reverse zoom.
    let layout = LayoutSettings(innerHorizontalGap: 0, innerVerticalGap: 0,
      outerTopGap: 0, outerRightGap: 0, outerBottomGap: 0, outerLeftGap: 0)
    let controller = OverviewController(focusWindow: { _, _, _, _ in },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in })
    defer {
      controller.close()
      controller.prepare(windowPreviewsEnabled: false)
    }
    func panels() -> [NSWindow] { NSApplication.shared.windows.filter { $0.title == "Defi Overview" } }

    // A panel of an earlier test may still be in its closing fade.
    let earlierClosed = await waitUntil(timeout: 2) { panels().allSatisfy { !$0.isVisible } }
    XCTAssertTrue(earlierClosed)
    controller.prepare(windowPreviewsEnabled: true, snapshot: fixtureSnapshot, layout: layout)
    XCTAssertEqual(controller.retainedPanelCount, screens.count)
    XCTAssertTrue(panels().allSatisfy { !$0.isVisible }, "Preparing must not show the Overview")
    func prepareUntilReady() async -> Bool {
      // The daemon re-prepares on every discovery tick; a missed capture retries the same way.
      var last = Date.distantPast
      return await waitUntil(timeout: 10) {
        if Date().timeIntervalSince(last) > 1 {
          last = Date()
          controller.prepare(windowPreviewsEnabled: true, snapshot: fixtureSnapshot, layout: layout)
        }
        // Defi captures the desktop itself, whatever the wallpaper is.
        return WindowCaptureStore.shared.picture(windowID).map {
          !$0.isReduced && $0.processID == processID && $0.appID == appID
        } == true && screens.allSatisfy { screen in
          self.monitorID(of: screen).flatMap { CGDirectDisplayID(exactly: $0.rawValue) }
            .flatMap(WindowCaptureStore.shared.background) != nil
        }
      }
    }
    let ready = await prepareUntilReady()
    XCTAssertTrue(ready, "Shared captures=\(controller.captureCacheDescription)")
    let picture = try XCTUnwrap(WindowCaptureStore.shared.picture(windowID))
    let projection = projectOverview(snapshot: fixtureSnapshot, monitorID: monitorID,
      bounds: Rect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height),
      viewport: OverviewViewport(), layout: layout, zoom: 0.5)
    let scene = try XCTUnwrap(OverviewSurfaceScene(projection: projection, workspaceID: workspace.id,
      screen: screen, pictures: [windowID: picture], windows: windows))
    XCTAssertEqual(scene.surfaceWindowIDs, [windowID])
    scene.animate(opening: true, duration: 0)
    let texture = try XCTUnwrap(scene.layer.sublayers?.first)
    XCTAssertTrue((texture.contents as AnyObject?) === picture.contents, "The zoom must draw the shared picture, not a copy")
    XCTAssertEqual(texture.cornerRadius * texture.transform.m11, 12, accuracy: 0.01,
      "The Overview texture must match the card's radius after scaling")
    XCTAssertEqual(texture.bounds.size, nativeBounds.size)

    controller.open(snapshot: fixtureSnapshot, layout: layout, windowPreviewsEnabled: true)
    XCTAssertEqual(panels().filter(\.isVisible).count, screens.count, "Every display must show the Overview without waiting for captures")
    XCTAssertEqual(controller.surfaceTransitionCount, 1)
    XCTAssertEqual(controller.surfaceFallbackCount, screens.count - 1, "Empty workspaces fade in instead of zooming")
    XCTAssertTrue(controller.openingTransitionHistory.contains("started(surfaces:1,cached:0,cards:0)"),
      controller.openingTransitionHistory)
    let opened = await waitUntil(timeout: 1) {
      controller.openingTransitionHistory.contains("completed") && panels().filter(\.isVisible).allSatisfy { $0.alphaValue == 1 }
    }
    XCTAssertTrue(opened, "Every display must finish opening: \(controller.openingTransitionHistory)")
    XCTAssertEqual(controller.surfacePresentedFrameCount, 1, "The zoom must retain one fixed screenshot")
    XCTAssertEqual(fixture.frame, fixtureFrame, "Projection must not mutate native geometry")
    controller.close()
    controller.prepare(windowPreviewsEnabled: true, snapshot: fixtureSnapshot, layout: layout)
    controller.open(snapshot: fixtureSnapshot, layout: layout, windowPreviewsEnabled: true)
    // The previous closing task ends after 0.22 seconds; it must not hide the reopened scene.
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(controller.isOpen)
    XCTAssertEqual(panels().filter(\.isVisible).count, screens.count, "Reopening must survive the earlier closing task")

    controller.handleKey(.select)
    let selected = await waitUntil(timeout: 1) { !controller.isOpen }
    XCTAssertTrue(selected)
    XCTAssertEqual(controller.surfacePresentedFrameCount, 1, "Enter must retain the surface scene during the closing zoom")
    controller.releaseIdleOverviewResources()
    XCTAssertTrue(panels().allSatisfy { !$0.isVisible }, "Memory cleanup must hide the overlay even when it cancels the closing task")

    let destination = NSWindow(contentRect: fixtureFrame, styleMask: [.titled], backing: .buffered, defer: false)
    destination.isReleasedWhenClosed = false
    destination.title = "Defi Destination Fixture"
    destination.backgroundColor = .systemBlue
    destination.setFrame(fixtureFrame, display: true)
    destination.orderFrontRegardless()
    defer { destination.close() }
    let destinationID = WindowID(rawValue: UInt64(destination.windowNumber))
    let destinationWorkspace = Workspace(id: WorkspaceID(rawValue: "destination"),
      columns: [Column(window: destinationID, width: .fraction(nativeBounds.width / screen.frame.width))])
    windows[destinationID] = Window(id: destinationID, appID: appID, title: destination.title,
      frame: try XCTUnwrap(windows[windowID]).frame, processID: processID)
    let navigation = snapshot([workspace, destinationWorkspace], active: workspace.id)
    controller.prepare(windowPreviewsEnabled: true, snapshot: navigation, layout: layout)
    controller.open(snapshot: navigation, layout: layout, windowPreviewsEnabled: true)
    controller.handleKey(.down)
    controller.update(snapshot: snapshot([workspace, destinationWorkspace], active: destinationWorkspace.id),
      layout: layout, windowPreviewsEnabled: true)
    let previewed = await waitUntil(timeout: 2) { controller.previewCacheCount > 0 }
    XCTAssertTrue(previewed)
    // Close after the 0.22 second opening zoom, so the reverse zoom uses the displayed preview.
    try await Task.sleep(for: .milliseconds(250))
    let closings = controller.previewClosingCount
    controller.handleKey(.select)
    let closing = await waitUntil(timeout: 0.8) { !controller.isOpen }
    XCTAssertTrue(closing)
    XCTAssertEqual(controller.previewClosingCount, closings + screens.count,
      "Every display must zoom back through its preview; empty workspaces zoom the wallpaper")
    XCTAssertTrue(panels().contains(where: \.isVisible), "Changing workspace must retain the displayed preview during the reverse zoom")
    let hidden = await waitUntil(timeout: 2) { panels().allSatisfy { !$0.isVisible } }
    XCTAssertTrue(hidden)
    XCTAssertEqual(destination.frame, fixtureFrame)

    // A reused window number must never show the previous owner's pixels.
    var foreignWindows = fixtureSnapshot.windows
    foreignWindows[windowID]?.appID = "different.owner"
    let foreign = OverviewSnapshot(monitors: fixtureSnapshot.monitors, monitorFrames: monitorFrames,
      windows: foreignWindows, activeMonitorID: monitorID)
    controller.open(snapshot: foreign, layout: layout, windowPreviewsEnabled: true)
    XCTAssertEqual(controller.previewCacheCount, 0)
    controller.close()
    let foreignHidden = await waitUntil(timeout: 2) { panels().allSatisfy { !$0.isVisible } }
    XCTAssertTrue(foreignHidden)

    // Captures requested by the earlier phases must not land after the clear.
    let idle = await waitUntil(timeout: 5) { !WindowCaptureCache.shared.isCapturing }
    XCTAssertTrue(idle)
    WindowCaptureStore.shared.clear()
    controller.prepare(windowPreviewsEnabled: false)
    let zooms = controller.surfaceTransitionCount
    controller.open(snapshot: fixtureSnapshot, layout: layout, windowPreviewsEnabled: false)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(WindowCaptureStore.shared.count, 0, "Opting out of previews must not request any capture")
    XCTAssertEqual(controller.surfaceTransitionCount, zooms + 1, "The zoom must run from verified native frames without previews")
    XCTAssertTrue(controller.openingTransitionHistory.contains("started(surfaces:0,"), controller.openingTransitionHistory)
    controller.close()
    // Releasing the controller mid-zoom strands a screen-sized panel above every later test's windows.
    let finalHidden = await waitUntil(timeout: 2) { panels().allSatisfy { !$0.isVisible } }
    XCTAssertTrue(finalHidden)
    controller.prepare(windowPreviewsEnabled: false)
  }

  func testOverviewNavigationResumesFromDisplayedPosition() async throws {
    _ = try preflight()
    let screen = try XCTUnwrap(NSScreen.main)
    let monitorID = try XCTUnwrap(self.monitorID(of: screen))
    let windows = (0..<5).map { index in
      Window(id: WindowID(rawValue: UInt64(index + 1)), appID: "test", title: "Vertical window \(index)",
        frame: Rect(x: 0, y: 0, width: 700, height: 700), processID: getpid())
    }
    let workspaces = windows.map { window in
      Workspace(id: WorkspaceID(rawValue: "vertical-\(window.id.rawValue)"),
        columns: [Column(window: window.id, width: .fraction(0.5))])
    }
    func snapshot(_ active: Int) -> OverviewSnapshot {
      OverviewSnapshot(monitors: [Monitor(id: monitorID, workspaces: workspaces, activeWorkspace: workspaces[active].id)],
        monitorFrames: [monitorID: Rect(x: 0, y: 0, width: screen.frame.width, height: screen.visibleFrame.height)],
        windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }), activeMonitorID: monitorID)
    }
    var nativeSelections: [WindowID] = []
    let controller = OverviewController(focusWindow: { id, _, _, _ in nativeSelections.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in })
    controller.open(snapshot: snapshot(2), layout: LayoutSettings(), windowPreviewsEnabled: false)
    defer { controller.close(); controller.close() }
    func findView(_ view: NSView) -> OverviewView? {
      (view as? OverviewView) ?? view.subviews.lazy.compactMap(findView).first
    }
    let input = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView.flatMap(findView) }.first)
    func minY() -> CGFloat? {
      (input.accessibilityChildren() as? [NSAccessibilityElement])?
        .first { $0.accessibilityLabel() == "Vertical window 2" }?.accessibilityFrame().minY
    }
    func moved(from origin: CGFloat) -> Bool { minY().map { abs($0 - origin) > 1 } == true }
    let faded = await waitUntil(timeout: 1) { input.window?.alphaValue == 1 }
    XCTAssertTrue(faded)
    let before = try XCTUnwrap(minY())
    controller.handleKey(.down)
    let animating = await waitUntil(timeout: 0.2) { moved(from: before) }
    XCTAssertTrue(animating, "Vertical keyboard navigation must animate before native activation completes")
    let awaitingActivation = try XCTUnwrap(minY())
    XCTAssertTrue(nativeSelections.isEmpty, "Overview arrows must not move native windows")
    controller.update(snapshot: snapshot(2), layout: LayoutSettings())
    XCTAssertEqual(try XCTUnwrap(minY()), awaitingActivation, accuracy: 1, "An unchanged runtime snapshot must preserve deferred navigation")
    controller.update(snapshot: snapshot(3), layout: LayoutSettings())
    XCTAssertEqual(try XCTUnwrap(minY()), awaitingActivation, accuracy: 1, "Activating the workspace must preserve the displayed source position")
    let resumed = await waitUntil(timeout: 0.2) { moved(from: awaitingActivation) }
    XCTAssertTrue(resumed, "Activation must preserve the ongoing animation timeline")
    let intermediate = try XCTUnwrap(minY())
    controller.handleKey(.up)
    controller.update(snapshot: snapshot(2), layout: LayoutSettings())
    XCTAssertEqual(try XCTUnwrap(minY()), intermediate, accuracy: 1, "Repeated arrows must resume from the displayed position")
    let returned = await waitUntil(timeout: 1) {
      controller.update(snapshot: snapshot(2), layout: LayoutSettings())
      return !moved(from: before)
    }
    XCTAssertTrue(returned, "Snapshot refreshes must not prevent the transition from finishing")
    controller.handleKey(.down)
    controller.handleKey(.up)
    controller.update(snapshot: snapshot(2), layout: LayoutSettings())
    // Proving that no superseded destination appears needs the full animation duration.
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(try XCTUnwrap(minY()), before, accuracy: 1, "A reversal before the first refresh must cancel the superseded destination")
    controller.handleKey(.down)
    let started = await waitUntil(timeout: 0.2) { moved(from: before) }
    XCTAssertTrue(started)
    controller.update(snapshot: snapshot(1), layout: LayoutSettings())
    let target = projectOverview(snapshot: snapshot(1), monitorID: monitorID,
      bounds: Rect(x: 0, y: 0, width: input.bounds.width, height: input.bounds.height),
      viewport: OverviewViewport(), layout: LayoutSettings(), zoom: 0.5)
    let card = try XCTUnwrap(target.workspaces.flatMap(\.windows).first { $0.windowID == windows[2].id }).frame
    let expected = try XCTUnwrap(input.window).convertToScreen(input.convert(
      NSRect(x: card.x, y: card.y, width: card.width, height: card.height), to: nil)).minY
    let superseded = await waitUntil(timeout: 1) { minY().map { abs($0 - expected) <= 1 } == true }
    XCTAssertTrue(superseded, "An unrelated workspace activation must supersede the predicted destination")
  }

  // MARK: Two-display lane

  func testTwoDisplayWindowsStayOnTheirDisplay() throws {
    let platform = try preflight()
    try requireTwoDisplays()
    // Match the running daemon's geometry; restoring the desk stops it.
    let arrangement = DisplayArrangementController()
    defer { arrangement.restore() }
    if arrangement.reconcile() { XCTAssertTrue(pumpRunLoop(until: displaysSettled, timeout: 2)) }
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let id = fixtures.tiledWindowID
    let snapshot = platform.snapshot(config: Config())
    let window = try XCTUnwrap(snapshot.windows.first { $0.id == id })
    let element = try XCTUnwrap(platform.elements[id])
    let monitors = snapshot.monitors.sorted { $0.frame.height < $1.frame.height }
    guard let smaller = monitors.first, let taller = monitors.last, taller.frame.height - smaller.frame.height > 10 else {
      try notRun(lane: "two-display", reason: "requires two displays with different usable heights")
    }
    for invalidatesDisplayState in [false, true] {
      for monitor in [smaller, taller, smaller] {
        if invalidatesDisplayState { onNavigation { platform.invalidateFrameStateForDisplayChange() } }
        let target = Rect(x: monitor.frame.x, y: monitor.frame.y,
          width: min(window.frame.width, monitor.frame.width), height: monitor.frame.height)
        onNavigation { platform.apply([FrameAssignment(windowID: id, frame: target)], source: "test-monitor-height") }
        XCTAssertTrue(settleFrames(platform))
        var actual: Rect?
        XCTAssertTrue(pumpRunLoop(until: {
          actual = platform.frame(of: element)
          return actual.map { abs($0.height - target.height) <= 2 && abs($0.y - target.y) <= 2 } == true
        }, timeout: 1), "Monitor transfer must fill the destination height: monitor=\(monitor.id) invalidated=\(invalidatesDisplayState) target=\(target) actual=\(String(describing: actual)) trace=\(onNavigation { platform.frameCoordinatorTrace })")
      }
    }
    for monitor in snapshot.monitors {
      let target = parkedFrame(window.frame, display: monitor.physicalFrame, visibleFrame: monitor.frame,
        otherDisplays: snapshot.monitors.filter { $0.id != monitor.id }.map(\.physicalFrame))
      onNavigation { platform.apply([FrameAssignment(windowID: id, frame: target)], hiddenWindowIDs: [id]) }
      XCTAssertTrue(settleFrames(platform))
      var actual: Rect?
      XCTAssertTrue(pumpRunLoop(until: {
        actual = platform.frame(of: element)
        return actual.map { abs($0.x - target.x) <= 2 && holdsParkedY($0.y, target.y) } == true
      }, timeout: 1), "Parking must converge: target=\(target) actual=\(String(describing: actual))")
      let rect = cgRect(try XCTUnwrap(actual))
      for other in snapshot.monitors where other.id != monitor.id {
        let overlap = rect.intersection(cgRect(other.physicalFrame))
        XCTAssertTrue(overlap.isNull || overlap.isEmpty, "Parking leaked into \(other.id): \(overlap)")
      }
    }
  }

  func testTwoDisplayStaircaseKeepsPartialColumnsAndRoutesPointer() throws {
    let platform = try preflight()
    try requireTwoDisplays()
    let initialFrames = DisplayArrangementController.currentFrames()
    let primary = MonitorID(rawValue: UInt64(CGMainDisplayID()))
    let cursor = try XCTUnwrap(CGEvent(source: nil)?.location)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
      // Never commit a leaked staircase to the macOS session; keep the restored desk.
      if !isDisplayStaircase(initialFrames, primary: primary) {
        XCTAssertEqual(DisplayArrangementController.apply(initialFrames, scope: .forSession), .success)
        XCTAssertTrue(pumpRunLoop(until: { DisplayArrangementController.currentFrames() == initialFrames }, timeout: 2))
      }
      CGWarpMouseCursorPosition(cursor)
      try? FileManager.default.removeItem(at: directory)
    }
    func makeController() -> DisplayArrangementController {
      DisplayArrangementController(readFrames: DisplayArrangementController.currentFrames,
        applyFrames: DisplayArrangementController.apply, primaryDisplay: { primary },
        stateURL: directory.appending(path: "arrangement.json"), sessionID: "desktop-test")
    }
    // Exercise the transformed arrangement even when the user's displays are vertical.
    var desk = initialFrames
    var nextX = try XCTUnwrap(initialFrames[primary]).width
    for id in initialFrames.keys.sorted(by: { $0.rawValue < $1.rawValue }) where id != primary {
      desk[id]?.x = nextX
      desk[id]?.y = 0
      nextX += initialFrames[id]!.width
    }
    let fixtures = try openFixtures(platform)
    defer { closeFixtures(fixtures) }
    let id = fixtures.tiledWindowID
    let window = try XCTUnwrap(platform.snapshot(config: Config()).windows.first { $0.id == id })
    var controller = makeController()
    defer { controller.restore() }
    XCTAssertEqual(DisplayArrangementController.apply(desk), .success)
    XCTAssertTrue(pumpRunLoop(until: { DisplayArrangementController.currentFrames() == desk }, timeout: 2))
    _ = controller.reconcile()
    XCTAssertEqual(controller.status, "isolated")
    XCTAssertEqual(controller.deskFrames, desk)
    XCTAssertTrue(pumpRunLoop(until: displaysSettled, timeout: 2))
    let technical = DisplayArrangementController.currentFrames()
    var crossings = 0
    for frame in technical.values {
      for (x, y, dx, dy) in [
        (frame.x, frame.y + frame.height / 2, -5.0, 0.0), (frame.x + frame.width - 1, frame.y + frame.height / 2, 5, 0),
        (frame.x + frame.width / 2, frame.y, 0, -5), (frame.x + frame.width / 2, frame.y + frame.height - 1, 0, 5),
      ] {
        guard let expected = displayPointerDestination(x: x, y: y, deltaX: dx, deltaY: dy, technical: technical, desk: desk)
        else { continue }
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
          mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left))
        event.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        XCTAssertTrue(controller.pointerRouter.route(event))
        let observed = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(observed.x, expected.x, accuracy: 2)
        XCTAssertEqual(observed.y, expected.y, accuracy: 2)
        crossings += 1
      }
    }
    XCTAssertEqual(crossings, 2 * (technical.count - 1), "Each shared desk edge must route in both directions")
    let monitors = platform.discoverMonitors()
    for monitor in monitors {
      let frame = monitor.frame
      let target = Rect(x: frame.x + frame.width * 0.8, y: frame.y,
        width: window.frame.width, height: min(window.frame.height, frame.height))
      onNavigation { platform.apply([FrameAssignment(windowID: id, frame: target)]) }
      XCTAssertTrue(settleFrames(platform))
      let element = try XCTUnwrap(platform.elements[id])
      var actual: Rect?
      XCTAssertTrue(pumpRunLoop(until: {
        actual = platform.frame(of: element)
        return actual.map { abs($0.x - target.x) <= 2 && abs($0.width - target.width) <= 2 } == true
      }, timeout: 1), "A partial column must converge: target=\(target) actual=\(String(describing: actual))")
      let rect = cgRect(try XCTUnwrap(actual))
      XCTAssertGreaterThan(rect.intersection(cgRect(frame)).width, 100, "The neighboring column's preview disappeared")
      for other in monitors where other.id != monitor.id {
        let overlap = rect.intersection(cgRect(other.physicalFrame))
        XCTAssertTrue(overlap.isNull || overlap.isEmpty, "Partial ribbon leaked onto another display")
      }
    }

    // A restarted controller must never adopt a leaked staircase as the desk.
    controller.restore()
    XCTAssertEqual(DisplayArrangementController.apply(technical), .success)
    controller = makeController()
    _ = controller.reconcile()
    XCTAssertEqual(controller.deskFrames, desk)
    let other = try XCTUnwrap(technical.keys.first { $0 != primary })
    let source = try XCTUnwrap(technical[primary])
    let x = source.x + source.width - 1
    let y = source.y + min(source.height, try XCTUnwrap(initialFrames[other]).height) / 2
    let destination = try XCTUnwrap(displayPointerDestination(x: x, y: y, deltaX: 5, deltaY: 0, technical: technical, desk: desk))
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let router = controller.pointerRouter
    let manager = onNavigation { HotKeyManager(
      config: Config(input: InputConfig(focusFollowsMouse: true)),
      pointerMotionHandler: { invocation in DispatchQueue.main.async { received.value.append(invocation) } },
      displayPointerRouter: router
    ) { _ in } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let event = try XCTUnwrap(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
      mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left))
    event.setDoubleValueField(.mouseEventDeltaX, value: 5)
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: {
      received.value.contains { $0.location == CGPoint(x: destination.x, y: destination.y) && $0.windowID == nil }
    }, timeout: 0.5), "The first crossing event must deliver the destination: \(received.value)")
    XCTAssertEqual(router.warpCount, 1)
    XCTAssertEqual(controller.restore(), desk)
  }

  // MARK: Performance lane

  func testPerfOverviewNavigationRenderBudget() async throws {
    _ = try preflight()
    guard ProcessInfo.processInfo.environment["DEFI_E2E_PERF"] == "1" else {
      try notRun(lane: "perf", reason: "set DEFI_E2E_PERF=1 to measure render budgets")
    }
    let screen = try XCTUnwrap(NSScreen.main)
    let monitorID = try XCTUnwrap(self.monitorID(of: screen))
    let controller = OverviewController(focusWindow: { _, _, _, _ in },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in })
    let panel = OverviewPanel(monitorID: monitorID, screen: screen, usesCapturedDesktop: true, delegate: controller)
    defer { panel.hide() }
    var windows: [WindowID: Window] = [:]
    let workspaces = (0..<5).map { row in
      Workspace(id: WorkspaceID(rawValue: "render-\(row)"), columns: (0..<4).map { column in
        let id = WindowID(rawValue: UInt64(row * 4 + column + 1))
        windows[id] = Window(id: id, appID: "com.apple.finder", title: "Overview render fixture \(id)",
          frame: Rect(x: 0, y: 0, width: 1200, height: 1300), processID: getpid())
        return Column(window: id, width: .fraction(0.66))
      })
    }
    let snapshot = OverviewSnapshot(monitors: [Monitor(id: monitorID, workspaces: workspaces,
      activeWorkspace: workspaces[2].id)], monitorFrames: [monitorID:
        Rect(x: 0, y: 0, width: screen.frame.width, height: screen.visibleFrame.height)],
      windows: windows, activeMonitorID: monitorID)
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    NSGradient(starting: .systemBlue, ending: .systemOrange)!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 45)
    image.unlockFocus()
    // Full-resolution shared pictures, scaled by the layers like the live cache.
    let context = try XCTUnwrap(CGContext(data: nil, width: 2_400, height: 2_600, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.systemTeal.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 2_600))
    let picture = WindowPicture(contents: try XCTUnwrap(context.makeImage()),
      size: CGSize(width: 1_200, height: 1_300), capturedAt: 1, pixelScale: 2)
    let blurred = try XCTUnwrap(overviewBlurredPreview(try XCTUnwrap(picture.image)))
    let previews = windows.mapValues { _ in picture }
    panel.setDesktopImage(image)
    panel.show()
    var costs: [Double] = []
    for index in 0..<160 {
      let projection = projectOverview(snapshot: snapshot, monitorID: monitorID,
        bounds: Rect(x: 0, y: 0, width: panel.view.bounds.width, height: panel.view.bounds.height),
        viewport: OverviewViewport(workspaceOffset: sin(Double(index) / 20) * 0.6),
        layout: LayoutSettings(), zoom: 0.5)
      let started = CACurrentMediaTime()
      panel.view.update(snapshot: snapshot, projection: projection, selection: nil, drag: nil,
        borderStyle: WindowBorderStyle(config: BordersConfig()), windowCornerRadius: 12,
        previews: previews, blurredPreviews: previews.mapValues { _ in blurred }, previewOpacities: [:])
      panel.view.displayIfNeeded()
      if index >= 20 { costs.append(CACurrentMediaTime() - started) }
      if index % 20 == 0 { await Task.yield() }
    }
    let p95 = costs.sorted()[Int(Double(costs.count - 1) * 0.95)]
    print("DEFI_E2E overview-draw meanMs=\(costs.reduce(0, +) / Double(costs.count) * 1000) p95Ms=\(p95 * 1000) samples=\(costs.count)")
    XCTAssertLessThan(p95, 1 / Double(max(screen.maximumFramesPerSecond, 60)), "Warm overview drawing must fit one refresh budget")
    XCTAssertLessThanOrEqual(panel.view.titleRasterizationCount, windows.count, "Moving cards must reuse their rendered titles")

    controller.open(snapshot: snapshot, layout: LayoutSettings(), windowPreviewsEnabled: false)
    defer { controller.close() }
    func findView(_ view: NSView) -> OverviewView? {
      (view as? OverviewView) ?? view.subviews.lazy.compactMap(findView).first
    }
    let input = try XCTUnwrap(NSApp.windows.compactMap { window -> OverviewView? in
      guard window !== panel.window, let root = window.contentView else { return nil }
      return findView(root)
    }.first)
    let group = try XCTUnwrap((input.accessibilityChildren() as? [NSAccessibilityElement])?.first { $0.accessibilityRole() == .group })
    let label = group.accessibilityLabel()
    let before = group.accessibilityFrame()
    let updates = input.presentationUpdateCount
    for _ in 0..<100 {
      controller.overviewView(input, scrolled: NSPoint(x: 0, y: -1), hasPreciseScrollingDeltas: true, at: NSPoint(x: 100, y: 100))
    }
    XCTAssertLessThan(input.presentationUpdateCount - updates, 5, "Precise events must coalesce rather than project every input event")
    let scrolled = await waitUntil(timeout: 1) {
      (input.accessibilityChildren() as? [NSAccessibilityElement])?.first { $0.accessibilityLabel() == label }
        .map { abs($0.accessibilityFrame().minY - before.minY - 100) <= 0.5 } == true
    }
    XCTAssertTrue(scrolled, "The last pending frame must preserve all trackpad deltas")
  }

  // MARK: Harness

  /// One loud preflight replaces per-test silent skips.
  private func preflight() throws -> MacOSPlatform {
    guard ProcessInfo.processInfo.environment["DEFI_E2E"] == "1" else {
      throw XCTSkip("Set DEFI_E2E=1 to run real-desktop tests")
    }
    let platform = onNavigation { MacOSPlatform() }
    let accessibility = platform.accessibilityTrusted(prompt: false)
    let screenRecording = CGPreflightScreenCaptureAccess()
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let fixture = ProcessInfo.processInfo.environment["DEFI_DESKTOP_FIXTURE_BINARY"]
    print("DEFI_E2E accessibility=\(accessibility ? "available" : "unavailable") screen-recording=\(screenRecording ? "available" : "unavailable") reduce-motion=\(reduceMotion ? "on" : "off") displays=\(NSScreen.screens.count)")
    let missing = [
      accessibility ? nil : "Accessibility permission for the test process",
      screenRecording ? nil : "Screen Recording permission for the test process",
      reduceMotion ? "Reduce Motion disabled" : nil,
      fixture.map { FileManager.default.isExecutableFile(atPath: $0) } == true
        ? nil : "DEFI_DESKTOP_FIXTURE_BINARY (run script/test_desktop.sh)",
    ].compactMap { $0 }
    guard missing.isEmpty else {
      throw DesktopPreflightFailure(description: "Desktop preflight requires: " + missing.joined(separator: ", "))
    }
    return platform
  }

  private func requireTwoDisplays() throws {
    let count = NSScreen.screens.count
    if count < 2 { try notRun(lane: "two-display", reason: "requires 2 displays, found \(count)") }
  }

  /// verify.py accepts a skip only with this marker and reports it as not run.
  private func notRun(lane: String, reason: String) throws -> Never {
    print("DEFI_E2E not-run lane=\(lane) test=\(name) reason=\(reason)")
    throw XCTSkip("\(lane) lane: \(reason)")
  }

  private var frontmostBeforeFixtures: NSRunningApplication?

  private func openFixtures(_ platform: MacOSPlatform) throws -> DesktopFocusFixturePair {
    frontmostBeforeFixtures = NSWorkspace.shared.frontmostApplication
    return try DesktopFocusFixturePair(platform: platform) { self.pumpRunLoop(until: $0, timeout: $1) }
  }

  /// What can block a pointer hit test, front to back.
  private func windowsDescription(at point: CGPoint) -> [String] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return windows.compactMap { window in
      guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { return nil }
      return "\(window[kCGWindowOwnerName as String] ?? "?") layer=\(window[kCGWindowLayer as String] ?? "?") \(frame)"
    }
  }

  private func closeFixtures(_ fixtures: DesktopFocusFixturePair) {
    XCTAssertNoThrow(try fixtures.close())
    frontmostBeforeFixtures?.activate()
  }

  /// AX focus brings a fixture forward even when cooperative activation refuses the runner's request.
  private func activate(_ process: Process, focusing id: WindowID, _ platform: MacOSPlatform) throws {
    // An active runner must yield before any other app can take activation.
    NSApplication.shared.yieldActivation(to: try XCTUnwrap(NSRunningApplication(processIdentifier: process.processIdentifier)))
    onNavigation { platform.focus(id) }
    XCTAssertTrue(pumpRunLoop(until: {
      platform.snapshot(config: Config()).focusedWindowID == id
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
    }, timeout: 2), "The fixture must hold native focus before the next request: frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) target=\(process.processIdentifier) runner=\(getpid()) focused=\(String(describing: platform.snapshot(config: Config()).focusedWindowID)) id=\(id)")
  }

  /// Cooperative activation lets the runner activate only when the active app yields to it.
  private func activateTestRunner(through fixtures: DesktopFocusFixturePair, _ platform: MacOSPlatform) throws {
    try activate(fixtures.floatingProcess, focusing: fixtures.floatingWindowID, platform)
    let source = try XCTUnwrap(NSRunningApplication(processIdentifier: fixtures.floatingProcess.processIdentifier))
    NSApplication.shared.setActivationPolicy(.regular)
    fixtures.yieldActivation(to: getpid())
    // Activation arrives as an AppKit event, so only the application event loop observes it.
    XCTAssertTrue(pumpApplicationEvents(until: {
      NSRunningApplication.current.activate(from: source, options: [])
      return NSApplication.shared.isActive
    }, timeout: 2), "The frontmost fixture must yield activation to the test runner")
  }

  private func settleFrames(_ platform: MacOSPlatform) -> Bool {
    pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 2)
  }

  private func displaysSettled() -> Bool {
    let frames = DisplayArrangementController.currentFrames()
    return NSScreen.screens.count == frames.count && NSScreen.screens.allSatisfy { screen in
      monitorID(of: screen).flatMap { frames[$0] }.map {
        $0.x == screen.frame.minX && $0.width == screen.frame.width
      } == true
    }
  }

  private func monitorID(of screen: NSScreen) -> MonitorID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { MonitorID(rawValue: $0.uint64Value) }
  }

  private func cgRect(_ rect: Rect) -> CGRect {
    CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
  }

  private func startHotKeys(_ manager: HotKeyManager) throws {
    try onNavigation { try manager.start() }
    if onNavigation({ manager.bindingError == nil && manager.bindingCount > 0 }), !ShortcutRecorderButton.capturesKeyboard {
      XCTAssertTrue(pumpRunLoop(until: {
        onNavigation { manager.isHotKeyCaptureEnabled || manager.bindingError != nil }
      }, timeout: 2), "Carbon hotkey registration did not complete")
      XCTAssertNil(onNavigation { manager.bindingError })
    } else {
      XCTAssertTrue(pumpRunLoop(until: { onNavigation { manager.isEnabled } }, timeout: 2), "The event tap did not start")
    }
  }

  /// An app with a taller title bar stops a little above the predicted corner.
  private func holdsParkedY(_ actual: Double, _ target: Double) -> Bool {
    actual <= target + 2 && actual >= target - parkingVerticalSlack - 2
  }

  private func pumpRunLoop(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
  }

  @discardableResult
  private func pumpRunLoop(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
    }
    return condition()
  }

  /// Dispatches queued AppKit events so local monitors and the key window observe them.
  @discardableResult
  private func pumpApplicationEvents(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      if let event = NSApplication.shared.nextEvent(matching: .any,
        until: min(deadline, Date().addingTimeInterval(0.01)), inMode: .default, dequeue: true) {
        NSApplication.shared.sendEvent(event)
      }
    }
    return condition()
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}

/// Desktop tests own AppKit on MainActor; native commands enter the same serial
/// executor as the installed daemon. Never wrap a synchronous desktop snapshot.
@discardableResult
private func onNavigation<T>(_ body: @NavigationActor () throws -> T) rethrows -> T {
  try NavigationActor.shared.queue.sync {
    try NavigationActor.assumeIsolated(body)
  }
}

/// Hotkey callbacks run on the navigation actor while the test reads on the main actor.
private final class CommandLog: Sendable {
  private let commands = Mutex<[String]>([])
  func append(_ command: String) { commands.withLock { $0.append(command) } }
  var count: Int { commands.withLock { $0.count } }
  var all: [String] { commands.withLock { $0 } }
}

@MainActor
private final class DesktopValue<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}
