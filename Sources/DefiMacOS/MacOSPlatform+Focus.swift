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
  case .cancelled, .failed, .failedAfterMutation:
    return nil
  case .completed, .cancelledAfterMutation:
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
    completion: (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) {
    submitFocus(
      windowID,
      unlessUserInputAfter: maximumUserInputTimestamp,
      suppressesNativeFocusEvent: true,
      cursorWarpUnlessPointerMovedAfter: cursorWarpInputTimestamp,
      completion: completion
    )
  }

  private func submitFocus(
    _ windowID: WindowID,
    unlessUserInputAfter maximumUserInputTimestamp: TimeInterval?,
    suppressesNativeFocusEvent: Bool,
    cursorWarpUnlessPointerMovedAfter cursorWarpInputTimestamp: TimeInterval? = nil,
    completion: (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil
  ) {
    guard let element = elements[windowID],
      let processID = processIDs[windowID],
      let application = applications[processID]
    else {
      completion?(.failed)
      return
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
        }
      )
    ) { [weak self] result in
      Task { @MainActor [weak self] in
        if let internalFocusRequestID, let self {
          self.internalFocusSuppressions[windowID] =
            internalFocusSuppressionAfterCompletion(
              self.internalFocusSuppressions[windowID],
              requestID: internalFocusRequestID,
              result: result
            )
        }
        switch result {
        case .completed:
          self?.borderManager.revealPendingBorders()
          if let cursorWarpInputTimestamp = cursorWarpTimestampAfterNativeFocus(
            result: result,
            requestedTimestamp: cursorWarpInputTimestamp
          ) {
            self?.warpCursor(
              to: windowID,
              unlessPointerMovedAfter: cursorWarpInputTimestamp
            )
          }
        case .cancelled:
          break
        case .cancelledAfterMutation:
          if let maximumUserInputTimestamp {
            self?.recoverUserFocus(
              after: maximumUserInputTimestamp,
              excludingWindowID: windowID,
              excludingProcessID: processID
            )
          }
        case .failed:
          break
        case .failedAfterMutation:
          break
        }
        completion?(result)
      }
    }
  }

  private func recoverUserFocus(
    after timestamp: TimeInterval,
    excludingWindowID: WindowID,
    excludingProcessID: pid_t
  ) {
    guard let target = userInputTracker.focusRecoveryTarget(
      after: timestamp,
      excludingWindowID: excludingWindowID,
      excludingProcessID: excludingProcessID
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
        suppressesNativeFocusEvent: false
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

}
