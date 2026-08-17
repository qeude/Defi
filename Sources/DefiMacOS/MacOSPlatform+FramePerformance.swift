import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

extension MacOSPlatform {
public var hiddenWindowCount: Int {
    lastHiddenWindowIDs.count
  }

  public func isWindowHidden(_ windowID: WindowID) -> Bool {
    lastHiddenWindowIDs.contains(windowID)
  }

  public func hasPendingFrameTransition(_ windowID: WindowID) -> Bool {
    frameTransitionIsPending(
      target: targetFrames[windowID],
      observed: latestObservedFrames[windowID]
    )
  }

  public func acceptObservedFrame(_ frame: Rect, for windowID: WindowID) {
    targetFrames[windowID] = nil
    pendingFrameCorrections[windowID] = nil
    frameCommitExpectations[windowID] = nil
    latestObservedFrames[windowID] = frame
  }

  public func userAdjustedFrames(
    for windowIDs: Set<WindowID>
  ) -> [WindowID: Rect] {
    guard mouseResizeGesturePending, !windowIDs.isEmpty else { return [:] }
    return framesByWindowID(for: windowIDs, in: copyCGWindows())
  }

  public var latencySensitiveWindowIDs: Set<WindowID> {
    let processIDs = frameCoordinator.slowProcessIDs
    return Set(
      self.processIDs.compactMap { windowID, processID in
        processIDs.contains(processID) ? windowID : nil
      }
    )
  }

  public var latencySensitiveProcessCount: Int {
    frameCoordinator.slowProcessIDs.count
  }

  public var hasPendingFrameDebt: Bool {
    !pendingFrameDebtWindowIDs.isEmpty
  }

  public var successfulPositionWriteCount: Int {
    positionWriteCount + frameCoordinator.writeCount
  }

  public var skippedStalePositionWriteCount: Int {
    frameCoordinator.staleWriteCount
  }

  public var droppedPositionFrameCount: Int {
    frameCoordinator.droppedCount
  }

  public func completedPosition(for windowID: WindowID) -> CGPoint? {
    frameCoordinator.completedPosition(for: windowID)
  }

  public var frameCoordinatorTrace: String {
    frameCoordinator.trace
  }

  public var hasNewlyDiscoveredWindows: Bool {
    !newlyDiscoveredWindowIDs.isEmpty
  }

  public func recordPerformanceTrace(_ event: String) {
    frameCoordinator.recordTrace(event)
  }

  public var parkingPerformance: (checks: Int, repairs: Int) {
    frameCoordinator.parkingPerformance
  }

  public var initialSettlementPerformance: (checks: Int, repairs: Int) {
    frameCoordinator.initialSettlementPerformance
  }

  public var frameCommitPerformance:
    (
      settling: Int,
      deferred: Int,
      observed: Int,
      maximumObservedLatencyMS: Double
    )
  {
    (
      frameCommitExpectations.count,
      deferredFrameCommitMismatchCount,
      observedFrameCommitCount,
      maximumObservedFrameCommitLatencyMS
    )
  }

  public var frameCoordinatorPerformance:
    (
      lastDurationMS: Double,
      maximumDurationMS: Double,
      slowFrames: Int,
      animationFrames: Int,
      animationDurationMS: Double
    )
  {
    frameCoordinator.performance
  }

  public var successfulSizeWriteCount: Int {
    sizeWriteCount + frameCoordinator.animatedSizeWriteCount
  }

  public var frameApplyDurationMS: Double {
    lastFrameApplyDurationMS
  }

  public var windowSnapshotPerformance:
    (
      lastDurationMS: Double,
      maximumDurationMS: Double,
      p50DurationMS: Double,
      p95DurationMS: Double,
      full: Int,
      incremental: Int,
      cached: Int,
      applicationInventories: Int,
      applicationWindowListReads: Int,
      applicationInventoryP50MS: Double,
      applicationInventoryP95MS: Double,
      applicationWindowListP50MS: Double,
      applicationWindowListP95MS: Double,
      cgCopies: Int,
      lastCGCopyDurationMS: Double,
      maximumCGCopyDurationMS: Double
    )
  {
    (
      lastWindowSnapshotDurationMS,
      maximumWindowSnapshotDurationMS,
      durationPercentile(0.50, samples: windowSnapshotDurationSamplesMS),
      durationPercentile(0.95, samples: windowSnapshotDurationSamplesMS),
      fullWindowSnapshotCount,
      incrementalWindowSnapshotCount,
      cachedWindowSnapshotCount,
      applicationInventorySnapshotCount,
      applicationWindowListReadCount,
      durationPercentile(0.50, samples: applicationInventoryDurationSamplesMS),
      durationPercentile(0.95, samples: applicationInventoryDurationSamplesMS),
      durationPercentile(0.50, samples: applicationWindowListDurationSamplesMS),
      durationPercentile(0.95, samples: applicationWindowListDurationSamplesMS),
      snapshotCGWindowCopyCount,
      lastSnapshotCGWindowCopyDurationMS,
      maximumSnapshotCGWindowCopyDurationMS
    )
  }

  public var hasReliableWindowTopologyObservation: Bool {
    eventMonitor?.hasReliableWindowTopologyCoverage(
      for: Set(applications.keys)
    ) == true
  }

  public var hasReliableApplicationLifecycleObservation: Bool {
    eventMonitor?.hasReliableApplicationLifecycleObservation == true
  }

  public var recommendedApplicationInventoryRefreshInterval: TimeInterval {
    applicationInventoryRefreshInterval(
      reliableLifecycleObservation: hasReliableApplicationLifecycleObservation
    )
  }

  public var recommendedWindowListRefreshInterval: TimeInterval {
    let hasPendingUnmatchedRetry = unmatchedWindowElementsByProcess.contains {
      processID, elements in
      elements.isEmpty == false
        && unmatchedWindowRetryIsPending(
          attempts: unmatchedWindowRetryAttemptsByProcess[processID] ?? 0
        )
    }
    let hasPendingWindowListReadRetry =
      windowListReadRetryAttemptsByProcess.values.contains {
        unmatchedWindowRetryIsPending(attempts: $0)
      }
    let hasPendingCGWindowInventoryRetry =
      cgWindowInventoryRetryAttempts.map {
        unmatchedWindowRetryIsPending(attempts: $0)
      } == true
    return windowListRefreshInterval(
      hasPendingShortRetry:
        hasPendingUnmatchedRetry
        || hasPendingWindowListReadRetry
        || hasPendingCGWindowInventoryRetry
        || !retainedWindowIDs.isEmpty,
      reliableTopologyObservation: hasReliableWindowTopologyObservation
    )
  }

  public var hasReliableDesktopObservation: Bool {
    hasReliableWindowTopologyObservation
      && eventMonitor?.hasReliableFrameCoverage() == true
  }

  public var desktopObservationCoverage:
    (
      applicationObservers: Int,
      applications: Int,
      topologyWindows: Int,
      requiredTopologyWindows: Int,
      frameWindows: Int,
      requiredFrameWindows: Int
    )
  {
    eventMonitor?.observationCoverage ?? (0, 0, 0, 0, 0, 0)
  }

  public var windowAttributeReadPerformance:
    (batched: Int, fallback: Int, metadata: Int, metadataReuses: Int)
  {
    (
      batchedWindowAttributeReadCount,
      fallbackWindowAttributeReadCount,
      windowManagementMetadataReadCount,
      windowManagementMetadataReuseCount
    )
  }

  public var focusDurationMS: Double {
    focusWriter.durationMS
  }

  public var focusPerformance:
    (
      durationMS: Double,
      fastPaths: Int,
      cancelled: Int,
      retries: Int,
      mainDurationMS: Double,
      raiseDurationMS: Double,
      activationDurationMS: Double
    )
  {
    focusWriter.performance
  }

  public var hasPendingAnimatedFrameWrites: Bool {
    frameCoordinator.isAnimating
  }

  public var hasPendingFrameWrites: Bool {
    frameCoordinator.isBusy
  }

  public func cursorWarpFrameIsReady(for windowID: WindowID) -> Bool {
    cursorWarpFrameReadiness(
      latestWriteSucceeded: frameCoordinator.latestWriteSucceeded(
        for: windowID
      ),
      observedFrame: latestObservedFrames[windowID],
      targetFrame: targetFrames[windowID]
    )
  }

  public var pendingAnimatedFrameWindowIDs: Set<WindowID> {
    frameCoordinator.pendingAnimatedWindowIDs
  }

  public var pendingFrameWindowIDs: Set<WindowID> {
    unresolvedFrameDebtWindowIDs(
      pendingWindowIDs: frameCoordinator.pendingWindowIDs,
      debtWindowIDs: pendingFrameDebtWindowIDs,
      targetFrames: targetFrames,
      observedFrames: latestObservedFrames
    )
  }

  public var hasPendingFocusWrite: Bool {
    focusWriter.isBusy
  }

  public var hasPendingNativeFocusEvent: Bool {
    nativeFocusEventPending
  }
}
