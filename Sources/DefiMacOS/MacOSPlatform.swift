import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
public final class MacOSPlatform {
  let snapshotEngine = SnapshotEngine()
  var elements: [WindowID: AXUIElement] {
    get { snapshotEngine.elements }
    set { snapshotEngine.elements = newValue }
  }
  var processIDs: [WindowID: pid_t] {
    get { snapshotEngine.processIDs }
    set { snapshotEngine.processIDs = newValue }
  }
  var transientOwnerWindowIDs: [WindowID: WindowID] {
    get { snapshotEngine.transientOwnerWindowIDs }
    set { snapshotEngine.transientOwnerWindowIDs = newValue }
  }
  var transientOwnerResolutionAttempts: [WindowID: Int] {
    get { snapshotEngine.transientOwnerResolutionAttempts }
    set { snapshotEngine.transientOwnerResolutionAttempts = newValue }
  }
  var transientOwnerResolutionRetryAfter: [WindowID: TimeInterval] {
    get { snapshotEngine.transientOwnerResolutionRetryAfter }
    set { snapshotEngine.transientOwnerResolutionRetryAfter = newValue }
  }
  var floatingWindowIDs: Set<WindowID> {
    get { snapshotEngine.floatingWindowIDs }
    set { snapshotEngine.floatingWindowIDs = newValue }
  }
  var applications: [pid_t: AXUIElement] {
    get { snapshotEngine.applications }
    set { snapshotEngine.applications = newValue }
  }
  var applicationIDsByProcess: [pid_t: String] {
    get { snapshotEngine.applicationIDsByProcess }
    set { snapshotEngine.applicationIDsByProcess = newValue }
  }
  var applicationWindowCounts: [pid_t: Int] {
    get { snapshotEngine.applicationWindowCounts }
    set { snapshotEngine.applicationWindowCounts = newValue }
  }
  var enhancedUIByProcess: [pid_t: Bool] {
    get { snapshotEngine.enhancedUIByProcess }
    set { snapshotEngine.enhancedUIByProcess = newValue }
  }
  var multipleAttributeReadsSupportedByProcess: [pid_t: Bool] {
    get { snapshotEngine.multipleAttributeReadsSupportedByProcess }
    set { snapshotEngine.multipleAttributeReadsSupportedByProcess = newValue }
  }
  var failedBatchedWindowAttributeReadsByElement: [AXWindowElementIdentity: Int] {
    get { snapshotEngine.failedBatchedWindowAttributeReadsByElement }
    set { snapshotEngine.failedBatchedWindowAttributeReadsByElement = newValue }
  }
  var batchedWindowAttributeReadCount: Int {
    get { snapshotEngine.batchedWindowAttributeReadCount }
    set { snapshotEngine.batchedWindowAttributeReadCount = newValue }
  }
  var fallbackWindowAttributeReadCount: Int {
    get { snapshotEngine.fallbackWindowAttributeReadCount }
    set { snapshotEngine.fallbackWindowAttributeReadCount = newValue }
  }
  var windowManagementCapabilities: [WindowID: WindowManagementCapabilities] {
    get { snapshotEngine.windowManagementCapabilities }
    set { snapshotEngine.windowManagementCapabilities = newValue }
  }
  var windowManagementMetadataReadCount: Int {
    get { snapshotEngine.windowManagementMetadataReadCount }
    set { snapshotEngine.windowManagementMetadataReadCount = newValue }
  }
  var windowManagementMetadataReuseCount: Int {
    get { snapshotEngine.windowManagementMetadataReuseCount }
    set { snapshotEngine.windowManagementMetadataReuseCount = newValue }
  }
  let frameCoordinator = AXFrameCoordinator()
  let focusWriter = AXFocusWriter()
  let focusRecoveryResolver = AXFocusRecoveryResolver()
  let windowIDProvider = AXWindowIDProvider()
  var privateWindowIDLookupCount: Int {
    get { snapshotEngine.privateWindowIDLookupCount }
    set { snapshotEngine.privateWindowIDLookupCount = newValue }
  }
  var publicWindowIDFallbackCount: Int {
    get { snapshotEngine.publicWindowIDFallbackCount }
    set { snapshotEngine.publicWindowIDFallbackCount = newValue }
  }
  let screenCaptureAccessAvailable = CGPreflightScreenCaptureAccess()
  let borderManager = WindowBorderManager()
  let borderBoundsProvider = WindowServerBoundsProvider()
  var targetFrames: [WindowID: Rect] {
    get { snapshotEngine.targetFrames }
    set { snapshotEngine.targetFrames = newValue }
  }
  var pendingFrameDebtWindowIDs = Set<WindowID>()
  var pendingFrameCorrections: [WindowID: Rect] {
    get { snapshotEngine.pendingFrameCorrections }
    set { snapshotEngine.pendingFrameCorrections = newValue }
  }
  var latestObservedFrames: [WindowID: Rect] {
    get { snapshotEngine.latestObservedFrames }
    set { snapshotEngine.latestObservedFrames = newValue }
  }
  var frameCommitExpectations: [WindowID: FrameCommitExpectation] {
    get { snapshotEngine.frameCommitExpectations }
    set { snapshotEngine.frameCommitExpectations = newValue }
  }
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] = [:]
  var newlyDiscoveredWindowIDs: Set<WindowID> {
    get { snapshotEngine.newlyDiscoveredWindowIDs }
    set { snapshotEngine.newlyDiscoveredWindowIDs = newValue }
  }
  var hasCompletedWindowSnapshot = false
  var windowTopologyEventPending = false

  public var hasPendingWindowTopologyEvent: Bool {
    windowTopologyEventPending
  }
  var pendingWindowTopologyProcessIDs: Set<pid_t> {
    get { snapshotEngine.pendingWindowTopologyProcessIDs }
    set { snapshotEngine.pendingWindowTopologyProcessIDs = newValue }
  }
  var windowTopologyRequiresFullSnapshot = false
  var pendingWindowTopologyInputTimestamp: TimeInterval? {
    get { snapshotEngine.pendingWindowTopologyInputTimestamp }
    set { snapshotEngine.pendingWindowTopologyInputTimestamp = newValue }
  }
  var pendingFrameProcessIDs: Set<pid_t> {
    get { snapshotEngine.pendingFrameProcessIDs }
    set { snapshotEngine.pendingFrameProcessIDs = newValue }
  }
  var observedFrameEventWindowIDs: Set<WindowID> {
    get { snapshotEngine.observedFrameEventWindowIDs }
    set { snapshotEngine.observedFrameEventWindowIDs = newValue }
  }
  var pendingFrameRequiresFullSnapshot = false
  var lastSnapshotWindows: [Window] {
    get { snapshotEngine.lastSnapshotWindows }
    set { snapshotEngine.lastSnapshotWindows = newValue }
  }
  var lastSnapshotWindowIDs: Set<WindowID> {
    get { snapshotEngine.lastSnapshotWindowIDs }
    set { snapshotEngine.lastSnapshotWindowIDs = newValue }
  }
  var lastSnapshotProcessIDs: Set<pid_t> {
    get { snapshotEngine.lastSnapshotProcessIDs }
    set { snapshotEngine.lastSnapshotProcessIDs = newValue }
  }
  var lastApplicationWindowElements: [pid_t: [AXUIElement]] {
    get { snapshotEngine.lastApplicationWindowElements }
    set { snapshotEngine.lastApplicationWindowElements = newValue }
  }
  var minimizedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { snapshotEngine.minimizedWindowElementsByProcess }
    set { snapshotEngine.minimizedWindowElementsByProcess = newValue }
  }
  var transientGeometryWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { snapshotEngine.transientGeometryWindowElementsByProcess }
    set { snapshotEngine.transientGeometryWindowElementsByProcess = newValue }
  }
  var unmatchedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { snapshotEngine.unmatchedWindowElementsByProcess }
    set { snapshotEngine.unmatchedWindowElementsByProcess = newValue }
  }
  var unmatchedWindowRetryAttemptsByProcess: [pid_t: Int] {
    get { snapshotEngine.unmatchedWindowRetryAttemptsByProcess }
    set { snapshotEngine.unmatchedWindowRetryAttemptsByProcess = newValue }
  }
  var windowListReadRetryAttemptsByProcess: [pid_t: Int] {
    get { snapshotEngine.windowListReadRetryAttemptsByProcess }
    set { snapshotEngine.windowListReadRetryAttemptsByProcess = newValue }
  }
  var cgWindowInventoryRetryAttempts: Int? {
    get { snapshotEngine.cgWindowInventoryRetryAttempts }
    set { snapshotEngine.cgWindowInventoryRetryAttempts = newValue }
  }
  var retainedWindowIDs: Set<WindowID> {
    get { snapshotEngine.retainedWindowIDs }
    set { snapshotEngine.retainedWindowIDs = newValue }
  }
  var retainedWindowDeadlines: [WindowID: TimeInterval] {
    get { snapshotEngine.retainedWindowDeadlines }
    set { snapshotEngine.retainedWindowDeadlines = newValue }
  }
  var explicitlyDestroyedWindowIDs: Set<WindowID> {
    get { snapshotEngine.explicitlyDestroyedWindowIDs }
    set { snapshotEngine.explicitlyDestroyedWindowIDs = newValue }
  }
  var lastWindowSnapshotDurationMS = 0.0
  var maximumWindowSnapshotDurationMS = 0.0
  var windowSnapshotDurationSamplesMS: [Double] {
    get { snapshotEngine.windowSnapshotDurationSamplesMS }
    set { snapshotEngine.windowSnapshotDurationSamplesMS = newValue }
  }
  var fullWindowSnapshotCount = 0
  var incrementalWindowSnapshotCount = 0
  var cachedWindowSnapshotCount = 0
  var applicationInventorySnapshotCount = 0
  var applicationWindowListReadCount = 0
  var applicationInventoryDurationSamplesMS: [Double] {
    get { snapshotEngine.applicationInventoryDurationSamplesMS }
    set { snapshotEngine.applicationInventoryDurationSamplesMS = newValue }
  }
  var applicationWindowListDurationSamplesMS: [Double] {
    get { snapshotEngine.applicationWindowListDurationSamplesMS }
    set { snapshotEngine.applicationWindowListDurationSamplesMS = newValue }
  }
  var snapshotCGWindowCopyCount = 0
  var lastSnapshotCGWindowCopyDurationMS = 0.0
  var maximumSnapshotCGWindowCopyDurationMS = 0.0
  var preparedCGWindowInventory: [CGWindowRecord]? {
    get { snapshotEngine.preparedCGWindowInventory }
    set { snapshotEngine.preparedCGWindowInventory = newValue }
  }
  var preparedCGWindowInventoryDurationMS = 0.0
  var preparedCGWindowInventoryAvailable = false
  var cgWindowInventoryPreparationPending = false
  var preparedAXWindowAttributes: [WindowID: AXWindowAttributes] {
    get { snapshotEngine.preparedAXWindowAttributes }
    set { snapshotEngine.preparedAXWindowAttributes = newValue }
  }
  var preparedTransientOwnerWindowIDs: [WindowID: WindowID] {
    get { snapshotEngine.preparedTransientOwnerWindowIDs }
    set { snapshotEngine.preparedTransientOwnerWindowIDs = newValue }
  }
  var preparedAXApplicationWindows: [pid_t: PreparedAXApplicationWindows] {
    get { snapshotEngine.preparedAXApplicationWindows }
    set { snapshotEngine.preparedAXApplicationWindows = newValue }
  }
  var preparedAXWindowAttributesAvailable = false
  var preparedAXWindowAttributesGeneration: UInt64? {
    get { snapshotEngine.preparedAXWindowAttributesGeneration }
    set { snapshotEngine.preparedAXWindowAttributesGeneration = newValue }
  }
  var preparedAXWindowAttributesInputTimestamp: TimeInterval? {
    get { snapshotEngine.preparedAXWindowAttributesInputTimestamp }
    set { snapshotEngine.preparedAXWindowAttributesInputTimestamp = newValue }
  }
  var preparedAXWindowAttributesWindowIDs: Set<WindowID> {
    get { snapshotEngine.preparedAXWindowAttributesWindowIDs }
    set { snapshotEngine.preparedAXWindowAttributesWindowIDs = newValue }
  }
  var preparedAXWindowAttributesProcessIDs: Set<pid_t> {
    get { snapshotEngine.preparedAXWindowAttributesProcessIDs }
    set { snapshotEngine.preparedAXWindowAttributesProcessIDs = newValue }
  }
  var axWindowAttributePreparationPending = false
  var windowSnapshotObservationGeneration: UInt64 {
    get { snapshotEngine.windowSnapshotObservationGeneration }
    set { snapshotEngine.windowSnapshotObservationGeneration = newValue }
  }
  var deferredFrameCommitMismatchCount = 0
  var observedFrameCommitCount = 0
  var maximumObservedFrameCommitLatencyMS = 0.0
  var commandLatency = CommandLatencyAccumulator()
  var commandDiagnosticHandler:
    (@MainActor @Sendable (CommandDiagnosticSample) -> Void)?
  var lastHiddenWindowIDs: Set<WindowID> {
    get { snapshotEngine.lastHiddenWindowIDs }
    set { snapshotEngine.lastHiddenWindowIDs = newValue }
  }
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
  var deferredFreshReadProcessIDs: Set<pid_t> {
    get { snapshotEngine.deferredFreshReadProcessIDs }
    set { snapshotEngine.deferredFreshReadProcessIDs = newValue }
  }
  var deferredFreshReadsStartedAt: TimeInterval? {
    get { snapshotEngine.deferredFreshReadsStartedAt }
    set { snapshotEngine.deferredFreshReadsStartedAt = newValue }
  }
  var chunkedFullRefreshRemainingProcessIDs: Set<pid_t>? {
    get { snapshotEngine.chunkedFullRefreshRemainingProcessIDs }
    set { snapshotEngine.chunkedFullRefreshRemainingProcessIDs = newValue }
  }
  var incompatibleFreshReadDeadlines: [pid_t: TimeInterval] {
    get { snapshotEngine.incompatibleFreshReadDeadlines }
    set { snapshotEngine.incompatibleFreshReadDeadlines = newValue }
  }
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
    preparedTransientOwnerWindowIDs.removeAll(keepingCapacity: true)
    preparedAXApplicationWindows.removeAll(keepingCapacity: true)
    preparedAXWindowAttributesAvailable = false
    preparedAXWindowAttributesGeneration = nil
    preparedAXWindowAttributesInputTimestamp = nil
    preparedAXWindowAttributesWindowIDs.removeAll(keepingCapacity: true)
    preparedAXWindowAttributesProcessIDs.removeAll(keepingCapacity: true)
  }

}
