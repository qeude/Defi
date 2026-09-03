import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel

func registerNotificationBatch(
  notifications: [String],
  add: (String) -> AXError,
  remove: (String) -> Void
) -> Bool {
  var registered: [String] = []
  for notification in notifications {
    let result = add(notification)
    guard result == .success || result == .notificationAlreadyRegistered else {
      for registeredNotification in registered {
        remove(registeredNotification)
      }
      return false
    }
    registered.append(notification)
  }
  return true
}

let notificationObservationMaxAttempts = 3

enum NotificationObservationKind: String, CaseIterable {
  case applicationTopology = "app"
  case windowTopology = "window"
  case frame
}

typealias NotificationObservationFailureCounts = [
  NotificationObservationKind: [pid_t: Int]
]

func updatedNotificationObservationFailureCounts(
  _ counts: NotificationObservationFailureCounts,
  activeProcessIDs: Set<pid_t>,
  failedProcessID: pid_t? = nil,
  kind: NotificationObservationKind? = nil
) -> NotificationObservationFailureCounts {
  var updated = counts.mapValues { failures in
    failures.filter { activeProcessIDs.contains($0.key) }
  }.filter { !$0.value.isEmpty }
  if let failedProcessID, let kind,
    activeProcessIDs.contains(failedProcessID)
  {
    updated[kind, default: [:]][failedProcessID, default: 0] += 1
  }
  return updated
}

func processIDsIncompatibleWithNotificationObservation(
  _ counts: NotificationObservationFailureCounts,
  kind: NotificationObservationKind
) -> Set<pid_t> {
  Set(
    (counts[kind] ?? [:])
      .filter { $0.value >= notificationObservationMaxAttempts }
      .keys
  )
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
  _ display: CGDirectDisplayID,
  _ flags: CGDisplayChangeSummaryFlags,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let monitor = Unmanaged<PlatformEventMonitor>
    .fromOpaque(context)
    .takeUnretainedValue()
  Task { @MainActor [weak monitor] in
    monitor?.handleDisplayReconfiguration(display: display, flags: flags)
  }
}

extension PlatformEventMonitor {
  fileprivate func handleDisplayReconfiguration(
    display _: CGDirectDisplayID,
    flags _: CGDisplayChangeSummaryFlags
  ) {
    handler(.screens, nil)
  }
}
