import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel

@MainActor
final class PlatformEventMonitor {
  private let handler: (PlatformEventKind, pid_t?) -> Void
  private let userInputTracker: UserInputTracker
  private let frameHandler: (AXUIElement) -> Void
  private let liveFrameHandler: () -> Void
  private let borderStackingHandler: () -> Void
  private var workspaceTokens: [NSObjectProtocol] = []
  private var screenTokens: [NSObjectProtocol] = []
  private var mouseMonitor: Any?
  private var mouseGestureNormalizer = MouseGestureEventNormalizer()
  private var observers: [pid_t: AXObserver] = [:]
  private var observedWindows: [pid_t: [AXUIElement]] = [:]
  private var frameNotificationsEnabled = true
  private var displayCallbackRegistered = false

  init(
    handler: @escaping (PlatformEventKind, pid_t?) -> Void,
    userInputTracker: UserInputTracker = UserInputTracker(),
    frameHandler: @escaping (AXUIElement) -> Void = { _ in },
    liveFrameHandler: @escaping () -> Void = {},
    borderStackingHandler: @escaping () -> Void = {}
  ) {
    self.handler = handler
    self.userInputTracker = userInputTracker
    self.frameHandler = frameHandler
    self.liveFrameHandler = liveFrameHandler
    self.borderStackingHandler = borderStackingHandler
  }

  func start() {
    let center = NSWorkspace.shared.notificationCenter
    workspaceTokens.append(
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handler(.focus, nil)
        }
      }
    )
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification,
    ] {
      workspaceTokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            self?.handler(.application, nil)
          }
        }
      )
    }
    workspaceTokens.append(
      center.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let processID = (notification.userInfo?[
          NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication)?.processIdentifier
        MainActor.assumeIsolated {
          self?.handler(.applicationTerminated, processID)
        }
      }
    )
    screenTokens.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handler(.screens, nil)
        }
      }
    )
    let displayResult = CGDisplayRegisterReconfigurationCallback(
      displayReconfigurationCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    displayCallbackRegistered = displayResult == .success

    mouseMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        if event.type == .leftMouseDown {
          let rawWindowID = event.cgEvent?.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
          ) ?? Int64(event.windowNumber)
          self.userInputTracker.record(
            timestamp: event.timestamp,
            focusIntent: .mouse(
              windowID: mouseFocusIntentWindowID(rawWindowID: rawWindowID)
            )
          )
        }
        if event.type == .leftMouseDragged || event.type == .leftMouseUp {
          self.liveFrameHandler()
        }
        let actions = self.mouseGestureNormalizer.actions(for: event.type)
        if actions.refreshBorderStacking {
          self.borderStackingHandler()
        }
        if actions.synchronizeDesktop {
          self.handler(.mouse, nil)
        }
      }
    }
  }

  func refresh(applications: [pid_t: [AXUIElement]]) {
    let activeProcessIDs = Set(applications.keys)
    for processID in observers.keys where !activeProcessIDs.contains(processID) {
      observers[processID] = nil
      observedWindows[processID] = nil
    }

    for (processID, windows) in applications {
      guard let observer = observer(for: processID) else { continue }
      let application = AXUIElementCreateApplication(processID)
      subscribe(
        observer,
        element: application,
        notifications: [
          kAXFocusedWindowChangedNotification,
          kAXWindowCreatedNotification,
        ]
      )

      var known = observedWindows[processID] ?? []
      for window in windows where !known.contains(where: { CFEqual($0, window) }) {
        var notifications = [
          kAXUIElementDestroyedNotification,
          kAXWindowMiniaturizedNotification,
          kAXWindowDeminiaturizedNotification,
        ]
        if frameNotificationsEnabled {
          notifications.append(contentsOf: [
            kAXMovedNotification,
            kAXResizedNotification,
          ])
        }
        subscribe(
          observer,
          element: window,
          notifications: notifications
        )
        known.append(window)
      }
      observedWindows[processID] = known.filter { candidate in
        windows.contains(where: { CFEqual($0, candidate) })
      }
    }
  }

  func setFrameNotificationsEnabled(_ enabled: Bool) {
    guard frameNotificationsEnabled != enabled else { return }
    frameNotificationsEnabled = enabled
    for (processID, windows) in observedWindows {
      guard let observer = observers[processID] else { continue }
      for window in windows {
        for notification in [kAXMovedNotification, kAXResizedNotification] {
          if enabled {
            subscribe(
              observer,
              element: window,
              notifications: [notification]
            )
          } else {
            AXObserverRemoveNotification(
              observer,
              window,
              notification as CFString
            )
          }
        }
      }
    }
  }

  private func observer(for processID: pid_t) -> AXObserver? {
    if let observer = observers[processID] {
      return observer
    }

    var observer: AXObserver?
    let result = AXObserverCreate(
      processID,
      { _, element, notification, context in
        guard let context else { return }
        let monitor = Unmanaged<PlatformEventMonitor>
          .fromOpaque(context)
          .takeUnretainedValue()
        MainActor.assumeIsolated {
          var processID: pid_t = 0
          let normalizedProcessID =
            AXUIElementGetPid(element, &processID) == .success
            ? processID
            : nil
          switch notification as String {
          case kAXFocusedWindowChangedNotification:
            monitor.handler(.focus, normalizedProcessID)
          case kAXMovedNotification, kAXResizedNotification:
            monitor.frameHandler(element)
            monitor.handler(.frame, normalizedProcessID)
          default:
            monitor.handler(.windows, normalizedProcessID)
          }
        }
      },
      &observer
    )
    guard result == .success, let observer else { return nil }
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )
    observers[processID] = observer
    return observer
  }

  private func subscribe(
    _ observer: AXObserver,
    element: AXUIElement,
    notifications: [String]
  ) {
    let context = Unmanaged.passUnretained(self).toOpaque()
    for notification in notifications {
      let result = AXObserverAddNotification(
        observer,
        element,
        notification as CFString,
        context
      )
      if result != .success && result != .notificationAlreadyRegistered {
        continue
      }
    }
  }

  func stop() {
    if displayCallbackRegistered {
      CGDisplayRemoveReconfigurationCallback(
        displayReconfigurationCallback,
        Unmanaged.passUnretained(self).toOpaque()
      )
      displayCallbackRegistered = false
    }
    let center = NSWorkspace.shared.notificationCenter
    for token in workspaceTokens {
      center.removeObserver(token)
    }
    workspaceTokens.removeAll()
    for token in screenTokens {
      NotificationCenter.default.removeObserver(token)
    }
    screenTokens.removeAll()
    if let mouseMonitor {
      NSEvent.removeMonitor(mouseMonitor)
      self.mouseMonitor = nil
    }
  }
}

private func displayReconfigurationCallback(
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
