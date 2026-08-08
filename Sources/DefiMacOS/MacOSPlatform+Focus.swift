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
}

func internalFocusSuppressionAfterCompletion(
  _ suppression: InternalFocusSuppression?,
  requestID: UInt64,
  result: NativeFocusResult
) -> InternalFocusSuppression? {
  guard suppression?.requestID == requestID else { return suppression }
  switch result {
  case .completedWithoutMutation, .superseded, .cancelled, .failed,
    .failedAfterMutation:
    return nil
  case .completed, .cancelledAfterMutation, .cancelledAfterInputMutation:
    return suppression
  }
}

@MainActor
extension MacOSPlatform {

  public func isWindowNativelyFocused(_ windowID: WindowID) -> Bool {
    guard let processID = processIDs[windowID] else { return false }
    return lastNativeFocusedWindowID == windowID
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
  }

  public func focus(
    _ windowID: WindowID,
    unlessUserInputAfter maximumUserInputTimestamp: TimeInterval? = nil,
    cursorWarpUnlessPointerMovedAfter cursorWarpInputTimestamp: TimeInterval? = nil,
    cursorWarpPrefersTargetFrame: Bool = false,
    completion: (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) {
    submitFocus(
      windowID,
      unlessUserInputAfter: maximumUserInputTimestamp,
      suppressesNativeFocusEvent: true,
      cursorWarpUnlessPointerMovedAfter: cursorWarpInputTimestamp,
      cursorWarpPrefersTargetFrame: cursorWarpPrefersTargetFrame,
      completion: completion
    )
  }

  private func submitFocus(
    _ windowID: WindowID,
    unlessUserInputAfter maximumUserInputTimestamp: TimeInterval?,
    suppressesNativeFocusEvent: Bool,
    cursorWarpUnlessPointerMovedAfter cursorWarpInputTimestamp: TimeInterval? = nil,
    cursorWarpPrefersTargetFrame: Bool = false,
    focusRecoveryFallback providedFocusRecoveryFallback:
      NativeFocusRecoveryFallback? = nil,
    completion: (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) {
    guard let element = elements[windowID],
      let processID = processIDs[windowID],
      let application = applications[processID]
    else {
      completion?(.failed)
      return
    }
    let focusRecoveryFallback = maximumUserInputTimestamp.flatMap { _ in
      providedFocusRecoveryFallback ?? capturedNativeFocusRecoveryFallback()
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
      nextInternalFocusRequestID &+= 1
      internalFocusRequestID = nextInternalFocusRequestID
      internalFocusSuppressions[windowID] = InternalFocusSuppression(
        requestID: nextInternalFocusRequestID,
        deadline: ProcessInfo.processInfo.systemUptime + 2
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
    focusWriter.submit(
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
        case .superseded, .cancelled:
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

  private func recoverUserFocus(_ request: NativeFocusRecoveryRequest) {
    guard let target = userInputTracker.focusRecoveryTarget(
      after: request.timestamp,
      excludingWindowID: request.excludingWindowID,
      excludingProcessID: request.excludingProcessID,
      fallbackWindowID: request.fallback?.windowID,
      fallbackProcessID: request.fallback?.processID
    ),
      userInputTracker.latestEventTimestamp <= target.timestamp
    else {
      return
    }
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
