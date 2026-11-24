import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel

func registerNotificationBatch(
  notifications: [String],
  add: (String) -> AXError,
  remove: (String) -> Void
) -> AXError {
  var registered: [String] = []
  for notification in notifications {
    let result = add(notification)
    guard result == .success || result == .notificationAlreadyRegistered else {
      for registeredNotification in registered {
        remove(registeredNotification)
      }
      return result
    }
    registered.append(notification)
  }
  return .success
}

func notificationObservationRetryDelays(for kind: NotificationObservationKind) -> [TimeInterval] {
  // A launching app refuses its observer for seconds (cannotComplete), so its retries span a launch.
  kind == .applicationTopology ? [0.25, 0.5, 1, 2, 4] : [0, 0]
}

func notificationObservationMaxAttempts(for kind: NotificationObservationKind) -> Int {
  notificationObservationRetryDelays(for: kind).count + 1
}

enum NotificationObservationKind: String, CaseIterable {
  case applicationTopology = "app"
  case windowTopology = "window"
  case frame
}

typealias NotificationObservationFailureCounts = [
  NotificationObservationKind: [pid_t: Int]
]

struct NotificationObservationFailure {
  let processID: pid_t
  let attempts: Int
  let error: AXError
  let retryAfter: TimeInterval
}

func observedWindowCount(
  _ required: [pid_t: [AXUIElement]],
  coveredBy observed: [pid_t: [AXUIElement]]
) -> Int {
  required.reduce(into: 0) { count, entry in
    let observedWindows = observed[entry.key] ?? []
    count += entry.value.filter { requiredWindow in
      observedWindows.contains(where: { CFEqual($0, requiredWindow) })
    }.count
  }
}

func displayReconfigurationCallback(
  _: CGDirectDisplayID,
  _: CGDisplayChangeSummaryFlags,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let monitor = Unmanaged<PlatformEventMonitor>
    .fromOpaque(context)
    .takeUnretainedValue()
  Task { @MainActor [weak monitor] in
    monitor?.handler(.screens, nil)
  }
}
