import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

struct InternalFocusSuppression: Equatable, Sendable {
  let requestID: UInt64
  let deadline: TimeInterval
  let maximumInputTimestamp: TimeInterval
}

func internalFocusSuppressionConsumesEvent(
  _ suppression: InternalFocusSuppression,
  suppressedWindowID: WindowID,
  latestFocusIntent: UserInputTracker.FocusIntent?
) -> Bool {
  guard let latestFocusIntent,
    latestFocusIntent.timestamp > suppression.maximumInputTimestamp
  else {
    return true
  }
  switch latestFocusIntent.source {
  case .keyboard:
    return false
  case .mouse(let windowID):
    return windowID != suppressedWindowID
  }
}

func extendingInternalFocusSuppression(
  _ suppression: InternalFocusSuppression,
  through inputTimestamp: TimeInterval,
  deadline: TimeInterval
) -> InternalFocusSuppression {
  InternalFocusSuppression(
    requestID: suppression.requestID,
    deadline: max(suppression.deadline, deadline),
    maximumInputTimestamp: max(
      suppression.maximumInputTimestamp,
      inputTimestamp
    )
  )
}

func internalFocusSuppressionAfterCompletion(
  _ suppression: InternalFocusSuppression?,
  requestID: UInt64,
  result: NativeFocusResult
) -> InternalFocusSuppression? {
  guard suppression?.requestID == requestID else { return suppression }
  switch result {
  case .completedWithoutMutation, .frameSuperseded, .superseded, .cancelled:
    return nil
  case .completed, .supersededAfterMutation, .cancelledAfterMutation,
    .cancelledAfterInputMutation, .failed, .failedAfterMutation:
    return suppression
  }
}

@MainActor
extension MacOSPlatform {

  public func invalidateFocusStateForDisplayChange() {
    focusWriter.invalidate()
    focusRecoveryResolver.invalidate()
    internalFocusSuppressions.removeAll(keepingCapacity: true)
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
    completion: (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) -> NativeFocusRequestID? {
    submitFocus(
      windowID,
      unlessUserInputAfter: maximumUserInputTimestamp,
      suppressesNativeFocusEvent: true,
      focusRecoveryFallbackWindowID: focusRecoveryFallbackWindowID,
      cursorWarpUnlessPointerMovedAfter: cursorWarpInputTimestamp,
      cursorWarpPrefersTargetFrame: cursorWarpPrefersTargetFrame,
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
    focusRecoveryFallback providedFocusRecoveryFallback:
      NativeFocusRecoveryFallback? = nil,
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
    let focusRecoveryRequest = maximumUserInputTimestamp.map {
      NativeFocusRecoveryRequest(
        timestamp: $0,
        excludingWindowID: windowID,
        excludingProcessID: processID,
        fallback: focusRecoveryFallback
      )
    }
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
        if let recoveryRequest = nativeCompletion.recoveryRequest {
          self?.recoverUserFocus(recoveryRequest)
        }
        switch result {
        case .completed, .completedWithoutMutation:
          self?.borderManager.revealPendingBorders()
          if let cursorWarpInputTimestamp = cursorWarpTimestampAfterNativeFocus(
            result: result,
            requestedTimestamp: cursorWarpInputTimestamp
          ) {
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

  private func recoverUserFocus(_ request: NativeFocusRecoveryRequest) {
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
      submitFocus(
        windowID,
        unlessUserInputAfter: target.timestamp,
        suppressesNativeFocusEvent: false,
        focusRecoveryFallback: NativeFocusRecoveryFallback(
          windowID: windowID,
          processID: processIDs[windowID] ?? target.processID
        )
      )
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
            timestamp: target.timestamp
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
    timestamp: TimeInterval
  ) {
    frameCoordinator.recordTrace(
      "focus-recovery auxiliary-window=\(windowID.rawValue)"
    )
    focusWriter.submit(
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
        recoveryRequest: NativeFocusRecoveryRequest(
          timestamp: timestamp,
          excludingWindowID: windowID,
          excludingProcessID: processID,
          fallback: nil
        )
      )
    ) { [weak self] completion in
      guard let recoveryRequest = completion.recoveryRequest else { return }
      Task { @MainActor [weak self] in
        self?.recoverUserFocus(recoveryRequest)
      }
    }
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
