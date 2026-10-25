import DefiRuntime
import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
extension MacOSPlatform {

  nonisolated public func requestWindowTopologyRefresh(
    processID: pid_t,
    inputTimestamp: TimeInterval? = nil
  ) {
    snapshotEngine.recordObservation(
      .windows,
      processID: processID,
      inputTimestamp: inputTimestamp
    )
  }

  public func presentInvalidateInputAfterEventTapReenabled(
    at timestamp: TimeInterval
  ) {
    invalidatePointerCacheFromPresentation()
    if eventMonitor?.resetMouseGestureState() == true {
      mouseFocusReleasePending = true
    }
  }

  public func presentStartObserving(
    _ handler: @escaping @NavigationActor @Sendable () -> Void,
    desktopSessionHandler: @escaping @NavigationActor @Sendable (Bool) -> Void = { _ in },
    displayConfigurationHandler: @escaping @NavigationActor @Sendable () -> Void = {},
    mouseGestureStartedHandler: @escaping @NavigationActor @Sendable () -> Void = {},
    mouseGestureHandler: @escaping @NavigationActor @Sendable () -> Void = {}
  ) {
    guard eventMonitor == nil else { return }
    if observationMeasurementAccess == nil {
    accessibilityDisplayObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.publishPresentationStatus() }
    }
    }
    let handleEvent: (PlatformEventKind, pid_t?, AXUIElement?) -> Void = {
      [weak self] kind, processID, element in
      let processID = positiveProcessID(processID)
      defer { if self?.observationMeasurementAccess == nil { self?.publishPresentationStatus() } }
      let eventInput = self?.userInputTracker.snapshot
      let eventInputTimestamp = eventInput?.latestEventTimestamp
      let previousWindowCount = processID.flatMap {
        self?.applicationWindowCounts[$0]
      }
      let windowID = element.flatMap { element in
        self?.elements.first(where: { CFEqual($0.value, element) })?.key
      }
      let refreshProcessID =
        kind == .mouse || kind == .mouseRelease
        ? self.flatMap {
          mouseGestureRefreshProcessID(
            latestFocusIntent: $0.userInputTracker.snapshot.latestFocusIntent,
            focusedWindowID: $0.lastNativeFocusedWindowID,
            processIDs: $0.processIDs
          )
        }
        : processID
      self?.snapshotEngine.recordObservation(
        kind,
        processID: refreshProcessID,
        windowID: windowID,
        createdElement: kind == .windowCreated ? element : nil,
        inputTimestamp: eventInputTimestamp
      )
      if kind == .windowCreated || kind == .windows, let processID {
        self?.frameCoordinator.recordTrace(
          "window-event kind=\(String(describing: kind)) pid=\(processID)"
        )
      }
      if kind == .frame {
        if let windowID {
          self?.enqueueBorderGeometry([windowID], requiresNativeRead: true)
          self?.frameCoordinator.requestInitialSettlementVerification(windowID: windowID)
        }
      }
      if kind == .mouse {
        self?.mouseFocusReleaseEventGeneration = nil
        self?.mouseResizeGesturePending = true
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
        )
        self?.nativeFocusEventPending = true
        self?.nativeFocusEventTimestamp = ProcessInfo.processInfo.systemUptime
        self?.borderStackingSettle.trigger()
        if let processID {
          self?.nativeFocusEventProcessIDs.insert(processID)
        } else {
          self?.nativeFocusEventHasUnknownProcess = true
        }
        if let self {
          self.delayedObservationCampaigns.merge(
            lane: .focus,
            delays: [50, 150, 350, 700, 1_200, 2_000, 3_500, 5_500, 8_000, 12_000],
            platform: self
          ) { [weak self] _, generation in
            guard let self, self.nativeFocusEventPending else { return }
            let engine = self.snapshotEngine
            let focusGeneration = engine.nativeFocusEventGeneration
            let campaigns = self.delayedObservationCampaigns
            self.deliverObservation {
              guard engine.nativeFocusEventPending,
                engine.nativeFocusEventGeneration == focusGeneration,
                campaigns.isCurrent(.focus, generation: generation)
              else { return }
              handler()
            }
          }
        }
      }
      let lifecycleRefreshDelays = applicationLifecycleRefreshDelays(for: kind)
      if !lifecycleRefreshDelays.isEmpty, let self {
        let lane = ObservationRetryLane.lifecycle(processID)
        self.delayedObservationCampaigns.merge(
          lane: lane, delays: lifecycleRefreshDelays, platform: self
        ) { [weak self] _, generation in
          guard let self else { return }
          if case .process(let processID) = applicationLifecycleRetryInvalidation(
            for: kind, processID: processID,
            knownWindowCount: processID.flatMap { self.applicationWindowCounts[$0] }
          ) {
            self.snapshotEngine.recordObservation(.windows, processID: processID)
          } else {
            self.invalidateWindowSnapshot()
            self.snapshotEngine.recordObservation(.windows, processID: nil)
          }
          let campaigns = self.delayedObservationCampaigns
          self.deliverObservation {
            guard campaigns.isCurrent(lane, generation: generation) else { return }
            handler()
          }
        }
      }
      if let processID, let previousWindowCount, let self,
        !windowTopologyRefreshDelays(for: kind).isEmpty
      {
        let lane = ObservationRetryLane.creation(processID)
        self.delayedObservationCampaigns.merge(
          lane: lane, delays: windowTopologyRefreshDelays(for: kind), platform: self
        ) { [weak self] delay, generation in
          guard let self,
            delay == 50 || self.applicationWindowCounts[processID] == previousWindowCount
          else { return }
          self.requestWindowTopologyRefresh(processID: processID, inputTimestamp: eventInputTimestamp)
          let campaigns = self.delayedObservationCampaigns
          self.deliverObservation {
            guard campaigns.isCurrent(lane, generation: generation) else { return }
            handler()
          }
        }
      }
      if kind == .screens {
        NavigationActor.enqueue { displayConfigurationHandler() }
      }
      if platformEventCancelsMouseAnimation(kind) {
        NavigationActor.enqueue { mouseGestureHandler() }
      }
      self?.deliverObservation { handler() }
    }
    if let observationMeasurementAccess {
      observationMeasurementAccess.receive = handleEvent
      return
    }
    let monitor = makeEventMonitor(
      handler: { kind, processID in handleEvent(kind, processID, nil) },
      desktopSessionHandler: { change in
        NavigationActor.enqueue { desktopSessionHandler(change == .becameActive) }
      },
      windowEventHandler: { kind, processID, element in
        handleEvent(kind, processID, element)
      },
      mouseGestureStartedHandler: { NavigationActor.enqueue { mouseGestureStartedHandler() } }
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

  func presentScheduleWindowBorderStackingRefresh(reusingSnapshot: Bool = false) {
    if !reusingSnapshot { invalidateWindowSnapshot() }
    let request = borderStackingRefreshState.request(
      for: borderManager.activeWindowID
    )
    borderStackingRefreshTask?.cancel()
    guard let request else { return }
    borderStackingRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      // The window-list read below waits on a WindowServer transaction; during an overlay
      // motion that wait stalls the compositor, and the hidden border can wait for landing.
      while frameCoordinator.isBusy(for: request.windowID) || RibbonProxyStore.shared.isMoving {
        // A motion lasts hundreds of milliseconds: polling it at frame rate only wakes the main actor.
        try? await Task.sleep(for: .milliseconds(RibbonProxyStore.shared.isMoving ? 50 : 4))
        guard !Task.isCancelled else { return }
      }
      let monitorFrames = lastMonitorFrames
      let knownWindowIDs = Set(elements.keys)
      let targetProcessID = processIDs[request.windowID]
      let targetFrame: Rect? =
        {
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
      if reusingSnapshot, !frameCoordinator.isBusy,
        let inventory = snapshotEngine.borderStackingInventory(now: ProcessInfo.processInfo.systemUptime),
        let entries = windowBorderStackEntries(
          inventory: inventory, targetWindowID: request.windowID,
          targetProcessID: targetProcessID, targetFrame: targetFrame
        )
      {
        let stacking = DefiMacOS.windowBorderStacking(
          targetWindowID: request.windowID,
          ownProcessID: ProcessInfo.processInfo.processIdentifier,
          floatingLevel: NSWindow.Level.floating.rawValue, entries: entries,
          monitorFrames: monitorFrames, knownWindowIDs: knownWindowIDs
        )
        refreshWindowBorderStacking(request, stacking: stacking)
        return
      }
      // Off-main window-list reads contend with main-thread AppKit border geometry inside
      // SkyLight's CA transaction sync and stall the main thread and the ribbon ~0.5 s.
      let stacking = copyWindowBorderStacking(
        targetWindowID: request.windowID,
        targetProcessID: targetProcessID,
        targetFrame: targetFrame,
        monitorFrames: monitorFrames,
        knownWindowIDs: knownWindowIDs
      )
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
    presentRevealWindowBordersIfReady()
  }

  public func presentUpdateWindowBorders(
    frames: [FrameAssignment],
    selectedWindowID: WindowID?,
    liveWindowID: WindowID?,
    config: BordersConfig
  ) {
    borderFrames = frames.filter {
      !presentedNativeFullscreenWindowIDs.contains($0.windowID)
    }
    borderSelectedWindowID = selectedWindowID.flatMap {
      presentedNativeFullscreenWindowIDs.contains($0) ? nil : $0
    }
    borderHiddenWindowIDs = lastHiddenWindowIDs
    borderLiveWindowID = liveWindowID
    borderStyle = WindowBorderStyle(config: config)
    let style = borderStyle
    NavigationActor.enqueue { RibbonProxyPresenter.borderStyle = style }
    presentRefreshWindowBorders()
    if let ownedWindowID = borderManager.ownedSurfaceWindowID {
      borderBoundsProvider.probe(ownedWindowID: ownedWindowID)
    }
    syncWindowBorderSubscriptions()
    presentScheduleWindowBorderStackingRefresh(reusingSnapshot: true)
    presentRevealWindowBordersIfReady()
  }

  public func presentStageWindowBorderSelection(_ selectedWindowID: WindowID?) {
    let selectedWindowID = selectedWindowID.flatMap {
      presentedNativeFullscreenWindowIDs.contains($0) ? nil : $0
    }
    presentedSelectedWindowID = selectedWindowID
    frameCoordinator.updateLiveBorderWindowID(selectedWindowID)
    let selectedFrame = selectedWindowID.flatMap { windowID in
      resolvedBorderFrame(for: windowID)
    }
    borderManager.prepareForSelection(
      selectedWindowID,
      displayedFrame: selectedFrame
    )
    syncWindowBorderSubscriptions()
  }

  public func presentCommitWindowBorderSelection(_ selectedWindowID: WindowID?) {
    presentStageWindowBorderSelection(selectedWindowID)
    refreshWindowBorderGeometry(
      windowIDs: borderManager.liveGeometryWindowIDs
    )
    presentScheduleWindowBorderStackingRefresh()
  }

  func presentRevealWindowBordersIfReady() {
    guard
      windowBorderStackingIsReadyForReveal(
        windowBorderStacking,
        selectedWindowID: presentedSelectedWindowID,
        activeWindowID: borderManager.activeWindowID,
        nativeFocusedWindowID:
          verifiedNativeFocusedWindowID ?? lastNativeFocusedWindowID
      )
    else { return }
    borderManager.revealPendingBorders()
  }

  private func activeIsMinimizedOrHidden(_ windowID: WindowID) -> Bool {
    if lastHiddenWindowIDs.contains(windowID)
      || presentedNativeFullscreenWindowIDs.contains(windowID)
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

  public func presentRefreshWindowBorders() {
    // A selected window that is no longer on screen (minimized, hidden, or
    // parked) must never keep an overlay drawn over whatever is displayed.
    if let active = borderManager.activeWindowID,
      !borderFrames.contains(where: { $0.windowID == active })
        || activeIsMinimizedOrHidden(active)
    {
      presentHideWindowBorders()
      return
    }
    defer { syncWindowBorderSubscriptions() }
    let liveGeometryWindowIDs = borderManager.liveGeometryWindowIDs
    // WindowServer move events track transient geometry; AX caches must not override it.
    if windowServerDrivesBorders,
      isLeftMouseButtonDown || frameCoordinator.isBusy
        || borderRefreshBlockedBySettling(
          liveWindowIDs: liveGeometryWindowIDs,
          expectations: frameCommitExpectations,
          now: ProcessInfo.processInfo.systemUptime
        )
    { return }
    if isLeftMouseButtonDown {
      refreshWindowBorderGeometry(windowIDs: liveGeometryWindowIDs)
      return
    }
    if frameCoordinator.isBusy {
      let displayedFrames: [WindowID: Rect] = Dictionary(
        uniqueKeysWithValues: liveGeometryWindowIDs.compactMap { windowID in
          guard
            let assignment = borderFrames.first(where: {
              $0.windowID == windowID
            })
          else { return nil }
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
          let frame = displayedFrames[windowID]
            ?? nativeFrames[windowID]
            ?? relevantFrames.first(where: { $0.windowID == windowID })?.frame
        else {
          return nil
        }
        return (windowID, frame)
      }
    )
    borderManager.updateGeometry(
      frames: finalDisplayedFrames,
      style: borderStyle
    )
  }

  func makeEventMonitor(
    handler: @escaping (PlatformEventKind, pid_t?) -> Void,
    desktopSessionHandler: @escaping (DesktopSessionActivityChange) -> Void = { _ in },
    windowEventHandler: ((PlatformEventKind, pid_t?, AXUIElement) -> Void)? = nil,
    mouseGestureStartedHandler: @escaping () -> Void = {}
  ) -> PlatformEventMonitor {
    PlatformEventMonitor(
      handler: handler, userInputTracker: userInputTracker,
      desktopSessionHandler: desktopSessionHandler, windowEventHandler: windowEventHandler,
      liveFrameHandler: { [weak self] pressedWindowID, type, eventPointer in
        guard let self else { return }
        if type != .leftMouseDown {
          self.enqueueBorderGeometry(self.borderManager.liveGeometryWindowIDs, requiresNativeRead: true)
        }
        // The event's own location: the queue may run after the pointer left the edge.
        if let pressedWindowID, type != .leftMouseUp,
          let pointer = eventPointer ?? CGEvent(source: nil)?.location
        {
          NavigationActor.enqueue {
            self.stretchWindowProxyEarly(pressedWindowID, pressing: type == .leftMouseDown, pointer: pointer)
          }
        }
      },
      borderStackingHandler: { [weak self] in
        self?.presentScheduleWindowBorderStackingRefresh()
      },
      mouseGestureStartedHandler: mouseGestureStartedHandler)
  }

  private func resolvedWindowBorderStacking(
    for targetWindowID: WindowID?
  ) -> WindowBorderStacking {
    windowBorderStacking.targetWindowID == targetWindowID
      ? windowBorderStacking
      : .inactive(for: targetWindowID)
  }

  func refreshWindowBorderGeometry(
    windowIDs: Set<WindowID>
  ) {
    guard !windowIDs.isEmpty else { return }
    for windowID in windowIDs { snapshotEngine.recordCachedBorderFrame(for: windowID) }
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
      invalidatePointerCacheFromPresentation()
    }
  }

  /// Keeps visible rings on the real frames for a moment: an app can still clamp,
  /// round, or move its window after the motion landed.
  func settleWindowBordersOnRealFrames() {
    borderSettleTask?.cancel()
    borderSettleTask = Task { @MainActor [weak self] in
      for _ in 0..<45 {
        guard let self, !Task.isCancelled else { return }
        refreshWindowBorderGeometry(windowIDs: borderManager.liveGeometryWindowIDs)
        try? await Task.sleep(for: .milliseconds(33))
      }
    }
  }

  public func presentHideWindowBorders() {
    borderManager.hide()
    syncWindowBorderSubscriptions()
  }

  public func presentSetWindowBordersSuppressed(_ suppressed: Bool) {
    guard borderManager.isSuppressed != suppressed else { return }
    borderManager.setSuppressed(suppressed)
    syncWindowBorderSubscriptions()
    if suppressed {
      borderStackingRefreshTask?.cancel()
      return
    }
    presentStageWindowBorderSelection(borderSelectedWindowID)
    presentRefreshWindowBorders()
    presentScheduleWindowBorderStackingRefresh()
    presentRevealWindowBordersIfReady()
  }

  public func presentUpdateNativeFullscreenPlaceholders(
    _ placeholders: [NativeFullscreenPlaceholder],
    selectedWindowID: WindowID?,
    stackingWindowID: WindowID?
  ) {
    if nativeFullscreenPlaceholderManager.sync(
      placeholders,
      selectedWindowID: selectedWindowID,
      stackingWindowID: stackingWindowID,
      suppressedWindowIDs: presentedActiveNativeFullscreenWindowIDs,
      accentColor: borderStyle.activeColor
    ) {
      invalidatePointerCacheFromPresentation()
    }
  }

  public func presentHideNativeFullscreenPlaceholders() {
    nativeFullscreenPlaceholderManager.hide()
    invalidatePointerCacheFromPresentation()
  }



  func displayedBorderFrame(
    for assignment: FrameAssignment,
    nativeFrame: Rect?
  ) -> Rect {
    let written = frameCoordinator.borderWriteIsRecent(for: assignment.windowID)
      ? frameCoordinator.latestDisplayedBorderFrame(for: assignment.windowID) : nil
    return written ?? nativeFrame
      ?? frameCoordinator.latestDisplayedBorderFrame(for: assignment.windowID)
      ?? assignment.frame
  }

  private func resolvedBorderFrame(for windowID: WindowID) -> Rect? {
    let windowServerDriven = windowServerDrivesBorders
    // Between Defi's own writes, WindowServer bounds are the real frame now; the AX
    // read-back queues behind a slow app's writes and lagged up to a second.
    let realFrame = windowServerDriven || frameCoordinator.borderWriteIsRecent(for: windowID)
      ? nil : borderBoundsProvider.frame(for: windowID)
    return windowBorderGeometryFrame(
      windowServerDriven: windowServerDriven,
      windowServerFrame: windowServerDriven ? borderBoundsProvider.frame(for: windowID) : nil,
      displayedFrame: windowServerDriven
        ? nil : realFrame ?? frameCoordinator.latestDisplayedBorderFrame(for: windowID),
      plannedFrame: borderFrames.first(where: { $0.windowID == windowID })?.frame
    )
  }

  var windowServerDrivesBorders: Bool {
    borderSync.isWindowServer && borderBoundsProvider.isAvailable
  }

  func makeWindowBorderSync() -> WindowBorderSync {
    let boundsProvider = borderBoundsProvider
    let events = SkyLightWindowEventSource.shared
    let mover = SkyLightBorderSurfaceMover {
      boundsProvider.frame(for: WindowID(rawValue: UInt64($0)))
    }
    // Without an AppKit cache resync, SkyLight moves leave stale panel frames behind.
    let sync = WindowBorderSync(
      events: events, mover: mover,
      // shortcut: off until real-desktop soaks beat the AppKit path; re-enable with the checks above.
      available: false
    )
    sync.onFlush = { [weak self] windowIDs in
      guard let self else { return }
      self.refreshWindowBorderGeometry(
        windowIDs: windowIDs.intersection(self.borderManager.liveGeometryWindowIDs)
      )
    }
    sync.onReordered = { [weak self] in
      self?.presentScheduleWindowBorderStackingRefresh()
      self?.borderStackingSettle.trigger()
    }
    sync.onClosed = { [weak self] windowID in
      guard let self, let processID = self.processIDs[windowID] else { return }
      self.requestWindowTopologyRefresh(processID: processID)
    }
    borderManager.surfaceMover = { [weak self, weak sync] moves in
      // Before the bounds probe, keep AppKit moves without downgrading the mover.
      guard let self, let sync, self.windowServerDrivesBorders else { return false }
      return sync.move(moves)
    }
    borderManager.surfaceBounds = { [weak self] number in
      guard let self, self.windowServerDrivesBorders else { return nil }
      return self.borderBoundsProvider.frame(for: WindowID(rawValue: UInt64(number)))
    }
    borderManager.trace = { [weak self] in self?.frameCoordinator.recordTrace($0) }
    return sync
  }

  func makeWindowBorderStackingSettle() -> WindowBorderStackingSettle {
    let settle = WindowBorderStackingSettle { delay, work in
      let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
      return { item.cancel() }
    }
    settle.onPass = { [weak self] in self?.presentScheduleWindowBorderStackingRefresh() }
    return settle
  }

  /// Compares each visible border with real WindowServer geometry.
  public func auditWindowBorderGeometry() -> String {
    let backend = borderSync.backendDescription
    guard borderBoundsProvider.isAvailable else { return "backend=\(backend) bounds-unavailable" }
    let expected = borderManager.expectedEdgeFrames(windowFrame: borderBoundsProvider.frame(for:))
    let actual = expected.values.reduce(into: [UInt32: Rect]()) { result, edges in
      for number in edges.keys {
        result[number] = borderBoundsProvider.frame(for: WindowID(rawValue: UInt64(number)))
      }
    }
    return windowBorderAuditReport(expected: expected, actual: actual, backend: backend)
  }

  func syncWindowBorderSubscriptions() {
    if borderSync.isWindowServer, borderBoundsProvider.failureCount > 0 {
      borderSync.downgrade("bounds")
    }
    guard borderBoundsProvider.isAvailable else { return }
    borderSync.subscribe(borderManager.liveGeometryWindowIDs)
  }

  public func presentSetFrameNotificationsEnabled(_ enabled: Bool) {
    let suppressedRefresh = eventMonitor?.setFrameNotificationsEnabled(enabled)
    guard enabled else { return }
    if windowServerDrivesBorders {
      borderSync.reconcile(borderManager.liveGeometryWindowIDs)
    }
    // Notifications were ignored while animated writes ran. Force fresh reads
    // before trusting the final committed frames.
    let committedWindowIDs = Set(frameCommitExpectations.keys)
    let committedProcessIDs = Set(committedWindowIDs.compactMap { processIDs[$0] })
    snapshotEngine.recordFrameRefresh(
      windowIDs: committedWindowIDs,
      processIDs: (committedProcessIDs.isEmpty ? lastSnapshotProcessIDs : committedProcessIDs)
        .union(suppressedRefresh?.processIDs ?? []),
      requiresFullSnapshot: suppressedRefresh?.requiresFullSnapshot ?? false
    )
  }

  nonisolated public var isLeftMouseButtonDown: Bool {
    CGEventSource.buttonState(.combinedSessionState, button: .left)
  }

}
