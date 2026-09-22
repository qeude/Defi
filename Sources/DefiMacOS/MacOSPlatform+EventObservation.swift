import DefiRuntime
import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@NavigationActor
extension MacOSPlatform {

  public func invalidateFrameStateForDisplayChange() {
    frameCoordinator.invalidate(reason: "display-change")
    clearFrameState()
  }

  public func invalidateStateForDesktopSessionChange() {
    invalidateWindowSnapshot()
    snapshotEngine.invalidateAccessibilitySession()
    DispatchQueue.main.async { [self] in eventMonitor?.resetAccessibilityObservers() }
    frameCoordinator.invalidate(reason: "desktop-session-change")
    clearFrameState()
    invalidateFocusStateForDisplayChange()
  }

  public func cancelPendingFrameWrites() {
    frameSubmissionGeneration &+= 1
    frameCoordinator.invalidate(reason: "mouse-gesture")
  }

  public func prepareForRestore() async {
    frameSubmissionGeneration &+= 1
    invalidateFocusStateForDisplayChange()
    while focusWriter.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    let coordinator = frameCoordinator
    await Task.detached { coordinator.invalidateAndWaitForWrites() }.value
    clearFrameState()
  }

  private func clearFrameState() {
    frameSubmissionGeneration &+= 1
    targetFrames.removeAll(keepingCapacity: true)
    pendingFrameDebtWindowIDs.removeAll(keepingCapacity: true)
    pendingFrameCorrections.removeAll(keepingCapacity: true)
    latestObservedFrames.removeAll(keepingCapacity: true)
    frameCommitExpectations.removeAll(keepingCapacity: true)
    initialFrameSettlementDeadlines.removeAll(keepingCapacity: true)
    lastHiddenWindowIDs.removeAll(keepingCapacity: true)
    desiredSelectedWindowID = nil
    lastNativeFocusedWindowID = nil
    verifiedNativeFocusedWindowID = nil
    DispatchQueue.main.async { [self] in
      borderFrames.removeAll(keepingCapacity: true)
      borderHiddenWindowIDs.removeAll(keepingCapacity: true)
      borderLiveWindowID = nil
      borderManager.hide()
    }
  }

}
