import AppKit
import ApplicationServices
import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import XCTest
import class SwiftUI.NSHostingMenu

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

  func testTiledFocusKeepsFloatingWindowAboveIt() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let onscreenWindowIDs = Set(
      copyCGWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])
        .map { WindowID(rawValue: UInt64($0.id)) }
    )
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
        platform.focus(originalFocusedWindowID)
        pumpRunLoop(for: 0.3)
      }
    }

    var focusResult: NativeFocusResult?
    platform.focus(floating.id, completion: { focusResult = $0 })
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult != nil },
        timeout: 1
      )
    )
    XCTAssertTrue(focusResult == .completed || focusResult == .completedWithoutMutation)
    guard let tiledElement = platform.elements[tiled.id],
      let processID = tiled.processID,
      let tiledApplication = platform.applications[processID]
    else {
      XCTFail("Tiled test window lost its Accessibility elements")
      return
    }
    focusResult = nil
    platform.focus(tiled.id, completion: { focusResult = $0 })
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult != nil },
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
    _ = platform.snapshot(config: Config())

    focusResult = nil
    platform.focus(tiled.id, completion: { focusResult = $0 })
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult != nil },
        timeout: 1
      )
    )
    XCTAssertTrue(focusResult == .completed || focusResult == .completedWithoutMutation)

    let windowOrder = copyCGWindows(
      options: [.optionOnScreenOnly, .excludeDesktopElements]
    ).map { WindowID(rawValue: UInt64($0.id)) }
    guard let floatingIndex = windowOrder.firstIndex(of: floating.id),
      let tiledIndex = windowOrder.firstIndex(of: tiled.id)
    else {
      XCTFail("Focused test windows disappeared from WindowServer order")
      return
    }
    XCTAssertLessThan(floatingIndex, tiledIndex)
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
      platform.apply([FrameAssignment(windowID: window.id, frame: target)])
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
      platform.apply([FrameAssignment(windowID: window.id, frame: original)])
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

  func testHorizontalAnimationFrameWritesPositionWithoutSize() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first else {
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
      platform.apply([FrameAssignment(windowID: window.id, frame: original)])
      pumpRunLoop(for: 0.3)
    }
    let sizeWrites = platform.successfulSizeWriteCount

    platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      asynchronousPositions: true,
      animationDuration: 0.08,
      animationRefreshRateHz: 120,
      animateSizeChanges: true,
      source: "test-resize-animation"
    )
    XCTAssertTrue(
      pumpRunLoop(
        until: { !platform.hasPendingAnimatedFrameWrites },
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
      "resize animation did not converge; app=\(window.appID) target=\(target) actual=\(String(describing: actual)) trace=\(platform.frameCoordinatorTrace)"
    )
    XCTAssertEqual(actual?.width ?? 0, target.width, accuracy: 2)
    XCTAssertGreaterThanOrEqual(
      platform.successfulSizeWriteCount - sizeWrites,
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
      platform.apply(
        [FrameAssignment(windowID: window.id, frame: target)],
        asynchronousPositions: true,
        animationDuration: 0.05,
        animationRefreshRateHz: 120,
        source: "test-animation"
      )
      guard pumpRunLoop(
        until: { !platform.hasPendingAnimatedFrameWrites },
        timeout: 0.5
      ) else {
        failedPreconditions.append("\(window.appID):animation")
        competingPlatform.apply([
          FrameAssignment(windowID: window.id, frame: original)
        ])
        pumpRunLoop(for: 0.15)
        platform.acceptObservedFrame(original, for: window.id)
        continue
      }

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
      if competingWriteConverged,
        let expectation = platform.frameCommitExpectations[window.id]
      {
        selected = (window, original, target, expectation)
        break
      }
      failedPreconditions.append(
        "\(window.appID):\(String(describing: lastCompetingFrame))"
      )
      competingPlatform.apply([
        FrameAssignment(windowID: window.id, frame: original)
      ])
      pumpRunLoop(for: 0.15)
      platform.acceptObservedFrame(original, for: window.id)
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
      platform.apply([FrameAssignment(windowID: window.id, frame: original)])
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

    let writesBeforeDesktopSync = platform.successfulPositionWriteCount
    platform.requestFrameRefresh(for: window.id)
    let delayedSnapshot = platform.snapshot(config: Config())
    platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      asynchronousPositions: true,
      source: "desktop-sync"
    )
    pumpRunLoop(for: 0.08)

    XCTAssertTrue(delayedSnapshot.targetMismatches.isEmpty)
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
    guard
      let window = testWindows(in: snapshot).first(
        where: { $0.id != snapshot.focusedWindowID }
      )
    else {
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
        platform.focus(originalFocusedWindowID)
        pumpRunLoop(for: 0.5)
      }
    }

    for windowID in [windows[0].id, windows[1].id, windows[0].id, windows[1].id] {
      platform.focus(windowID)
    }

    XCTAssertTrue(
      pumpRunLoop(
        until: {
          !platform.hasPendingFocusWrite
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
    var commands: [String] = []
    let menu = NSHostingMenu(rootView: MenuBarContent(
      activeWorkspace: "dev",
      workspaces: [MenuWorkspace(id: "dev", label: "Dev"), MenuWorkspace(id: "web", label: "Web")],
      commandHandler: { commands.append($0) }
    ))
    menu.update()
    XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["✓ Dev", "Web", "Quit Defi"])
    let workspaceIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Web" })
    menu.performActionForItem(at: workspaceIndex)
    pumpRunLoop(for: 0.05)
    let quitIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Quit Defi" })
    menu.performActionForItem(at: quitIndex)
    pumpRunLoop(for: 0.05)
    XCTAssertEqual(commands, ["workspace web", "quit"])
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
    var inputs: [CheatsheetInput] = []
    var commands: [String] = []
    let manager = HotKeyManager(
      config: Config(
        modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
        defaultKeyModifier: "hyper",
        keys: ["hyper-slash": "toggle-cheatsheet"]
      ),
      cheatsheetHandler: { inputs.append($0) }
    ) { commands.append($0.command) }
    try manager.start()
    defer { manager.stop() }
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
      inputs.contains(.modifiersChanged(matches: true, released: false))
    }, timeout: 1))
    pumpRunLoop(for: 0.65)
    XCTAssertEqual(inputs.last, .modifiersChanged(matches: true, released: false))
    let shortcut = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 44, keyDown: true
    ))
    shortcut.flags = modifier.flags
    shortcut.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { commands == ["toggle-cheatsheet"] }, timeout: 1))
    shortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    shortcut.post(tap: .cghidEventTap)
    pumpRunLoop(for: 0.1)
    XCTAssertEqual(commands, ["toggle-cheatsheet"])
    manager.setCheatsheetVisible(true)
    let escape = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 53, keyDown: true
    ))
    escape.flags = modifier.flags
    escape.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { inputs.last == .dismiss }, timeout: 1))
  }

  func testHotKeysAreCapturedWhileMainActorIsBlocked() throws {
    _ = try makePlatform()
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      keys: ["hyper-left": "focus-column left"]
    )
    let tracker = UserInputTracker()
    var received: [HotKeyInvocation] = []
    let manager = HotKeyManager(
      config: config,
      userInputTracker: tracker
    ) { invocation in
      received.append(invocation)
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
      manager.capturedKeyCount,
      eventCount,
      "event tap must keep capturing while AX/layout blocks the main actor"
    )
    pumpRunLoop(for: 0.2)
    XCTAssertEqual(received.count, eventCount)
    XCTAssertTrue(received.allSatisfy { $0.command == "focus-column left" })
    XCTAssertTrue(received.allSatisfy { $0.timestamp > 0 })
    XCTAssertEqual(tracker.latestEventTimestamp, received.last?.timestamp)
    XCTAssertEqual(manager.tapReenableCount, 0)
  }

  func testConfiguredHyperArrowNavigatesOverview() throws {
    _ = try makePlatform()
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      keys: ["hyper-left": "focus-column left"]
    )
    var commands: [HotKeyInvocation] = []
    var overviewActions: [OverviewKeyAction] = []
    let manager = HotKeyManager(
      config: config,
      overviewHandler: { overviewActions.append($0) }
    ) { commands.append($0) }
    try manager.start()
    manager.setOverviewModeEnabled(true)

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
      pumpRunLoop(until: { overviewActions == [.left] }, timeout: 1)
    )
    XCTAssertEqual(commands, [])
    XCTAssertEqual(manager.capturedKeyCount, 1)
  }

  func testScrollWheelAdvancesUserInputTracker() throws {
    _ = try makePlatform()
    let tracker = UserInputTracker()
    let manager = HotKeyManager(
      config: Config(),
      userInputTracker: tracker
    ) { _ in }
    try manager.start()
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
    var received: [PointerMotionInvocation] = []
    let manager = HotKeyManager(
      config: config,
      pointerMotionTracker: platform.pointerMotionTracker,
      pointerMotionHandler: { invocation in
        received.append(invocation)
      }
    ) { _ in }
    try manager.start()

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
      pumpRunLoop(until: { !received.isEmpty }, timeout: 0.5),
      "mouse movement did not reach event tap"
    )
    pumpRunLoop(for: 0.1)
    let resolvedPointerWindowID = received.last.flatMap {
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
    let transitionsBeforeWarp = manager.pointerTransitionCount

    XCTAssertTrue(
      platform.warpCursor(
        to: otherWindow.id,
        unlessUserInputAfter: .greatestFiniteMagnitude
      )
    )
    pumpRunLoop(for: 0.2)

    XCTAssertEqual(platform.cursorWarpPerformance.applied, 1)
    XCTAssertEqual(
      manager.pointerTransitionCount,
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
      platform.apply([
        FrameAssignment(windowID: window.id, frame: originalFrame)
      ])
      CGWarpMouseCursorPosition(originalCursorLocation)
      pumpRunLoop(for: 0.3)
    }

    XCTAssertEqual(CGWarpMouseCursorPosition(outside), .success)
    platform.apply(
      [FrameAssignment(windowID: window.id, frame: targetFrame)],
      asynchronousPositions: true,
      cursorWarpWindowIDAfterCommit: window.id,
      cursorWarpInputTimestampAfterCommit: .greatestFiniteMagnitude,
      cursorWarpIsCurrentAfterCommit: { true }
    )

    XCTAssertTrue(
      pumpRunLoop(
        until: { platform.cursorWarpPerformance.applied == 1 },
        timeout: 1
      ),
      "cursor did not warp after the target frame committed; performance=\(platform.cursorWarpPerformance) trace=\(platform.frameCoordinatorTrace)"
    )
  }

  func testPointerTrackingStartsWhenHotKeyParsingFails() throws {
    _ = try makePlatform()
    let config = Config(
      input: InputConfig(focusFollowsMouse: true),
      keys: ["unknown-no-such-key": "focus-column left"]
    )
    var received: [PointerMotionInvocation] = []
    let manager = HotKeyManager(
      config: config,
      pointerMotionHandler: { invocation in
        received.append(invocation)
      }
    ) { _ in }
    XCTAssertNotNil(manager.bindingError)
    XCTAssertEqual(manager.bindingCount, 0)
    try manager.start()

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
      pumpRunLoop(until: { !received.isEmpty }, timeout: 0.5),
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

    XCTAssertTrue(
      pumpRunLoop(
        until: { platform.parkingPerformance.repairs >= 1 },
        timeout: 1.6
      ),
      "parking repair did not run before its 1.4 second backstop"
    )
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
