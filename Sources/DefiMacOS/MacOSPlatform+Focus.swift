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
      let cancelled = focusWriter.cancel(
        requestID,
        recoveryFallback: fallback
      )
      if !cancelled,
        let fallback,
        let timestamp = submittedFocusRecoveryTimestamp
      {
        submitFocusRecoveryFallback(
          fallback,
          timestamp: timestamp
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
    return lastNativeFocusedWindowID == windowID
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
  }

  @discardableResult
  public func focus(
    _ windowID: WindowID,
    unlessUserInputAfter maximumUserInputTimestamp: TimeInterval? = nil,
    focusRecoveryFallbackWindowID: WindowID? = nil,
    cursorWarpUnlessPointerMovedAfter cursorWarpInputTimestamp: TimeInterval? = nil,
    cursorWarpPrefersTargetFrame: Bool = false,
    cursorWarpIsCurrent: (@MainActor @Sendable () -> Bool)? = nil,
    completion: (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) -> NativeFocusRequestID? {
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
    cursorWarpIsCurrent: (@MainActor @Sendable () -> Bool)? = nil,
    focusRecoveryFallback providedFocusRecoveryFallback:
      NativeFocusRecoveryFallback? = nil,
    createsRecoveryRequest: Bool = true,
    completion: (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil
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
        fallback: focusRecoveryFallback
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
      || NSWorkspace.shared.frontmostApplication?.processIdentifier != processID
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
        inputGuard: maximumUserInputTimestamp.map {
          FocusInputGuard(
            tracker: userInputTracker,
            maximumTimestamp: $0
          )
        },
        recoveryRequest: focusRecoveryRequest
      )
    ) { [weak self] nativeCompletion in
      Task { @MainActor [weak self] in
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
          focusRecoveryIntentIsCurrent(
            requestGeneration: recoveryIntentGeneration,
            currentGeneration: self.focusRecoveryIntentGeneration
          )
        {
          self.recoverUserFocus(
            recoveryRequest,
            intentGeneration: recoveryIntentGeneration
          )
        }
        switch result {
        case .completed, .completedWithoutMutation:
          self?.borderManager.revealPendingBorders()
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
    guard focusRecoveryIntentIsCurrent(
      requestGeneration: intentGeneration,
      currentGeneration: focusRecoveryIntentGeneration
    ) else { return }
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
    let processID =
      target.processID
      ?? target.windowID.flatMap { windowID in
        copyCGWindows().first {
          $0.id == CGWindowID(exactly: windowID.rawValue)
        }?.processID
      }
    guard let processID,
      userInputTracker.latestEventTimestamp <= target.timestamp
    else {
      return
    }
    if let windowID = target.windowID {
      focusRecoveryResolver.resolve(
        windowID: windowID,
        processID: processID
      ) { [weak self] resolution in
        Task { @MainActor [weak self] in
          guard let self,
            focusRecoveryIntentIsCurrent(
              requestGeneration: intentGeneration,
              currentGeneration: self.focusRecoveryIntentGeneration
            ),
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
    activateFocusRecoveryProcess(processID)
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
          NSWorkspace.shared.frontmostApplication?.processIdentifier
          != processID,
        inputGuard: FocusInputGuard(
          tracker: userInputTracker,
          maximumTimestamp: timestamp
        ),
        recoveryRequest: recoveryRequest
      )
    ) { [weak self] completion in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.submittedFocusRecoveryGeneration == recoveryGeneration {
          self.submittedFocusRecoveryRequestID = nil
          self.submittedFocusRecoveryTimestamp = nil
          self.submittedFocusRecoveryGeneration = nil
        }
        if let recoveryRequest = completion.recoveryRequest,
          focusRecoveryIntentIsCurrent(
            requestGeneration: intentGeneration,
            currentGeneration: self.focusRecoveryIntentGeneration
          )
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
    NSRunningApplication(processIdentifier: processID)?.activate()
  }

  private func capturedNativeFocusRecoveryFallback()
    -> NativeFocusRecoveryFallback?
  {
    let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
