import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel

@MainActor
final class PlatformEventMonitor {
  let handler: (PlatformEventKind, pid_t?) -> Void
  private let userInputTracker: UserInputTracker
  private let desktopSessionHandler: (DesktopSessionActivityChange) -> Void
  private let desktopSessionStateProvider: () -> DesktopSessionState
  private let windowEventHandler: (PlatformEventKind, pid_t?, AXUIElement) -> Void
  private let liveFrameHandler: () -> Void
  private let borderStackingHandler: () -> Void
  private let mouseGestureStartedHandler: () -> Void
  private var workspaceTokens: [NSObjectProtocol] = []
  private var sessionTokens: [NSObjectProtocol] = []
  private var screenTokens: [NSObjectProtocol] = []
  private var mouseMonitor: Any?
  private var mouseGestureNormalizer = MouseGestureEventNormalizer()
  private var observers: [pid_t: AXObserver] = [:]
  private var topologyObservedProcessIDs = Set<pid_t>()
  private var notificationObservationFailureCounts: NotificationObservationFailureCounts = [:]
  private var observedWindows: [pid_t: [AXUIElement]] = [:]
  private var topologyRequiredWindows: [pid_t: [AXUIElement]] = [:]
  private var frameRequiredWindows: [pid_t: [AXUIElement]] = [:]
  private var topologyObservedWindows: [pid_t: [AXUIElement]] = [:]
  private var frameObservedWindows: [pid_t: [AXUIElement]] = [:]
  private var frameNotificationsEnabled = true
  private var suppressedFrameProcessIDs = Set<pid_t>()
  private var suppressedFrameRequiresFullSnapshot = false
  private var displayCallbackRegistered = false
  private var desktopSessionNormalizer = DesktopSessionEventNormalizer()
  private var desktopSessionActive = true

  init(
    handler: @escaping (PlatformEventKind, pid_t?) -> Void,
    userInputTracker: UserInputTracker = UserInputTracker(),
    desktopSessionHandler: @escaping (DesktopSessionActivityChange) -> Void = { _ in },
    desktopSessionStateProvider: @escaping () -> DesktopSessionState =
      currentDesktopSessionState,
    windowEventHandler: ((PlatformEventKind, pid_t?, AXUIElement) -> Void)? = nil,
    liveFrameHandler: @escaping () -> Void = {},
    borderStackingHandler: @escaping () -> Void = {},
    mouseGestureStartedHandler: @escaping () -> Void = {}
  ) {
    self.handler = handler
    self.userInputTracker = userInputTracker
    self.desktopSessionHandler = desktopSessionHandler
    self.desktopSessionStateProvider = desktopSessionStateProvider
    self.windowEventHandler =
      windowEventHandler ?? { kind, processID, _ in
        handler(kind, processID)
      }
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
    for (name, event) in [
      (NSWorkspace.willSleepNotification, DesktopSessionEvent.willSleep),
      (NSWorkspace.didWakeNotification, .didWake),
      (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
      (NSWorkspace.screensDidWakeNotification, .screensDidWake),
      (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
      (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
    ] {
      sessionTokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            guard let self,
              let change = self.desktopSessionNormalizer.consume(event)
            else { return }
            self.desktopSessionActive = change == .becameActive
            if !self.desktopSessionActive {
              self.resetAccessibilityObservers()
            }
            self.desktopSessionHandler(change)
          }
        }
      )
    }
    let initialDesktopSessionState = desktopSessionStateProvider()
    desktopSessionNormalizer = DesktopSessionEventNormalizer(
      initialState: initialDesktopSessionState
    )
    desktopSessionActive = initialDesktopSessionState.isActive
    if !desktopSessionActive {
      resetAccessibilityObservers()
      desktopSessionHandler(.becameInactive)
    }
    workspaceTokens.append(
      center.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handler(.space, nil)
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
        guard self.desktopSessionActive else { return }
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
        if actions.needsGestureSynchronization {
          self.handler(.mouse, nil)
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
    requiredFrameWindows: [pid_t: [AXUIElement]]? = nil,
    transientGeometryWindows: [pid_t: [AXUIElement]] = [:]
  ) {
    guard desktopSessionActive else { return }
    let activeProcessIDs = Set(applications.keys)
    notificationObservationFailureCounts = updatedNotificationObservationFailureCounts(
      notificationObservationFailureCounts,
      activeProcessIDs: activeProcessIDs
    )
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
      let requiredFrames = frameWindowsRequiringCoverage(
        requested: requiredFrameWindows?[processID] ?? windows,
        transientGeometry: transientGeometryWindows[processID] ?? [],
        applicationWindows: windows
      )
      for window in requiredTopology
      where !isIncompatibleWithNotificationObservation(
        .windowTopology,
        processID: processID
      ) {
        if !topologyObserved.contains(where: { CFEqual($0, window) }),
          subscribe(
            observer,
            processID: processID,
            kind: .windowTopology,
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
      }
      for window in windows {
        if !isIncompatibleWithNotificationObservation(
          .frame,
          processID: processID
        ),
          frameNotificationsEnabled,
          requiredFrames.contains(where: { CFEqual($0, window) }),
          !frameObserved.contains(where: { CFEqual($0, window) }),
          subscribe(
            observer,
            processID: processID,
            kind: .frame,
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
    guard
      !isIncompatibleWithNotificationObservation(
        .applicationTopology,
        processID: processID
      )
    else { return }
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
    let requiredProcessIDs =
      processIDs.subtracting(
        incompatibleNotificationProcessIDs(for: .applicationTopology)
      )
    guard requiredProcessIDs.isSubset(of: topologyObservedProcessIDs) else {
      return false
    }
    let incompatibleWindowProcessIDs = incompatibleNotificationProcessIDs(
      for: .windowTopology
    )
    return topologyRequiredWindows.allSatisfy { processID, windows in
      guard requiredProcessIDs.contains(processID),
        !incompatibleWindowProcessIDs.contains(processID)
      else { return true }
      let topologyObserved = topologyObservedWindows[processID] ?? []
      return windows.allSatisfy { window in
        topologyObserved.contains(where: { CFEqual($0, window) })
      }
    }
  }

  func processIDsWithoutReliableTopologyCoverage(
    activeProcessIDs: Set<pid_t>
  ) -> Set<pid_t> {
    var uncovered = activeProcessIDs.subtracting(topologyObservedProcessIDs)
    for (processID, windows) in topologyRequiredWindows {
      let observed = topologyObservedWindows[processID] ?? []
      if !windows.allSatisfy({ window in
        observed.contains(where: { CFEqual($0, window) })
      }) {
        uncovered.insert(processID)
      }
    }
    return uncovered
  }

  var incompatibleNotificationProcessIDs: Set<pid_t> {
    NotificationObservationKind.allCases.reduce(into: Set<pid_t>()) {
      $0.formUnion(incompatibleNotificationProcessIDs(for: $1))
    }
  }

  var notificationObservationFailureCountsValue: NotificationObservationFailureCounts {
    notificationObservationFailureCounts
  }

  private func isIncompatibleWithNotificationObservation(
    _ kind: NotificationObservationKind,
    processID: pid_t
  ) -> Bool {
    incompatibleNotificationProcessIDs(for: kind).contains(processID)
  }

  private func incompatibleNotificationProcessIDs(
    for kind: NotificationObservationKind
  ) -> Set<pid_t> {
    processIDsIncompatibleWithNotificationObservation(
      notificationObservationFailureCounts,
      kind: kind
    )
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

  var processIDsWithoutReliableFrameCoverage: Set<pid_t> {
    Set(
      frameRequiredWindows.compactMap { processID, windows in
        let observed = frameObservedWindows[processID] ?? []
        return windows.allSatisfy { window in
          observed.contains(where: { CFEqual($0, window) })
        } ? nil : processID
      })
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
    workspaceTokens.count == 6
  }

  func setFrameNotificationsEnabled(_ enabled: Bool) -> (
    processIDs: Set<pid_t>, requiresFullSnapshot: Bool
  ) {
    guard frameNotificationsEnabled != enabled else { return ([], false) }
    frameNotificationsEnabled = enabled
    guard enabled else {
      suppressedFrameProcessIDs.removeAll(keepingCapacity: true)
      suppressedFrameRequiresFullSnapshot = false
      return ([], false)
    }
    let refresh = (
      processIDs: suppressedFrameProcessIDs,
      requiresFullSnapshot: suppressedFrameRequiresFullSnapshot
    )
    suppressedFrameProcessIDs.removeAll(keepingCapacity: true)
    suppressedFrameRequiresFullSnapshot = false
    return refresh
  }

  func recordSuppressedFrameNotification(processID: pid_t?) {
    guard frameNotificationsEnabled == false else { return }
    if let processID {
      suppressedFrameProcessIDs.insert(processID)
    } else {
      suppressedFrameRequiresFullSnapshot = true
    }
  }

  func resetAccessibilityObservers() {
    for observer in observers.values {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .commonModes
      )
    }
    observers.removeAll(keepingCapacity: true)
    topologyObservedProcessIDs.removeAll(keepingCapacity: true)
    observedWindows.removeAll(keepingCapacity: true)
    topologyRequiredWindows.removeAll(keepingCapacity: true)
    frameRequiredWindows.removeAll(keepingCapacity: true)
    topologyObservedWindows.removeAll(keepingCapacity: true)
    frameObservedWindows.removeAll(keepingCapacity: true)
    frameNotificationsEnabled = true
    suppressedFrameProcessIDs.removeAll(keepingCapacity: true)
    suppressedFrameRequiresFullSnapshot = false
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
            guard monitor.frameNotificationsEnabled else {
              monitor.recordSuppressedFrameNotification(
                processID: normalizedProcessID
              )
              return
            }
            monitor.windowEventHandler(.frame, normalizedProcessID, element)
          case kAXUIElementDestroyedNotification:
            monitor.windowEventHandler(.windows, normalizedProcessID, element)
          case kAXWindowCreatedNotification:
            monitor.handler(.windowCreated, normalizedProcessID)
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
      processID: processID,
      kind: .applicationTopology,
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
    processID: pid_t,
    kind: NotificationObservationKind,
    element: AXUIElement,
    notifications: [String]
  ) -> Bool {
    let context = Unmanaged.passUnretained(self).toOpaque()
    let registered = registerNotificationBatch(
      notifications: notifications,
      add: { notification in
        AXObserverAddNotification(
          observer,
          element,
          notification as CFString,
          context
        )
      },
      remove: { notification in
        AXObserverRemoveNotification(
          observer,
          element,
          notification as CFString
        )
      }
    )
    if !registered {
      notificationObservationFailureCounts = updatedNotificationObservationFailureCounts(
        notificationObservationFailureCounts,
        activeProcessIDs: Set(observers.keys),
        failedProcessID: processID,
        kind: kind
      )
    }
    return registered
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
    for token in sessionTokens {
      center.removeObserver(token)
    }
    sessionTokens.removeAll()
    for token in screenTokens {
      NotificationCenter.default.removeObserver(token)
    }
    screenTokens.removeAll()
    if let mouseMonitor {
      NSEvent.removeMonitor(mouseMonitor)
      self.mouseMonitor = nil
    }
    resetAccessibilityObservers()
  }
}
