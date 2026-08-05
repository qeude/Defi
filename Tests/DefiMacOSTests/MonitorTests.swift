import AppKit
import DefiModel
import XCTest

@testable import DefiMacOS

@MainActor
final class MonitorTests: XCTestCase {
  private let internalDisplay = MonitorSnapshot(
    id: MonitorID(rawValue: 1),
    frame: Rect(x: 0, y: 0, width: 1_512, height: 901),
    physicalFrame: Rect(x: 0, y: 0, width: 1_512, height: 982),
    refreshRateHz: 120
  )

  func testMonitorGeometryDetectsDisplayReplacement() {
    let externalDisplay = MonitorSnapshot(
      id: MonitorID(rawValue: 3),
      frame: Rect(x: 0, y: 30, width: 2_560, height: 1_362),
      physicalFrame: Rect(x: 0, y: 0, width: 2_560, height: 1_440),
      refreshRateHz: 120
    )

    XCTAssertTrue(
      monitorGeometryChanged(from: [internalDisplay], to: [externalDisplay])
    )
  }

  func testMonitorGeometryDetectsVisibleFrameResize() {
    let resized = MonitorSnapshot(
      id: internalDisplay.id,
      frame: Rect(x: 0, y: 0, width: 1_512, height: 880),
      physicalFrame: internalDisplay.physicalFrame,
      refreshRateHz: 120
    )

    XCTAssertTrue(
      monitorGeometryChanged(from: [internalDisplay], to: [resized])
    )
  }

  func testMonitorGeometryIgnoresRefreshRateOnlyChange() {
    let changedRefreshRate = MonitorSnapshot(
      id: internalDisplay.id,
      frame: internalDisplay.frame,
      physicalFrame: internalDisplay.physicalFrame,
      refreshRateHz: 60
    )

    XCTAssertFalse(
      monitorGeometryChanged(from: [internalDisplay], to: [changedRefreshRate])
    )
  }

  func testMonitorGeometryIgnoresOrdering() {
    let externalDisplay = MonitorSnapshot(
      id: MonitorID(rawValue: 3),
      frame: Rect(x: 1_512, y: 0, width: 2_560, height: 1_362),
      physicalFrame: Rect(x: 1_512, y: 0, width: 2_560, height: 1_440),
      refreshRateHz: 120
    )

    XCTAssertFalse(
      monitorGeometryChanged(
        from: [internalDisplay, externalDisplay],
        to: [externalDisplay, internalDisplay]
      )
    )
  }

  func testScreenParameterNotificationIsClassifiedAsDisplayChange() {
    var receivedKinds: [PlatformEventKind] = []
    let monitor = PlatformEventMonitor { kind, _ in receivedKinds.append(kind) }
    monitor.start()
    defer { monitor.stop() }

    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification,
      object: NSApplication.shared
    )

    XCTAssertEqual(receivedKinds, [.screens])
  }

  func testTerminationNotificationIncludesApplicationProcessID() {
    var receivedKind: PlatformEventKind?
    var receivedProcessID: pid_t?
    let monitor = PlatformEventMonitor { kind, processID in
      receivedKind = kind
      receivedProcessID = processID
    }
    monitor.start()
    defer { monitor.stop() }

    let application = NSRunningApplication.current
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.didTerminateApplicationNotification,
      object: NSWorkspace.shared,
      userInfo: [NSWorkspace.applicationUserInfoKey: application]
    )

    XCTAssertEqual(receivedKind, .applicationTerminated)
    XCTAssertEqual(receivedProcessID, application.processIdentifier)
  }
}
