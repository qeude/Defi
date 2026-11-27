import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog
import Synchronization

/// Chromium's link URL bubble is one window, reported created again each time a hovered
/// link shows it: holding the screen for it froze the page at every link.
private let openedWindowNumbers = Mutex<Set<CGWindowID>>([])

private func windowOpenedBefore(_ number: CGWindowID?) -> Bool {
  guard let number else { return false }
  return openedWindowNumbers.withLock { !$0.insert(number).inserted }
}

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
    mouseGestureStartedHandler: @escaping @NavigationActor @Sendable (WindowID?) -> Void = { _ in },
    mouseGestureHandler: @escaping @NavigationActor @Sendable () -> Void = {},
    activatedWindowHandler: @escaping @NavigationActor @Sendable (WindowID, TimeInterval) -> Void = { _, _ in }
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
      // An app hidden (Command-H) or shown again: its windows' borders and dims follow at once.
      if kind == .application {
        self?.enqueuePresentation { $0.presentRefreshWindowBorders() }
      }
      if kind == .space {
        NavigationActor.enqueue { [weak self] in self?.holdWindowProxiesForFullscreenReturn() }
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
      // A window opening: the screen holds still until the ribbon opens it in its slot,
      // instead of macOS drawing it over the others first. Accessory apps' popovers and
      // panels are not windows to open in the ribbon, nor are Defi's own surfaces beside
      // its Settings window (SwiftUI names that one only after it is created).
      // A link's URL bubble or a tooltip shows on hover or scroll: an app's next window
      // opens on a key or a click, and only that one holds the screen.
      // shortcut: an app slower than 1.5 s to open its window shows macOS's placement; widen per app if seen.
      let unrequested = (previousWindowCount ?? 0) > 0
        && eventInput.map { ProcessInfo.processInfo.systemUptime - $0.latestPress > 1.5 } == true
      if kind == .windowCreated, let processID, let element, !unrequested,
        NSRunningApplication(processIdentifier: processID)?.activationPolicy == .regular,
        processID != ProcessInfo.processInfo.processIdentifier || isStandardWindow(element),
        case let createdNumber = self?.windowIDProvider.windowID(for: element),
        !windowOpenedBefore(createdNumber), !floatsAtCreation(createdNumber, processID: processID) {
        // Only the latest window's check may release the hold: an earlier one timing out
        // would cut short the hold a later window still waits on.
        let opening = ProcessInfo.processInfo.systemUptime
        let hold: @Sendable () -> Void = { [weak self] in
          NavigationActor.enqueue { [weak self] in
            self?.latestOpening = opening
            self?.holdWindowProxiesForOpening(processID)
          }
        }
        // An input method's candidate list and mode marker open in the app typed into, and
        // holding the screen for them flickered at every conversion. While such typing goes
        // on, the hold waits for a read that tells them apart: a read that waits on the app,
        // so a new window can show before its hold. Otherwise the hold starts at once.
        let typesWithInputMethod = eventInput.map { opening - $0.latestTyping < 0.5 } == true
          && inputMethodEnabled()
        if !typesWithInputMethod { hold() }
        // An app's later dialogs, panels and native tabs open where they are: checked
        // after the hold, off the main thread, since the read waits on the app.
        let created = UncheckedSendable(value: element), checksOwnWindow = (previousWindowCount ?? 0) > 0
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
          if typesWithInputMethod {
            if isTextInputAccessory(created.value) { return }
            hold()
          }
          // Read last, once the hold is decided, so the log never delays it.
          var verdict = "new-window-timeout"
          defer {
            ribbonProxyLogger.notice("open-created pid=\(processID) windows=\(previousWindowCount ?? 0) verdict=\(verdict, privacy: .public) \(createdWindowSummary(created.value, number: createdNumber), privacy: .public)")
          }
          // Picture in picture floats above the overlay and never opens a column: holding
          // the screen for its layout froze every window behind it.
          if let createdNumber, windowFloatsAboveRibbon(createdNumber) {
            verdict = "floats"
            return NavigationActor.enqueue { [weak self] in
              if self?.latestOpening == opening { RibbonProxyPresenter.releaseHolds() }
            }
          }
          let shown = applicationShownWindowIDs(processID)
          if checksOwnWindow, let frame = ownWindowFrame(created.value) {
            verdict = frame == nil ? "dialog-or-tab" : "own-window"
            NavigationActor.enqueue { [weak self] in
              guard let self, latestOpening == opening else { return }
              releaseOpeningHoldUnlessOwnWindow(processID, at: frame)
            }
            return
          }
          // A first window, or an app too slow to answer (Finder): WindowServer showing it
          // a new standard window confirms one, and the hold waits for its layout. The
          // screen stays held while this check runs, and moves again as soon as it fails.
          NavigationActor.enqueue { RibbonProxyPresenter.extendHolds(to: 0.8) }
          let deadline = ProcessInfo.processInfo.systemUptime + 0.8
          while ProcessInfo.processInfo.systemUptime < deadline {
            if !applicationShownWindowIDs(processID).isSubset(of: shown) {
              verdict = "new-window"
              return NavigationActor.enqueue { RibbonProxyPresenter.extendHolds() }
            }
            usleep(20_000)
          }
          NavigationActor.enqueue { [weak self] in
            if self?.latestOpening == opening { RibbonProxyPresenter.releaseHolds() }
          }
        }
      }
      // An app brought forward (Command-Tab, the Dock): its focused window alone is read, so
      // the ribbon moves as at a keyboard command instead of after a read of all its windows.
      if kind == .focus, let processID, let self,
        let activation = userInputTracker.snapshot.applicationActivation, activation.processID == processID {
        let elements = UncheckedSendable(value: self.elements), coordinator = frameCoordinator
        // WindowServer has already ordered the activated app's key window in front, and answers
        // without the app, which can spend its whole read timeout activating.
        // Its front window only: a new window Defi does not know yet must not hand over to an
        // older one, possibly on another workspace.
        // On the main thread: off it, SkyLight waits for the main thread's pending commit
        // while holding the lock that commit needs, stalling both for half a second.
        let front = ribbonProxyOnScreenWindows().first { $0.processID == processID && $0.layer == 0 }
          .flatMap { elements.value[$0.id] == nil ? nil : $0.id }
        DispatchQueue.global(qos: .userInteractive).async {
          func known(_ element: AXUIElement?) -> WindowID? {
            element.flatMap { element in elements.value.first(where: { CFEqual($0.value, element) })?.key }
          }
          // A slow app's focused window lags its activation; one window leaves no
          // ambiguity, as in the snapshot's own fallback, so the ribbon still animates.
          let started = ProcessInfo.processInfo.systemUptime
          let focused = front == nil ? applicationFocusedWindow(processID) : nil
          let focusedID = front ?? known(focused)
          let windowID = focusedID ?? known(applicationSingleWindow(processID))
          if focusedID == nil {
            coordinator.recordTrace("activation-read pid=\(processID) focused=\(focused == nil ? "none" : "unknown") window=\(windowID.map { String($0.rawValue) } ?? "none") ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - started) * 1_000))")
          }
          guard let windowID else { return }
          NavigationActor.enqueue { activatedWindowHandler(windowID, activation.timestamp) }
        }
      }
      // Only a destroyed window element resolves here: its ring goes before macOS's
      // close animation, not after the next snapshot. A quit app's windows go at once.
      let closing = kind == .windows ? windowID.map { [$0] } ?? []
        : kind == .applicationTerminated ? (self?.processIDs.filter { $0.value == processID }.map(\.key) ?? []) : []
      if !closing.isEmpty {
        self?.enqueuePresentation { platform in closing.forEach(platform.borderManager.hideClosing) }
      }
      if kind == .windowCreated || kind == .windows, let processID {
        self?.frameCoordinator.recordTrace(
          "window-event kind=\(String(describing: kind)) pid=\(processID)"
        )
      }
      if kind == .frame {
        if let windowID {
          NavigationActor.enqueue { [weak self] in
            guard let self, activeNativeFullscreenWindowIDs.contains(windowID),
              !returnedNativeFullscreenWindowIDs.contains(windowID) else { return }
            noteNativeFullscreenReturn()
          }
        }
        if let windowID {
          if let self, borderManager.hasElevatedDim,
            let frame = borderBoundsProvider.frame(for: windowID) ?? latestObservedFrames[windowID] {
            borderManager.lowerDims(overlapping: frame, movedWindowID: windowID)
          }
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
        ) { [weak self] isEarliestStage, generation in
          guard let self,
            isEarliestStage || self.applicationWindowCounts[processID] == previousWindowCount
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
      mouseGestureStartedHandler: { windowID in NavigationActor.enqueue { mouseGestureStartedHandler(windowID) } }
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
        refreshWindowDimElevations(inventory.filter(\.isOnscreen).map {
          WindowStackEntry(
            windowID: WindowID(rawValue: UInt64($0.id)), processID: $0.processID, layer: $0.layer, frame: $0.frame)
        })
        return
      }
      // Off-main window-list reads contend with main-thread AppKit border geometry inside
      // SkyLight's CA transaction sync and stall the main thread and the ribbon ~0.5 s.
      // With dims, one full read serves both the ring's stacking and the dims' elevation.
      let onScreen = borderManager.dimCandidateWindowIDs.isEmpty ? nil : copyOnScreenWindowStackEntries()
      let stacking = copyWindowBorderStacking(
        targetWindowID: request.windowID,
        targetProcessID: targetProcessID,
        targetFrame: targetFrame,
        monitorFrames: monitorFrames,
        knownWindowIDs: knownWindowIDs,
        onScreen: onScreen
      )
      refreshWindowBorderStacking(request, stacking: stacking)
      refreshWindowDimElevations(onScreen ?? [])
    }
  }

  private func refreshWindowDimElevations(_ entries: [WindowStackEntry]) {
    let candidates = borderManager.dimCandidateWindowIDs
    guard !candidates.isEmpty else { return borderManager.setDimElevations([]) }
    borderManager.setDimElevations(windowDimElevations(
      dimmed: candidates, entries: entries, ownProcessID: ProcessInfo.processInfo.processIdentifier,
      knownWindowIDs: Set(elements.keys)))
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
    borderStyle = WindowBorderStyle(config: config)
    let style = borderStyle, shownSelection = borderSelectedWindowID
    NavigationActor.enqueue {
      RibbonProxyPresenter.borderStyle = style
      RibbonProxyPresenter.setDimFocus(shownSelection)
    }
    watchBorderAccessibility()
    guard !bordersLackAccessibility else { return }
    presentRefreshWindowBorders()
    if let ownedWindowID = borderManager.ownedSurfaceWindowID {
      borderBoundsProvider.probe(ownedWindowID: ownedWindowID)
    }
    syncWindowBorderSubscriptions()
    presentScheduleWindowBorderStackingRefresh(reusingSnapshot: true)
    presentRevealWindowBordersIfReady()
  }

  public func presentHideBordersOnFullscreenDisplays(_ windowIDs: Set<WindowID>) {
    borderManager.setFullscreenHidden(windowIDs)
  }

  public func presentStageWindowBorderSelection(_ selectedWindowID: WindowID?) {
    let selectedWindowID = selectedWindowID.flatMap {
      presentedNativeFullscreenWindowIDs.contains($0) ? nil : $0
    }
    presentedSelectedWindowID = selectedWindowID
    // A refresh before the daemon's update, as on an app activation, plans this selection.
    borderSelectedWindowID = selectedWindowID
    NavigationActor.enqueue { RibbonProxyPresenter.setDimFocus(selectedWindowID) }
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

  /// Checks once a second that Accessibility is still granted: revoked, focus changes stop
  /// arriving and the dims would stay on whatever windows they covered.
  private func watchBorderAccessibility() {
    guard borderTrustTimer == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyBorderAccessibility(trusted: AXIsProcessTrusted()) }
    }
    borderTrustTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func applyBorderAccessibility(trusted: Bool) {
    guard trusted == bordersLackAccessibility else { return }
    bordersLackAccessibility = !trusted
    if trusted { presentRefreshWindowBorders() } else { presentHideWindowBorders() }
  }

  /// The configured style, ringing the focused window while it shows a refused resize.
  var drawnBorderStyle: WindowBorderStyle {
    refusalRingWindowID != nil && refusalRingWindowID == borderSelectedWindowID
      ? borderStyle.ringingFocusedWindow : borderStyle
  }

  public func presentRefreshWindowBorders() {
    guard !bordersLackAccessibility else { return }
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
      borderManager.updateGeometry(frames: displayedFrames, style: drawnBorderStyle)
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
    let hiddenProcessIDs = Set(Set(borderFrames.compactMap { processIDs[$0.windowID] }).filter {
      NSRunningApplication(processIdentifier: $0)?.isHidden == true
    })
    let plan = planWindowBorders(
      frames: hiddenProcessIDs.isEmpty
        ? borderFrames : borderFrames.filter { processIDs[$0.windowID].map { !hiddenProcessIDs.contains($0) } ?? true },
      selectedWindowID: borderSelectedWindowID,
      hiddenWindowIDs: borderHiddenWindowIDs,
      monitorFrames: lastMonitorFrames,
      style: drawnBorderStyle
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
      style: drawnBorderStyle
    )
  }

  func makeEventMonitor(
    handler: @escaping (PlatformEventKind, pid_t?) -> Void,
    desktopSessionHandler: @escaping (DesktopSessionActivityChange) -> Void = { _ in },
    windowEventHandler: ((PlatformEventKind, pid_t?, AXUIElement) -> Void)? = nil,
    mouseGestureStartedHandler: @escaping (WindowID?) -> Void = { _ in }
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
      style: drawnBorderStyle
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
    stackingWindowID: WindowID?,
    suppressedMonitorIDs: Set<MonitorID>,
    fullscreenWindows: [WindowID: pid_t] = [:]
  ) {
    if nativeFullscreenPlaceholderManager.sync(
      placeholders,
      selectedWindowID: selectedWindowID,
      stackingWindowID: stackingWindowID,
      suppressedMonitorIDs: suppressedMonitorIDs,
      fullscreenWindows: fullscreenWindows,
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

/// The application's focused window, read with a short timeout: a busy app keeps the
/// usual path, which reads its windows anyway.
func applicationFocusedWindow(_ processID: pid_t) -> AXUIElement? {
  let application = AXUIElementCreateApplication(processID)
  AXUIElementSetMessagingTimeout(application, 0.1)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
    let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return (value as! AXUIElement)
}

/// A window already above the standard level when created never opens a column, so it never
/// holds the screen: Photoshop recreates its contextual task bar at every zoom or brush
/// change, and even a hold released at once froze the screen at every key. A level not set
/// yet reads as standard and holds as before.
private func floatsAtCreation(_ number: CGWindowID?, processID: pid_t) -> Bool {
  guard let number, windowFloatsAboveRibbon(number) else { return false }
  ribbonProxyLogger.notice("open-hold-skipped pid=\(processID) window=\(number) floats")
  return true
}

func windowFloatsAboveRibbon(_ number: CGWindowID) -> Bool {
  (ribbonProxyWindowDescriptions([number]).first?[kCGWindowLayer as String] as? Int).map { $0 > 0 } ?? false
}

/// The standard-level windows WindowServer shows for an app, from its public list.
func applicationShownWindowIDs(_ processID: pid_t) -> Set<WindowID> {
  Set(ribbonProxyOnScreenWindows().filter { window in
    window.processID == processID && window.layer == 0 && window.frame.width > 100 && window.frame.height > 100
  }.map(\.id))
}

/// The application's only window, read with the same short timeout; nil for several.
func applicationSingleWindow(_ processID: pid_t) -> AXUIElement? {
  let application = AXUIElementCreateApplication(processID)
  AXUIElementSetMessagingTimeout(application, 0.1)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
    let windows = value as? [AXUIElement], windows.count == 1 else { return nil }
  return windows[0]
}

/// What an app created, for the overlay log: no title, only what tells such windows apart.
func createdWindowSummary(_ element: AXUIElement, number: CGWindowID?) -> String {
  let ax = AXMessagingTimeoutAccess.shared.withTimeout(accessibilityReadTimeoutSeconds, elements: [element]) {
    var values: CFArray?
    AXUIElementCopyMultipleAttributeValues(element,
      [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values)
    let read = values as? [AnyObject] ?? []
    guard read.count == 4 else { return "role=unread" }
    let frame = frameFromAXValues(positionValue: read[2], sizeValue: read[3])
      .map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.width))x\(Int($0.height))" } ?? "none"
    return "role=\(read[0] as? String ?? "none") subrole=\(read[1] as? String ?? "none") frame=\(frame)"
  }
  guard let number, let server = ribbonProxyWindowDescriptions([number]).first else {
    return "\(ax) window=\(number.map(String.init) ?? "none")"
  }
  return "\(ax) window=\(number) layer=\(server[kCGWindowLayer as String] as? Int ?? -1) "
    + "alpha=\(server[kCGWindowAlpha as String] as? Double ?? -1) "
    + "onscreen=\(server[kCGWindowIsOnscreen as String] as? Bool ?? false)"
}

private func isStandardWindow(_ element: AXUIElement) -> Bool {
  var subrole: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success
    && subrole as? String == kAXStandardWindowSubrole
}
