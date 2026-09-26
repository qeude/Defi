import DefiRuntime
import AppKit
import Synchronization
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@NavigationActor
public final class MacOSPlatform {
  nonisolated let snapshotEngine: SnapshotEngine


  @MainActor func frame(of element: AXUIElement) -> Rect? {
    snapshotEngine.frame(of: element)
  }

  func stableWindowID(
    processID: pid_t?,
    in windows: [Window]
  ) -> WindowID? {
    snapshotEngine.stableWindowID(
      processID: processID,
      in: windows
    )
  }

  nonisolated public func accessibilityTrusted(prompt: Bool) -> Bool {
    return snapshotEngine.accessibilityTrusted(prompt: prompt)
  }

  @MainActor public func snapshot(config: Config) -> DesktopSnapshot {
    return snapshotEngine.snapshot(config: config)
  }

  public func beginSnapshot(
    config: Config,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool,
    forceApplicationInventoryRefresh: Bool,
    completion: @escaping @NavigationActor @Sendable (DesktopSnapshot) -> Void
  ) {
    snapshotEngine.beginSnapshot(
      config: config,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh,
      completion: completion
    )
  }

  @MainActor public func snapshot(
    config: Config,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool = false,
    forceApplicationInventoryRefresh: Bool = false
  ) -> DesktopSnapshot {
    return snapshotEngine.snapshot(
      config: config,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh
    )
  }
  nonisolated var elements: [WindowID: AXUIElement] {
    get { snapshotEngine.elements }
    set { snapshotEngine.elements = newValue }
  }
  nonisolated var processIDs: [WindowID: pid_t] {
    get { snapshotEngine.processIDs }
    set { snapshotEngine.processIDs = newValue }
  }
  nonisolated var transientOwnerWindowIDs: [WindowID: WindowID] {
    get { snapshotEngine.transientOwnerWindowIDs }
    set { snapshotEngine.transientOwnerWindowIDs = newValue }
  }
  nonisolated var transientOwnerResolutionAttempts: [WindowID: Int] {
    get { snapshotEngine.transientOwnerResolutionAttempts }
    set { snapshotEngine.transientOwnerResolutionAttempts = newValue }
  }
  nonisolated var transientOwnerResolutionRetryAfter: [WindowID: TimeInterval] {
    get { snapshotEngine.transientOwnerResolutionRetryAfter }
    set { snapshotEngine.transientOwnerResolutionRetryAfter = newValue }
  }
  nonisolated var floatingWindowIDs: Set<WindowID> {
    get { snapshotEngine.floatingWindowIDs }
    set { snapshotEngine.floatingWindowIDs = newValue }
  }
  nonisolated var applications: [pid_t: AXUIElement] {
    get { snapshotEngine.applications }
    set { snapshotEngine.applications = newValue }
  }
  nonisolated var applicationIDsByProcess: [pid_t: String] {
    get { snapshotEngine.applicationIDsByProcess }
    set { snapshotEngine.applicationIDsByProcess = newValue }
  }
  nonisolated var applicationWindowCounts: [pid_t: Int] {
    get { snapshotEngine.applicationWindowCounts }
    set { snapshotEngine.applicationWindowCounts = newValue }
  }
  nonisolated var enhancedUIByProcess: [pid_t: Bool] {
    get { snapshotEngine.enhancedUIByProcess }
    set { snapshotEngine.enhancedUIByProcess = newValue }
  }
  nonisolated var multipleAttributeReadsSupportedByProcess: [pid_t: Bool] {
    get { snapshotEngine.multipleAttributeReadsSupportedByProcess }
    set { snapshotEngine.multipleAttributeReadsSupportedByProcess = newValue }
  }
  nonisolated var failedBatchedWindowAttributeReadsByElement: [AXWindowElementIdentity: Int] {
    get { snapshotEngine.failedBatchedWindowAttributeReadsByElement }
    set { snapshotEngine.failedBatchedWindowAttributeReadsByElement = newValue }
  }
  nonisolated var batchedWindowAttributeReadCount: Int {
    get { snapshotEngine.batchedWindowAttributeReadCount }
    set { snapshotEngine.batchedWindowAttributeReadCount = newValue }
  }
  nonisolated var fallbackWindowAttributeReadCount: Int {
    get { snapshotEngine.fallbackWindowAttributeReadCount }
    set { snapshotEngine.fallbackWindowAttributeReadCount = newValue }
  }
  nonisolated var windowManagementCapabilities: [WindowID: WindowManagementCapabilities] {
    get { snapshotEngine.windowManagementCapabilities }
    set { snapshotEngine.windowManagementCapabilities = newValue }
  }
  nonisolated var windowManagementMetadataReadCount: Int {
    get { snapshotEngine.windowManagementMetadataReadCount }
    set { snapshotEngine.windowManagementMetadataReadCount = newValue }
  }
  nonisolated var windowManagementMetadataReuseCount: Int {
    get { snapshotEngine.windowManagementMetadataReuseCount }
    set { snapshotEngine.windowManagementMetadataReuseCount = newValue }
  }
  nonisolated let frameCoordinator = AXFrameCoordinator()
  nonisolated let focusWriter = AXFocusWriter()
  nonisolated let focusRecoveryResolver = AXFocusRecoveryResolver()
  @MainActor lazy var windowIDProvider = AXWindowIDProvider()


  @MainActor lazy var borderManager = WindowBorderManager()
  @MainActor lazy var nativeFullscreenPlaceholderManager = NativeFullscreenPlaceholderManager()
  @MainActor lazy var borderBoundsProvider = WindowServerBoundsProvider()
  nonisolated var targetFrames: [WindowID: Rect] {
    get { snapshotEngine.targetFrames }
    set { snapshotEngine.targetFrames = newValue }
  }
  nonisolated var pendingFrameDebtWindowIDs: Set<WindowID> {
    get { snapshotEngine.pendingFrameDebtWindowIDs }
    set { snapshotEngine.pendingFrameDebtWindowIDs = newValue }
  }
  nonisolated var pendingFrameCorrections: [WindowID: Rect] {
    get { snapshotEngine.pendingFrameCorrections }
    set { snapshotEngine.pendingFrameCorrections = newValue }
  }
  nonisolated var latestObservedFrames: [WindowID: Rect] {
    get { snapshotEngine.latestObservedFrames }
    set { snapshotEngine.latestObservedFrames = newValue }
  }
  nonisolated var frameCommitExpectations: [WindowID: FrameCommitExpectation] {
    get { snapshotEngine.frameCommitExpectations }
    set { snapshotEngine.frameCommitExpectations = newValue }
  }
  nonisolated var initialFrameSettlementDeadlines: [WindowID: TimeInterval] {
    get { snapshotEngine.initialFrameSettlementDeadlines }
    set { snapshotEngine.initialFrameSettlementDeadlines = newValue }
  }
  nonisolated var newlyDiscoveredWindowIDs: Set<WindowID> {
    get { snapshotEngine.newlyDiscoveredWindowIDs }
    set { snapshotEngine.newlyDiscoveredWindowIDs = newValue }
  }
  nonisolated var hasCompletedWindowSnapshot: Bool {
    get { snapshotEngine.hasCompletedWindowSnapshot }
    set { snapshotEngine.hasCompletedWindowSnapshot = newValue }
  }

  public var hasPendingWindowTopologyEvent: Bool {
    snapshotEngine.pendingObservations.topologyPending
  }
  nonisolated var lastSnapshotWindows: [Window] {
    get { snapshotEngine.lastSnapshotWindows }
    set { snapshotEngine.lastSnapshotWindows = newValue }
  }
  nonisolated var lastSnapshotWindowIDs: Set<WindowID> {
    get { snapshotEngine.lastSnapshotWindowIDs }
    set { snapshotEngine.lastSnapshotWindowIDs = newValue }
  }
  nonisolated var lastSnapshotProcessIDs: Set<pid_t> {
    get { snapshotEngine.lastSnapshotProcessIDs }
    set { snapshotEngine.lastSnapshotProcessIDs = newValue }
  }
  nonisolated var lastApplicationWindowElements: [pid_t: [AXUIElement]] {
    get { snapshotEngine.lastApplicationWindowElements }
    set { snapshotEngine.lastApplicationWindowElements = newValue }
  }
  nonisolated var minimizedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { snapshotEngine.minimizedWindowElementsByProcess }
    set { snapshotEngine.minimizedWindowElementsByProcess = newValue }
  }
  nonisolated var transientGeometryWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { snapshotEngine.transientGeometryWindowElementsByProcess }
    set { snapshotEngine.transientGeometryWindowElementsByProcess = newValue }
  }
  nonisolated var unmatchedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { snapshotEngine.unmatchedWindowElementsByProcess }
    set { snapshotEngine.unmatchedWindowElementsByProcess = newValue }
  }
  nonisolated var unmatchedWindowRetryAttemptsByProcess: [pid_t: Int] {
    get { snapshotEngine.unmatchedWindowRetryAttemptsByProcess }
    set { snapshotEngine.unmatchedWindowRetryAttemptsByProcess = newValue }
  }
  nonisolated var windowListReadRetryAttemptsByProcess: [pid_t: Int] {
    get { snapshotEngine.windowListReadRetryAttemptsByProcess }
    set { snapshotEngine.windowListReadRetryAttemptsByProcess = newValue }
  }
  nonisolated var cgWindowInventoryRetryAttempts: Int? {
    get { snapshotEngine.cgWindowInventoryRetryAttempts }
    set { snapshotEngine.cgWindowInventoryRetryAttempts = newValue }
  }
  nonisolated var retainedWindowIDs: Set<WindowID> {
    get { snapshotEngine.retainedWindowIDs }
    set { snapshotEngine.retainedWindowIDs = newValue }
  }
  nonisolated var retainedWindowDeadlines: [WindowID: TimeInterval] {
    get { snapshotEngine.retainedWindowDeadlines }
    set { snapshotEngine.retainedWindowDeadlines = newValue }
  }
  nonisolated var lastWindowSnapshotDurationMS: Double {
    get { snapshotEngine.lastWindowSnapshotDurationMS }
    set { snapshotEngine.lastWindowSnapshotDurationMS = newValue }
  }
  nonisolated var maximumWindowSnapshotDurationMS: Double {
    get { snapshotEngine.maximumWindowSnapshotDurationMS }
    set { snapshotEngine.maximumWindowSnapshotDurationMS = newValue }
  }
  nonisolated var windowSnapshotDurationSamplesMS: [Double] {
    get { snapshotEngine.windowSnapshotDurationSamplesMS }
    set { snapshotEngine.windowSnapshotDurationSamplesMS = newValue }
  }
  nonisolated var fullWindowSnapshotCount: Int {
    get { snapshotEngine.fullWindowSnapshotCount }
    set { snapshotEngine.fullWindowSnapshotCount = newValue }
  }
  nonisolated var incrementalWindowSnapshotCount: Int {
    get { snapshotEngine.incrementalWindowSnapshotCount }
    set { snapshotEngine.incrementalWindowSnapshotCount = newValue }
  }
  nonisolated var cachedWindowSnapshotCount: Int {
    get { snapshotEngine.cachedWindowSnapshotCount }
    set { snapshotEngine.cachedWindowSnapshotCount = newValue }
  }
  nonisolated var applicationInventorySnapshotCount: Int {
    get { snapshotEngine.applicationInventorySnapshotCount }
    set { snapshotEngine.applicationInventorySnapshotCount = newValue }
  }
  nonisolated var applicationWindowListReadCount: Int {
    get { snapshotEngine.applicationWindowListReadCount }
    set { snapshotEngine.applicationWindowListReadCount = newValue }
  }
  nonisolated var applicationInventoryDurationSamplesMS: [Double] {
    get { snapshotEngine.applicationInventoryDurationSamplesMS }
    set { snapshotEngine.applicationInventoryDurationSamplesMS = newValue }
  }
  nonisolated var applicationWindowListDurationSamplesMS: [Double] {
    get { snapshotEngine.applicationWindowListDurationSamplesMS }
    set { snapshotEngine.applicationWindowListDurationSamplesMS = newValue }
  }
  nonisolated var snapshotCGWindowCopyCount: Int {
    get { snapshotEngine.snapshotCGWindowCopyCount }
    set { snapshotEngine.snapshotCGWindowCopyCount = newValue }
  }
  nonisolated var lastSnapshotCGWindowCopyDurationMS: Double {
    get { snapshotEngine.lastSnapshotCGWindowCopyDurationMS }
    set { snapshotEngine.lastSnapshotCGWindowCopyDurationMS = newValue }
  }
  nonisolated var maximumSnapshotCGWindowCopyDurationMS: Double {
    get { snapshotEngine.maximumSnapshotCGWindowCopyDurationMS }
    set { snapshotEngine.maximumSnapshotCGWindowCopyDurationMS = newValue }
  }
  nonisolated var windowSnapshotObservationGeneration: UInt64 {
    get { snapshotEngine.windowSnapshotObservationGeneration }
    set { snapshotEngine.windowSnapshotObservationGeneration = newValue }
  }
  nonisolated var deferredFrameCommitMismatchCount: Int {
    get { snapshotEngine.deferredFrameCommitMismatchCount }
    set { snapshotEngine.deferredFrameCommitMismatchCount = newValue }
  }
  nonisolated var observedFrameCommitCount: Int {
    get { snapshotEngine.observedFrameCommitCount }
    set { snapshotEngine.observedFrameCommitCount = newValue }
  }
  nonisolated var maximumObservedFrameCommitLatencyMS: Double {
    get { snapshotEngine.maximumObservedFrameCommitLatencyMS }
    set { snapshotEngine.maximumObservedFrameCommitLatencyMS = newValue }
  }
  var commandLatency = CommandLatencyAccumulator()
  var commandDiagnosticHandler: (@NavigationActor @Sendable (CommandDiagnosticSample) -> Void)?
  nonisolated var lastHiddenWindowIDs: Set<WindowID> {
    get { snapshotEngine.lastHiddenWindowIDs }
    set { snapshotEngine.lastHiddenWindowIDs = newValue }
  }
  @MainActor var presentationStatusPending = false
  @MainActor var accessibilityDisplayObserver: NSObjectProtocol?
  @MainActor var eventMonitor: PlatformEventMonitor?
  nonisolated var mouseResizeGesturePending: Bool {
    get { snapshotEngine.mouseResizeGesturePending }
    set { snapshotEngine.mouseResizeGesturePending = newValue }
  }
  nonisolated var mouseFocusReleasePending: Bool {
    get { snapshotEngine.mouseFocusReleasePending }
    set { snapshotEngine.mouseFocusReleasePending = newValue }
  }
  nonisolated var nativeFocusEventGeneration: UInt64 {
    get { snapshotEngine.nativeFocusEventGeneration }
    set { snapshotEngine.nativeFocusEventGeneration = newValue }
  }
  nonisolated var mouseFocusReleaseEventGeneration: UInt64? {
    get { snapshotEngine.mouseFocusReleaseEventGeneration }
    set { snapshotEngine.mouseFocusReleaseEventGeneration = newValue }
  }
  nonisolated var nativeFocusEventPending: Bool {
    get { snapshotEngine.nativeFocusEventPending }
    set { snapshotEngine.nativeFocusEventPending = newValue }
  }
  nonisolated var nativeFocusEventProcessIDs: Set<pid_t> {
    get { snapshotEngine.nativeFocusEventProcessIDs }
    set { snapshotEngine.nativeFocusEventProcessIDs = newValue }
  }
  nonisolated var nativeFocusEventHasUnknownProcess: Bool {
    get { snapshotEngine.nativeFocusEventHasUnknownProcess }
    set { snapshotEngine.nativeFocusEventHasUnknownProcess = newValue }
  }
  nonisolated var lastFocusedWindowByProcess: [pid_t: WindowID] {
    get { snapshotEngine.lastFocusedWindowByProcess }
    set { snapshotEngine.lastFocusedWindowByProcess = newValue }
  }
  nonisolated var verifiedNativeFocusedWindowID: WindowID? {
    get { snapshotEngine.verifiedNativeFocusedWindowID }
    set { snapshotEngine.verifiedNativeFocusedWindowID = newValue }
  }
  nonisolated var internalFocusSuppressions: [WindowID: InternalFocusSuppression] {
    get { snapshotEngine.internalFocusSuppressions }
    set { snapshotEngine.internalFocusSuppressions = newValue }
  }
  var nextInternalFocusRequestID: UInt64 = 0
  var submittedFocusRecoveryRequestID: NativeFocusRequestID?
  var submittedFocusRecoveryTimestamp: TimeInterval?
  var submittedFocusRecoveryGeneration: UInt64?
  var nextFocusRecoveryGeneration: UInt64 = 0
  nonisolated let cursorWarpGeneration = Mutex<UInt64>(0)
  var focusRecoveryIntentGeneration: UInt64 = 0 {
    didSet { cursorWarpGeneration.withLock { $0 &+= 1 } }
  }
  var frameSubmissionGeneration: UInt64 = 0 {
    didSet { cursorWarpGeneration.withLock { $0 &+= 1 } }
  }
  var positionWriteCount = 0
  var sizeWriteCount = 0
  var lastFrameApplyDurationMS = 0.0
  nonisolated var lastMonitorFrames: [Rect] {
    get { snapshotEngine.lastMonitorFrames }
    set { snapshotEngine.lastMonitorFrames = newValue }
  }
  nonisolated var deferredFreshReadProcessIDs: Set<pid_t> {
    get { snapshotEngine.deferredFreshReadProcessIDs }
    set { snapshotEngine.deferredFreshReadProcessIDs = newValue }
  }
  nonisolated var deferredFreshReadsStartedAt: TimeInterval? {
    get { snapshotEngine.deferredFreshReadsStartedAt }
    set { snapshotEngine.deferredFreshReadsStartedAt = newValue }
  }
  nonisolated var chunkedFullRefreshRemainingProcessIDs: Set<pid_t>? {
    get { snapshotEngine.chunkedFullRefreshRemainingProcessIDs }
    set { snapshotEngine.chunkedFullRefreshRemainingProcessIDs = newValue }
  }
  nonisolated var incompatibleFreshReadDeadlines: [pid_t: TimeInterval] {
    get { snapshotEngine.incompatibleFreshReadDeadlines }
    set { snapshotEngine.incompatibleFreshReadDeadlines = newValue }
  }
  @MainActor var pointerHitTestRecords: [CGWindowRecord] = []
  @MainActor var pointerHitTestDockProcessIDs = Set<pid_t>()
  @MainActor var pointerHitTestSnapshotTimestamp: TimeInterval?
  @MainActor var borderFrames: [FrameAssignment] = []
  @MainActor var borderSelectedWindowID: WindowID?
  var desiredSelectedWindowID: WindowID?
  nonisolated var lastNativeFocusedWindowID: WindowID? {
    get { snapshotEngine.lastNativeFocusedWindowID }
    set { snapshotEngine.lastNativeFocusedWindowID = newValue }
  }
  @MainActor var borderHiddenWindowIDs = Set<WindowID>()
  @MainActor var borderLiveWindowID: WindowID?
  public private(set) var nativeFullscreenWindowIDs = Set<WindowID>()
  public private(set) var activeNativeFullscreenWindowIDs = Set<WindowID>()
  @MainActor var windowBorderStacking = WindowBorderStacking.inactive(for: nil)
  @MainActor var borderStackingRefreshState = WindowBorderStackingRefreshState()
  @MainActor var borderStackingRefreshTask: Task<Void, Never>?
  @MainActor var borderStyle = WindowBorderStyle(
    enabled: true,
    width: 4,
    activeColor: 0xffc0_99ff,
    inactiveEnabled: false,
    inactiveColor: 0x66c0_99ff,
    captureEnabled: false
  )

  var presentationStatus = PlatformPresentationStatus()
  public var privateWindowIDLookupStatus: String { presentationStatus.windowIDStatus }
  public var successfulPrivateWindowIDLookupCount: Int { snapshotEngine.privateWindowIDLookupCount }
  public var publicWindowIDLookupFallbackCount: Int { snapshotEngine.publicWindowIDFallbackCount }
  public var isPrivateWindowBoundsLookupAvailable: Bool { presentationStatus.boundsAvailable }
  public var successfulPrivateWindowBoundsLookupCount: Int { presentationStatus.boundsSuccesses }
  public var privateWindowBoundsLookupFallbackCount: Int { presentationStatus.boundsFallbacks }
  public var isPrivateWindowConstraintLookupAvailable: Bool { presentationStatus.constraintsAvailable }
  public var successfulPrivateWindowConstraintLookupCount: Int { presentationStatus.constraintsSuccesses }
  public var privateWindowConstraintLookupFallbackCount: Int { presentationStatus.constraintsFallbacks }
  @MainActor var presentedNativeFullscreenWindowIDs = Set<WindowID>()
  @MainActor var presentedActiveNativeFullscreenWindowIDs = Set<WindowID>()
  @MainActor var presentedSelectedWindowID: WindowID?
  var plannedBorderFrames: [FrameAssignment] = []

  var cursorWarpAppliedCount = 0
  var cursorWarpSkippedCount = 0
  var cursorWarpFailedCount = 0

  public nonisolated let userInputTracker = UserInputTracker()
  public nonisolated let pointerMotionTracker = PointerMotionTracker()

  public init() {
    snapshotEngine = SnapshotEngine(
      frameCoordinator: frameCoordinator, userInputTracker: userInputTracker
    )
    snapshotEngine.host = self
    frameCoordinator.borderLiveGeometryHandler = { [weak self] frames in
      self?.enqueuePresentation { platform in
        var observed: [WindowID: Rect] = [:]
        for (windowID, completed) in frames {
          observed[windowID] = platform.borderBoundsProvider.frame(for: windowID) ?? completed
        }
        _ = platform.borderManager.updateGeometry(frames: observed, style: platform.borderStyle)
      }
    }
  }

  public func updateNativeFullscreenWindowIDs(
    _ windowIDs: Set<WindowID>,
    activeWindowIDs: Set<WindowID> = []
  ) {
    let entered = windowIDs.subtracting(nativeFullscreenWindowIDs)
    let exited = nativeFullscreenWindowIDs.subtracting(windowIDs)
    nativeFullscreenWindowIDs = windowIDs
    activeNativeFullscreenWindowIDs = activeWindowIDs.intersection(windowIDs)
    let now = ProcessInfo.processInfo.systemUptime
    if !entered.isEmpty {
      frameSubmissionGeneration &+= 1
      if entered.contains(where: frameCoordinator.isBusy(for:)) {
        frameCoordinator.invalidate(reason: "native-fullscreen")
      }
    }
    for windowID in entered {
      frameCommitExpectations[windowID] = nil
      initialFrameSettlementDeadlines[windowID] = now + 2.5
      pendingFrameCorrections[windowID] = nil
      pendingFrameDebtWindowIDs.remove(windowID)
    }
    for windowID in exited {
      initialFrameSettlementDeadlines[windowID] = now + 2.5
    }
    let activeIDs = activeNativeFullscreenWindowIDs
    enqueuePresentation { platform in
      platform.presentedNativeFullscreenWindowIDs = windowIDs
      platform.presentedActiveNativeFullscreenWindowIDs = activeIDs
      if let activeWindowID = platform.borderManager.activeWindowID,
        windowIDs.contains(activeWindowID) { platform.borderManager.hide() }
    }
    if !entered.isEmpty {
      let ids = entered.sorted { $0.rawValue < $1.rawValue }
        .map { String($0.rawValue) }.joined(separator: ",")
      frameCoordinator.recordTrace("fullscreen-enter ids=[\(ids)]")
    }
    if !exited.isEmpty {
      let ids = exited.sorted { $0.rawValue < $1.rawValue }
        .map { String($0.rawValue) }.joined(separator: ",")
      frameCoordinator.recordTrace("fullscreen-exit ids=[\(ids)]")
    }
  }

  public func isInitialFrameSettlementActive(
    for windowID: WindowID,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    initialFrameSettlementDeadlines[windowID].map { $0 > now } ?? false
  }

  public func requestFrameRefresh(for windowID: WindowID) {
    invalidateWindowSnapshot()
    snapshotEngine.recordObservation(
      .frame,
      processID: processIDs[windowID],
      windowID: windowID
    )
  }

  nonisolated func invalidateWindowSnapshot() {
    snapshotEngine.invalidateWindowSnapshot()
  }

}
