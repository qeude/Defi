import DefiRuntime
import AppKit
import ApplicationServices
import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import Synchronization
import XCTest
import class SwiftUI.NSHostingMenu

@testable import DefiMacOS

@MainActor
final class DesktopE2ETests: XCTestCase {
  func testOverviewShowsBothMonitorsBeforeLoadingPreviews() throws {
    _ = try makePlatform()
    let screens = NSScreen.screens
    guard screens.count > 1 else { throw XCTSkip("Requires two connected displays") }
    var windows: [WindowID: Window] = [:]
    var frames: [MonitorID: Rect] = [:]
    let monitors = screens.enumerated().map { index, screen in
      let id = MonitorID(rawValue: (screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as! NSNumber).uint64Value)
      frames[id] = Rect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
      let workspaces = (0..<4).map { row in
        let columns = (0..<6).map { column in
          let windowID = WindowID(rawValue: UInt64(1_000_000 + index * 100 + row * 6 + column))
          windows[windowID] = Window(
            id: windowID, appID: "test.overview", title: "Window \(column)",
            frame: Rect(x: 0, y: 0, width: 800, height: 600)
          )
          return Column(window: windowID, width: .fraction(0.5))
        }
        return Workspace(id: WorkspaceID(rawValue: "\(index)-\(row)"), columns: columns)
      }
      return Monitor(id: id, workspaces: workspaces, activeWorkspace: workspaces[0].id)
    }
    let controller = OverviewController(
      focusWindow: { _, _, _, _ in }, focusWorkspace: { _, _ in },
      drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in }
    )
    defer { controller.close() }
    controller.prepare(windowPreviewsEnabled: true)
    XCTAssertFalse(controller.isOpen)
    XCTAssertEqual(controller.retainedPanelCount, screens.count)
    XCTAssertTrue(NSApplication.shared.windows.filter { $0.title == "Defi Overview" }.allSatisfy { !$0.isVisible })
    for sample in 0..<3 {
      let start = ProcessInfo.processInfo.systemUptime
      controller.open(
        snapshot: OverviewSnapshot(monitors: monitors, monitorFrames: frames, windows: windows),
        layout: LayoutSettings(), windowPreviewsEnabled: true
      )
      let panels = NSApplication.shared.windows.filter { $0.title == "Defi Overview" && $0.isVisible }
      for panel in panels { panel.displayIfNeeded() }
      let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
      print("DEFI_E2E overview-open sample=\(sample) monitors=\(screens.count) windows=\(windows.count) ms=\(elapsed)")
      XCTAssertEqual(panels.count, screens.count)
      XCTAssertTrue(panels.allSatisfy { $0.alphaValue == 1 }, "Overview must be visible before captures or a delayed fade")
      XCTAssertEqual(controller.previewCacheCount, 0)
      controller.handleKey(.cancel)
      XCTAssertFalse(controller.isOpen)
      XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
    }
  }

  private func makePlatform() throws -> MacOSPlatform {
    guard ProcessInfo.processInfo.environment["DEFI_E2E"] == "1" else {
      throw XCTSkip("Set DEFI_E2E=1 to run real-desktop tests")
    }
    let platform = onNavigation { MacOSPlatform() }
    guard platform.accessibilityTrusted(prompt: false) else {
      print("DEFI_E2E accessibility=unavailable")
      throw XCTSkip("Accessibility permission unavailable to test process")
    }
    print("DEFI_E2E accessibility=available")
    return platform
  }

  private func testWindows(in snapshot: DesktopSnapshot) -> [Window] {
    let candidates = snapshot.windows
      .filter {
        $0.appID != "com.openai.codex"
          && $0.intrinsicSize == false
      }
    let visibleCandidates = candidates.filter { window in
      snapshot.monitors.contains { monitor in
        let windowRight = window.frame.x + window.frame.width
        let monitorRight = monitor.frame.x + monitor.frame.width
        let intersectionWidth = max(
          min(windowRight, monitorRight) - max(window.frame.x, monitor.frame.x),
          0
        )
        let windowBottom = window.frame.y + window.frame.height
        let monitorBottom = monitor.frame.y + monitor.frame.height
        let intersectionHeight = max(
          min(windowBottom, monitorBottom) - max(window.frame.y, monitor.frame.y),
          0
        )
        return intersectionWidth > 2 && intersectionHeight > 2
      }
    }
    return (visibleCandidates.isEmpty ? candidates : visibleCandidates)
      .sorted {
        if $0.appID == "com.t3tools.t3code" {
          return $1.appID != "com.t3tools.t3code"
        }
        if $1.appID == "com.t3tools.t3code" {
          return false
        }
        return $0.id.rawValue < $1.id.rawValue
      }
  }

  func testFocusedWindowRemainsResolvableWhileParkedOffscreen() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }

    onNavigation { platform.apply([
      FrameAssignment(
        windowID: window.id,
        frame: Rect(x: -10_000, y: -10_000, width: original.width, height: original.height)
      )
    ]) }
    pumpRunLoop(for: 0.2)
    onNavigation { platform.focus(window.id) }
    pumpRunLoop(for: 0.5)

    XCTAssertEqual(platform.snapshot(config: Config()).focusedWindowID, window.id)
  }

  func testKeyboardActivationAfterCompletedFocusSurvivesSnapshot() throws {
    let platform = try makePlatform()
    let initial = platform.snapshot(config: Config())
    let originalApplication = NSWorkspace.shared.frontmostApplication
    guard let window = testWindows(in: initial).first(where: {
      $0.processID != originalApplication?.processIdentifier
    }), let processID = window.processID else {
      throw XCTSkip("A window in another application is required")
    }
    defer { originalApplication?.activate() }

    let result = DesktopValue<NativeFocusResult?>(nil)
    onNavigation { platform.focus(window.id, completion: { value in DispatchQueue.main.async { result.value = value } }) }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while result.value == nil && ProcessInfo.processInfo.systemUptime < deadline {
      pumpRunLoop(for: 0.01)
    }
    XCTAssertEqual(result.value, .completed)
    let suppression = try XCTUnwrap(platform.internalFocusSuppressions[window.id])
    XCTAssertNotNil(suppression.completedAt)

    // Inject the normalized keyboard/activation events; resolve the target via real AX.
    let inputTimestamp = ProcessInfo.processInfo.systemUptime
    platform.userInputTracker.record(timestamp: inputTimestamp, focusIntent: .keyboard)
    platform.userInputTracker.recordApplicationActivation(processID: processID)
    let snapshot = platform.snapshot(config: Config())
    XCTAssertEqual(snapshot.focusedWindowID, window.id)
    XCTAssertTrue(snapshot.nativeFocusChanged)
    XCTAssertTrue(snapshot.nativeFocusIsApplicationActivation)
    XCTAssertNil(platform.internalFocusSuppressions[window.id])
  }

  func testFailedApplicationConnectionIsRenewedWithoutRestart() throws {
    let platform = try makePlatform()
    let initial = platform.snapshot(config: Config())
    guard let window = testWindows(in: initial).first,
      let processID = window.processID
    else { throw XCTSkip("No manageable desktop application") }

    // Simulate a cached connection that cannot serve the application's windows.
    platform.snapshotEngine.applications[processID] = AXUIElementCreateApplication(-1)
    platform.requestWindowTopologyRefresh(processID: processID)
    _ = platform.snapshot(config: Config())
    let renewed = try XCTUnwrap(platform.snapshotEngine.applications[processID])
    var renewedProcessID: pid_t = 0
    XCTAssertEqual(AXUIElementGetPid(renewed, &renewedProcessID), .success)
    XCTAssertEqual(renewedProcessID, processID)

    platform.requestWindowTopologyRefresh(processID: processID)
    let recovered = platform.snapshot(config: Config())
    XCTAssertTrue(recovered.windows.contains { $0.id == window.id })
  }

  func testObsoleteWindowDoesNotDisableSiblingObservation() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
      let processID = window.processID,
      let element = platform.elements[window.id]
    else { throw XCTSkip("No manageable desktop application") }
    let monitor = PlatformEventMonitor(handler: { _, _ in })
    defer { monitor.stop() }
    let obsolete = AXUIElementCreateApplication(-1)
    for _ in 0..<notificationObservationMaxAttempts {
      monitor.refresh(applications: [processID: [obsolete]])
    }
    XCTAssertEqual(
      monitor.notificationObservationFailureCountsValue[.windowTopology]?[processID],
      notificationObservationMaxAttempts
    )
    monitor.refresh(applications: [processID: [obsolete, element]])
    XCTAssertEqual(monitor.observationCoverage.topologyWindows, 1)
    XCTAssertEqual(monitor.observationCoverage.frameWindows, 1)
  }

  func testWindowObservationRecoversAfterTemporaryRegistrationFailure() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
      let processID = window.processID,
      let element = platform.elements[window.id]
    else { throw XCTSkip("No manageable desktop window") }
    var time: TimeInterval = 0
    var frameEvents = 0
    let monitor = PlatformEventMonitor(
      handler: { kind, _ in if kind == .frame { frameEvents += 1 } },
      now: { time },
      addNotification: { observer, element, notification, context in
        if time < 30, notification as String == kAXMovedNotification {
          return .cannotComplete
        }
        return AXObserverAddNotification(observer, element, notification, context)
      }
    )
    defer {
      monitor.stop()
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }
    for _ in 0..<notificationObservationMaxAttempts {
      monitor.refresh(applications: [processID: [element]])
    }
    XCTAssertFalse(monitor.hasReliableFrameCoverage())
    time = 30
    monitor.refresh(applications: [processID: [element]])
    XCTAssertTrue(monitor.hasReliableFrameCoverage())
    XCTAssertTrue(monitor.notificationObservationFailureCountsValue.isEmpty)
    var moved = window.frame
    moved.x += 8
    moved.width -= 16
    onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: moved)]) }
    XCTAssertTrue(pumpRunLoop(until: { frameEvents > 0 }, timeout: 1),
                  "Recovered observer did not receive native frame notifications")
  }

  func testTiledFocusKeepsFloatingWindowAboveIt() throws {
    let platform = try makePlatform()
    let initial = platform.snapshot(config: Config())
    let onscreenWindowIDs = Set(
      copyCGWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])
        .map { WindowID(rawValue: UInt64($0.id)) }
    )
    // Use a regular native window with a local floating rule. AppKit About
    // panels can hide on deactivation and are not a cross-app stacking fixture.
    guard let candidate = testWindows(in: initial).first(where: { window in
      onscreenWindowIDs.contains(window.id) && initial.monitors.contains { monitor in
        targetIntersects(window.frame, monitor: monitor.frame)
          && initial.windows.contains { other in
            other.processID != window.processID && !other.floating
              && onscreenWindowIDs.contains(other.id)
              && targetIntersects(other.frame, monitor: monitor.frame)
          }
      }
    }) else { throw XCTSkip("Two on-screen applications on one monitor required") }
    let config = Config(rules: [Rule(appID: candidate.appID, floating: true)])
    let snapshot = platform.snapshot(config: config)
    guard let floating = snapshot.windows.first(where: {
      $0.floating && onscreenWindowIDs.contains($0.id)
    }),
      let monitor = snapshot.monitors.first(where: {
        $0.frame.x < floating.frame.x + floating.frame.width
          && floating.frame.x < $0.frame.x + $0.frame.width
          && $0.frame.y < floating.frame.y + floating.frame.height
          && floating.frame.y < $0.frame.y + $0.frame.height
      }),
      let tiled = snapshot.windows.first(where: {
        !$0.floating
          && $0.processID != floating.processID
          && onscreenWindowIDs.contains($0.id)
          && monitor.frame.x < $0.frame.x + $0.frame.width
          && $0.frame.x < monitor.frame.x + monitor.frame.width
          && monitor.frame.y < $0.frame.y + $0.frame.height
          && $0.frame.y < monitor.frame.y + monitor.frame.height
      })
    else {
      throw XCTSkip("On-screen floating and tiled windows from different apps required")
    }
    let originalFocusedWindowID = snapshot.focusedWindowID
    defer {
      if let originalFocusedWindowID {
        onNavigation { platform.focus(originalFocusedWindowID) }
        pumpRunLoop(for: 0.3)
      }
    }

    let focusResult = DesktopValue<NativeFocusResult?>(nil)
    onNavigation { platform.focus(floating.id, completion: { value in DispatchQueue.main.async { focusResult.value = value } }) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult.value != nil },
        timeout: 1
      )
    )
    XCTAssertTrue(focusResult.value == .completed || focusResult.value == .completedWithoutMutation)
    guard let tiledElement = platform.elements[tiled.id],
      let processID = tiled.processID,
      let tiledApplication = platform.applications[processID]
    else {
      XCTFail("Tiled test window lost its Accessibility elements")
      return
    }
    focusResult.value = nil
    onNavigation { platform.focus(tiled.id, completion: { value in DispatchQueue.main.async { focusResult.value = value } }) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult.value != nil },
        timeout: 1
      )
    )
    XCTAssertEqual(
      AXUIElementPerformAction(
        tiledElement,
        kAXRaiseAction as CFString
      ),
      .success
    )
    pumpRunLoop(for: 0.1)
    _ = platform.snapshot(config: config)

    focusResult.value = nil
    onNavigation { platform.focus(tiled.id, completion: { value in DispatchQueue.main.async { focusResult.value = value } }) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult.value != nil },
        timeout: 1
      )
    )
    XCTAssertTrue(focusResult.value == .completed || focusResult.value == .completedWithoutMutation)

    // AX success acknowledges the request before WindowServer necessarily
    // publishes the new order. Assert native convergence, not callback timing.
    XCTAssertTrue(pumpRunLoop(until: {
      let order = copyCGWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])
        .map { WindowID(rawValue: UInt64($0.id)) }
      guard let floatingIndex = order.firstIndex(of: floating.id),
        let tiledIndex = order.firstIndex(of: tiled.id) else { return false }
      return floatingIndex < tiledIndex
    }, timeout: 0.5), "the floating window must remain above the focused tiled window")
    var focusedWindow: CFTypeRef?
    XCTAssertEqual(
      AXUIElementCopyAttributeValue(
        tiledApplication,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindow
      ),
      .success
    )
    XCTAssertTrue(focusedWindow.map { CFEqual($0, tiledElement) } == true)
  }

  func testAppliedTargetConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let candidates = testWindows(in: snapshot).filter {
      $0.frame.width > 500
    }
    guard candidates.isEmpty == false else {
      throw XCTSkip("No resizable desktop window")
    }
    var failures: [String] = []
    for window in candidates {
      let original = window.frame
      let target = Rect(
        x: original.x + 40,
        y: original.y,
        width: original.width - 80,
        height: original.height
      )
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: target)]) }
      let converged = pumpRunLoop(
        until: {
          let actual = platform.snapshot(config: Config()).windows
            .first(where: { $0.id == window.id })?.frame
          return abs((actual?.x ?? .infinity) - target.x) <= 2
            && abs((actual?.width ?? .infinity) - target.width) <= 2
        },
        timeout: 0.8
      )
      let actual = platform.snapshot(config: Config()).windows
        .first(where: { $0.id == window.id })?.frame
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
      if converged {
        return
      }
      failures.append(
        "\(window.appID)#\(window.id.rawValue) target=\(target) actual=\(String(describing: actual))"
      )
    }
    XCTFail("No resizable AX window converged: \(failures.joined(separator: "; "))")
  }

  func testUserAdjustedFramesReadFreshGeometryOffNavigationExecutor() async throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first else {
      throw XCTSkip("No manageable desktop window")
    }
    onNavigation {
      platform.latestObservedFrames[window.id] = Rect(x: -20_000, y: -20_000, width: 1, height: 1)
    }
    let frames = await platform.userAdjustedFrames(for: [window.id])
    let actual = try XCTUnwrap(frames[window.id])
    XCTAssertEqual(actual.x, window.frame.x, accuracy: 2)
    XCTAssertEqual(actual.y, window.frame.y, accuracy: 2)
    XCTAssertEqual(actual.width, window.frame.width, accuracy: 2)
    XCTAssertEqual(actual.height, window.frame.height, accuracy: 2)
  }

  func testHorizontalAnimationFrameWritesPositionWithoutSize() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }
    onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
    XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 1))
    let positionWrites = onNavigation { platform.successfulPositionWriteCount }
    let sizeWrites = onNavigation { platform.successfulSizeWriteCount }

    onNavigation { platform.apply([
      FrameAssignment(
        windowID: window.id,
        frame: Rect(
          x: original.x + 8,
          y: original.y,
          width: original.width,
          height: original.height
        )
      )
    ]) }
    pumpRunLoop(for: 0.2)

    XCTAssertGreaterThan(onNavigation { platform.successfulPositionWriteCount }, positionWrites)
    XCTAssertEqual(onNavigation { platform.successfulSizeWriteCount }, sizeWrites)
  }

  func testManagedResizeAnimationConvergesWithAdaptiveSizeWrites() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first else {
      throw XCTSkip("No desktop monitor")
    }
    guard let window = testWindows(in: snapshot).first(where: {
      $0.frame.width >= 500
        && $0.frame.x < monitor.frame.x + monitor.frame.width
        && $0.frame.x + $0.frame.width > monitor.frame.x
    }) else {
      throw XCTSkip("No visible resizable desktop window")
    }
    let original = window.frame
    let target = Rect(
      x: original.x,
      y: original.y,
      width: original.width - 120,
      height: original.height
    )
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }
    XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 1))
    let sizeWrites = onNavigation { platform.successfulSizeWriteCount }

    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      animationDuration: 0.08,
      animationRefreshRateHz: 120,
      animateSizeChanges: true,
      source: "test-resize-animation"
    ) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } },
        timeout: 1
      )
    )

    var actual: Rect?
    let converged = pumpRunLoop(
      until: {
        actual = platform.snapshot(config: Config()).windows
          .first(where: { $0.id == window.id })?.frame
        return abs((actual?.width ?? .infinity) - target.width) <= 2
      },
      timeout: 1
    )
    XCTAssertTrue(
      converged,
      "resize animation did not converge; app=\(window.appID) target=\(target) actual=\(String(describing: actual)) trace=\(onNavigation { platform.frameCoordinatorTrace })"
    )
    XCTAssertEqual(actual?.width ?? 0, target.width, accuracy: 2)
    XCTAssertGreaterThanOrEqual(
      onNavigation { platform.successfulSizeWriteCount } - sizeWrites,
      1
    )
  }

  func testUnhiddenOnePixelStripAnchorConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let candidates = testWindows(in: snapshot).filter {
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
      onNavigation { platform.apply(
        [FrameAssignment(windowID: window.id, frame: original)],
      ) }
      pumpRunLoop(for: 0.4)
    }

    onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: staged)]) }
    pumpRunLoop(for: 0.25)
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: anchored)],
      asynchronousPositionTimeoutSeconds: 0.05,
      source: "test-strip-sliver"
    ) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } },
        timeout: 0.8
      )
    )
    pumpRunLoop(for: 0.1)

    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    XCTAssertEqual(actual?.x ?? 0, anchored.x, accuracy: 2)
    XCTAssertEqual(actual?.y ?? 0, anchored.y, accuracy: 2)
    XCTAssertEqual(onNavigation { platform.hiddenWindowCount }, 0)
  }

  func testReenteringWindowJoinsFirstAnimatedRibbonSample() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let windows = testWindows(in: snapshot)
    guard windows.count >= 2,
      let window = windows.first,
      let neighbor = windows.dropFirst().first,
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
      onNavigation { platform.apply([
        FrameAssignment(windowID: window.id, frame: original),
        FrameAssignment(windowID: neighbor.id, frame: neighborOriginal),
      ]) }
      pumpRunLoop(for: 0.3)
    }

    onNavigation { platform.apply(
      [
        FrameAssignment(windowID: window.id, frame: parked),
        FrameAssignment(windowID: neighbor.id, frame: neighborOriginal),
      ],
      hiddenWindowIDs: [window.id],
    ) }
    pumpRunLoop(for: 0.3)
    onNavigation { platform.apply(
      [
        FrameAssignment(windowID: window.id, frame: target),
        FrameAssignment(windowID: neighbor.id, frame: neighborTarget),
      ],
      animationDuration: 0.05,
      animationRefreshRateHz: 120
    ) }
    pumpRunLoop(for: 0.4)

    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    let performance = onNavigation { platform.frameCoordinatorPerformance }
    let maximumAnimationFrames = completedFrameSpringSamples(
      duration: 0.05,
      refreshRateHz: 120
    ).count + 1
    XCTAssertEqual(actual?.x ?? 0, target.x, accuracy: 2)
    XCTAssertGreaterThanOrEqual(performance.animationFrames, 2)
    XCTAssertLessThanOrEqual(performance.animationFrames, maximumAnimationFrames)
  }

  func testPostAnimationCommitLagDoesNotTriggerUnanimatedCorrection() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first else {
      throw XCTSkip("No desktop monitor")
    }
    let candidates = testWindows(in: snapshot).filter { window in
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
    guard !candidates.isEmpty else {
      throw XCTSkip("No manageable desktop window")
    }

    let competingPlatform = try makePlatform()
    _ = competingPlatform.snapshot(config: Config())
    var selected:
      (
        window: Window,
        original: Rect,
        target: Rect,
        expectation: FrameCommitExpectation
      )?
    var failedPreconditions: [String] = []
    for window in candidates.sorted(by: { $0.frame.width > $1.frame.width }) {
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
      onNavigation { platform.apply(
        [FrameAssignment(windowID: window.id, frame: target)],
        animationDuration: 0.05,
        animationRefreshRateHz: 120,
        source: "test-animation"
      ) }
      guard pumpRunLoop(
        until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } },
        timeout: 0.5
      ) else {
        failedPreconditions.append("\(window.appID):animation")
        onNavigation { competingPlatform.apply([
          FrameAssignment(windowID: window.id, frame: original)
        ]) }
        pumpRunLoop(for: 0.15)
        onNavigation { platform.acceptObservedFrame(original, for: window.id) }
        continue
      }

      var competingWriteConverged = false
      var lastCompetingFrame: Rect?
      for _ in 0..<10 where !competingWriteConverged {
        onNavigation { competingPlatform.apply([
          FrameAssignment(windowID: window.id, frame: intermediate)
        ]) }
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
      if competingWriteConverged,
        let expectation = platform.frameCommitExpectations[window.id]
      {
        selected = (window, original, target, expectation)
        break
      }
      failedPreconditions.append(
        "\(window.appID):\(String(describing: lastCompetingFrame))"
      )
      onNavigation { competingPlatform.apply([
        FrameAssignment(windowID: window.id, frame: original)
      ]) }
      pumpRunLoop(for: 0.15)
      onNavigation { platform.acceptObservedFrame(original, for: window.id) }
    }
    guard let selected else {
      XCTFail(
        "test must force a delayed intermediate commit before checking quarantine; attempts=\(failedPreconditions)"
      )
      return
    }
    let window = selected.window
    let original = selected.original
    let target = selected.target
    let expectation = selected.expectation
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }
    let observationStartedAt = ProcessInfo.processInfo.systemUptime
    platform.frameCommitExpectations[window.id] = FrameCommitExpectation(
      from: expectation.from,
      target: expectation.target,
      issuedAt: observationStartedAt,
      deadline: observationStartedAt
        + frameCommitQuarantineDuration(
          animationDuration: 0.05,
          initialFrameSettlement: false
        ),
      observedAt: expectation.observedAt
    )

    let writesBeforeDesktopSync = onNavigation { platform.successfulPositionWriteCount }
    onNavigation { platform.requestFrameRefresh(for: window.id) }
    let delayedSnapshot = platform.snapshot(config: Config())
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      source: "desktop-sync"
    ) }
    pumpRunLoop(for: 0.08)

    XCTAssertTrue(delayedSnapshot.targetMismatches.isEmpty)
    XCTAssertGreaterThan(onNavigation { platform.frameCommitPerformance }.deferred, 0)
    XCTAssertEqual(
      onNavigation { platform.successfulPositionWriteCount },
      writesBeforeDesktopSync
    )
    XCTAssertFalse(
      onNavigation { platform.frameCoordinatorTrace }.contains("source=desktop-sync")
    )
  }

  func testNativeFocusEmitsPlatformEvent() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard
      let window = testWindows(in: snapshot).first(
        where: { $0.id != snapshot.focusedWindowID }
      )
    else {
      throw XCTSkip("Need a non-focused manageable window")
    }
    let eventCount = DesktopValue(0)
    onNavigation { platform.startObserving {
      DispatchQueue.main.async { eventCount.value += 1 }
    } }

    onNavigation { platform.focus(window.id) }
    pumpRunLoop(for: 0.6)

    XCTAssertGreaterThan(eventCount.value, 0)
    XCTAssertEqual(platform.snapshot(config: Config()).focusedWindowID, window.id)
  }

  func testRapidNativeFocusKeepsLatestIntent() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let windows = Array(testWindows(in: snapshot).prefix(2))
    guard windows.count == 2 else {
      throw XCTSkip("Need two manageable windows")
    }
    let originalFocusedWindowID = snapshot.focusedWindowID
    defer {
      if let originalFocusedWindowID {
        onNavigation { platform.focus(originalFocusedWindowID) }
        pumpRunLoop(for: 0.5)
      }
    }

    for windowID in [windows[0].id, windows[1].id, windows[0].id, windows[1].id] {
      onNavigation { platform.focus(windowID) }
    }

    XCTAssertTrue(
      pumpRunLoop(
        until: {
          !onNavigation { platform.hasPendingFocusWrite }
            && platform.snapshot(config: Config()).focusedWindowID
              == windows[1].id
        },
        timeout: 2
      ),
      "stale focus recovery overrode latest rapid focus intent"
    )
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

  func testSwiftUIMenuKeepsWorkspaceSelectionAndCommandRouting() throws {
    _ = try makePlatform()
    let commands = DesktopValue<[String]>([])
    let state = MenuBarState(accessibilityTrusted: { true })
    state.update(
      activeWorkspace: "dev",
      workspaces: [MenuWorkspace(id: "dev", label: "Dev"), MenuWorkspace(id: "web", label: "Web")]
    )
    let menu = NSHostingMenu(rootView: MenuBarContent(
      state: state,
      commandHandler: { commands.value.append($0) }
    ))
    menu.update()
    XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
      "Workspaces", "Launch at Login", "Configuration Guide…", "About Defi", "Quit Defi",
    ])
    let workspaces = try XCTUnwrap(menu.items.first { $0.title == "Workspaces" }?.submenu)
    workspaces.update()
    XCTAssertEqual(workspaces.items.first { $0.title == "Dev" }?.state, .on)
    let workspaceIndex = try XCTUnwrap(workspaces.items.firstIndex { $0.title == "Web" })
    workspaces.performActionForItem(at: workspaceIndex)
    pumpRunLoop(for: 0.05)
    let quitIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Quit Defi" })
    menu.performActionForItem(at: quitIndex)
    pumpRunLoop(for: 0.05)
    XCTAssertEqual(commands.value, ["workspace web", "quit"])
  }

  func testCheatsheetFitsContentAndNeverRestoresAClosedPanelOrTakesFocus() throws {
    _ = try makePlatform()
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let controller = CheatsheetController(config: Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"], defaultKeyModifier: "hyper"
    ))
    defer { controller.close() }
    controller.show(on: nil)
    let first = try XCTUnwrap(NSApplication.shared.windows.first {
      $0.title == "Defi keyboard shortcuts" && $0.isVisible
    })
    XCTAssertFalse(first.canBecomeKey)
    XCTAssertFalse(first.canBecomeMain)
    XCTAssertFalse(first.styleMask.contains(.titled))
    controller.close()
    controller.show(on: nil)
    pumpRunLoop(for: 0.3)
    XCTAssertFalse(first.isVisible)
    let current = try XCTUnwrap(NSApplication.shared.windows.first {
      $0.title == "Defi keyboard shortcuts" && $0.isVisible
    })
    XCTAssertEqual(current.alphaValue, 1, accuracy: 0.01)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
    let screen = try XCTUnwrap(current.screen)
    XCTAssertLessThan(current.frame.height, screen.visibleFrame.height - 48)
    XCTAssertLessThan(current.frame.width, screen.visibleFrame.width - 48)
    XCTAssertGreaterThan(current.frame.width, 600)
    let fittedFrame = current.frame
    pumpRunLoop(for: 0.2)
    XCTAssertEqual(current.frame, fittedFrame)
    XCTAssertEqual(current.frame.midX, screen.visibleFrame.midX, accuracy: 1)
    XCTAssertEqual(current.frame.midY, screen.visibleFrame.midY, accuracy: 1)
    controller.close()
    pumpRunLoop(for: 0.2)
    XCTAssertFalse(current.isVisible)
  }

  func testCheatsheetReceivesHeldModifierAndCapturesItsShortcut() throws {
    _ = try makePlatform()
    let inputs = DesktopValue<[CheatsheetInput]>([])
    let commands = DesktopValue<[String]>([])
    let manager = onNavigation { HotKeyManager(
      config: Config(
        modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
        defaultKeyModifier: "hyper",
        keys: ["hyper-slash": "toggle-cheatsheet"]
      ),
      cheatsheetHandler: { value in DispatchQueue.main.async { inputs.value.append(value) } }
    ) { value in DispatchQueue.main.async { commands.value.append(value.command) } } }
    try onNavigation { try manager.start() }
    defer { onNavigation { manager.stop() } }
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    let modifier = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 58, keyDown: true
    ))
    modifier.type = .flagsChanged
    modifier.flags = [.maskAlternate, .maskCommand, .maskControl]
    defer {
      modifier.flags = []
      modifier.post(tap: .cghidEventTap)
      pumpRunLoop(for: 0.1)
    }
    modifier.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: {
      inputs.value.contains(.modifiersChanged(matches: true, released: false))
    }, timeout: 1))
    pumpRunLoop(for: 0.65)
    XCTAssertEqual(inputs.value.last, .modifiersChanged(matches: true, released: false))
    let shortcut = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 44, keyDown: true
    ))
    shortcut.flags = modifier.flags
    shortcut.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { commands.value == ["toggle-cheatsheet"] }, timeout: 1))
    shortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    shortcut.post(tap: .cghidEventTap)
    pumpRunLoop(for: 0.1)
    XCTAssertEqual(commands.value, ["toggle-cheatsheet"])
    onNavigation { manager.setCheatsheetVisible(true) }
    let escape = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 53, keyDown: true
    ))
    escape.flags = modifier.flags
    escape.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { inputs.value.last == .dismiss }, timeout: 1))
  }

  func testHotKeysAreCapturedWhileMainActorIsBlocked() throws {
    _ = try makePlatform()
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      keys: ["hyper-left": "focus-column left"]
    )
    let tracker = UserInputTracker()
    let received = Mutex<[HotKeyInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      userInputTracker: tracker
    ) { invocation in
      received.withLock { $0.append(invocation) }
    } }
    try onNavigation { try manager.start() }
    defer { onNavigation { manager.stop() } }
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
        if let modifierRelease = CGEvent(
          keyboardEventSource: source,
          virtualKey: 59,
          keyDown: false
        ) {
          modifierRelease.type = .flagsChanged
          modifierRelease.flags = []
          modifierRelease.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }

    Thread.sleep(forTimeInterval: 0.35)
    XCTAssertEqual(
      onNavigation { manager.capturedKeyCount },
      eventCount,
      "event tap must keep capturing while AX/layout blocks the main actor"
    )
    let invocations = received.withLock { $0 }
    XCTAssertEqual(invocations.count, eventCount,
      "commands must be delivered before the main actor resumes")
    XCTAssertTrue(invocations.allSatisfy { $0.command == "focus-column left" })
    XCTAssertTrue(invocations.allSatisfy { $0.timestamp > 0 })
    XCTAssertEqual(tracker.latestEventTimestamp, invocations.last?.timestamp)
    XCTAssertEqual(onNavigation { manager.tapReenableCount }, 0)
  }

  func testWorkspaceMonitorShortcutsAreCaptured() throws {
    _ = try makePlatform()
    let commands = DesktopValue<[String]>([])
    let manager = onNavigation { HotKeyManager(config: Config()) { value in DispatchQueue.main.async { commands.value.append(value.command) } } }
    try onNavigation { try manager.start() }
    defer { onNavigation { manager.stop() } }
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    for (index, direction) in ["left", "right", "down", "up"].enumerated() {
      let event = try XCTUnwrap(CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(123 + index), keyDown: true
      ))
      event.flags = [.maskControl, .maskAlternate, .maskShift]
      event.post(tap: .cghidEventTap)
      XCTAssertTrue(pumpRunLoop(until: { commands.value.count == index + 1 }, timeout: 1))
      event.type = .keyUp
      event.flags = []
      event.post(tap: .cghidEventTap)
      XCTAssertEqual(commands.value.last, "move-workspace-to-monitor \(direction)")
    }
    XCTAssertEqual(onNavigation { manager.capturedKeyCount }, 4)
  }

  func testAliasedOverrideWinsOverFixedMonitorShortcut() throws {
    _ = try makePlatform()
    let commands = DesktopValue<[String]>([])
    let manager = onNavigation { HotKeyManager(config: Config(
      modifierCombinations: ["combo": "Ctrl + Alt + Shift"],
      keys: ["combo-left": "focus-column first"]
    )) { value in DispatchQueue.main.async { commands.value.append(value.command) } } }
    try onNavigation { try manager.start() }
    defer { onNavigation { manager.stop() } }
    let event = try XCTUnwrap(CGEvent(
      keyboardEventSource: nil, virtualKey: 123, keyDown: true
    ))
    event.flags = [.maskControl, .maskAlternate, .maskShift]
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { !commands.value.isEmpty }, timeout: 1))
    event.type = .keyUp
    event.flags = []
    event.post(tap: .cghidEventTap)
    XCTAssertEqual(commands.value, ["focus-column first"])
    XCTAssertEqual(onNavigation { manager.capturedKeyCount }, 1)
  }

  func testConfiguredHyperArrowNavigatesOverview() throws {
    _ = try makePlatform()
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      keys: ["hyper-left": "focus-column left"]
    )
    let commands = DesktopValue<[HotKeyInvocation]>([])
    let overviewActions = DesktopValue<[OverviewKeyAction]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      overviewHandler: { value in DispatchQueue.main.async { overviewActions.value.append(value) } }
    ) { value in DispatchQueue.main.async { commands.value.append(value) } } }
    try onNavigation { try manager.start() }
    onNavigation { manager.setOverviewModeEnabled(true) }

    DispatchQueue.global(qos: .userInteractive).async {
      Thread.sleep(forTimeInterval: 0.05)
      guard
        let source = CGEventSource(stateID: .hidSystemState),
        let event = CGEvent(
          keyboardEventSource: source,
          virtualKey: 123,
          keyDown: true
        )
      else { return }
      event.flags = [.maskAlternate, .maskCommand, .maskControl]
      event.post(tap: .cghidEventTap)
    }

    XCTAssertTrue(
      pumpRunLoop(until: { overviewActions.value == [.left] }, timeout: 1)
    )
    XCTAssertEqual(commands.value, [])
    XCTAssertEqual(onNavigation { manager.capturedKeyCount }, 1)
  }

  func testScrollWheelAdvancesUserInputTracker() throws {
    _ = try makePlatform()
    let tracker = UserInputTracker()
    let manager = onNavigation { HotKeyManager(
      config: Config(),
      userInputTracker: tracker
    ) { _ in } }
    try onNavigation { try manager.start() }
    let previousTimestamp = tracker.latestEventTimestamp

    guard let source = CGEventSource(stateID: .hidSystemState),
      let scroll = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 1,
        wheel1: 1,
        wheel2: 0,
        wheel3: 0
      )
    else {
      XCTFail("Could not create scroll-wheel event")
      return
    }
    scroll.post(tap: .cghidEventTap)

    XCTAssertTrue(
      pumpRunLoop(
        until: { tracker.latestEventTimestamp > previousTimestamp },
        timeout: 0.5
      ),
      "scroll-wheel input did not reach UserInputTracker"
    )
  }

  func testPointerTransitionsUseWindowUnderPointerAndWarpDoesNotLoop() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first,
      let focusedWindowID = snapshot.focusedWindowID,
      let focusedWindow = snapshot.windows.first(where: {
        $0.id == focusedWindowID
      }),
      let originalCursorLocation = CGEvent(source: nil)?.location
    else {
      throw XCTSkip("Focused on-screen managed window required")
    }
    defer {
      CGWarpMouseCursorPosition(originalCursorLocation)
    }

    let config = Config(
      input: InputConfig(
        focusFollowsMouse: true,
        mouseFollowsFocus: true
      )
    )
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      pointerMotionTracker: platform.pointerMotionTracker,
      pointerMotionHandler: { invocation in
        DispatchQueue.main.async { received.value.append(invocation) }
      }
    ) { _ in } }
    try onNavigation { try manager.start() }

    let focusedCenter = CGPoint(
      x: focusedWindow.frame.x + focusedWindow.frame.width / 2,
      y: focusedWindow.frame.y + min(20, focusedWindow.frame.height / 2)
    )
    XCTAssertEqual(CGWarpMouseCursorPosition(focusedCenter), .success)
    guard
      let source = CGEventSource(stateID: .hidSystemState),
      let movement = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: focusedCenter,
        mouseButton: .left
      )
    else {
      XCTFail("Could not create mouse movement event")
      return
    }
    movement.post(tap: .cghidEventTap)

    XCTAssertTrue(
      pumpRunLoop(until: { !received.value.isEmpty }, timeout: 0.5),
      "mouse movement did not reach event tap"
    )
    pumpRunLoop(for: 0.1)
    let resolvedPointerWindowID = received.value.last.flatMap {
      $0.windowID ?? platform.managedWindowID(at: $0.location)
    }
    XCTAssertEqual(resolvedPointerWindowID, focusedWindowID)
    guard let currentCursorLocation = CGEvent(source: nil)?.location,
      let otherWindow = snapshot.windows.first(where: { window in
        window.id != focusedWindowID
          && window.frame.x + window.frame.width / 2 >= monitor.frame.x
          && window.frame.y + window.frame.height / 2 >= monitor.frame.y
          && window.frame.x + window.frame.width / 2
            <= monitor.frame.x + monitor.frame.width
          && window.frame.y + window.frame.height / 2
            <= monitor.frame.y + monitor.frame.height
          && cursorWarpDestination(
            frame: window.frame,
            currentLocation: currentCursorLocation
          ) != nil
      })
    else {
      throw XCTSkip("Second on-screen managed window required")
    }
    let transitionsBeforeWarp = onNavigation { manager.pointerTransitionCount }

    onNavigation { platform.warpCursor(
      to: otherWindow.id,
      unlessUserInputAfter: .greatestFiniteMagnitude
    ) }
    pumpRunLoop(for: 0.2)

    XCTAssertEqual(onNavigation { platform.cursorWarpPerformance }.applied, 1)
    XCTAssertEqual(
      onNavigation { manager.pointerTransitionCount },
      transitionsBeforeWarp,
      "programmatic cursor warp must not emit pointer transitions"
    )
  }

  func testFrameCommitWarpsCursorForAcceptedNativeFocus() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first,
      let window = testWindows(in: snapshot).first,
      let originalCursorLocation = CGEvent(source: nil)?.location
    else {
      throw XCTSkip("Managed desktop window required")
    }
    let originalFrame = window.frame
    let targetFrame = Rect(
      x: originalFrame.x + 10,
      y: originalFrame.y,
      width: originalFrame.width,
      height: originalFrame.height
    )
    let outsideCandidates = [
      CGPoint(x: monitor.frame.x + 1, y: monitor.frame.y + 1),
      CGPoint(
        x: monitor.frame.x + monitor.frame.width - 1,
        y: monitor.frame.y + 1
      ),
      CGPoint(
        x: monitor.frame.x + 1,
        y: monitor.frame.y + monitor.frame.height - 1
      ),
      CGPoint(
        x: monitor.frame.x + monitor.frame.width - 1,
        y: monitor.frame.y + monitor.frame.height - 1
      ),
    ]
    guard let outside = outsideCandidates.first(where: {
      cursorWarpDestination(frame: targetFrame, currentLocation: $0) != nil
    }) else {
      throw XCTSkip("Window covers the usable monitor")
    }
    defer {
      onNavigation { platform.apply([
        FrameAssignment(windowID: window.id, frame: originalFrame)
      ]) }
      CGWarpMouseCursorPosition(originalCursorLocation)
      pumpRunLoop(for: 0.3)
    }

    XCTAssertEqual(CGWarpMouseCursorPosition(outside), .success)
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: targetFrame)],
      cursorWarpWindowIDAfterCommit: window.id,
      cursorWarpInputTimestampAfterCommit: .greatestFiniteMagnitude,
      cursorWarpIsCurrentAfterCommit: { true }
    ) }

    XCTAssertTrue(
      pumpRunLoop(
        until: { onNavigation { platform.cursorWarpPerformance }.applied == 1 },
        timeout: 1
      ),
      "cursor did not warp after the target frame committed; performance=\(onNavigation { platform.cursorWarpPerformance }) trace=\(onNavigation { platform.frameCoordinatorTrace })"
    )
  }

  func testPointerTrackingStartsWhenHotKeyParsingFails() throws {
    _ = try makePlatform()
    let config = Config(
      input: InputConfig(focusFollowsMouse: true),
      keys: ["unknown-no-such-key": "focus-column left"]
    )
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      pointerMotionHandler: { invocation in
        DispatchQueue.main.async { received.value.append(invocation) }
      }
    ) { _ in } }
    XCTAssertNotNil(onNavigation { manager.bindingError })
    XCTAssertEqual(onNavigation { manager.bindingCount }, 0)
    try onNavigation { try manager.start() }

    guard let location = CGEvent(source: nil)?.location,
      let source = CGEventSource(stateID: .hidSystemState),
      let movement = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: location,
        mouseButton: .left
      )
    else {
      XCTFail("Could not create mouse movement event")
      return
    }
    movement.post(tap: .cghidEventTap)

    XCTAssertTrue(
      pumpRunLoop(until: { !received.value.isEmpty }, timeout: 0.5),
      "pointer movement did not survive invalid hotkey parsing"
    )
  }

  func testCornerParkingConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
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
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }

    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      hiddenWindowIDs: [window.id],
    ) }
    let element = try XCTUnwrap(platform.elements[window.id])
    var actual: Rect?
    XCTAssertTrue(pumpRunLoop(until: {
      actual = platform.frame(of: element)
      return actual.map { abs($0.x - target.x) <= 2 && abs($0.y - target.y) <= 2 } == true
    }, timeout: 1.5), "the native frame must converge, independently of the snapshot refresh budget")
    XCTAssertFalse(onNavigation { platform.hasPendingAnimatedFrameWrites })
    XCTAssertEqual(actual?.x ?? 0, target.x, accuracy: 2)
    XCTAssertEqual(actual?.y ?? 0, target.y, accuracy: 2)
    XCTAssertEqual(onNavigation { platform.hiddenWindowCount }, 1)
  }

  func testIsolatedDisplayArrangementPreservesPartialRibbonAndRestores() throws {
    let platform = try makePlatform()
    let initialFrames = DisplayArrangementController.currentFrames()
    guard initialFrames.count > 1 else { throw XCTSkip("Requires two connected displays") }
    let initial = platform.snapshot(config: Config())
    let window = try XCTUnwrap(testWindows(in: initial).first)
    let initialPointer = CGEvent(source: nil)?.location
    let controller = DisplayArrangementController()
    defer {
      controller.restore()
      XCTAssertEqual(DisplayArrangementController.apply(initialFrames, scope: .forSession), .success)
      pumpRunLoop(for: 0.3)
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      if let initialPointer { CGWarpMouseCursorPosition(initialPointer) }
      XCTAssertEqual(DisplayArrangementController.currentFrames(), initialFrames)
    }
    // Exercise the transformed arrangement even when the user's displays are vertical.
    let primary = MonitorID(rawValue: UInt64(CGMainDisplayID()))
    var deskFrames = initialFrames
    var nextX = try XCTUnwrap(initialFrames[primary]).width
    for id in initialFrames.keys.sorted(by: { $0.rawValue < $1.rawValue }) where id != primary {
      deskFrames[id]?.x = nextX
      deskFrames[id]?.y = 0
      nextX += initialFrames[id]!.width
    }
    XCTAssertEqual(DisplayArrangementController.apply(deskFrames), .success)
    pumpRunLoop(for: 0.3)
    XCTAssertEqual(DisplayArrangementController.currentFrames(), deskFrames)
    _ = controller.reconcile()
    XCTAssertEqual(controller.status, "isolated")
    pumpRunLoop(for: 0.3)
    let monitors = platform.discoverMonitors()
    XCTAssertEqual(controller.deskFrames, deskFrames)
    let technical = DisplayArrangementController.currentFrames()
    var crossings = 0
    for frame in technical.values {
      let edges: [(Double, Double, Double, Double)] = [
        (frame.x, frame.y + frame.height / 2, -5, 0),
        (frame.x + frame.width - 1, frame.y + frame.height / 2, 5, 0),
        (frame.x + frame.width / 2, frame.y, 0, -5),
        (frame.x + frame.width / 2, frame.y + frame.height - 1, 0, 5),
      ]
      for (x, y, dx, dy) in edges {
        guard let expected = displayPointerDestination(
          x: x, y: y, deltaX: dx, deltaY: dy, technical: technical, desk: deskFrames
        ) else { continue }
        let event = try XCTUnwrap(CGEvent(
          mouseEventSource: nil, mouseType: .mouseMoved,
          mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        XCTAssertTrue(controller.pointerRouter.route(event))
        let observed = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(observed.x, expected.x, accuracy: 2)
        XCTAssertEqual(observed.y, expected.y, accuracy: 2)
        crossings += 1
      }
    }
    XCTAssertGreaterThan(crossings, 0)
    for monitor in monitors {
      let frame = monitor.frame
      let target = Rect(
        x: frame.x + frame.width * 0.8, y: frame.y,
        width: window.frame.width, height: min(window.frame.height, frame.height)
      )
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: target)]) }
      pumpRunLoop(for: 0.2)
      let element = try XCTUnwrap(platform.elements[window.id])
      let actual = try XCTUnwrap(platform.frame(of: element))
      XCTAssertEqual(actual.x, target.x, accuracy: 2)
      XCTAssertEqual(actual.width, target.width, accuracy: 2)
      let rect = CGRect(x: actual.x, y: actual.y, width: actual.width, height: actual.height)
      let visible = rect.intersection(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
      XCTAssertGreaterThan(visible.width, 100, "The neighboring column's preview disappeared")
      for other in monitors where other.id != monitor.id {
        let neighbor = other.physicalFrame
        let overlap = rect.intersection(CGRect(x: neighbor.x, y: neighbor.y, width: neighbor.width, height: neighbor.height))
        XCTAssertTrue(overlap.isNull || overlap.isEmpty, "Partial ribbon leaked onto another display")
      }
    }
    XCTAssertEqual(controller.restore(), deskFrames)
  }

  func testMonitorTransferFillsDestinationHeight() throws {
    let platform = try makePlatform()
    // Match the running daemon's geometry; stopping it now restores the desk.
    let arrangement = DisplayArrangementController()
    defer { arrangement.restore() }
    if arrangement.reconcile() { pumpRunLoop(for: 0.3) }
    let snapshot = platform.snapshot(config: Config())
    let monitors = snapshot.monitors.sorted { $0.frame.height < $1.frame.height }
    guard let smaller = monitors.first, let taller = monitors.last,
      taller.frame.height - smaller.frame.height > 10
    else { throw XCTSkip("Requires two monitors with different usable heights") }
    let window = try XCTUnwrap(testWindows(in: snapshot).first)
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }

    for invalidatesDisplayState in [false, true] {
      for monitor in [smaller, taller, smaller] {
        if invalidatesDisplayState { onNavigation { platform.invalidateFrameStateForDisplayChange() } }
        let target = Rect(
          x: monitor.frame.x, y: monitor.frame.y,
          width: min(window.frame.width, monitor.frame.width),
          height: monitor.frame.height
        )
        onNavigation { platform.apply(
          [FrameAssignment(windowID: window.id, frame: target)],
          animationDuration: invalidatesDisplayState ? 0 : 0.035,
          animateSizeChanges: !invalidatesDisplayState,
          source: "test-monitor-height"
        ) }
        XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 2))
        let element = try XCTUnwrap(platform.elements[window.id])
        var actual: Rect?
        XCTAssertTrue(pumpRunLoop(until: {
          actual = platform.frame(of: element)
          return actual.map { abs($0.height - target.height) <= 2 && abs($0.y - target.y) <= 2 } == true
        }, timeout: 1), "monitor=\(monitor.id) invalidated=\(invalidatesDisplayState) target=\(target) actual=\(String(describing: actual)) trace=\(onNavigation { platform.frameCoordinatorTrace })")
      }
    }
  }

  func testDisplayCrossingDeliversDestinationMotionWithoutAnotherEvent() throws {
    _ = try makePlatform()
    let original = DisplayArrangementController.currentFrames()
    guard original.count == 2 else { throw XCTSkip("Requires two monitors") }
    let cursor = try XCTUnwrap(CGEvent(source: nil)?.location)
    let primary = MonitorID(rawValue: UInt64(CGMainDisplayID()))
    let other = try XCTUnwrap(original.keys.first { $0 != primary })
    var desk = original
    let sourceFrame = try XCTUnwrap(original[primary])
    desk[other]?.x = sourceFrame.x + sourceFrame.width
    desk[other]?.y = sourceFrame.y
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    func makeController() -> DisplayArrangementController {
      DisplayArrangementController(
        readFrames: DisplayArrangementController.currentFrames,
        applyFrames: DisplayArrangementController.apply, primaryDisplay: { primary },
        stateURL: directory.appending(path: "arrangement.json"), sessionID: "desktop-test"
      )
    }
    var controller = makeController()
    defer {
      controller.restore()
      XCTAssertEqual(DisplayArrangementController.apply(original, scope: .forSession), .success)
      CGWarpMouseCursorPosition(cursor)
    }
    XCTAssertEqual(DisplayArrangementController.apply(desk), .success)
    pumpRunLoop(for: 0.3)
    _ = controller.reconcile()
    let technical = DisplayArrangementController.currentFrames()
    controller.restore()
    XCTAssertEqual(DisplayArrangementController.apply(technical), .success)
    controller = makeController()
    _ = controller.reconcile()
    XCTAssertEqual(controller.deskFrames, desk)
    let source = try XCTUnwrap(technical[primary])
    let x = source.x + source.width - 1
    let y = source.y + min(source.height, original[other]!.height) / 2
    let destination = try XCTUnwrap(displayPointerDestination(
      x: x, y: y, deltaX: 5, deltaY: 0, technical: technical, desk: desk
    ))
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let pointerRouter = controller.pointerRouter
    let manager = onNavigation { HotKeyManager(
      config: Config(input: InputConfig(focusFollowsMouse: true)),
      pointerMotionHandler: { invocation in
        DispatchQueue.main.async { received.value.append(invocation) }
      },
      displayPointerRouter: pointerRouter
    ) { _ in } }
    try onNavigation { try manager.start() }
    defer { onNavigation { manager.stop() } }
    let event = try XCTUnwrap(CGEvent(
      mouseEventSource: CGEventSource(stateID: .hidSystemState),
      mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left
    ))
    event.setDoubleValueField(.mouseEventDeltaX, value: 5)
    let startedAt = ProcessInfo.processInfo.systemUptime
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: {
      received.value.contains { $0.location == CGPoint(x: destination.x, y: destination.y) && $0.windowID == nil }
    }, timeout: 0.5), "First crossing event did not deliver the destination: \(received.value)")
    print("DEFI_E2E pointer-crossing-delivery-ms=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)")
    XCTAssertEqual(controller.pointerRouter.warpCount, 1)
  }

  func testParkingAvoidsEveryOtherConnectedMonitor() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard snapshot.monitors.count > 1,
      let window = testWindows(in: snapshot).first
    else { throw XCTSkip("Requires two connected monitors and a manageable window") }
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }
    for monitor in snapshot.monitors {
      for side in [ParkingSide.left, .right] {
        let target = resolveParkingPlacement(
          for: window.frame, ownerFrame: monitor.physicalFrame,
          parkingFrame: monitor.frame,
          allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
          preferredSide: side
        ).frame
        onNavigation { platform.apply(
          [FrameAssignment(windowID: window.id, frame: target)],
          hiddenWindowIDs: [window.id]
        ) }
        XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } }, timeout: 2))
        pumpRunLoop(for: 0.2)
        let element = try XCTUnwrap(platform.elements[window.id])
        let actual = try XCTUnwrap(platform.frame(of: element))
        XCTAssertEqual(actual.x, target.x, accuracy: 2, onNavigation { platform.frameCoordinatorTrace })
        XCTAssertEqual(actual.y, target.y, accuracy: 2)
        let rect = CGRect(x: actual.x, y: actual.y, width: actual.width, height: actual.height)
        for other in snapshot.monitors where other.id != monitor.id {
          let frame = other.physicalFrame
          let intersection = rect.intersection(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
          XCTAssertTrue(intersection.isNull || intersection.width <= 1 || intersection.height <= 1,
                        "Parking leaked into \(other.id): \(intersection)")
        }
      }
    }
  }

  func testCornerParkingRepairsDelayedRollback() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
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
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: parked)],
      hiddenWindowIDs: [window.id],
    ) }
    pumpRunLoop(for: 0.2)

    // Simulate one delayed application write, without starting a second
    // settlement coordinator that would keep restoring the competing target.
    let element = try XCTUnwrap(platform.elements[window.id])
    var rollback = CGPoint(x: window.frame.x + 40, y: window.frame.y)
    let rollbackValue = try XCTUnwrap(AXValueCreate(.cgPoint, &rollback))
    XCTAssertEqual(AXUIElementSetAttributeValue(
      element, kAXPositionAttribute as CFString, rollbackValue
    ), .success)

    var repaired: Rect?
    XCTAssertTrue(
      pumpRunLoop(
        until: {
          guard onNavigation({ platform.parkingPerformance }).repairs >= 1 else { return false }
          repaired = platform.frame(of: element)
          return repaired.map { abs($0.x - parked.x) <= 2 && abs($0.y - parked.y) <= 2 } == true
        },
        timeout: 1.6
      ),
      "parking repair did not converge before its 1.4 second backstop"
    )
    XCTAssertEqual(repaired?.x ?? 0, parked.x, accuracy: 2)
    XCTAssertEqual(repaired?.y ?? 0, parked.y, accuracy: 2)
    XCTAssertGreaterThanOrEqual(
      onNavigation { platform.parkingPerformance }.repairs,
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

/// Desktop tests own AppKit on MainActor; native commands enter the same serial
/// executor as the installed daemon. Never wrap a synchronous desktop snapshot.
@discardableResult
private func onNavigation<T>(_ body: @NavigationActor () throws -> T) rethrows -> T {
  try NavigationActor.shared.queue.sync {
    try NavigationActor.assumeIsolated(body)
  }
}

@MainActor
private final class DesktopValue<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}
