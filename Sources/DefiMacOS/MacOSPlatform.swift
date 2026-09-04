import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
public final class MacOSPlatform {
  lazy var snapshotEngine: SnapshotEngine = {
    let engine = SnapshotEngine(
      frameCoordinator: frameCoordinator,
      userInputTracker: userInputTracker
    )
    engine.host = self
    engine.frameCoordinator.borderLiveGeometryHandler = { [weak self] frames in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          // The overlay follows the frame actually displayed by the Window
          // Server - never the planned one - so clamping apps keep borders
          // matched to their real geometry.
          var resolvedFrames: [WindowID: Rect] = [:]
          for (windowID, completed) in frames {
            resolvedFrames[windowID] =
              self.borderBoundsProvider.frame(for: windowID) ?? completed
          }
          _ = self.borderManager.updateGeometry(
            frames: resolvedFrames,
            style: self.borderStyle
          )
        }
      }
    }
    return engine
  }()

  func frame(of element: AXUIElement) -> Rect? {
    snapshotEngine.frame(of: element)
  }

  func stableWindowID(
    processID: pid_t?,
    in windows: [Window],
    allowPendingNativeFocus: Bool = false
  ) -> WindowID? {
    snapshotEngine.stableWindowID(
      processID: processID,
      in: windows,
      allowPendingNativeFocus: allowPendingNativeFocus
    )
  }

  public func accessibilityTrusted(prompt: Bool) -> Bool {
    snapshotEngine.host = self
    return snapshotEngine.accessibilityTrusted(prompt: prompt)
  }

  public func snapshot(config: Config) -> DesktopSnapshot {
    snapshotEngine.host = self
    return snapshotEngine.snapshot(config: config)
  }

  public func beginSnapshot(
    config: Config,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool,
    forceApplicationInventoryRefresh: Bool,
    completion: @escaping @MainActor @Sendable (DesktopSnapshot) -> Void
  ) {
    snapshotEngine.host = self
    snapshotEngine.beginSnapshot(
      config: config,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh,
      completion: completion
    )
  }

  public func snapshot(
    config: Config,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool = false,
    forceApplicationInventoryRefresh: Bool = false
  ) -> DesktopSnapshot {
    snapshotEngine.host = self
    return snapshotEngine.snapshot(
      config: config,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh
    )
  }
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
  let borderManager = WindowBorderManager()
  let nativeFullscreenPlaceholderManager = NativeFullscreenPlaceholderManager()
  let borderBoundsProvider = WindowServerBoundsProvider()
  var targetFrames: [WindowID: Rect] {
    get { snapshotEngine.targetFrames }
    set { snapshotEngine.targetFrames = newValue }
  }
  var pendingFrameDebtWindowIDs: Set<WindowID> {
    get { snapshotEngine.pendingFrameDebtWindowIDs }
    set { snapshotEngine.pendingFrameDebtWindowIDs = newValue }
  }
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
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] {
    get { snapshotEngine.initialFrameSettlementDeadlines }
    set { snapshotEngine.initialFrameSettlementDeadlines = newValue }
  }
  var newlyDiscoveredWindowIDs: Set<WindowID> {
    get { snapshotEngine.newlyDiscoveredWindowIDs }
    set { snapshotEngine.newlyDiscoveredWindowIDs = newValue }
  }
  var hasCompletedWindowSnapshot: Bool {
    get { snapshotEngine.hasCompletedWindowSnapshot }
    set { snapshotEngine.hasCompletedWindowSnapshot = newValue }
  }
  var windowTopologyEventPending: Bool {
    get { snapshotEngine.windowTopologyEventPending }
    set { snapshotEngine.windowTopologyEventPending = newValue }
  }

  public var hasPendingWindowTopologyEvent: Bool {
    windowTopologyEventPending
  }
  var pendingWindowTopologyProcessIDs: Set<pid_t> {
    get { snapshotEngine.pendingWindowTopologyProcessIDs }
    set { snapshotEngine.pendingWindowTopologyProcessIDs = newValue }
  }
  var windowTopologyRequiresFullSnapshot: Bool {
    get { snapshotEngine.windowTopologyRequiresFullSnapshot }
    set { snapshotEngine.windowTopologyRequiresFullSnapshot = newValue }
  }
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
  var pendingFrameRequiresFullSnapshot: Bool {
    get { snapshotEngine.pendingFrameRequiresFullSnapshot }
    set { snapshotEngine.pendingFrameRequiresFullSnapshot = newValue }
  }
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
  var lastWindowSnapshotDurationMS: Double {
    get { snapshotEngine.lastWindowSnapshotDurationMS }
    set { snapshotEngine.lastWindowSnapshotDurationMS = newValue }
  }
  var maximumWindowSnapshotDurationMS: Double {
    get { snapshotEngine.maximumWindowSnapshotDurationMS }
    set { snapshotEngine.maximumWindowSnapshotDurationMS = newValue }
  }
  var windowSnapshotDurationSamplesMS: [Double] {
    get { snapshotEngine.windowSnapshotDurationSamplesMS }
    set { snapshotEngine.windowSnapshotDurationSamplesMS = newValue }
  }
  var fullWindowSnapshotCount: Int {
    get { snapshotEngine.fullWindowSnapshotCount }
    set { snapshotEngine.fullWindowSnapshotCount = newValue }
  }
  var incrementalWindowSnapshotCount: Int {
    get { snapshotEngine.incrementalWindowSnapshotCount }
    set { snapshotEngine.incrementalWindowSnapshotCount = newValue }
  }
  var cachedWindowSnapshotCount: Int {
    get { snapshotEngine.cachedWindowSnapshotCount }
    set { snapshotEngine.cachedWindowSnapshotCount = newValue }
  }
  var applicationInventorySnapshotCount: Int {
    get { snapshotEngine.applicationInventorySnapshotCount }
    set { snapshotEngine.applicationInventorySnapshotCount = newValue }
  }
  var applicationWindowListReadCount: Int {
    get { snapshotEngine.applicationWindowListReadCount }
    set { snapshotEngine.applicationWindowListReadCount = newValue }
  }
  var applicationInventoryDurationSamplesMS: [Double] {
    get { snapshotEngine.applicationInventoryDurationSamplesMS }
    set { snapshotEngine.applicationInventoryDurationSamplesMS = newValue }
  }
  var applicationWindowListDurationSamplesMS: [Double] {
    get { snapshotEngine.applicationWindowListDurationSamplesMS }
    set { snapshotEngine.applicationWindowListDurationSamplesMS = newValue }
  }
  var snapshotCGWindowCopyCount: Int {
    get { snapshotEngine.snapshotCGWindowCopyCount }
    set { snapshotEngine.snapshotCGWindowCopyCount = newValue }
  }
  var lastSnapshotCGWindowCopyDurationMS: Double {
    get { snapshotEngine.lastSnapshotCGWindowCopyDurationMS }
    set { snapshotEngine.lastSnapshotCGWindowCopyDurationMS = newValue }
  }
  var maximumSnapshotCGWindowCopyDurationMS: Double {
    get { snapshotEngine.maximumSnapshotCGWindowCopyDurationMS }
    set { snapshotEngine.maximumSnapshotCGWindowCopyDurationMS = newValue }
  }
  var preparedCGWindowInventory: [CGWindowRecord]? {
    get { snapshotEngine.preparedCGWindowInventory }
    set { snapshotEngine.preparedCGWindowInventory = newValue }
  }
  var preparedCGWindowInventoryDurationMS: Double {
    get { snapshotEngine.preparedCGWindowInventoryDurationMS }
    set { snapshotEngine.preparedCGWindowInventoryDurationMS = newValue }
  }
  var preparedCGWindowInventoryAvailable: Bool {
    get { snapshotEngine.preparedCGWindowInventoryAvailable }
    set { snapshotEngine.preparedCGWindowInventoryAvailable = newValue }
  }
  var cgWindowInventoryPreparationPending: Bool {
    get { snapshotEngine.cgWindowInventoryPreparationPending }
    set { snapshotEngine.cgWindowInventoryPreparationPending = newValue }
  }
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
  var preparedAXWindowAttributesAvailable: Bool {
    get { snapshotEngine.preparedAXWindowAttributesAvailable }
    set { snapshotEngine.preparedAXWindowAttributesAvailable = newValue }
  }
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
  var axWindowAttributePreparationPending: Bool {
    get { snapshotEngine.axWindowAttributePreparationPending }
    set { snapshotEngine.axWindowAttributePreparationPending = newValue }
  }
  var windowSnapshotObservationGeneration: UInt64 {
    get { snapshotEngine.windowSnapshotObservationGeneration }
    set { snapshotEngine.windowSnapshotObservationGeneration = newValue }
  }
  var deferredFrameCommitMismatchCount: Int {
    get { snapshotEngine.deferredFrameCommitMismatchCount }
    set { snapshotEngine.deferredFrameCommitMismatchCount = newValue }
  }
  var observedFrameCommitCount: Int {
    get { snapshotEngine.observedFrameCommitCount }
    set { snapshotEngine.observedFrameCommitCount = newValue }
  }
  var maximumObservedFrameCommitLatencyMS: Double {
    get { snapshotEngine.maximumObservedFrameCommitLatencyMS }
    set { snapshotEngine.maximumObservedFrameCommitLatencyMS = newValue }
  }
  var commandLatency = CommandLatencyAccumulator()
  var commandDiagnosticHandler:
    (@MainActor @Sendable (CommandDiagnosticSample) -> Void)?
  var lastHiddenWindowIDs: Set<WindowID> {
    get { snapshotEngine.lastHiddenWindowIDs }
    set { snapshotEngine.lastHiddenWindowIDs = newValue }
  }
  var eventMonitor: PlatformEventMonitor?
  var frameEventPending: Bool {
    get { snapshotEngine.frameEventPending }
    set { snapshotEngine.frameEventPending = newValue }
  }
  var mouseResizeGesturePending: Bool {
    get { snapshotEngine.mouseResizeGesturePending }
    set { snapshotEngine.mouseResizeGesturePending = newValue }
  }
  var mouseFocusReleasePending: Bool {
    get { snapshotEngine.mouseFocusReleasePending }
    set { snapshotEngine.mouseFocusReleasePending = newValue }
  }
  var nativeFocusEventGeneration: UInt64 {
    get { snapshotEngine.nativeFocusEventGeneration }
    set { snapshotEngine.nativeFocusEventGeneration = newValue }
  }
  var mouseFocusReleaseEventGeneration: UInt64? {
    get { snapshotEngine.mouseFocusReleaseEventGeneration }
    set { snapshotEngine.mouseFocusReleaseEventGeneration = newValue }
  }
  var nativeFocusEventPending: Bool {
    get { snapshotEngine.nativeFocusEventPending }
    set { snapshotEngine.nativeFocusEventPending = newValue }
  }
  var nativeFocusEventProcessIDs: Set<pid_t> {
    get { snapshotEngine.nativeFocusEventProcessIDs }
    set { snapshotEngine.nativeFocusEventProcessIDs = newValue }
  }
  var nativeFocusEventHasUnknownProcess: Bool {
    get { snapshotEngine.nativeFocusEventHasUnknownProcess }
    set { snapshotEngine.nativeFocusEventHasUnknownProcess = newValue }
  }
  var lastFocusedWindowByProcess: [pid_t: WindowID] {
    get { snapshotEngine.lastFocusedWindowByProcess }
    set { snapshotEngine.lastFocusedWindowByProcess = newValue }
  }
  var verifiedNativeFocusedWindowID: WindowID? {
    get { snapshotEngine.verifiedNativeFocusedWindowID }
    set { snapshotEngine.verifiedNativeFocusedWindowID = newValue }
  }
  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] {
    get { snapshotEngine.internalFocusSuppressions }
    set { snapshotEngine.internalFocusSuppressions = newValue }
  }
  var nextInternalFocusRequestID: UInt64 = 0
  var submittedFocusRecoveryRequestID: NativeFocusRequestID?
  var submittedFocusRecoveryTimestamp: TimeInterval?
  var submittedFocusRecoveryGeneration: UInt64?
  var nextFocusRecoveryGeneration: UInt64 = 0
  var focusRecoveryIntentGeneration: UInt64 = 0
  var positionWriteCount = 0
  var sizeWriteCount = 0
  var lastFrameApplyDurationMS = 0.0
  var lastMonitorFrames: [Rect] {
    get { snapshotEngine.lastMonitorFrames }
    set { snapshotEngine.lastMonitorFrames = newValue }
  }
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
  var lastNativeFocusedWindowID: WindowID? {
    get { snapshotEngine.lastNativeFocusedWindowID }
    set { snapshotEngine.lastNativeFocusedWindowID = newValue }
  }
  var borderHiddenWindowIDs = Set<WindowID>()
  var borderLiveWindowID: WindowID?
  public private(set) var nativeFullscreenWindowIDs = Set<WindowID>()
  public private(set) var activeNativeFullscreenWindowIDs = Set<WindowID>()
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

  public var isPrivateWindowConstraintLookupAvailable: Bool {
    borderBoundsProvider.constraintsAreAvailable
  }

  public var successfulPrivateWindowConstraintLookupCount: Int {
    borderBoundsProvider.successfulConstraintLookupCount
  }

  public var privateWindowConstraintLookupFallbackCount: Int {
    borderBoundsProvider.constraintFallbackCount
  }

  var cursorWarpAppliedCount = 0
  var cursorWarpSkippedCount = 0
  var cursorWarpFailedCount = 0

  public let userInputTracker = UserInputTracker()
  public let pointerMotionTracker = PointerMotionTracker()

  public init() {}

  public func updateNativeFullscreenWindowIDs(
    _ windowIDs: Set<WindowID>,
    activeWindowIDs: Set<WindowID> = []
  ) {
    let entered = windowIDs.subtracting(nativeFullscreenWindowIDs)
    let exited = nativeFullscreenWindowIDs.subtracting(windowIDs)
    nativeFullscreenWindowIDs = windowIDs
    activeNativeFullscreenWindowIDs = activeWindowIDs.intersection(windowIDs)
    let now = ProcessInfo.processInfo.systemUptime
    if entered.contains(where: frameCoordinator.isBusy(for:)) {
      frameCoordinator.invalidate(reason: "native-fullscreen")
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
    if let activeWindowID = borderManager.activeWindowID,
      windowIDs.contains(activeWindowID)
    {
      hideWindowBorders()
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
