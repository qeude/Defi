import AppKit
import ApplicationServices
import DefiConfig
import DefiCore
import DefiModel

struct RunningApplicationFacts: Equatable {
  let terminated: Bool
  let regular: Bool
  let bundleIdentifier: String?
  let localizedName: String?
}

struct Storage {
  var processWindowRetryDeadlines: [pid_t: TimeInterval] = [:]
  var applicationFacts: [pid_t: RunningApplicationFacts?] = [:]
  var applicationFactsGeneration: UInt64 = 0
  var discoveryMeasurementAccess: DiscoveryMeasurementAccess?
  var pendingObservations = SnapshotObservations()
  var nextBorderBindingRevision: UInt64 = 0
  var borderBindingRevisions: [WindowID: UInt64] = [:]

  func frameCommitReadIsCurrent(_ read: FrameCommitRead, inputTimestamp: TimeInterval) -> Bool {
    let id = read.binding.windowID
    guard let current = frameCommitExpectations[id] else { return false }
    return current.commitID == read.expectation.commitID
      && current.issuedAt == read.expectation.issuedAt
      && current.target == read.expectation.target
      && targetFrames[id] == current.target
      && borderBindingIsCurrent(read.binding)
      && !preparedWindowReadRevisions.invalidatedProcessIDs(
        since: read.revisions, candidates: [read.binding.processID]).contains(read.binding.processID)
      && inputTimestamp == read.inputTimestamp
  }

  mutating func advanceBorderBindingRevisions(for windowIDs: Set<WindowID>) {
    for windowID in windowIDs {
      frameCommitExpectations[windowID] = nil
      nextBorderBindingRevision &+= 1
      borderBindingRevisions[windowID] = elements[windowID] == nil ? nil : nextBorderBindingRevision
    }
  }

  func borderBindingIsCurrent(_ target: BorderGeometryReadTarget) -> Bool {
    !accessibilitySessionResetPending
      && borderBindingRevisions[target.windowID] == target.bindingRevision
      && processIDs[target.windowID] == target.processID
      && sameAXElement(elements[target.windowID], target.element)
      && sameAXElement(applications[target.processID], target.application)
  }

  var elements: [WindowID: AXUIElement] = [:]
  var processIDs: [WindowID: pid_t] = [:]
  var transientOwnerWindowIDs: [WindowID: WindowID] = [:]
  var transientOwnerResolutionAttempts: [WindowID: Int] = [:]
  var transientOwnerResolutionRetryAfter: [WindowID: TimeInterval] = [:]
  var floatingWindowIDs = Set<WindowID>()
  var applications: [pid_t: AXUIElement] = [:]
  var applicationIDsByProcess: [pid_t: String] = [:]
  var applicationWindowCounts: [pid_t: Int] = [:]
  var enhancedUIByProcess: [pid_t: Bool] = [:]
  var multipleAttributeReadsSupportedByProcess: [pid_t: Bool] = [:]
  var failedBatchedWindowAttributeReadsByElement: [AXWindowElementIdentity: Int] = [:]
  var batchedWindowAttributeReadCount = 0
  var fallbackWindowAttributeReadCount = 0
  var windowManagementCapabilities: [WindowID: WindowManagementCapabilities] =
    [:]
  var windowClassificationTraces: [WindowID: String] = [:]
  var nativeTabHiddenMembersByWindowID: [WindowID: Set<WindowID>] = [:]
  var nativeTabSettleDeadlines: [pid_t: TimeInterval] = [:]
  var windowManagementMetadataReadCount = 0
  var windowManagementMetadataReuseCount = 0
  var privateWindowIDLookupCount = 0
  var publicWindowIDFallbackCount = 0
  var targetFrames: [WindowID: Rect] = [:]
  var latestObservedFrames: [WindowID: Rect] = [:]
  var frameCommitExpectations: [WindowID: FrameCommitExpectation] = [:]
  var pendingFrameCorrections: [WindowID: Rect] = [:]
  var newlyDiscoveredWindowIDs = Set<WindowID>()
  var accessibilitySessionResetPending = false
  var hasCompletedWindowSnapshot = false
  var overviewPresentationActive = false
  var lastSnapshotWindows: [Window] = []
  var lastSnapshotWindowIDs = Set<WindowID>()
  var lastSnapshotProcessIDs = Set<pid_t>()
  var lastResolvedFrontmostProcessID: pid_t?
  var lastApplicationWindowElements: [pid_t: [AXUIElement]] = [:]
  var minimizedWindowElementsByProcess: [pid_t: [AXUIElement]] = [:]
  var transientGeometryWindowElementsByProcess: [pid_t: [AXUIElement]] = [:]
  var unmatchedWindowElementsByProcess: [pid_t: [AXUIElement]] = [:]
  var unmatchedWindowRetryAttemptsByProcess: [pid_t: Int] = [:]
  var windowListReadRetryAttemptsByProcess: [pid_t: Int] = [:]
  var cgWindowInventoryRetryAttempts: Int?
  var retainedWindowIDs = Set<WindowID>()
  var retainedWindowDeadlines: [WindowID: TimeInterval] = [:]
  var lastWindowSnapshotDurationMS = 0.0
  var maximumWindowSnapshotDurationMS = 0.0
  var windowSnapshotDurationSamplesMS: [Double] = []
  var fullWindowSnapshotCount = 0
  var incrementalWindowSnapshotCount = 0
  var cachedWindowSnapshotCount = 0
  var applicationInventorySnapshotCount = 0
  var applicationWindowListReadCount = 0
  var applicationInventoryDurationSamplesMS: [Double] = []
  var applicationWindowListDurationSamplesMS: [Double] = []
  var snapshotCGWindowCopyCount = 0
  var lastSnapshotCGWindowCopyDurationMS = 0.0
  var maximumSnapshotCGWindowCopyDurationMS = 0.0
  var lastCGWindowInventory: CGWindowInventory?
  var cgWindowDiscoveryRetries = CGWindowDiscoveryRetryTracker()
  var cgWindowDiscoveryDiagnostics: [CGWindowDiscoveryDiagnostic] = []
  var cgWindowDiscoveryTraceSignatures: [CGWindowDiscoveryIdentity: String] = [:]
  var windowSnapshotObservationGeneration: UInt64 = 0
  var preparedWindowReadRevisions = PreparedWindowReadRevisions()
  var deferredFrameCommitMismatchCount = 0
  var observedFrameCommitCount = 0
  var maximumObservedFrameCommitLatencyMS = 0.0
  var lastHiddenWindowIDs = Set<WindowID>()
  var deferredFreshReadProcessIDs = Set<pid_t>()
  var deferredFreshReadsStartedAt: TimeInterval?
  var chunkedFullRefreshRemainingProcessIDs: Set<pid_t>?
  var fallbackFreshReadDeadlines: [pid_t: TimeInterval] = [:]
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] = [:]
  var mouseResizeGesturePending: Bool = false
  var mouseFocusReleasePending: Bool = false
  var nativeFocusEventGeneration: UInt64 = 0
  var mouseFocusReleaseEventGeneration: UInt64? = nil
  var nativeFocusEventPending: Bool = false
  var nativeFocusEventProcessIDs: Set<pid_t> = Set<pid_t>()
  var nativeFocusEventHasUnknownProcess: Bool = false
  var nativeFocusEventTimestamp: TimeInterval = 0
  var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  var nativeFullscreenExitDeadlines: [WindowID: TimeInterval] = [:]
  var nativeFullscreenProcessIDsByWindowID: [WindowID: pid_t] = [:]
  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] = [:]
  var lastMonitorFrames: [Rect] = []
  var pendingFrameDebtWindowIDs: Set<WindowID> = Set<WindowID>()
  var lastNativeFocusedWindowID: WindowID? = nil
  var nativeFocusIsAppPopup = false
  var verifiedNativeFocusedWindowID: WindowID? = nil
  var lastUnconfirmedActivationTimestamp: TimeInterval?
}

/// Versions prepared AX reads without weakening the global CG inventory revision.
struct PreparedWindowReadRevisions: Sendable {
  var global: UInt64 = 0
  var processes: [pid_t: UInt64] = [:]

  mutating func invalidate(processID: pid_t?) {
    if let processID {
      processes[processID, default: 0] &+= 1
    } else {
      global &+= 1
      processes.removeAll(keepingCapacity: true)
    }
  }

  func invalidatedProcessIDs(since captured: Self, candidates: Set<pid_t>) -> Set<pid_t> {
    guard global == captured.global else { return candidates }
    return candidates.filter { processes[$0] != captured.processes[$0] }
  }
}

/// A discovery cutoff. Observations recorded after consumption belong to the next pass.
// AX handles identify remote objects; only the serial snapshot queue reads their attributes.
struct SnapshotObservations: Equatable, @unchecked Sendable {
  var createdElements: [pid_t: [AXUIElement]] = [:]
  var topologyPending = false
  var topologyProcessIDs = Set<pid_t>()
  var topologyRequiresFullSnapshot = false
  var topologyInputTimestamp: TimeInterval?
  var framePending = false
  var frameProcessIDs = Set<pid_t>()
  var frameWindowIDs = Set<WindowID>()
  var frameRequiresFullSnapshot = false
  var frameIncludesUnscopedRefresh = false
  var destroyedWindowIDs = Set<WindowID>()
}

func windowSizeConstraintsForSnapshot(
  previousWindow: Window?, overviewActive: Bool,
  freshRead: () -> WindowSizeConstraints?
) -> WindowSizeConstraints? {
  // Optional native metadata must not interrupt the overview's presentation
  // thread. The ordinary discovery path refreshes it again after closing.
  guard overviewActive else { return freshRead() }
  return previousWindow.map {
    WindowSizeConstraints(minimumWidth: $0.minimumTiledWidth,
      maximumWidth: $0.maximumTiledWidth, maximumHeight: $0.maximumTiledHeight,
      minimumHeight: $0.minimumTiledHeight)
  }
}

func sameAXElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil): return true
  case let (lhs?, rhs?): return CFEqual(lhs, rhs)
  default: return false
  }
}
