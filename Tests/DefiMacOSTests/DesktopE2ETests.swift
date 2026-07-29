import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import XCTest

@testable import DefiMacOS

@MainActor
final class DesktopE2ETests: XCTestCase {
  private func makePlatform() throws -> MacOSPlatform {
    guard ProcessInfo.processInfo.environment["DEFI_E2E"] == "1" else {
      throw XCTSkip("Set DEFI_E2E=1 to run real-desktop tests")
    }
    let platform = MacOSPlatform()
    guard platform.accessibilityTrusted(prompt: false) else {
      throw XCTSkip("Accessibility permission unavailable to test process")
    }
    return platform
  }

  func testFocusedWindowRemainsResolvableWhileParkedOffscreen() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = snapshot.windows.first else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    defer {
      platform.apply([FrameAssignment(windowID: window.id, frame: original)])
      pumpRunLoop(for: 0.3)
    }

    platform.apply([
      FrameAssignment(
        windowID: window.id,
        frame: Rect(x: -10_000, y: -10_000, width: original.width, height: original.height)
      )
    ])
    pumpRunLoop(for: 0.2)
    platform.focus(window.id)
    pumpRunLoop(for: 0.5)

    XCTAssertEqual(platform.snapshot(config: Config()).focusedWindowID, window.id)
  }

  func testAppliedTargetConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = snapshot.windows.max(by: { $0.frame.width < $1.frame.width }),
      window.frame.width > 500
    else {
      throw XCTSkip("No resizable desktop window")
    }
    let original = window.frame
    let target = Rect(
      x: original.x + 12,
      y: original.y,
      width: original.width - 24,
      height: original.height
    )
    defer {
      platform.apply([FrameAssignment(windowID: window.id, frame: original)])
      pumpRunLoop(for: 0.3)
    }

    platform.apply([FrameAssignment(windowID: window.id, frame: target)])
    pumpRunLoop(for: 0.4)
    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame

    XCTAssertNotNil(actual)
    XCTAssertEqual(actual?.x ?? 0, target.x, accuracy: 2)
    XCTAssertEqual(actual?.width ?? 0, target.width, accuracy: 2)
  }

  func testHorizontalAnimationFrameWritesPositionWithoutSize() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = snapshot.windows.first else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    defer {
      platform.apply([FrameAssignment(windowID: window.id, frame: original)])
      pumpRunLoop(for: 0.3)
    }
    platform.apply([FrameAssignment(windowID: window.id, frame: original)])
    let positionWrites = platform.successfulPositionWriteCount
    let sizeWrites = platform.successfulSizeWriteCount

    platform.apply([
      FrameAssignment(
        windowID: window.id,
        frame: Rect(
          x: original.x + 8,
          y: original.y,
          width: original.width,
          height: original.height
        )
      )
    ])
    pumpRunLoop(for: 0.2)

    XCTAssertGreaterThan(platform.successfulPositionWriteCount, positionWrites)
    XCTAssertEqual(platform.successfulSizeWriteCount, sizeWrites)
  }

  func testUnhiddenOnePixelStripAnchorConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let candidates = snapshot.windows.filter {
      !$0.intrinsicSize && $0.frame.width >= 300
    }
    let preferredWindow =
      candidates.first(where: { $0.appID == "com.t3tools.t3code" })
      ?? candidates.max(by: { $0.frame.width < $1.frame.width })
    guard let window = preferredWindow,
      let monitor = snapshot.monitors.first
    else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    let staged = Rect(
      x: monitor.frame.x
        + max(monitor.frame.width - original.width, 0) / 2,
      y: monitor.frame.y
        + max(monitor.frame.height - original.height, 0) / 2,
      width: original.width,
      height: original.height
    )
    let anchored = resolveParkingPlacement(
      for: staged,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    defer {
      platform.apply(
        [FrameAssignment(windowID: window.id, frame: original)],
        asynchronousPositions: true
      )
      pumpRunLoop(for: 0.4)
    }

    platform.apply([FrameAssignment(windowID: window.id, frame: staged)])
    pumpRunLoop(for: 0.25)
    platform.apply(
      [FrameAssignment(windowID: window.id, frame: anchored)],
      asynchronousPositions: true,
      asynchronousPositionTimeoutSeconds: 0.05,
      source: "test-strip-sliver"
    )
    XCTAssertTrue(
      pumpRunLoop(
        until: { !platform.hasPendingAnimatedFrameWrites },
        timeout: 0.8
      )
    )
    pumpRunLoop(for: 0.1)

    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    XCTAssertEqual(actual?.x ?? 0, anchored.x, accuracy: 2)
    XCTAssertEqual(actual?.y ?? 0, anchored.y, accuracy: 2)
    XCTAssertEqual(platform.hiddenWindowCount, 0)
  }

  func testReenteringWindowJoinsFirstAnimatedRibbonSample() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard snapshot.windows.count >= 2,
      let window = snapshot.windows.first,
      let neighbor = snapshot.windows.dropFirst().first,
      let monitor = snapshot.monitors.first
    else {
      throw XCTSkip("Need two manageable desktop windows")
    }
    let original = window.frame
    let neighborOriginal = neighbor.frame
    let parked = resolveParkingPlacement(
      for: original,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    let target = Rect(
      x: original.x + 16,
      y: original.y,
      width: original.width,
      height: original.height
    )
    let neighborTarget = Rect(
      x: neighborOriginal.x + 16,
      y: neighborOriginal.y,
      width: neighborOriginal.width,
      height: neighborOriginal.height
    )
    defer {
      platform.apply([
        FrameAssignment(windowID: window.id, frame: original),
        FrameAssignment(windowID: neighbor.id, frame: neighborOriginal),
      ])
      pumpRunLoop(for: 0.3)
    }

    platform.apply(
      [
        FrameAssignment(windowID: window.id, frame: parked),
        FrameAssignment(windowID: neighbor.id, frame: neighborOriginal),
      ],
      hiddenWindowIDs: [window.id],
      asynchronousPositions: true
    )
    pumpRunLoop(for: 0.3)
    platform.apply(
      [
        FrameAssignment(windowID: window.id, frame: target),
        FrameAssignment(windowID: neighbor.id, frame: neighborTarget),
      ],
      asynchronousPositions: true,
      animationDuration: 0.05,
      animationRefreshRateHz: 120
    )
    pumpRunLoop(for: 0.4)

    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    let performance = platform.frameCoordinatorPerformance
    XCTAssertEqual(actual?.x ?? 0, target.x, accuracy: 2)
    XCTAssertGreaterThanOrEqual(performance.animationFrames, 2)
    XCTAssertLessThanOrEqual(performance.animationFrames, 5)
    XCTAssertTrue(platform.frameCoordinatorTrace.contains("reentry=1"))
    XCTAssertFalse(platform.frameCoordinatorTrace.contains("stage-reentry"))
  }

  func testPostAnimationCommitLagDoesNotTriggerUnanimatedCorrection() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first else {
      throw XCTSkip("No desktop monitor")
    }
    let candidates = snapshot.windows.filter { window in
      let intersectionWidth = max(
        min(
          window.frame.x + window.frame.width,
          monitor.frame.x + monitor.frame.width
        ) - max(window.frame.x, monitor.frame.x),
        0
      )
      return !window.intrinsicSize
        && intersectionWidth >= window.frame.width * 0.5
    }
    guard let window = candidates.max(by: { $0.frame.width < $1.frame.width }) else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    let animatedWidth = max(original.width - 160, 200)
    let target = Rect(
      x: original.x + 80,
      y: original.y,
      width: animatedWidth,
      height: original.height
    )
    let intermediate = Rect(
      x: original.x + 40,
      y: original.y,
      width: animatedWidth,
      height: original.height
    )
    defer {
      platform.apply([FrameAssignment(windowID: window.id, frame: original)])
      pumpRunLoop(for: 0.3)
    }

    platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      asynchronousPositions: true,
      animationDuration: 0.05,
      animationRefreshRateHz: 120,
      source: "test-animation"
    )
    XCTAssertTrue(
      pumpRunLoop(
        until: { !platform.hasPendingAnimatedFrameWrites },
        timeout: 0.5
      )
    )

    let competingPlatform = try makePlatform()
    _ = competingPlatform.snapshot(config: Config())
    var competingWriteConverged = false
    var lastCompetingFrame: Rect?
    for _ in 0..<10 where !competingWriteConverged {
      competingPlatform.apply([
        FrameAssignment(windowID: window.id, frame: intermediate)
      ])
      competingWriteConverged = pumpRunLoop(
        until: {
          let actual = competingPlatform.snapshot(config: Config()).windows
            .first(where: { $0.id == window.id })?.frame
          lastCompetingFrame = actual
          return abs((actual?.x ?? .infinity) - intermediate.x) <= 2
        },
        timeout: 0.03
      )
    }
    XCTAssertTrue(
      competingWriteConverged,
      "test must force a delayed intermediate commit before checking quarantine; app=\(window.appID) original=\(original) target=\(target) intermediate=\(intermediate) actual=\(String(describing: lastCompetingFrame))"
    )
    guard competingWriteConverged else { return }

    let writesBeforeDesktopSync = platform.successfulPositionWriteCount
    let delayedSnapshot = platform.snapshot(config: Config())
    platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      asynchronousPositions: true,
      source: "desktop-sync"
    )
    pumpRunLoop(for: 0.08)

    XCTAssertEqual(delayedSnapshot.targetMismatchCount, 0)
    XCTAssertGreaterThan(platform.frameCommitPerformance.deferred, 0)
    XCTAssertEqual(
      platform.successfulPositionWriteCount,
      writesBeforeDesktopSync
    )
    XCTAssertFalse(
      platform.frameCoordinatorTrace.contains("source=desktop-sync")
    )
  }

  func testNativeFocusEmitsPlatformEvent() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = snapshot.windows.first(where: { $0.id != snapshot.focusedWindowID }) else {
      throw XCTSkip("Need a non-focused manageable window")
    }
    var eventCount = 0
    platform.startObserving {
      eventCount += 1
    }

    platform.focus(window.id)
    pumpRunLoop(for: 0.6)

    XCTAssertGreaterThan(eventCount, 0)
    XCTAssertEqual(platform.snapshot(config: Config()).focusedWindowID, window.id)
  }

  func testSnapshotUsesUniqueWindowIDsPerProcess() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let windowsByProcess = Dictionary(grouping: snapshot.windows, by: \.processID)

    for (processID, windows) in windowsByProcess {
      XCTAssertEqual(
        Set(windows.map(\.id)).count,
        windows.count,
        "process \(String(describing: processID)) mapped multiple AX windows to one CG window"
      )
    }
  }

  func testHotKeysAreCapturedWhileMainActorIsBlocked() throws {
    _ = try makePlatform()
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      keys: ["hyper-left": "focus-column left"]
    )
    var received: [String] = []
    let manager = try HotKeyManager(config: config) { command in
      received.append(command)
    }
    try manager.start()
    let eventCount = 8

    DispatchQueue.global(qos: .userInteractive).async {
      Thread.sleep(forTimeInterval: 0.05)
      let flags: CGEventFlags = [
        .maskAlternate,
        .maskCommand,
        .maskControl,
      ]
      for _ in 0..<eventCount {
        guard
          let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: 123,
            keyDown: true
          )
        else {
          continue
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
      }
    }

    Thread.sleep(forTimeInterval: 0.35)
    XCTAssertEqual(
      manager.capturedKeyCount,
      eventCount,
      "event tap must keep capturing while AX/layout blocks the main actor"
    )
    pumpRunLoop(for: 0.2)
    XCTAssertEqual(received.count, eventCount)
    XCTAssertEqual(manager.tapReenableCount, 0)
  }

  func testCornerParkingConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = snapshot.windows.first,
      let monitor = snapshot.monitors.first
    else {
      throw XCTSkip("No manageable desktop window")
    }
    let target = resolveParkingPlacement(
      for: window.frame,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    defer {
      platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)])
      pumpRunLoop(for: 0.3)
    }

    platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      hiddenWindowIDs: [window.id],
      asynchronousPositions: true
    )
    pumpRunLoop(for: 0.3)
    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    XCTAssertFalse(platform.hasPendingAnimatedFrameWrites)
    XCTAssertEqual(actual?.x ?? 0, target.x, accuracy: 2)
    XCTAssertEqual(actual?.y ?? 0, target.y, accuracy: 2)
    XCTAssertEqual(platform.hiddenWindowCount, 1)
  }

  func testCornerParkingRepairsDelayedRollback() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = snapshot.windows.first,
      let monitor = snapshot.monitors.first
    else {
      throw XCTSkip("No manageable desktop window")
    }
    let parked = resolveParkingPlacement(
      for: window.frame,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    defer {
      platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)])
      pumpRunLoop(for: 0.3)
    }
    platform.apply(
      [FrameAssignment(windowID: window.id, frame: parked)],
      hiddenWindowIDs: [window.id],
      asynchronousPositions: true
    )
    pumpRunLoop(for: 0.2)

    let competingPlatform = try makePlatform()
    _ = competingPlatform.snapshot(config: Config())
    let rollback = Rect(
      x: window.frame.x + 40,
      y: window.frame.y,
      width: window.frame.width,
      height: window.frame.height
    )
    competingPlatform.apply([
      FrameAssignment(windowID: window.id, frame: rollback)
    ])
    pumpRunLoop(for: 0.2)

    pumpRunLoop(for: 0.5)
    let repaired = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    XCTAssertEqual(repaired?.x ?? 0, parked.x, accuracy: 2)
    XCTAssertEqual(repaired?.y ?? 0, parked.y, accuracy: 2)
    XCTAssertGreaterThanOrEqual(
      platform.parkingPerformance.repairs,
      1
    )
  }

  private func pumpRunLoop(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      RunLoop.main.run(mode: .default, before: deadline)
    }
  }

  private func pumpRunLoop(
    until condition: () -> Bool,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(
        mode: .default,
        before: min(deadline, Date().addingTimeInterval(0.01))
      )
    }
    return condition()
  }

}
