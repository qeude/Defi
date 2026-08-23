import AppKit
import DefiModel
import Testing

@testable import DefiMacOS

@MainActor
struct MonitorTests {
  private let internalDisplay = MonitorSnapshot(
    id: MonitorID(rawValue: 1),
    frame: Rect(x: 0, y: 0, width: 1_512, height: 901),
    physicalFrame: Rect(x: 0, y: 0, width: 1_512, height: 982),
    refreshRateHz: 120
  )

  @Test
  func `Monitor geometry detects display replacement`() {
    let externalDisplay = MonitorSnapshot(
      id: MonitorID(rawValue: 3),
      frame: Rect(x: 0, y: 30, width: 2_560, height: 1_362),
      physicalFrame: Rect(x: 0, y: 0, width: 2_560, height: 1_440),
      refreshRateHz: 120
    )

    #expect(monitorGeometryChanged(from: [internalDisplay], to: [externalDisplay]))
  }

  @Test
  func `Monitor geometry detects visible frame resize`() {
    let resized = MonitorSnapshot(
      id: internalDisplay.id,
      frame: Rect(x: 0, y: 0, width: 1_512, height: 880),
      physicalFrame: internalDisplay.physicalFrame,
      refreshRateHz: 120
    )

    #expect(monitorGeometryChanged(from: [internalDisplay], to: [resized]))
  }

  @Test
  func `Monitor geometry ignores refresh rate only change`() {
    let changedRefreshRate = MonitorSnapshot(
      id: internalDisplay.id,
      frame: internalDisplay.frame,
      physicalFrame: internalDisplay.physicalFrame,
      refreshRateHz: 60
    )

    #expect(monitorGeometryChanged(from: [internalDisplay], to: [changedRefreshRate]) == false)
  }

  @Test
  func `Monitor geometry ignores ordering`() {
    let externalDisplay = MonitorSnapshot(
      id: MonitorID(rawValue: 3),
      frame: Rect(x: 1_512, y: 0, width: 2_560, height: 1_362),
      physicalFrame: Rect(x: 1_512, y: 0, width: 2_560, height: 1_440),
      refreshRateHz: 120
    )

    #expect(
      monitorGeometryChanged(
        from: [internalDisplay, externalDisplay],
        to: [externalDisplay, internalDisplay]
      ) == false)
  }

  @Test
  func `Screen parameter notification is classified as display change`() {
    var receivedKinds: [PlatformEventKind] = []
    let monitor = PlatformEventMonitor { kind, _ in receivedKinds.append(kind) }
    monitor.start()
    defer { monitor.stop() }

    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification,
      object: NSApplication.shared
    )

    #expect(receivedKinds == [.screens])
  }

  @Test
  func `Termination notification includes application process ID`() {
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

    #expect(receivedKind == .applicationTerminated)
    #expect(receivedProcessID == application.processIdentifier)
  }
}
