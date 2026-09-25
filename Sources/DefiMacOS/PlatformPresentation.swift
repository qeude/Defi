import AppKit
import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime

/// A non-authoritative projection of UI effects and observer coverage.
struct PlatformPresentationStatus: Sendable {
  var windowIDStatus = "unprobed"
  var boundsAvailable = false
  var boundsSuccesses = 0
  var boundsFallbacks = 0
  var constraintsAvailable = false
  var constraintsSuccesses = 0
  var constraintsFallbacks = 0
  var topologyReliable = false
  var framesReliable = false
  var lifecycleReliable = false
  var uncoveredTopologyProcesses = Set<pid_t>()
  var incompatibleProcesses = Set<pid_t>()
  var failures: NotificationObservationFailureCounts = [:]
  var failureCodes: [NotificationObservationKind: [pid_t: [Int32]]] = [:]
  var coverage = (applicationObservers: 0, applications: 0, topologyWindows: 0,
    requiredTopologyWindows: 0, frameWindows: 0, requiredFrameWindows: 0)
  var frontmostProcessID: pid_t?
  var reduceMotion = false
  var borders = WindowBorderPerformance(
    allocated: 0, visible: 0, dormant: 0, activeOpacity: 0, estimatedSurfacePixels: 0,
    appliedPlans: 0, skippedPlans: 0, geometryUpdates: 0, captureEnabled: false
  )
}

extension MacOSPlatform {
  public var frontmostProcessID: pid_t? { presentationStatus.frontmostProcessID }
  public var reduceMotion: Bool { presentationStatus.reduceMotion }
  nonisolated func enqueuePresentation(
    _ effect: @escaping @MainActor @Sendable (MacOSPlatform) -> Void
  ) {
    DispatchQueue.main.async { [self] in
      effect(self)
      publishPresentationStatus()
    }
  }

  @MainActor func publishPresentationStatus() {
    guard !presentationStatusPending else { return }
    presentationStatusPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
      presentationStatusPending = false
      collectPresentationStatus()
    }
  }

  @MainActor private func collectPresentationStatus() {
    let failures = eventMonitor?.notificationObservationFailureCountsValue ?? [:]
    var failureCodes: [NotificationObservationKind: [pid_t: [Int32]]] = [:]
    for (kind, processes) in failures {
      for processID in processes.keys {
        failureCodes[kind, default: [:]][processID] =
          eventMonitor?.notificationObservationErrors(kind: kind, processID: processID) ?? []
      }
    }
    let status = PlatformPresentationStatus(
      windowIDStatus: windowIDProvider.probeResult.map(String.init) ?? "unprobed",
      boundsAvailable: borderBoundsProvider.isAvailable,
      boundsSuccesses: borderBoundsProvider.successfulLookupCount,
      boundsFallbacks: borderBoundsProvider.failureCount,
      constraintsAvailable: borderBoundsProvider.constraintsAreAvailable,
      constraintsSuccesses: borderBoundsProvider.successfulConstraintLookupCount,
      constraintsFallbacks: borderBoundsProvider.constraintFallbackCount,
      topologyReliable: eventMonitor?.hasReliableWindowTopologyCoverage(for: Set(applications.keys)) == true,
      framesReliable: eventMonitor?.hasReliableFrameCoverage() == true,
      lifecycleReliable: eventMonitor?.hasReliableApplicationLifecycleObservation == true,
      uncoveredTopologyProcesses: eventMonitor?.processIDsWithoutReliableTopologyCoverage(activeProcessIDs: Set(applications.keys)) ?? [],
      incompatibleProcesses: eventMonitor?.incompatibleNotificationProcessIDs ?? [],
      failures: failures,
      failureCodes: failureCodes,
      coverage: eventMonitor?.observationCoverage ?? (0, 0, 0, 0, 0, 0),
      frontmostProcessID: currentFrontmostProcessID(),
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      borders: borderManager.performance
    )
    NavigationActor.enqueue { [self] in presentationStatus = status }
  }

  @MainActor func invalidatePointerCacheFromPresentation() {
    NavigationActor.enqueue { [self] in invalidatePointerHitTestCache() }
  }

  func scheduleWindowBorderStackingRefresh(reusingSnapshot: Bool = false) {
    enqueuePresentation { $0.presentScheduleWindowBorderStackingRefresh(reusingSnapshot: reusingSnapshot) }
  }

  func revealWindowBordersIfReady() {
    enqueuePresentation { $0.presentRevealWindowBordersIfReady() }
  }

  public func startObserving(
    _ handler: @escaping @NavigationActor @Sendable () -> Void,
    desktopSessionHandler: @escaping @NavigationActor @Sendable (Bool) -> Void = { _ in },
    displayConfigurationHandler: @escaping @NavigationActor @Sendable () -> Void = {},
    mouseGestureStartedHandler: @escaping @NavigationActor @Sendable () -> Void = {},
    mouseGestureHandler: @escaping @NavigationActor @Sendable () -> Void = {}
  ) {
    enqueuePresentation {
      $0.presentStartObserving(handler, desktopSessionHandler: desktopSessionHandler,
        displayConfigurationHandler: displayConfigurationHandler,
        mouseGestureStartedHandler: mouseGestureStartedHandler, mouseGestureHandler: mouseGestureHandler)
    }
  }

  public func invalidateInputAfterEventTapReenabled(at timestamp: TimeInterval) {
    userInputTracker.invalidate(at: timestamp)
    pointerMotionTracker.invalidate(at: timestamp)
    invalidatePointerHitTestCache()
    enqueuePresentation { $0.presentInvalidateInputAfterEventTapReenabled(at: timestamp) }
  }

  public func updateWindowBorders(frames: [FrameAssignment], selectedWindowID: WindowID?,
    liveWindowID: WindowID?, config: BordersConfig) {
    plannedBorderFrames = frames
    enqueuePresentation {
      $0.presentUpdateWindowBorders(frames: frames, selectedWindowID: selectedWindowID,
        liveWindowID: liveWindowID, config: config)
    }
  }

  public func stageWindowBorderSelection(_ windowID: WindowID?) {
    desiredSelectedWindowID = windowID
    frameCoordinator.updateLiveBorderWindowID(windowID)
    enqueuePresentation { $0.presentStageWindowBorderSelection(windowID) }
  }

  public func commitWindowBorderSelection(_ windowID: WindowID?) {
    desiredSelectedWindowID = windowID
    frameCoordinator.updateLiveBorderWindowID(windowID)
    enqueuePresentation { $0.presentCommitWindowBorderSelection(windowID) }
  }

  public func refreshWindowBorders() { enqueuePresentation { $0.presentRefreshWindowBorders() } }
  public func hideWindowBorders() { enqueuePresentation { $0.presentHideWindowBorders() } }
  public func setWindowBordersSuppressed(_ suppressed: Bool) {
    enqueuePresentation { $0.presentSetWindowBordersSuppressed(suppressed) }
  }
  public func updateNativeFullscreenPlaceholders(_ placeholders: [NativeFullscreenPlaceholder],
    selectedWindowID: WindowID?, stackingWindowID: WindowID?) {
    enqueuePresentation {
      $0.presentUpdateNativeFullscreenPlaceholders(placeholders, selectedWindowID: selectedWindowID,
        stackingWindowID: stackingWindowID)
    }
  }
  public func hideNativeFullscreenPlaceholders() {
    enqueuePresentation { $0.presentHideNativeFullscreenPlaceholders() }
  }
  public var windowBorderPerformance: WindowBorderPerformance { presentationStatus.borders }

  public func setFrameNotificationsEnabled(_ enabled: Bool) {
    enqueuePresentation { $0.presentSetFrameNotificationsEnabled(enabled) }
  }
}
