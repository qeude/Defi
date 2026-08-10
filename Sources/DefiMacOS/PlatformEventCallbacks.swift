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
