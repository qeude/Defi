import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
extension MacOSPlatform {

  public func focus(_ windowID: WindowID) {
    guard let element = elements[windowID],
      let processID = processIDs[windowID],
      let application = applications[processID]
    else {
      return
    }
    internalFocusDeadlines[windowID] =
      ProcessInfo.processInfo.systemUptime + 2
    let focusWritePending = focusWriter.isBusy
    let activatesApplication =
      focusWriter.hasInFlightRequest(forDifferentProcess: processID)
      || NSWorkspace.shared.frontmostApplication?.processIdentifier != processID
    let hasMultipleManagedWindows =
      processIDs.values.lazy.filter { $0 == processID }.prefix(2).count > 1
    let hasUnmanagedAuxiliaryWindows =
      (applicationWindowCounts[processID] ?? 0)
      > processIDs.values.lazy.filter { $0 == processID }.count
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
        activatesApplication: activatesApplication
      )
    ) { [weak self] completedLatest in
      guard completedLatest else { return }
      Task { @MainActor [weak self] in
        self?.borderManager.revealPendingBorders()
      }
    }
  }

}
