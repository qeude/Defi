import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
extension MacOSPlatform {

  public func invalidateFrameStateForDisplayChange() {
    frameCoordinator.invalidate(reason: "display-change")
    frameCoordinator.startDisplayLink()
    clearFrameState()
  }

  public func cancelPendingFrameWrites() {
    frameCoordinator.invalidate(reason: "mouse-gesture")
  }

  public func prepareForSynchronousRestore() {
    frameCoordinator.invalidateAndWaitForWrites()
    clearFrameState()
  }

  private func clearFrameState() {
    targetFrames.removeAll(keepingCapacity: true)
    pendingFrameDebtWindowIDs.removeAll(keepingCapacity: true)
    pendingFrameCorrections.removeAll(keepingCapacity: true)
    latestObservedFrames.removeAll(keepingCapacity: true)
    frameCommitExpectations.removeAll(keepingCapacity: true)
    initialFrameSettlementDeadlines.removeAll(keepingCapacity: true)
    lastHiddenWindowIDs.removeAll(keepingCapacity: true)
    borderFrames.removeAll(keepingCapacity: true)
    desiredSelectedWindowID = nil
    lastNativeFocusedWindowID = nil
    borderHiddenWindowIDs.removeAll(keepingCapacity: true)
    borderLiveWindowID = nil
    borderManager.hide()
  }

}
