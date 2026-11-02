import DefiConfig
import DefiRuntime
import Foundation
import XCTest

@testable import DefiMacOS

private enum Bound { @TaskLocal static var value = false }

/// macOS 15's Swift runtime aborts when an `isolated deinit` runs outside a task with a
/// task-local bound. XCTest runs synchronous tests on the main thread outside any task.
@MainActor
final class DeinitWithTaskLocalTests: XCTestCase {
  func testMainActorObjectsReleaseWithTaskLocalBound() {
    Bound.$value.withValue(true) {
      AccessibilityPermissionMonitor(center: NotificationCenter()) { _ in false }.start {}
      _ = KeyboardLayoutObserver {}
      _ = OverviewController(focusWindow: { _, _, _, _ in }, focusWorkspace: { _, _ in },
        drop: { _, _, _, _, _ in }, activateMonitor: { _ in }, openStateChanged: { _ in },
        notificationCenter: NotificationCenter(), commitScrollOffsets: { _ in })
    }
  }

  func testHotKeyManagerReleasesWithTaskLocalBound() {
    NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated {
        Bound.$value.withValue(true) { _ = HotKeyManager(config: Config()) { _ in } }
      }
    }
  }
}
