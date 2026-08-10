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
  private let mouseGestureStartedHandler: () -> Void
  private var workspaceTokens: [NSObjectProtocol] = []
  private var screenTokens: [NSObjectProtocol] = []
  private var mouseMonitor: Any?
  private var mouseGestureNormalizer = MouseGestureEventNormalizer()
  private var observers: [pid_t: AXObserver] = [:]
  private var topologyObservedProcessIDs = Set<pid_t>()
  private var observedWindows: [pid_t: [AXUIElement]] = [:]
  private var topologyRequiredWindows: [pid_t: [AXUIElement]] = [:]
  private var frameRequiredWindows: [pid_t: [AXUIElement]] = [:]
  private var topologyObservedWindows: [pid_t: [AXUIElement]] = [:]
  private var frameObservedWindows: [pid_t: [AXUIElement]] = [:]
  private var frameNotificationsEnabled = true
  private var displayCallbackRegistered = false

  init(
    handler: @escaping (PlatformEventKind, pid_t?) -> Void,
    userInputTracker: UserInputTracker = UserInputTracker(),
    frameHandler: @escaping (AXUIElement) -> Void = { _ in },
    liveFrameHandler: @escaping () -> Void = {},
    borderStackingHandler: @escaping () -> Void = {},
    mouseGestureStartedHandler: @escaping () -> Void = {}
  ) {
    self.handler = handler
    self.userInputTracker = userInputTracker
    self.frameHandler = frameHandler
    self.liveFrameHandler = liveFrameHandler
    self.borderStackingHandler = borderStackingHandler
    self.mouseGestureStartedHandler = mouseGestureStartedHandler
  }

  func start() {
    let center = NSWorkspace.shared.notificationCenter
    workspaceTokens.append(
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let processID =
          (notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
          ] as? NSRunningApplication)?.processIdentifier
        MainActor.assumeIsolated {
          self?.handler(.focus, processID)
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
        let processID =
          (notification.userInfo?[
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
      matching: [
        .leftMouseDown,
        .leftMouseDragged,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
      ]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        if eventStartsMouseFocusInteraction(event.type) {
          let rawWindowID =
            event.cgEvent?.getIntegerValueField(
              .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
            ) ?? Int64(event.windowNumber)
          self.userInputTracker.record(
            timestamp: event.timestamp,
            focusIntent: event.type == .leftMouseDown
              ? .mouse(
                windowID: mouseFocusIntentWindowID(rawWindowID: rawWindowID)
              )
              : nil
          )
        }
        if event.type == .leftMouseDragged || event.type == .leftMouseUp {
          self.liveFrameHandler()
        }
        let actions = self.mouseGestureNormalizer.actions(
          for: event.type,
          buttonNumber: event.buttonNumber
        )
        if actions.refreshBorderStacking {
          self.borderStackingHandler()
        }
        if actions.startsGesture {
          self.mouseGestureStartedHandler()
        }
        switch actions.synchronization {
        case .gesture:
          self.handler(.mouse, nil)
        case nil:
          break
        }
        if actions.endsFocusInteraction {
          self.handler(.mouseRelease, nil)
        }
      }
    }
  }

  func resetMouseGestureState() -> Bool {
    mouseGestureNormalizer.reset()
  }

  func refresh(
    applications: [pid_t: [AXUIElement]],
    requiredTopologyWindows: [pid_t: [AXUIElement]]? = nil,
    requiredFrameWindows: [pid_t: [AXUIElement]]? = nil
  ) {
    let activeProcessIDs = Set(applications.keys)
    for processID in observers.keys where !activeProcessIDs.contains(processID) {
      observers[processID] = nil
      topologyObservedProcessIDs.remove(processID)
      observedWindows[processID] = nil
      topologyRequiredWindows[processID] = nil
      frameRequiredWindows[processID] = nil
      topologyObservedWindows[processID] = nil
      frameObservedWindows[processID] = nil
    }

    for (processID, windows) in applications {
      guard let observer = observer(for: processID) else { continue }
      prepareForWindowDiscovery(
        processID: processID,
        application: AXUIElementCreateApplication(processID),
        observer: observer
      )

      var known = observedWindows[processID] ?? []
      var topologyObserved = topologyObservedWindows[processID] ?? []
      var frameObserved = frameObservedWindows[processID] ?? []
      let requiredTopology = topologyWindowsRequiringCoverage(
        requested: requiredTopologyWindows?[processID] ?? windows,
        previouslyRequired: topologyRequiredWindows[processID] ?? [],
        observed: topologyObserved,
        applicationWindows: windows
      )
      let requiredFrames = requiredFrameWindows?[processID] ?? windows
      for window in windows {
        if !topologyObserved.contains(where: { CFEqual($0, window) }),
          subscribe(
            observer,
            element: window,
            notifications: [
              kAXUIElementDestroyedNotification,
              kAXWindowMiniaturizedNotification,
              kAXWindowDeminiaturizedNotification,
            ]
          )
        {
          topologyObserved.append(window)
        }
        if frameNotificationsEnabled,
          requiredFrames.contains(where: { CFEqual($0, window) }),
          !frameObserved.contains(where: { CFEqual($0, window) }),
          subscribe(
            observer,
            element: window,
            notifications: [kAXMovedNotification, kAXResizedNotification]
          )
        {
          frameObserved.append(window)
        }
        if !known.contains(where: { CFEqual($0, window) }) {
          known.append(window)
        }
      }
      let obsoleteFrameWindows = frameObserved.filter { candidate in
        !requiredFrames.contains(where: { CFEqual($0, candidate) })
      }
      for window in obsoleteFrameWindows {
        for notification in [kAXMovedNotification, kAXResizedNotification] {
          AXObserverRemoveNotification(
            observer,
            window,
            notification as CFString
          )
        }
      }
      observedWindows[processID] = known.filter { candidate in
        windows.contains(where: { CFEqual($0, candidate) })
      }
      topologyRequiredWindows[processID] = requiredTopology
      frameRequiredWindows[processID] = requiredFrames
      topologyObservedWindows[processID] = topologyObserved.filter { candidate in
        windows.contains(where: { CFEqual($0, candidate) })
      }
      frameObservedWindows[processID] = frameObserved.filter { candidate in
        requiredFrames.contains(where: { CFEqual($0, candidate) })
      }
    }
  }

  func prepareForWindowDiscovery(
    processID: pid_t,
    application: AXUIElement
  ) {
    guard let observer = observer(for: processID) else { return }
    prepareForWindowDiscovery(
      processID: processID,
      application: application,
      observer: observer
    )
  }

  func hasReliableWindowTopologyCoverage(
    for processIDs: Set<pid_t>
  ) -> Bool {
    guard processIDs.isSubset(of: topologyObservedProcessIDs) else {
      return false
    }
    return topologyRequiredWindows.allSatisfy { processID, windows in
      let topologyObserved = topologyObservedWindows[processID] ?? []
      return windows.allSatisfy { window in
        topologyObserved.contains(where: { CFEqual($0, window) })
      }
    }
  }

  func hasReliableFrameCoverage() -> Bool {
    guard frameNotificationsEnabled else { return false }
    return frameRequiredWindows.allSatisfy { processID, windows in
      let frameObserved = frameObservedWindows[processID] ?? []
      return windows.allSatisfy { window in
        frameObserved.contains(where: { CFEqual($0, window) })
      }
    }
  }

  var observationCoverage:
    (
      applicationObservers: Int,
      applications: Int,
      topologyWindows: Int,
      requiredTopologyWindows: Int,
      frameWindows: Int,
      requiredFrameWindows: Int
    )
  {
    (
      topologyObservedProcessIDs.count,
      observers.count,
      observedWindowCount(
        topologyRequiredWindows,
        coveredBy: topologyObservedWindows
      ),
      topologyRequiredWindows.values.reduce(0) { $0 + $1.count },
      observedWindowCount(
        frameRequiredWindows,
        coveredBy: frameObservedWindows
      ),
      frameRequiredWindows.values.reduce(0) { $0 + $1.count }
    )
  }

  var hasReliableApplicationLifecycleObservation: Bool {
    workspaceTokens.count == 5
  }

  func setFrameNotificationsEnabled(_ enabled: Bool) {
    guard frameNotificationsEnabled != enabled else { return }
    frameNotificationsEnabled = enabled
    let windowsByProcess = enabled ? frameRequiredWindows : frameObservedWindows
    for (processID, windows) in windowsByProcess {
      guard let observer = observers[processID] else { continue }
      if enabled {
        for window in windows
        where !((frameObservedWindows[processID] ?? []).contains {
          CFEqual($0, window)
        }) {
          if subscribe(
            observer,
            element: window,
            notifications: [kAXMovedNotification, kAXResizedNotification]
          ) {
            frameObservedWindows[processID, default: []].append(window)
          }
        }
      } else {
        for window in windows {
          for notification in [kAXMovedNotification, kAXResizedNotification] {
            AXObserverRemoveNotification(
              observer,
              window,
              notification as CFString
            )
          }
        }
        frameObservedWindows[processID] = []
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

  private func prepareForWindowDiscovery(
    processID: pid_t,
    application: AXUIElement,
    observer: AXObserver
  ) {
    guard !topologyObservedProcessIDs.contains(processID) else { return }
    if subscribe(
      observer,
      element: application,
      notifications: [
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification,
      ]
    ) {
      topologyObservedProcessIDs.insert(processID)
    }
  }

  @discardableResult
  private func subscribe(
    _ observer: AXObserver,
    element: AXUIElement,
    notifications: [String]
  ) -> Bool {
    let context = Unmanaged.passUnretained(self).toOpaque()
    var allRegistered = true
    for notification in notifications {
      let result = AXObserverAddNotification(
        observer,
        element,
        notification as CFString,
        context
      )
      if result != .success && result != .notificationAlreadyRegistered {
        allRegistered = false
      }
    }
    return allRegistered
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

private func observedWindowCount(
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
