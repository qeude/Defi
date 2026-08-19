import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
public final class MacOSPlatform {
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
  var windowManagementCapabilities: [WindowID: WindowManagementCapabilities] = [:]
  var windowManagementMetadataReadCount = 0
  var windowManagementMetadataReuseCount = 0
  let frameCoordinator = AXFrameCoordinator()
  let focusWriter = AXFocusWriter()
  let focusRecoveryResolver = AXFocusRecoveryResolver()
  let windowIDProvider = AXWindowIDProvider()
  var privateWindowIDLookupCount = 0
  var publicWindowIDFallbackCount = 0
  let screenCaptureAccessAvailable = CGPreflightScreenCaptureAccess()
  let borderManager = WindowBorderManager()
  let borderBoundsProvider = WindowServerBoundsProvider()
  var targetFrames: [WindowID: Rect] = [:]
  var pendingFrameDebtWindowIDs = Set<WindowID>()
  var pendingFrameCorrections: [WindowID: Rect] = [:]
  var latestObservedFrames: [WindowID: Rect] = [:]
  var frameCommitExpectations: [WindowID: FrameCommitExpectation] = [:]
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] = [:]
  var newlyDiscoveredWindowIDs = Set<WindowID>()
  var hasCompletedWindowSnapshot = false
  var windowTopologyEventPending = false
  var pendingWindowTopologyProcessIDs = Set<pid_t>()
  var windowTopologyRequiresFullSnapshot = false
  var pendingWindowTopologyInputTimestamp: TimeInterval?
  var pendingFrameProcessIDs = Set<pid_t>()
  var observedFrameEventWindowIDs = Set<WindowID>()
  var pendingFrameRequiresFullSnapshot = false
  var lastSnapshotWindows: [Window] = []
  var lastSnapshotWindowIDs = Set<WindowID>()
  var lastSnapshotProcessIDs = Set<pid_t>()
  var lastApplicationWindowElements: [pid_t: [AXUIElement]] = [:]
  var minimizedWindowElementsByProcess: [pid_t: [AXUIElement]] = [:]
  var transientGeometryWindowElementsByProcess: [pid_t: [AXUIElement]] = [:]
  var unmatchedWindowElementsByProcess: [pid_t: [AXUIElement]] = [:]
  var unmatchedWindowRetryAttemptsByProcess: [pid_t: Int] = [:]
  var windowListReadRetryAttemptsByProcess: [pid_t: Int] = [:]
  var cgWindowInventoryRetryAttempts: Int?
  var retainedWindowIDs = Set<WindowID>()
  var retainedWindowDeadlines: [WindowID: TimeInterval] = [:]
  var explicitlyDestroyedWindowIDs = Set<WindowID>()
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
  var preparedCGWindowInventory: [CGWindowRecord]?
  var preparedCGWindowInventoryDurationMS = 0.0
  var preparedCGWindowInventoryAvailable = false
  var cgWindowInventoryPreparationPending = false
  var preparedAXWindowAttributes: [WindowID: AXWindowAttributes] = [:]
  var preparedAXApplicationWindows: [pid_t: PreparedAXApplicationWindows] = [:]
  var preparedAXWindowAttributesAvailable = false
  var preparedAXWindowAttributesGeneration: UInt64?
  var preparedAXWindowAttributesInputTimestamp: TimeInterval?
  var preparedAXWindowAttributesWindowIDs = Set<WindowID>()
  var preparedAXWindowAttributesProcessIDs = Set<pid_t>()
  var axWindowAttributePreparationPending = false
  var windowSnapshotObservationGeneration: UInt64 = 0
  var deferredFrameCommitMismatchCount = 0
  var observedFrameCommitCount = 0
  var maximumObservedFrameCommitLatencyMS = 0.0
  var commandLatency = CommandLatencyAccumulator()
  var lastHiddenWindowIDs = Set<WindowID>()
  var eventMonitor: PlatformEventMonitor?
  var frameEventPending = false
  var mouseResizeGesturePending = false
  var mouseFocusReleasePending = false
  var nativeFocusEventGeneration: UInt64 = 0
  var mouseFocusReleaseEventGeneration: UInt64?
  var nativeFocusEventPending = false
  var nativeFocusEventProcessIDs = Set<pid_t>()
  var nativeFocusEventHasUnknownProcess = false
  var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  var verifiedNativeFocusedWindowID: WindowID?
  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] = [:]
  var nextInternalFocusRequestID: UInt64 = 0
  var submittedFocusRecoveryRequestID: NativeFocusRequestID?
  var submittedFocusRecoveryTimestamp: TimeInterval?
  var submittedFocusRecoveryGeneration: UInt64?
  var nextFocusRecoveryGeneration: UInt64 = 0
  var focusRecoveryIntentGeneration: UInt64 = 0
  var positionWriteCount = 0
  var sizeWriteCount = 0
  var lastFrameApplyDurationMS = 0.0
  var lastMonitorFrames: [Rect] = []
  var pointerHitTestRecords: [CGWindowRecord] = []
  var pointerHitTestDockProcessIDs = Set<pid_t>()
  var pointerHitTestSnapshotTimestamp: TimeInterval?
  var borderFrames: [FrameAssignment] = []
  var borderSelectedWindowID: WindowID?
  var desiredSelectedWindowID: WindowID?
  var lastNativeFocusedWindowID: WindowID?
  var borderHiddenWindowIDs = Set<WindowID>()
  var borderLiveWindowID: WindowID?
  var windowBorderStacking = WindowBorderStacking.inactive(for: nil)
  var borderStackingRefreshState = WindowBorderStackingRefreshState()
  var borderStackingRefreshTask: Task<Void, Never>?
  var borderStyle = WindowBorderStyle(
    enabled: true,
    width: 4,
    activeColor: 0xffc0_99ff,
    inactiveEnabled: false,
    inactiveColor: 0x66c0_99ff,
    captureEnabled: false
  )

  public var isPrivateWindowIDLookupAvailable: Bool {
    windowIDProvider.isAvailable
  }

  public var privateWindowIDLookupStatus: String {
    switch windowIDProvider.probeResult {
    case .none: "unprobed"
    case .some(true): "true"
    case .some(false): "false"
    }
  }

  public var successfulPrivateWindowIDLookupCount: Int {
    privateWindowIDLookupCount
  }

  public var publicWindowIDLookupFallbackCount: Int {
    publicWindowIDFallbackCount
  }

  public var isPrivateWindowBoundsLookupAvailable: Bool {
    borderBoundsProvider.isAvailable
  }

  public var successfulPrivateWindowBoundsLookupCount: Int {
    borderBoundsProvider.successfulLookupCount
  }

  public var privateWindowBoundsLookupFallbackCount: Int {
    borderBoundsProvider.failureCount
  }

  public var hasScreenCaptureAccess: Bool {
    screenCaptureAccessAvailable
  }
  var cursorWarpAppliedCount = 0
  var cursorWarpSkippedCount = 0
  var cursorWarpFailedCount = 0

  public let userInputTracker = UserInputTracker()
  public let pointerMotionTracker = PointerMotionTracker()

  public init() {
    frameCoordinator.startDisplayLink()
  }

  public func requestFrameRefresh(for windowID: WindowID) {
    invalidatePreparedAXWindowAttributes()
    frameEventPending = true
    observedFrameEventWindowIDs.insert(windowID)
    guard let processID = processIDs[windowID] else {
      pendingFrameRequiresFullSnapshot = true
      return
    }
    pendingFrameProcessIDs.insert(processID)
  }

  func invalidatePreparedAXWindowAttributes() {
    windowSnapshotObservationGeneration &+= 1
    preparedCGWindowInventory = nil
    preparedCGWindowInventoryAvailable = false
    preparedAXWindowAttributes.removeAll(keepingCapacity: true)
    preparedAXApplicationWindows.removeAll(keepingCapacity: true)
    preparedAXWindowAttributesAvailable = false
    preparedAXWindowAttributesGeneration = nil
    preparedAXWindowAttributesInputTimestamp = nil
    preparedAXWindowAttributesWindowIDs.removeAll(keepingCapacity: true)
    preparedAXWindowAttributesProcessIDs.removeAll(keepingCapacity: true)
  }

}
