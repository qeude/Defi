import Foundation
import Testing
@testable import DefiMacOS

@MainActor
struct AccessibilityPermissionMonitorTests {
  @Test
  func promptsOnceAndStartsOnceAfterNotification() {
    let center = NotificationCenter()
    var trusted = false
    var prompts = 0
    var starts = 0
    let monitor = AccessibilityPermissionMonitor(center: center) { prompt in
      if prompt { prompts += 1 }
      return trusted
    }
    monitor.start { starts += 1 }
    monitor.start { starts += 1 }
    #expect(prompts == 1)
    #expect(starts == 0)
    center.post(name: AccessibilityPermissionMonitor.notification, object: nil)
    #expect(starts == 0)
    trusted = true
    center.post(name: AccessibilityPermissionMonitor.notification, object: nil)
    #expect(starts == 1)
    monitor.refresh()
    center.post(name: AccessibilityPermissionMonitor.notification, object: nil)
    #expect(starts == 1)
    #expect(prompts == 1)
  }

  @Test
  func fallbackDetectsGrantAndStopCancelsStartup() {
    var trusted = false
    var starts = 0
    let monitor = AccessibilityPermissionMonitor(center: NotificationCenter()) { _ in trusted }
    monitor.start { starts += 1 }
    trusted = true
    monitor.refresh()
    monitor.refresh()
    #expect(starts == 1)

    trusted = false
    let cancelled = AccessibilityPermissionMonitor(center: NotificationCenter()) { _ in trusted }
    cancelled.start { starts += 1 }
    cancelled.stop()
    trusted = true
    cancelled.refresh()
    #expect(starts == 1)
  }

  @Test
  func alreadyTrustedStartsWithoutPrompt() {
    var prompts = 0
    var starts = 0
    let monitor = AccessibilityPermissionMonitor(center: NotificationCenter()) { prompt in
      if prompt { prompts += 1 }
      return true
    }
    monitor.start { starts += 1 }
    monitor.start { starts += 1 }
    #expect(starts == 1)
    #expect(prompts == 0)
  }
}
