import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
extension MacOSPlatform {

  public func requestWindowTopologyRefresh(
    processID: pid_t,
    inputTimestamp: TimeInterval? = nil
  ) {
    invalidatePreparedAXWindowAttributes()
    windowTopologyEventPending = true
    pendingWindowTopologyProcessIDs.insert(processID)
    if let inputTimestamp {
      pendingWindowTopologyInputTimestamp = max(
        pendingWindowTopologyInputTimestamp ?? inputTimestamp,
        inputTimestamp
      )
    }
  }

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
    desktopSessionHandler: @escaping (Bool) -> Void = { _ in },
    displayConfigurationHandler: @escaping () -> Void = {},
    mouseGestureStartedHandler: @escaping () -> Void = {},
    mouseGestureHandler: @escaping () -> Void = {}
  ) {
    guard eventMonitor == nil else { return }
    let monitor = PlatformEventMonitor(
      handler: { [weak self] kind, processID in
        let eventInput = self?.userInputTracker.snapshot
        let eventInputTimestamp = eventInput?.latestEventTimestamp
        let previousWindowCount = processID.flatMap {
          self?.applicationWindowCounts[$0]
        }
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
          if kind == .windowCreated || kind == .windows || kind == .application
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
          self?.mouseFocusReleaseEventGeneration =
            self?.nativeFocusEventGeneration
        }
        if kind == .focus {
          if let self {
            self.nativeFocusEventGeneration &+= 1
          }
          self?.verifiedNativeFocusedWindowID = nil
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
          for delay in [50, 150, 350, 700, 1_200, 2_000, 3_500, 5_500, 8_000, 12_000] {
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
        if let processID, let previousWindowCount {
          for delay in windowTopologyRefreshDelays(
            for: kind,
            latestInputTimestamp: eventInputTimestamp,
            latestCloseIntentTimestamp: eventInput?.latestCloseIntent ?? 0,
            now: ProcessInfo.processInfo.systemUptime
          ) {
            DispatchQueue.main.asyncAfter(
              deadline: .now() + .milliseconds(delay)
            ) { [weak self] in
              guard let self,
                self.applicationWindowCounts[processID] == previousWindowCount
              else { return }
              self.requestWindowTopologyRefresh(
                processID: processID,
                inputTimestamp: eventInputTimestamp
              )
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
      desktopSessionHandler: { change in
        desktopSessionHandler(change == .becameActive)
      },
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
        self.snapshotEngine.recordExplicitlyDestroyedWindow(windowID)
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
      let stacking = await copyWindowBorderStackingOffMain(
        targetWindowID: request.windowID,
        targetProcessID: targetProcessID,
        targetFrame: targetFrame,
        monitorFrames: monitorFrames,
        knownWindowIDs: knownWindowIDs
      )
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
    borderFrames = frames.filter {
      !nativeFullscreenWindowIDs.contains($0.windowID)
    }
    borderSelectedWindowID = selectedWindowID.flatMap {
      nativeFullscreenWindowIDs.contains($0) ? nil : $0
    }
    borderHiddenWindowIDs = lastHiddenWindowIDs
    borderLiveWindowID = liveWindowID
    borderStyle = WindowBorderStyle(config: config)
    refreshWindowBorders()
    if let ownedWindowID = borderManager.ownedSurfaceWindowID
    {
      borderBoundsProvider.probe(ownedWindowID: ownedWindowID)
    }
    scheduleWindowBorderStackingRefresh()
    revealWindowBordersIfReady()
  }

  public func stageWindowBorderSelection(_ selectedWindowID: WindowID?) {
    let selectedWindowID = selectedWindowID.flatMap {
      nativeFullscreenWindowIDs.contains($0) ? nil : $0
    }
    desiredSelectedWindowID = selectedWindowID
    frameCoordinator.updateLiveBorderWindowID(selectedWindowID)
    let selectedFrame = selectedWindowID.flatMap { windowID in
      resolvedBorderFrame(for: windowID)
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
        nativeFocusedWindowID:
          verifiedNativeFocusedWindowID ?? lastNativeFocusedWindowID
      )
    else { return }
    borderManager.revealPendingBorders()
  }

  private func activeIsMinimizedOrHidden(_ windowID: WindowID) -> Bool {
    if lastHiddenWindowIDs.contains(windowID)
      || nativeFullscreenWindowIDs.contains(windowID)
    {
      return true
    }
    guard let element = elements[windowID] else {
      return false
    }
    for minimized in minimizedWindowElementsByProcess.values {
      if minimized.contains(where: { CFEqual($0, element) }) {
        return true
      }
    }
    return false
  }

  public func refreshWindowBorders() {
    // A selected window that is no longer on screen (minimized, hidden, or
    // parked) must never keep an overlay drawn over whatever is displayed.
    if let active = borderManager.activeWindowID,
      !borderFrames.contains(where: { $0.windowID == active })
        || activeIsMinimizedOrHidden(active)
    {
      hideWindowBorders()
      return
    }
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
    let borderGeometryIsSettling = borderRefreshBlockedBySettling(
      liveWindowIDs: liveGeometryWindowIDs,
      expectations: frameCommitExpectations,
      now: ProcessInfo.processInfo.systemUptime
    )
    if borderGeometryIsSettling {
      // Writes are still settling. Keep following displayed frames without
      // replanning: if an application stops confirming its frame commits,
      // overlays must converge on the real window instead of freezing at a
      // mid-transition geometry.
      refreshWindowBorderGeometry(windowIDs: liveGeometryWindowIDs)
      return
    }
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
    guard
      let frame = frame(of: element) ?? resolvedBorderFrame(for: windowID)
    else {
      return
    }
    latestObservedFrames[windowID] = frame
    if borderManager.updateGeometry(
      frames: [windowID: frame],
      style: borderStyle
    ) {
      invalidatePointerHitTestCache()
    }
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

  public func setWindowBordersSuppressed(_ suppressed: Bool) {
    guard borderManager.isSuppressed != suppressed else { return }
    borderManager.setSuppressed(suppressed)
    if suppressed {
      borderStackingRefreshTask?.cancel()
      return
    }
    stageWindowBorderSelection(borderSelectedWindowID)
    refreshWindowBorders()
    scheduleWindowBorderStackingRefresh()
    revealWindowBordersIfReady()
  }

  public func updateNativeFullscreenPlaceholders(
    _ placeholders: [NativeFullscreenPlaceholder],
    selectedWindowID: WindowID?,
    stackingWindowID: WindowID?
  ) {
    if nativeFullscreenPlaceholderManager.sync(
      placeholders,
      selectedWindowID: selectedWindowID,
      stackingWindowID: stackingWindowID,
      suppressedWindowIDs: activeNativeFullscreenWindowIDs,
      accentColor: borderStyle.activeColor
    ) {
      invalidatePointerHitTestCache()
    }
  }

  public func hideNativeFullscreenPlaceholders() {
    nativeFullscreenPlaceholderManager.hide()
    invalidatePointerHitTestCache()
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
    let suppressedRefresh = eventMonitor?.setFrameNotificationsEnabled(enabled)
    guard enabled else { return }
    invalidatePreparedAXWindowAttributes()
    // Notifications were ignored while animated writes ran. Force fresh reads
    // before trusting the final committed frames.
    let committedWindowIDs = Set(frameCommitExpectations.keys)
    observedFrameEventWindowIDs.formUnion(committedWindowIDs)
    let committedProcessIDs = Set(committedWindowIDs.compactMap { processIDs[$0] })
    frameEventPending = true
    pendingFrameProcessIDs.formUnion(
      committedProcessIDs.isEmpty ? lastSnapshotProcessIDs : committedProcessIDs
    )
    if let suppressedRefresh {
      pendingFrameProcessIDs.formUnion(suppressedRefresh.processIDs)
      pendingFrameRequiresFullSnapshot =
        pendingFrameRequiresFullSnapshot
        || suppressedRefresh.requiresFullSnapshot
    }
  }

  public var isLeftMouseButtonDown: Bool {
    CGEventSource.buttonState(.combinedSessionState, button: .left)
  }

}

@concurrent
private func copyWindowBorderStackingOffMain(
  targetWindowID: WindowID,
  targetProcessID: pid_t?,
  targetFrame: Rect?,
  monitorFrames: [Rect],
  knownWindowIDs: Set<WindowID>
) async -> WindowBorderStacking {
  copyWindowBorderStacking(
    targetWindowID: targetWindowID,
    targetProcessID: targetProcessID,
    targetFrame: targetFrame,
    monitorFrames: monitorFrames,
    knownWindowIDs: knownWindowIDs
  )
}
