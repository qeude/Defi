import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
extension MacOSPlatform {

  public func invalidateInputAfterEventTapReenabled(
    at timestamp: TimeInterval
  ) {
    userInputTracker.invalidate(at: timestamp)
    pointerMotionTracker.invalidate(at: timestamp)
    invalidatePointerHitTestCache()
    if eventMonitor?.resetMouseGestureState() == true {
      mouseFocusReleasePending = true
    }
  }

  public func startObserving(
    _ handler: @escaping () -> Void,
    displayConfigurationHandler: @escaping () -> Void = {},
    mouseGestureStartedHandler: @escaping () -> Void = {},
    mouseGestureHandler: @escaping () -> Void = {}
  ) {
    guard eventMonitor == nil else { return }
    let monitor = PlatformEventMonitor(
      handler: { [weak self] kind, processID in
        self?.invalidatePreparedAXWindowAttributes()
        if let self {
          pendingWindowTopologyInputTimestamp =
            updatedWindowTopologyInputTimestamp(
              for: kind,
              latestInputTimestamp: userInputTracker.latestEventTimestamp,
              previousTimestamp: pendingWindowTopologyInputTimestamp
            )
        }
        switch windowSnapshotInvalidation(for: kind, processID: processID) {
        case .process(let processID):
          self?.windowTopologyEventPending = true
          self?.pendingWindowTopologyProcessIDs.insert(processID)
          self?.frameCoordinator.recordTrace(
            "window-event kind=\(String(describing: kind)) pid=\(processID)"
          )
        case .full:
          if kind == .windows || kind == .application
            || kind == .applicationTerminated
          {
            self?.windowTopologyEventPending = true
          }
          self?.windowTopologyRequiresFullSnapshot = true
        case .none:
          break
        }
        if kind == .frame || kind == .mouse {
          self?.frameEventPending = true
        }
        if kind == .frame {
          if let processID {
            self?.pendingFrameProcessIDs.insert(processID)
          } else {
            self?.pendingFrameRequiresFullSnapshot = true
          }
        }
        if kind == .mouse {
          self?.mouseResizeGesturePending = true
          if let self,
            let processID = mouseGestureRefreshProcessID(
              latestFocusIntent: userInputTracker.snapshot.latestFocusIntent,
              focusedWindowID: lastNativeFocusedWindowID,
              processIDs: processIDs
            )
          {
            pendingFrameProcessIDs.insert(processID)
          } else {
            self?.pendingFrameRequiresFullSnapshot = true
          }
          if self?.isLeftMouseButtonDown == true {
            self?.frameCoordinator.suspendInitialSettlementRepairs()
          }
        }
        if kind == .mouseRelease {
          self?.mouseFocusReleasePending = true
        }
        if kind == .focus {
          self?.lastNativeFocusedWindowID = nativeFocusedWindowIDAfterEvent(
            kind,
            cachedWindowID: self?.lastNativeFocusedWindowID
          )
          self?.userInputTracker.recordObservedFocus(
            windowID: nil,
            processID: processID
              ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
          )
          self?.nativeFocusEventPending = true
          if let processID {
            self?.nativeFocusEventProcessIDs.insert(processID)
          } else {
            self?.nativeFocusEventHasUnknownProcess = true
          }
          for delay in [50, 150, 350] {
            DispatchQueue.main.asyncAfter(
              deadline: .now() + .milliseconds(delay)
            ) { [weak self] in
              guard self?.nativeFocusEventPending == true else { return }
              handler()
            }
          }
        }
        let lifecycleRefreshDelays = applicationLifecycleRefreshDelays(for: kind)
        if !lifecycleRefreshDelays.isEmpty {
          for delay in lifecycleRefreshDelays {
            DispatchQueue.main.asyncAfter(
              deadline: .now() + .milliseconds(delay)
            ) { [weak self] in
              guard let self else { return }
              self.invalidatePreparedAXWindowAttributes()
              self.windowTopologyEventPending = true
              self.windowTopologyRequiresFullSnapshot = true
              handler()
            }
          }
        }
        if kind == .screens {
          displayConfigurationHandler()
        }
        if platformEventCancelsMouseAnimation(kind) {
          mouseGestureHandler()
        }
        handler()
      },
      userInputTracker: userInputTracker,
      frameHandler: { [weak self] element in
        guard let self else { return }
        self.refreshWindowBorderGeometry(for: element)
        if let windowID = self.elements.first(where: {
          CFEqual($0.value, element)
        })?.key {
          self.observedFrameEventWindowIDs.insert(windowID)
          self.frameCoordinator.requestInitialSettlementVerification(
            windowID: windowID
          )
        }
      },
      liveFrameHandler: { [weak self] in
        guard let self else { return }
        self.refreshWindowBorderGeometry(
          windowIDs: self.borderManager.liveGeometryWindowIDs
        )
      },
      borderStackingHandler: { [weak self] in
        self?.scheduleWindowBorderStackingRefresh()
      },
      mouseGestureStartedHandler: mouseGestureStartedHandler,
      windowDestroyedHandler: { [weak self] element in
        guard let self,
          let windowID = self.elements.first(where: {
            CFEqual($0.value, element)
          })?.key
        else {
          return
        }
        self.explicitlyDestroyedWindowIDs.insert(windowID)
      }
    )
    monitor.start()
    eventMonitor = monitor
    let windowsByProcess = Dictionary(
      grouping:
        elements
        .compactMap { windowID, element in
          processIDs[windowID].map { ($0, element) }
        },
      by: \.0
    ).mapValues { $0.map(\.1) }
    monitor.refresh(applications: windowsByProcess)
  }

  func scheduleWindowBorderStackingRefresh() {
    let request = borderStackingRefreshState.request(
      for: borderManager.activeWindowID
    )
    borderStackingRefreshTask?.cancel()
    guard let request else { return }
    borderStackingRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while frameCoordinator.isBusy(for: request.windowID) {
        try? await Task.sleep(for: .milliseconds(4))
        guard !Task.isCancelled else { return }
      }
      let monitorFrames = lastMonitorFrames
      let knownWindowIDs = Set(elements.keys)
      let targetProcessID = processIDs[request.windowID]
      let targetFrame: Rect? = {
        guard
          let point = frameCoordinator.completedPosition(for: request.windowID),
          let size = frameCoordinator.completedSize(for: request.windowID)
        else {
          return nil
        }
        return Rect(
          x: point.x,
          y: point.y,
          width: size.width,
          height: size.height
        )
      }()
        ?? borderFrames.first(where: { $0.windowID == request.windowID })?.frame
        ?? latestObservedFrames[request.windowID]
      let stacking = await Task.detached(priority: .utility) {
        copyWindowBorderStacking(
          targetWindowID: request.windowID,
          targetProcessID: targetProcessID,
          targetFrame: targetFrame,
          monitorFrames: monitorFrames,
          knownWindowIDs: knownWindowIDs
        )
      }.value
      guard !Task.isCancelled else { return }
      refreshWindowBorderStacking(request, stacking: stacking)
    }
  }

  private func refreshWindowBorderStacking(
    _ request: WindowBorderStackingRefreshRequest,
    stacking: WindowBorderStacking
  ) {
    guard
      borderStackingRefreshState.shouldApply(
        request,
        activeWindowID: borderManager.activeWindowID
      )
    else {
      return
    }
    windowBorderStacking = stacking
    borderManager.updateActiveStacking(
      for: request.windowID,
      stacking: stacking
    )
    revealWindowBordersIfReady()
  }

  public func updateWindowBorders(
    frames: [FrameAssignment],
    selectedWindowID: WindowID?,
    liveWindowID: WindowID?,
    config: BordersConfig
  ) {
    borderFrames = frames
    borderSelectedWindowID = selectedWindowID
    borderHiddenWindowIDs = lastHiddenWindowIDs
    borderLiveWindowID = liveWindowID
    borderStyle = WindowBorderStyle(
      enabled: config.enabled,
      width: config.width,
      activeColor: parseBorderColor(config.color) ?? 0xffc0_99ff,
      inactiveEnabled: config.inactiveEnabled,
      inactiveColor: parseBorderColor(config.inactiveColor) ?? 0x66c0_99ff,
      captureEnabled: config.captureEnabled
    )
    refreshWindowBorders()
    if !screenCaptureAccessAvailable,
      let ownedWindowID = borderManager.ownedSurfaceWindowID
    {
      borderBoundsProvider.probe(ownedWindowID: ownedWindowID)
    }
    scheduleWindowBorderStackingRefresh()
    revealWindowBordersIfReady()
  }

  public func stageWindowBorderSelection(
    _ selectedWindowID: WindowID?,
    displayedFrame: Rect? = nil
  ) {
    desiredSelectedWindowID = selectedWindowID
    let selectedFrame = selectedWindowID.flatMap { windowID in
      displayedFrame ?? resolvedBorderFrame(for: windowID)
    }
    borderManager.prepareForSelection(
      selectedWindowID,
      displayedFrame: selectedFrame
    )
  }

  public func commitWindowBorderSelection(_ selectedWindowID: WindowID?) {
    stageWindowBorderSelection(selectedWindowID)
    refreshWindowBorderGeometry(
      windowIDs: borderManager.liveGeometryWindowIDs
    )
    scheduleWindowBorderStackingRefresh()
  }

  func revealWindowBordersIfReady() {
    guard
      windowBorderStackingIsReadyForReveal(
        windowBorderStacking,
        selectedWindowID: desiredSelectedWindowID,
        activeWindowID: borderManager.activeWindowID,
        nativeFocusedWindowID: lastNativeFocusedWindowID
      )
    else { return }
    borderManager.revealPendingBorders()
  }

  public func refreshWindowBorders() {
    let liveGeometryWindowIDs = borderManager.liveGeometryWindowIDs
    if isLeftMouseButtonDown {
      refreshWindowBorderGeometry(windowIDs: liveGeometryWindowIDs)
      return
    }
    if frameCoordinator.isBusy {
      let displayedFrames: [WindowID: Rect] = Dictionary(
        uniqueKeysWithValues: liveGeometryWindowIDs.compactMap { windowID in
          guard let assignment = borderFrames.first(where: {
            $0.windowID == windowID
          }) else { return nil }
          return (
            windowID,
            displayedBorderFrame(for: assignment, nativeFrame: nil)
          )
        }
      )
      borderManager.updateGeometry(frames: displayedFrames, style: borderStyle)
      return
    }
    let borderGeometryIsSettling = liveGeometryWindowIDs.contains { windowID in
      guard let expectation = frameCommitExpectations[windowID] else {
        return false
      }
      return expectation.observedAt == nil
    }
    guard !borderGeometryIsSettling else { return }
    let plan = planWindowBorders(
      frames: borderFrames,
      selectedWindowID: borderSelectedWindowID,
      hiddenWindowIDs: borderHiddenWindowIDs,
      monitorFrames: lastMonitorFrames,
      style: borderStyle
    )
    let planWindowIDs = Set(plan.tracked.map(\.windowID))
    let retainedLiveWindowIDs =
      liveGeometryWindowIDs
      .subtracting(planWindowIDs)
    let retainedLiveFrames = borderFrames.filter {
      retainedLiveWindowIDs.contains($0.windowID)
    }
    let relevantFrames =
      plan.tracked.map {
        FrameAssignment(windowID: $0.windowID, frame: $0.frame)
      } + retainedLiveFrames
    let nativeFrames = windowBorderFrameSnapshot(
      windowIDs: Set(relevantFrames.map(\.windowID)),
      frameProvider: borderBoundsProvider.frame
    )
    let displayedFrames = Dictionary(
      uniqueKeysWithValues: relevantFrames.map { assignment in
        (
          assignment.windowID,
          displayedBorderFrame(
            for: assignment,
            nativeFrame: nativeFrames[assignment.windowID]
          )
        )
      }
    )
    borderManager.sync(
      plan,
      displayedFrames: displayedFrames,
      stacking: resolvedWindowBorderStacking(for: plan.active?.windowID)
    )
    let finalDisplayedFrames: [WindowID: Rect] = Dictionary(
      uniqueKeysWithValues: borderManager.liveGeometryWindowIDs.compactMap { windowID in
        guard
          let fallback = displayedFrames[windowID]
            ?? relevantFrames.first(where: { $0.windowID == windowID })?.frame
        else {
          return nil
        }
        return (
          windowID,
          nativeFrames[windowID] ?? fallback
        )
      }
    )
    borderManager.updateGeometry(
      frames: finalDisplayedFrames,
      style: borderStyle
    )
  }

  private func resolvedWindowBorderStacking(
    for targetWindowID: WindowID?
  ) -> WindowBorderStacking {
    windowBorderStacking.targetWindowID == targetWindowID
      ? windowBorderStacking
      : .inactive(for: targetWindowID)
  }

  private func refreshWindowBorderGeometry(for element: AXUIElement) {
    guard
      let windowID = elements.first(where: { CFEqual($0.value, element) })?.key,
      borderManager.liveGeometryWindowIDs.contains(windowID)
    else {
      return
    }
    refreshWindowBorderGeometry(windowIDs: [windowID])
  }

  private func refreshWindowBorderGeometry(
    windowIDs: Set<WindowID>
  ) {
    guard !windowIDs.isEmpty else { return }
    let frames = Dictionary(
      uniqueKeysWithValues: windowIDs.compactMap { windowID in
        resolvedBorderFrame(for: windowID).map { (windowID, $0) }
      }
    )
    guard !frames.isEmpty else {
      return
    }
    let geometryChanged = borderManager.updateGeometry(
      frames: frames,
      style: borderStyle
    )
    if geometryChanged {
      invalidatePointerHitTestCache()
    }
  }

  public func hideWindowBorders() {
    borderManager.hide()
  }

  public var windowBorderPerformance: WindowBorderPerformance {
    borderManager.performance
  }

  private func displayedBorderFrame(
    for assignment: FrameAssignment,
    nativeFrame: Rect?
  ) -> Rect {
    if let nativeFrame {
      return nativeFrame
    }
    if assignment.windowID == borderLiveWindowID,
      let observed = latestObservedFrames[assignment.windowID]
    {
      return observed
    }
    let point = frameCoordinator.completedPosition(for: assignment.windowID)
    let size = frameCoordinator.completedSize(for: assignment.windowID)
    if point == nil, size == nil, frameCoordinator.isBusy,
      let observed = latestObservedFrames[assignment.windowID]
    {
      return observed
    }
    return Rect(
      x: point.map { Double($0.x) } ?? assignment.frame.x,
      y: point.map { Double($0.y) } ?? assignment.frame.y,
      width: size.map { Double($0.width) } ?? assignment.frame.width,
      height: size.map { Double($0.height) } ?? assignment.frame.height
    )
  }

  private func resolvedBorderFrame(for windowID: WindowID) -> Rect? {
    resolvedWindowBorderFrame(
      nativeFrame: borderBoundsProvider.frame(for: windowID),
      observedFrame: latestObservedFrames[windowID],
      plannedFrame: borderFrames.first(where: { $0.windowID == windowID })?.frame
    )
  }

  public func setFrameNotificationsEnabled(_ enabled: Bool) {
    eventMonitor?.setFrameNotificationsEnabled(enabled)
    guard enabled else { return }
    invalidatePreparedAXWindowAttributes()
    // Notifications were ignored while animated writes ran. Force fresh reads
    // before trusting the final committed frames.
    frameEventPending = true
    pendingFrameProcessIDs.formUnion(lastSnapshotProcessIDs)
  }

  public var isLeftMouseButtonDown: Bool {
    CGEventSource.buttonState(.combinedSessionState, button: .left)
  }

}
