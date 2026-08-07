import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
extension MacOSPlatform {

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
    if suppressesNativeFocusEvent {
      internalFocusDeadlines[windowID] =
        ProcessInfo.processInfo.systemUptime + 2
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
          guard let maximumUserInputTimestamp else { return }
          self?.recoverUserFocus(
            after: maximumUserInputTimestamp,
            excludingWindowID: windowID,
            excludingProcessID: processID
          )
        case .failed:
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
