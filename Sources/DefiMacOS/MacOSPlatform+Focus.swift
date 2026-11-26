import DefiRuntime
import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

extension MacOSPlatform {

  public func invalidateFocusStateForDisplayChange() {
    focusRecoveryIntentGeneration &+= 1
    focusWriter.invalidate()
    focusRecoveryResolver.invalidate()
    submittedFocusRecoveryRequestID = nil
    submittedFocusRecoveryTimestamp = nil
    submittedFocusRecoveryGeneration = nil
    let now = ProcessInfo.processInfo.systemUptime
    internalFocusSuppressions = internalFocusSuppressions.filter {
      $0.value.deadline >= now
    }
  }

  public func invalidateFocusRecovery() {
    invalidateFocusRecovery(recoveringTo: nil)
  }

  /// A newer focus-bearing command owns native focus: recovery from an older request
  /// must not re-activate the app being navigated away from during the motion.
  public func supersedeFocusRecovery() {
    invalidateFocusRecovery(recoveringTo: nil, preservingCompletedSuppressions: true)
  }

  public func invalidateFocusRecovery(recoveringTo windowID: WindowID?) {
    invalidateFocusRecovery(
      recoveringTo: windowID,
      preservingCompletedSuppressions: false
    )
  }

  private func invalidateFocusRecovery(
    recoveringTo windowID: WindowID?,
    preservingCompletedSuppressions: Bool
  ) {
    focusRecoveryIntentGeneration &+= 1
    focusRecoveryResolver.invalidate()
    let now = ProcessInfo.processInfo.systemUptime
    internalFocusSuppressions = focusSuppressionsAfterRecoveryInvalidation(
      internalFocusSuppressions,
      now: now,
      preservingCompleted: preservingCompletedSuppressions
    )
    let fallback = windowID.flatMap { fallbackWindowID in
      processIDs[fallbackWindowID].map {
        NativeFocusRecoveryFallback(
          windowID: fallbackWindowID,
          processID: $0
        )
      }
    }
    if let requestID = submittedFocusRecoveryRequestID {
      _ = focusWriter.cancel(requestID)
      if let fallback,
        let timestamp = submittedFocusRecoveryTimestamp
      {
        submitFocusRecoveryFallback(
          fallback,
          timestamp: max(
            timestamp,
            userInputTracker.latestEventTimestamp
          )
        )
        return
      }
    }
    submittedFocusRecoveryRequestID = nil
    submittedFocusRecoveryTimestamp = nil
    submittedFocusRecoveryGeneration = nil
  }

  public func isWindowNativelyFocused(_ windowID: WindowID) -> Bool {
    guard let processID = processIDs[windowID] else { return false }
    return !nativeFocusEventPending && lastNativeFocusedWindowID == windowID
      && frontmostProcessID == processID
  }

  @discardableResult
  public func focus(
    _ windowID: WindowID,
    unlessUserInputAfter maximumUserInputTimestamp: TimeInterval? = nil,
    focusRecoveryFallbackWindowID: WindowID? = nil,
    cursorWarpUnlessPointerMovedAfter cursorWarpInputTimestamp: TimeInterval? = nil,
    cursorWarpPrefersTargetFrame: Bool = false,
    cursorWarpIsCurrent: (@NavigationActor @Sendable () -> Bool)? = nil,
    restoresPreviousFocusOnFailure: Bool = true,
    completion: (@NavigationActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) -> NativeFocusRequestID? {
    let activatesNativeFullscreen = nativeFullscreenActivationWindowID == windowID
    if activatesNativeFullscreen { nativeFullscreenActivationWindowID = nil }
    guard activatesNativeFullscreen || !nativeFullscreenWindowIDs.contains(windowID) else {
      enqueuePresentation { $0.nativeFullscreenPlaceholderManager.focus(windowID) }
      completion?(.completedWithoutMutation)
      return nil
    }
    // A direct focus request is the new source of truth. Any asynchronous
    // recovery started by an older request must not be allowed to submit a
    // focus write after this one.
    invalidateFocusRecovery(
      recoveringTo: nil,
      preservingCompletedSuppressions: true
    )
    return submitFocus(
      windowID,
      unlessUserInputAfter: maximumUserInputTimestamp,
      suppressesNativeFocusEvent: true,
      focusRecoveryFallbackWindowID: focusRecoveryFallbackWindowID,
      cursorWarpUnlessPointerMovedAfter: cursorWarpInputTimestamp,
      cursorWarpPrefersTargetFrame: cursorWarpPrefersTargetFrame,
      cursorWarpIsCurrent: cursorWarpIsCurrent,
      restoresFallbackOnFailure: restoresPreviousFocusOnFailure,
      completion: completion
    )
  }

  @discardableResult
  private func submitFocus(
    _ windowID: WindowID,
    unlessUserInputAfter maximumUserInputTimestamp: TimeInterval?,
    suppressesNativeFocusEvent: Bool,
    focusRecoveryFallbackWindowID: WindowID? = nil,
    cursorWarpUnlessPointerMovedAfter cursorWarpInputTimestamp: TimeInterval? = nil,
    cursorWarpPrefersTargetFrame: Bool = false,
    cursorWarpIsCurrent: (@NavigationActor @Sendable () -> Bool)? = nil,
    focusRecoveryFallback providedFocusRecoveryFallback:
      NativeFocusRecoveryFallback? = nil,
    restoresFallbackOnFailure: Bool = true,
    createsRecoveryRequest: Bool = true,
    completion: (@NavigationActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) -> NativeFocusRequestID? {
    guard let element = elements[windowID],
      let processID = processIDs[windowID],
      let application = applications[processID]
    else {
      completion?(.failed)
      return nil
    }
    let focusRecoveryFallback = maximumUserInputTimestamp.flatMap { _ in
      providedFocusRecoveryFallback
        ?? focusRecoveryFallbackWindowID.flatMap { fallbackWindowID in
          processIDs[fallbackWindowID].map {
            NativeFocusRecoveryFallback(
              windowID: fallbackWindowID,
              processID: $0
            )
          }
        }
        ?? capturedNativeFocusRecoveryFallback()
    }
    let focusRecoveryRequest = createsRecoveryRequest ? maximumUserInputTimestamp.map {
      NativeFocusRecoveryRequest(
        timestamp: $0,
        excludingWindowID: windowID,
        excludingProcessID: processID,
        fallback: focusRecoveryFallback,
        restoresFallbackOnFailure: restoresFallbackOnFailure
      )
    } : nil
    let internalFocusRequestID: UInt64?
    if suppressesNativeFocusEvent {
      let requestInputTimestamp = maximumUserInputTimestamp
        ?? userInputTracker.latestEventTimestamp
      let suppressionDeadline = ProcessInfo.processInfo.systemUptime + 2
      if focusWriter.isBusy {
        internalFocusSuppressions = internalFocusSuppressions.mapValues {
          extendingInternalFocusSuppression(
            $0,
            through: requestInputTimestamp,
            deadline: suppressionDeadline
          )
        }
      }
      nextInternalFocusRequestID &+= 1
      internalFocusRequestID = nextInternalFocusRequestID
      internalFocusSuppressions[windowID] = InternalFocusSuppression(
        requestID: nextInternalFocusRequestID,
        deadline: suppressionDeadline,
        maximumInputTimestamp: requestInputTimestamp
      )
    } else {
      internalFocusRequestID = nil
    }
    let focusWritePending = focusWriter.isBusy
    let activatesApplication =
      focusWriter.hasInFlightRequest(forDifferentProcess: processID)
      || frontmostProcessID != processID
    let trackedWindowCount = processIDs.values.lazy.filter { $0 == processID }.count
    let hasMultipleManagedWindows = trackedWindowCount > 1
    let hasTrackedAuxiliaryWindows = floatingWindowIDs.contains {
      processIDs[$0] == processID
    }
    let hasUnmanagedAuxiliaryWindows =
      (applicationWindowCounts[processID] ?? 0)
      > trackedWindowCount
      || hasTrackedAuxiliaryWindows
    let selectsSpecificWindow = shouldSelectSpecificWindow(
      activatesApplication: activatesApplication,
      hasUnmanagedAuxiliaryWindows: hasUnmanagedAuxiliaryWindows,
      hasMultipleManagedWindows: hasMultipleManagedWindows,
      focusWritePending: focusWritePending,
      targetWasLastFocused: lastFocusedWindowByProcess[processID] == windowID
    )
    let recoveryIntentGeneration = focusRecoveryIntentGeneration
    return focusWriter.submit(
      AsyncFocusRequest(
        element: element,
        application: application,
        processID: processID,
        selectsSpecificWindow: selectsSpecificWindow,
        validatesSpecificWindowFocus: !selectsSpecificWindow,
        activatesApplication: activatesApplication,
        foregroundWindowElements: foregroundFloatingWindowElements(
          above: windowID
        ),
        inputGuard: maximumUserInputTimestamp.map {
          FocusInputGuard(
            tracker: userInputTracker,
            maximumTimestamp: $0
          )
        },
        recoveryRequest: focusRecoveryRequest
      )
    ) { [weak self] nativeCompletion in
      NavigationActor.enqueue { [weak self] in
        let result = nativeCompletion.result
        if let internalFocusRequestID, let self {
          self.internalFocusSuppressions[windowID] =
            internalFocusSuppressionAfterCompletion(
              self.internalFocusSuppressions[windowID],
              requestID: internalFocusRequestID,
              result: result
            )
        }
        if let recoveryRequest = nativeCompletion.recoveryRequest,
          let self,
          recoveryIntentGeneration == self.focusRecoveryIntentGeneration
        {
          self.recoverUserFocus(
            recoveryRequest,
            intentGeneration: recoveryIntentGeneration
          )
        }
        switch result {
        case .completed, .completedWithoutMutation:
          guard self?.focusRecoveryIntentGeneration == recoveryIntentGeneration else {
            completion?(.superseded)
            return
          }
          self?.verifiedNativeFocusedWindowID = windowID
          // Native full-screen detection falls back on this before AX reports the new frame.
          self?.lastFocusedWindowByProcess[processID] = windowID
          self?.enqueuePresentation { $0.presentScheduleWindowBorderStackingRefresh() }
          self?.enqueuePresentation { $0.presentRevealWindowBordersIfReady() }
          if let cursorWarpInputTimestamp = cursorWarpTimestampAfterNativeFocus(
            result: result,
            requestedTimestamp: cursorWarpInputTimestamp
          ), cursorWarpIsCurrent?() ?? true {
            self?.warpCursor(
              to: windowID,
              unlessUserInputAfter: cursorWarpInputTimestamp,
              preferringTargetFrame: cursorWarpPrefersTargetFrame
            )
          }
        case .frameSuperseded, .superseded, .supersededAfterMutation,
          .cancelled:
          break
        case .cancelledAfterMutation:
          break
        case .cancelledAfterInputMutation:
          break
        case .failed:
          break
        case .failedAfterMutation:
          break
        }
        completion?(result)
      }
    }
  }

  @discardableResult
  public func cancelFocus(
    _ requestID: NativeFocusRequestID,
    recoveringTo windowID: WindowID? = nil
  ) -> Bool {
    let fallback = windowID.flatMap { fallbackWindowID in
      processIDs[fallbackWindowID].map {
        NativeFocusRecoveryFallback(
          windowID: fallbackWindowID,
          processID: $0
        )
      }
    }
    return focusWriter.cancel(requestID, recoveryFallback: fallback)
  }

  private func recoverUserFocus(
    _ request: NativeFocusRecoveryRequest,
    intentGeneration: UInt64
  ) {
    guard intentGeneration == focusRecoveryIntentGeneration else { return }
    let target = userInputTracker.focusRecoveryTarget(
      after: request.timestamp,
      excludingWindowID: request.excludingWindowID,
      excludingProcessID: request.excludingProcessID,
      fallbackWindowID: request.fallback?.windowID,
      fallbackProcessID: request.fallback?.processID
    ) ?? nativeFocusRecoveryFallbackTarget(
      request,
      latestEventTimestamp: userInputTracker.latestEventTimestamp
    )
    guard let target,
      userInputTracker.latestEventTimestamp <= target.timestamp
    else { return }
    if let windowID = target.windowID, elements[windowID] != nil {
      frameCoordinator.recordTrace(
        "focus-recovery window=\(windowID.rawValue)"
      )
      nextFocusRecoveryGeneration &+= 1
      let recoveryGeneration = nextFocusRecoveryGeneration
      let requestID = submitFocus(
        windowID,
        unlessUserInputAfter: target.timestamp,
        suppressesNativeFocusEvent: false,
        completion: { [weak self] _ in
          guard let self,
            self.submittedFocusRecoveryGeneration == recoveryGeneration
          else { return }
          self.submittedFocusRecoveryRequestID = nil
          self.submittedFocusRecoveryTimestamp = nil
          self.submittedFocusRecoveryGeneration = nil
        }
      )
      submittedFocusRecoveryRequestID = requestID
      submittedFocusRecoveryTimestamp =
        requestID == nil ? nil : target.timestamp
      submittedFocusRecoveryGeneration =
        requestID == nil ? nil : recoveryGeneration
      return
    }
    guard userInputTracker.latestEventTimestamp <= target.timestamp else { return }
    if let windowID = target.windowID {
      focusRecoveryResolver.resolve(
        windowID: windowID,
        processID: target.processID
      ) { [weak self] processID, resolution in
        NavigationActor.enqueue { [weak self] in
          guard let self, let processID,
            intentGeneration == self.focusRecoveryIntentGeneration,
            self.userInputTracker.latestEventTimestamp <= target.timestamp
          else {
            return
          }
          guard let resolution else {
            self.activateFocusRecoveryProcess(processID)
            return
          }
          self.submitAuxiliaryFocusRecovery(
            element: resolution.element,
            windowID: windowID,
            processID: processID,
            application: resolution.application,
            timestamp: target.timestamp,
            intentGeneration: intentGeneration
          )
        }
      }
      return
    }
    if let processID = target.processID { activateFocusRecoveryProcess(processID) }
  }

  private func submitAuxiliaryFocusRecovery(
    element: AXUIElement,
    windowID: WindowID,
    processID: pid_t,
    application: AXUIElement,
    timestamp: TimeInterval,
    intentGeneration: UInt64
  ) {
    frameCoordinator.recordTrace(
      "focus-recovery auxiliary-window=\(windowID.rawValue)"
    )
    nextFocusRecoveryGeneration &+= 1
    let recoveryGeneration = nextFocusRecoveryGeneration
    let recoveryRequest = NativeFocusRecoveryRequest(
      timestamp: timestamp,
      excludingWindowID: windowID,
      excludingProcessID: processID,
      fallback: nil
    )
    let requestID = focusWriter.submit(
      AsyncFocusRequest(
        element: element,
        application: application,
        processID: processID,
        selectsSpecificWindow: true,
        validatesSpecificWindowFocus: false,
        activatesApplication:
          frontmostProcessID
          != processID,
        foregroundWindowElements: [],
        inputGuard: FocusInputGuard(
          tracker: userInputTracker,
          maximumTimestamp: timestamp
        ),
        recoveryRequest: recoveryRequest
      )
    ) { [weak self] completion in
      NavigationActor.enqueue { [weak self] in
        guard let self else { return }
        if self.submittedFocusRecoveryGeneration == recoveryGeneration {
          self.submittedFocusRecoveryRequestID = nil
          self.submittedFocusRecoveryTimestamp = nil
          self.submittedFocusRecoveryGeneration = nil
        }
        if let recoveryRequest = completion.recoveryRequest,
          intentGeneration == self.focusRecoveryIntentGeneration
        {
          self.recoverUserFocus(
            recoveryRequest,
            intentGeneration: intentGeneration
          )
        }
      }
    }
    submittedFocusRecoveryRequestID = requestID
    submittedFocusRecoveryTimestamp = timestamp
    submittedFocusRecoveryGeneration = recoveryGeneration
  }

  private func foregroundFloatingWindowElements(
    above targetWindowID: WindowID
  ) -> [AXUIElement] {
    guard !floatingWindowIDs.contains(targetWindowID),
      let targetFrame = lastSnapshotWindows.first(where: {
        $0.id == targetWindowID
      })?.frame,
      let targetMonitor = lastMonitorFrames.first(where: {
        targetIntersects(targetFrame, monitor: $0)
      })
    else { return [] }

    var remaining = floatingWindowIDs.subtracting(lastHiddenWindowIDs).filter {
      windowID in
      lastSnapshotWindows.first(where: { $0.id == windowID }).map {
        targetIntersects($0.frame, monitor: targetMonitor)
      } == true
    }
    var ordered = (snapshotEngine.lastCGWindowInventory ?? []).reversed()
      .compactMap { record -> WindowID? in
        let windowID = WindowID(rawValue: UInt64(record.id))
        return remaining.remove(windowID) == nil ? nil : windowID
      }
    ordered.append(contentsOf: remaining.sorted { $0.rawValue < $1.rawValue })
    return ordered.compactMap { elements[$0] }
  }

  private func submitFocusRecoveryFallback(
    _ fallback: NativeFocusRecoveryFallback,
    timestamp: TimeInterval
  ) {
    guard let windowID = fallback.windowID else {
      submittedFocusRecoveryRequestID = nil
      submittedFocusRecoveryTimestamp = nil
      submittedFocusRecoveryGeneration = nil
      return
    }
    nextFocusRecoveryGeneration &+= 1
    let recoveryGeneration = nextFocusRecoveryGeneration
    let requestID = submitFocus(
      windowID,
      unlessUserInputAfter: timestamp,
      suppressesNativeFocusEvent: false,
      focusRecoveryFallback: fallback,
      createsRecoveryRequest: false,
      completion: { [weak self] _ in
        guard let self,
          self.submittedFocusRecoveryGeneration == recoveryGeneration
        else { return }
        self.submittedFocusRecoveryRequestID = nil
        self.submittedFocusRecoveryTimestamp = nil
        self.submittedFocusRecoveryGeneration = nil
      }
    )
    submittedFocusRecoveryRequestID = requestID
    submittedFocusRecoveryTimestamp = requestID == nil ? nil : timestamp
    submittedFocusRecoveryGeneration =
      requestID == nil ? nil : recoveryGeneration
  }

  private func activateFocusRecoveryProcess(_ processID: pid_t) {
    frameCoordinator.recordTrace("focus-recovery pid=\(processID)")
    let application = applications[processID] ?? AXUIElementCreateApplication(processID)
    nextFocusRecoveryGeneration &+= 1
    let generation = nextFocusRecoveryGeneration
    let timestamp = userInputTracker.latestEventTimestamp
    submittedFocusRecoveryRequestID = focusWriter.submit(
      AsyncFocusRequest(element: application, application: application, processID: processID,
        selectsSpecificWindow: false, validatesSpecificWindowFocus: false,
        activatesApplication: true, foregroundWindowElements: [],
        inputGuard: FocusInputGuard(tracker: userInputTracker,
          maximumTimestamp: timestamp), recoveryRequest: nil)
    ) { [weak self] _ in
      NavigationActor.enqueue {
        guard let self, self.submittedFocusRecoveryGeneration == generation else { return }
        self.submittedFocusRecoveryRequestID = nil
        self.submittedFocusRecoveryTimestamp = nil
        self.submittedFocusRecoveryGeneration = nil
      }
    }
    submittedFocusRecoveryTimestamp = timestamp
    submittedFocusRecoveryGeneration = generation
  }

  private func capturedNativeFocusRecoveryFallback()
    -> NativeFocusRecoveryFallback?
  {
    let processID = frontmostProcessID
    let windowID = lastNativeFocusedWindowID.flatMap { windowID in
      processIDs[windowID] == processID ? windowID : nil
    }
    guard windowID != nil || processID != nil else { return nil }
    return NativeFocusRecoveryFallback(
      windowID: windowID,
      processID: processID
    )
  }

}

extension MacOSPlatform {
  /// Brings the windows forward in order, the last on top, off the input path and without
  /// activating their applications.
  public func raiseWindows(_ windowIDs: [WindowID]) {
    let windows = windowIDs.compactMap { windowID in
      elements[windowID].map {
        PreparedAXWindowElement(
          windowID: windowID, processID: processIDs[windowID] ?? 0, element: $0, usesBatchedAttributeReads: false)
      }
    }
    guard !windows.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      for element in windows.map(\.element) {
        _ = AXMessagingTimeoutAccess.shared.withTimeout(frameRefreshInterval, elements: [element]) { () -> AXError in
          performAccessibilityWrite(on: element) { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
        }
      }
    }
  }

  /// Presses the window's close button off the input path. The window leaves the model only when
  /// macOS reports it destroyed: an app may answer with a sheet and keep it.
  public func pressCloseButton(_ windowID: WindowID) -> Bool {
    guard let element = elements[windowID] else { return false }
    let window = PreparedAXWindowElement(
      windowID: windowID, processID: processIDs[windowID] ?? 0, element: element, usesBatchedAttributeReads: false)
    pressCloseButton(window, retries: [0.1, 0.25, 0.5])
    return true
  }

  // An app still handling a frame change or launch answers cannotComplete; a later press lands.
  private func pressCloseButton(_ window: PreparedAXWindowElement, retries: ArraySlice<TimeInterval>) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let element = window.element
      let result = AXMessagingTimeoutAccess.shared.withTimeout(1, elements: [element]) { () -> AXError in
        var button: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button)
        guard read == .success, let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
          return read == .success ? .attributeUnsupported : read
        }
        let closeButton = unsafeDowncast(button, to: AXUIElement.self)
        return performAccessibilityWrite(on: closeButton) {
          AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        }
      }
      NavigationActor.enqueue {
        guard let self else { return }
        self.recordPerformanceTrace("close-window window=\(window.windowID.rawValue) result=\(result.rawValue)")
        guard result == .cannotComplete, let delay = retries.first else { return }
        NavigationActor.shared.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
          NavigationActor.assumeIsolated { self?.pressCloseButton(window, retries: retries.dropFirst()) }
        }
      }
    }
  }
}
