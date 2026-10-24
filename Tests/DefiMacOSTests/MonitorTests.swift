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
  func `Monitor geometry changes with displays and visible frames, not refresh rate or order`() {
    func display(_ id: UInt64, x: Double = 0, visibleHeight: Double = 901, refresh: Double = 120) -> MonitorSnapshot {
      MonitorSnapshot(id: MonitorID(rawValue: id), frame: Rect(x: x, y: 0, width: 1_512, height: visibleHeight),
        physicalFrame: Rect(x: x, y: 0, width: 1_512, height: 982), refreshRateHz: refresh)
    }
    let external = display(3, x: 1_512)
    #expect(monitorGeometryChanged(from: [internalDisplay], to: [display(3)]))
    #expect(monitorGeometryChanged(from: [internalDisplay], to: [display(1, visibleHeight: 880)]))
    #expect(!monitorGeometryChanged(from: [internalDisplay], to: [display(1, refresh: 60)]))
    #expect(!monitorGeometryChanged(from: [internalDisplay, external], to: [external, internalDisplay]))
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
