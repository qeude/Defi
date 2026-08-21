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

  public var latencySensitiveProcessDescription: String {
    frameCoordinator.slowProcessLatenciesMS.sorted { $0.key < $1.key }
      .map { processID, latencyMS in
        let appID = applicationIDsByProcess[processID] ?? "unknown"
        return "\(appID)@\(processID):\(String(format: "%.1f", latencyMS))ms"
      }.joined(separator: ",")
  }

  public var processLatencyDescription: String {
    frameCoordinator.processLatenciesMS.sorted { $0.key < $1.key }
      .map { processID, latencyMS in
        let appID = applicationIDsByProcess[processID] ?? "unknown"
        return "\(appID)@\(processID):\(String(format: "%.1f", latencyMS))ms"
      }.joined(separator: ",")
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

  public func beginCommandPerformance(_ context: CommandPerformanceContext) {
    commandLatency.begin(context)
    emitCommandDiagnostics()
  }

  public func setCommandDiagnosticHandler(
    _ handler: @escaping @MainActor @Sendable (CommandDiagnosticSample) -> Void
  ) {
    commandDiagnosticHandler = handler
  }

  public func setDiagnosticAnomalyHandler(
    _ handler: @escaping @Sendable (TimeInterval, String) -> Void
  ) {
    frameCoordinator.setDiagnosticAnomalyHandler(handler)
  }

  public func finishCommandDiagnostics() {
    commandLatency.finishCurrentDiagnostic()
    emitCommandDiagnostics()
  }

  public func recordCommandFocusExpectation(
    _ context: CommandPerformanceContext,
    expectsFocus: Bool
  ) {
    commandLatency.recordFocusExpectation(
      context,
      expectsFocus: expectsFocus
    )
  }

  func recordCommandPlan(
    _ context: CommandPerformanceContext,
    expectedWindowIDs: Set<WindowID>,
    hasFrameWrites: Bool,
    at timestamp: TimeInterval
  ) {
    guard let latency = commandLatency.recordPlan(
      context,
      expectedWindowIDs: expectedWindowIDs,
      hasFrameWrites: hasFrameWrites,
      at: timestamp
    ) else { return }
    frameCoordinator.recordTrace(
      "command-plan cg=\(context.generation) windows=\(expectedWindowIDs.count) ms=\(String(format: "%.2f", latency))"
    )
    emitCommandDiagnostics()
  }

  func recordCommandFirstWrite(
    _ context: CommandPerformanceContext,
    at timestamp: TimeInterval
  ) {
    guard let latency = commandLatency.recordFirstWrite(context, at: timestamp)
    else { return }
    frameCoordinator.recordTrace(
      "command-first-write cg=\(context.generation) ms=\(String(format: "%.2f", latency))"
    )
    emitCommandDiagnostics()
  }

  func recordCommandObservation(
    _ context: CommandPerformanceContext,
    windowID: WindowID,
    from: Rect,
    actual: Rect,
    target: Rect,
    at timestamp: TimeInterval
  ) {
    let result = commandLatency.recordObservation(
      context,
      windowID: windowID,
      from: from,
      actual: actual,
      target: target,
      at: timestamp
    )
    if let latency = result.firstObservationMS {
      frameCoordinator.recordTrace(
        "command-first-observed cg=\(context.generation) ms=\(String(format: "%.2f", latency))"
      )
    }
    if let latency = result.convergenceMS {
      frameCoordinator.recordTrace(
        "command-converged cg=\(context.generation) ms=\(String(format: "%.2f", latency))"
      )
    }
    emitCommandDiagnostics()
  }

  public func recordCommandFocus(
    _ context: CommandPerformanceContext,
    result: NativeFocusResult,
    at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    guard result == .completed || result == .completedWithoutMutation,
      let latency = commandLatency.recordFocus(context, at: timestamp)
    else { return }
    frameCoordinator.recordTrace(
      "command-focus cg=\(context.generation) ms=\(String(format: "%.2f", latency))"
    )
    emitCommandDiagnostics()
  }

  public var commandLatencyPerformance: CommandLatencyPerformance {
    commandLatency.performance
  }

  private func emitCommandDiagnostics() {
    let samples = commandLatency.takeDiagnosticSamples()
    for sample in samples {
      commandDiagnosticHandler?(sample)
    }
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

  public func processIDsWithoutReliableTopologyCoverage() -> Set<pid_t> {
    eventMonitor?.processIDsWithoutReliableTopologyCoverage(
      activeProcessIDs: Set(applications.keys)
    ) ?? []
  }

  public var hasDeferredFreshWindowReads: Bool {
    deferredFreshReadProcessIDs.isEmpty == false
  }

  public var incompatibleObservationProcessIDs: Set<pid_t> {
    eventMonitor?.incompatibleNotificationProcessIDs ?? []
  }

  public var hasChunkedFullRefreshPending: Bool {
    chunkedFullRefreshRemainingProcessIDs?.isEmpty == false
  }

  public var notificationObservationFailureSummary: String {
    let counts = eventMonitor?.notificationObservationFailureCountsValue ?? [:]
    guard !counts.isEmpty else { return "[]" }
    return "["
      + counts.sorted { $0.key < $1.key }
        .map { "\($0.key)x\($0.value)" }.joined(separator: ",")
      + "]"
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
    let baseInterval = windowListRefreshInterval(
      hasPendingShortRetry:
        hasPendingUnmatchedRetry
        || hasPendingWindowListReadRetry
        || hasPendingCGWindowInventoryRetry
        || !retainedWindowIDs.isEmpty,
      reliableTopologyObservation: hasReliableWindowTopologyObservation
    )
    return min(
      baseInterval,
      transientOwnerResolutionRefreshInterval(
        retryAfter: Array(transientOwnerResolutionRetryAfter.values),
        now: ProcessInfo.processInfo.systemUptime
      ) ?? baseInterval
    )
  }

  public var hasPendingTransientOwnerResolution: Bool {
    transientOwnerResolutionRetryAfter.isEmpty == false
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

  public var hasPendingDeferredParkingWrites: Bool {
    frameCoordinator.hasPendingDeferredParkingWrites
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
