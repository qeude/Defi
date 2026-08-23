import AppKit
import ApplicationServices
import DefiConfig
import DefiCore
import DefiModel

/// Owns the desktop-snapshot state domain: window/process registries,
/// discovery caches, retry bookkeeping, freshness budgets, and snapshot
/// telemetry.
///
/// Every property is lock-guarded so the snapshot pass can run on its own
/// serial queue while the main thread keeps reading published values. This is
/// the first strangler branch of ADR 0002; the endgame converts this class
/// into an actor once no synchronous cross-domain reader remains.
/// Unchecked sendable envelope for a value produced on the main thread and
/// consumed synchronously by the waiting engine queue.
/// AXUIElement handles are remote-object ports, safe to touch from any
/// thread (AXMessagingTimeoutAccess already hops threads with them). This
/// envelope carries such values across the engine/main boundary without
/// pretending they are value-semantically Sendable.
final class AssumedThreadSafe<T>: @unchecked Sendable {
  let value: T

  init(_ value: T) {
    self.value = value
  }
}

private final class MainHopBox<T>: @unchecked Sendable {
  let value: T

  init(_ value: T) {
    self.value = value
  }
}

final class SnapshotEngine: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Storage()

  let frameCoordinator: AXFrameCoordinator
  let userInputTracker: UserInputTracker

  private func read<T>(_ body: (inout Storage) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }

  weak var host: MacOSPlatform?

  private let snapshotQueue = DispatchQueue(
    label: "com.quentin.defi.snapshot",
    qos: .userInitiated
  )

  /// Runs a full desktop-snapshot pass off the main thread and publishes the
  /// result back to it. Serialized by the queue; main-thread readers only
  /// ever touch lock-guarded state.
  func beginSnapshot(
    config: Config,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool,
    forceApplicationInventoryRefresh: Bool,
    completion: @escaping @MainActor @Sendable (DesktopSnapshot) -> Void
  ) {
    precondition(host != nil, "host must be assigned")
    snapshotQueue.async { [weak self] in
      guard let self else { return }
      let result = self.snapshot(
        config: config,
        forceFullWindowRefresh: forceFullWindowRefresh,
        forceWindowListRefresh: forceWindowListRefresh,
        forceApplicationInventoryRefresh: forceApplicationInventoryRefresh
      )
      DispatchQueue.main.async {
        MainActor.assumeIsolated { completion(result) }
      }
    }
  }

  /// Runs main-actor work from the engine. Joins the main thread when called
  /// off it; executes inline when already there (synchronous test path).
  func onMain<T>(_ work: @MainActor (MacOSPlatform) -> T) -> T {
    precondition(
      host != nil,
      "SnapshotEngine.host must be assigned before snapshotting"
    )
    let box: MainHopBox<T> =
      Thread.isMainThread
      ? MainActor.assumeIsolated { MainHopBox(work(host!)) }
      : DispatchQueue.main.sync {
          MainActor.assumeIsolated { MainHopBox(work(host!)) }
        }
    return box.value
  }

  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] {
    get { read { $0.initialFrameSettlementDeadlines } }
    set { read { $0.initialFrameSettlementDeadlines = newValue } }
  }

  var frameEventPending: Bool {
    get { read { $0.frameEventPending } }
    set { read { $0.frameEventPending = newValue } }
  }

  var mouseResizeGesturePending: Bool {
    get { read { $0.mouseResizeGesturePending } }
    set { read { $0.mouseResizeGesturePending = newValue } }
  }

  var mouseFocusReleasePending: Bool {
    get { read { $0.mouseFocusReleasePending } }
    set { read { $0.mouseFocusReleasePending = newValue } }
  }

  var nativeFocusEventGeneration: UInt64 {
    get { read { $0.nativeFocusEventGeneration } }
    set { read { $0.nativeFocusEventGeneration = newValue } }
  }

  var mouseFocusReleaseEventGeneration: UInt64? {
    get { read { $0.mouseFocusReleaseEventGeneration } }
    set { read { $0.mouseFocusReleaseEventGeneration = newValue } }
  }

  var nativeFocusEventPending: Bool {
    get { read { $0.nativeFocusEventPending } }
    set { read { $0.nativeFocusEventPending = newValue } }
  }

  var nativeFocusEventProcessIDs: Set<pid_t> {
    get { read { $0.nativeFocusEventProcessIDs } }
    set { read { $0.nativeFocusEventProcessIDs = newValue } }
  }

  var nativeFocusEventHasUnknownProcess: Bool {
    get { read { $0.nativeFocusEventHasUnknownProcess } }
    set { read { $0.nativeFocusEventHasUnknownProcess = newValue } }
  }

  var lastFocusedWindowByProcess: [pid_t: WindowID] {
    get { read { $0.lastFocusedWindowByProcess } }
    set { read { $0.lastFocusedWindowByProcess = newValue } }
  }

  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] {
    get { read { $0.internalFocusSuppressions } }
    set { read { $0.internalFocusSuppressions = newValue } }
  }

  var lastMonitorFrames: [Rect] {
    get { read { $0.lastMonitorFrames } }
    set { read { $0.lastMonitorFrames = newValue } }
  }

  var pendingFrameDebtWindowIDs: Set<WindowID> {
    get { read { $0.pendingFrameDebtWindowIDs } }
    set { read { $0.pendingFrameDebtWindowIDs = newValue } }
  }

  var lastNativeFocusedWindowID: WindowID? {
    get { read { $0.lastNativeFocusedWindowID } }
    set { read { $0.lastNativeFocusedWindowID = newValue } }
  }

  var verifiedNativeFocusedWindowID: WindowID? {
    get { read { $0.verifiedNativeFocusedWindowID } }
    set { read { $0.verifiedNativeFocusedWindowID = newValue } }
  }

  // MARK: registries

  var elements: [WindowID: AXUIElement] {
    get { read { $0.elements } }
    set { read { $0.elements = newValue } }
  }

  var processIDs: [WindowID: pid_t] {
    get { read { $0.processIDs } }
    set { read { $0.processIDs = newValue } }
  }

  var applications: [pid_t: AXUIElement] {
    get { read { $0.applications } }
    set { read { $0.applications = newValue } }
  }

  var applicationIDsByProcess: [pid_t: String] {
    get { read { $0.applicationIDsByProcess } }
    set { read { $0.applicationIDsByProcess = newValue } }
  }

  var applicationWindowCounts: [pid_t: Int] {
    get { read { $0.applicationWindowCounts } }
    set { read { $0.applicationWindowCounts = newValue } }
  }

  var lastSnapshotWindows: [Window] {
    get { read { $0.lastSnapshotWindows } }
    set { read { $0.lastSnapshotWindows = newValue } }
  }

  var lastSnapshotWindowIDs: Set<WindowID> {
    get { read { $0.lastSnapshotWindowIDs } }
    set { read { $0.lastSnapshotWindowIDs = newValue } }
  }

  var lastSnapshotProcessIDs: Set<pid_t> {
    get { read { $0.lastSnapshotProcessIDs } }
    set { read { $0.lastSnapshotProcessIDs = newValue } }
  }

  var floatingWindowIDs: Set<WindowID> {
    get { read { $0.floatingWindowIDs } }
    set { read { $0.floatingWindowIDs = newValue } }
  }

  // MARK: discovery caches and retry bookkeeping

  var lastApplicationWindowElements: [pid_t: [AXUIElement]] {
    get { read { $0.lastApplicationWindowElements } }
    set { read { $0.lastApplicationWindowElements = newValue } }
  }

  var minimizedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { read { $0.minimizedWindowElementsByProcess } }
    set { read { $0.minimizedWindowElementsByProcess = newValue } }
  }

  var transientGeometryWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { read { $0.transientGeometryWindowElementsByProcess } }
    set { read { $0.transientGeometryWindowElementsByProcess = newValue } }
  }

  var unmatchedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { read { $0.unmatchedWindowElementsByProcess } }
    set { read { $0.unmatchedWindowElementsByProcess = newValue } }
  }

  var unmatchedWindowRetryAttemptsByProcess: [pid_t: Int] {
    get { read { $0.unmatchedWindowRetryAttemptsByProcess } }
    set { read { $0.unmatchedWindowRetryAttemptsByProcess = newValue } }
  }

  var windowListReadRetryAttemptsByProcess: [pid_t: Int] {
    get { read { $0.windowListReadRetryAttemptsByProcess } }
    set { read { $0.windowListReadRetryAttemptsByProcess = newValue } }
  }

  var cgWindowInventoryRetryAttempts: Int? {
    get { read { $0.cgWindowInventoryRetryAttempts } }
    set { read { $0.cgWindowInventoryRetryAttempts = newValue } }
  }

  var retainedWindowIDs: Set<WindowID> {
    get { read { $0.retainedWindowIDs } }
    set { read { $0.retainedWindowIDs = newValue } }
  }

  var retainedWindowDeadlines: [WindowID: TimeInterval] {
    get { read { $0.retainedWindowDeadlines } }
    set { read { $0.retainedWindowDeadlines = newValue } }
  }

  var explicitlyDestroyedWindowIDs: Set<WindowID> {
    get { read { $0.explicitlyDestroyedWindowIDs } }
    set { read { $0.explicitlyDestroyedWindowIDs = newValue } }
  }

  func recordExplicitlyDestroyedWindow(_ windowID: WindowID) {
    _ = read { $0.explicitlyDestroyedWindowIDs.insert(windowID) }
  }

  func consumeExplicitlyDestroyedWindows() -> Set<WindowID> {
    read {
      let windowIDs = $0.explicitlyDestroyedWindowIDs
      $0.explicitlyDestroyedWindowIDs.removeAll(keepingCapacity: true)
      return windowIDs
    }
  }

  var transientOwnerWindowIDs: [WindowID: WindowID] {
    get { read { $0.transientOwnerWindowIDs } }
    set { read { $0.transientOwnerWindowIDs = newValue } }
  }

  var transientOwnerResolutionAttempts: [WindowID: Int] {
    get { read { $0.transientOwnerResolutionAttempts } }
    set { read { $0.transientOwnerResolutionAttempts = newValue } }
  }

  var transientOwnerResolutionRetryAfter: [WindowID: TimeInterval] {
    get { read { $0.transientOwnerResolutionRetryAfter } }
    set { read { $0.transientOwnerResolutionRetryAfter = newValue } }
  }

  var windowManagementCapabilities: [WindowID: WindowManagementCapabilities] {
    get { read { $0.windowManagementCapabilities } }
    set { read { $0.windowManagementCapabilities = newValue } }
  }

  var enhancedUIByProcess: [pid_t: Bool] {
    get { read { $0.enhancedUIByProcess } }
    set { read { $0.enhancedUIByProcess = newValue } }
  }

  var multipleAttributeReadsSupportedByProcess: [pid_t: Bool] {
    get { read { $0.multipleAttributeReadsSupportedByProcess } }
    set { read { $0.multipleAttributeReadsSupportedByProcess = newValue } }
  }

  var failedBatchedWindowAttributeReadsByElement:
    [AXWindowElementIdentity: Int]
  {
    get { read { $0.failedBatchedWindowAttributeReadsByElement } }
    set { read { $0.failedBatchedWindowAttributeReadsByElement = newValue } }
  }

  // MARK: frame reconciliation inputs

  var targetFrames: [WindowID: Rect] {
    get { read { $0.targetFrames } }
    set { read { $0.targetFrames = newValue } }
  }

  var latestObservedFrames: [WindowID: Rect] {
    get { read { $0.latestObservedFrames } }
    set { read { $0.latestObservedFrames = newValue } }
  }

  var frameCommitExpectations: [WindowID: FrameCommitExpectation] {
    get { read { $0.frameCommitExpectations } }
    set { read { $0.frameCommitExpectations = newValue } }
  }

  var pendingFrameCorrections: [WindowID: Rect] {
    get { read { $0.pendingFrameCorrections } }
    set { read { $0.pendingFrameCorrections = newValue } }
  }

  var newlyDiscoveredWindowIDs: Set<WindowID> {
    get { read { $0.newlyDiscoveredWindowIDs } }
    set { read { $0.newlyDiscoveredWindowIDs = newValue } }
  }

  var hasCompletedWindowSnapshot: Bool {
    get { read { $0.hasCompletedWindowSnapshot } }
    set { read { $0.hasCompletedWindowSnapshot = newValue } }
  }

  // MARK: pending observation events

  var windowTopologyEventPending: Bool {
    get { read { $0.windowTopologyEventPending } }
    set { read { $0.windowTopologyEventPending = newValue } }
  }

  var pendingWindowTopologyProcessIDs: Set<pid_t> {
    get { read { $0.pendingWindowTopologyProcessIDs } }
    set { read { $0.pendingWindowTopologyProcessIDs = newValue } }
  }

  var windowTopologyRequiresFullSnapshot: Bool {
    get { read { $0.windowTopologyRequiresFullSnapshot } }
    set { read { $0.windowTopologyRequiresFullSnapshot = newValue } }
  }

  var pendingWindowTopologyInputTimestamp: TimeInterval? {
    get { read { $0.pendingWindowTopologyInputTimestamp } }
    set { read { $0.pendingWindowTopologyInputTimestamp = newValue } }
  }

  var pendingFrameProcessIDs: Set<pid_t> {
    get { read { $0.pendingFrameProcessIDs } }
    set { read { $0.pendingFrameProcessIDs = newValue } }
  }

  var observedFrameEventWindowIDs: Set<WindowID> {
    get { read { $0.observedFrameEventWindowIDs } }
    set { read { $0.observedFrameEventWindowIDs = newValue } }
  }

  var pendingFrameRequiresFullSnapshot: Bool {
    get { read { $0.pendingFrameRequiresFullSnapshot } }
    set { read { $0.pendingFrameRequiresFullSnapshot = newValue } }
  }

  var windowSnapshotObservationGeneration: UInt64 {
    get { read { $0.windowSnapshotObservationGeneration } }
    set { read { $0.windowSnapshotObservationGeneration = newValue } }
  }

  // MARK: prepared AX prefetch

  var preparedCGWindowInventory: [CGWindowRecord]? {
    get { read { $0.preparedCGWindowInventory } }
    set { read { $0.preparedCGWindowInventory = newValue } }
  }

  var preparedCGWindowInventoryDurationMS: Double {
    get { read { $0.preparedCGWindowInventoryDurationMS } }
    set { read { $0.preparedCGWindowInventoryDurationMS = newValue } }
  }

  var preparedCGWindowInventoryAvailable: Bool {
    get { read { $0.preparedCGWindowInventoryAvailable } }
    set { read { $0.preparedCGWindowInventoryAvailable = newValue } }
  }

  var cgWindowInventoryPreparationPending: Bool {
    get { read { $0.cgWindowInventoryPreparationPending } }
    set { read { $0.cgWindowInventoryPreparationPending = newValue } }
  }

  var preparedAXWindowAttributes: [WindowID: AXWindowAttributes] {
    get { read { $0.preparedAXWindowAttributes } }
    set { read { $0.preparedAXWindowAttributes = newValue } }
  }

  var preparedTransientOwnerWindowIDs: [WindowID: WindowID] {
    get { read { $0.preparedTransientOwnerWindowIDs } }
    set { read { $0.preparedTransientOwnerWindowIDs = newValue } }
  }

  var preparedAXApplicationWindows: [pid_t: PreparedAXApplicationWindows] {
    get { read { $0.preparedAXApplicationWindows } }
    set { read { $0.preparedAXApplicationWindows = newValue } }
  }

  var preparedAXWindowAttributesAvailable: Bool {
    get { read { $0.preparedAXWindowAttributesAvailable } }
    set { read { $0.preparedAXWindowAttributesAvailable = newValue } }
  }

  var preparedAXWindowAttributesGeneration: UInt64? {
    get { read { $0.preparedAXWindowAttributesGeneration } }
    set { read { $0.preparedAXWindowAttributesGeneration = newValue } }
  }

  var preparedAXWindowAttributesInputTimestamp: TimeInterval? {
    get { read { $0.preparedAXWindowAttributesInputTimestamp } }
    set { read { $0.preparedAXWindowAttributesInputTimestamp = newValue } }
  }

  var preparedAXWindowAttributesWindowIDs: Set<WindowID> {
    get { read { $0.preparedAXWindowAttributesWindowIDs } }
    set { read { $0.preparedAXWindowAttributesWindowIDs = newValue } }
  }

  var preparedAXWindowAttributesProcessIDs: Set<pid_t> {
    get { read { $0.preparedAXWindowAttributesProcessIDs } }
    set { read { $0.preparedAXWindowAttributesProcessIDs = newValue } }
  }

  var axWindowAttributePreparationPending: Bool {
    get { read { $0.axWindowAttributePreparationPending } }
    set { read { $0.axWindowAttributePreparationPending = newValue } }
  }

  // MARK: freshness budgets

  var deferredFreshReadProcessIDs: Set<pid_t> {
    get { read { $0.deferredFreshReadProcessIDs } }
    set { read { $0.deferredFreshReadProcessIDs = newValue } }
  }

  var deferredFreshReadsStartedAt: TimeInterval? {
    get { read { $0.deferredFreshReadsStartedAt } }
    set { read { $0.deferredFreshReadsStartedAt = newValue } }
  }

  var chunkedFullRefreshRemainingProcessIDs: Set<pid_t>? {
    get { read { $0.chunkedFullRefreshRemainingProcessIDs } }
    set { read { $0.chunkedFullRefreshRemainingProcessIDs = newValue } }
  }

  var incompatibleFreshReadDeadlines: [pid_t: TimeInterval] {
    get { read { $0.incompatibleFreshReadDeadlines } }
    set { read { $0.incompatibleFreshReadDeadlines = newValue } }
  }

  // MARK: telemetry

  var lastHiddenWindowIDs: Set<WindowID> {
    get { read { $0.lastHiddenWindowIDs } }
    set { read { $0.lastHiddenWindowIDs = newValue } }
  }

  var deferredFrameCommitMismatchCount: Int {
    get { read { $0.deferredFrameCommitMismatchCount } }
    set { read { $0.deferredFrameCommitMismatchCount = newValue } }
  }

  var observedFrameCommitCount: Int {
    get { read { $0.observedFrameCommitCount } }
    set { read { $0.observedFrameCommitCount = newValue } }
  }

  var maximumObservedFrameCommitLatencyMS = 0.0

  var batchedWindowAttributeReadCount: Int {
    get { read { $0.batchedWindowAttributeReadCount } }
    set { read { $0.batchedWindowAttributeReadCount = newValue } }
  }

  var fallbackWindowAttributeReadCount: Int {
    get { read { $0.fallbackWindowAttributeReadCount } }
    set { read { $0.fallbackWindowAttributeReadCount = newValue } }
  }

  var windowManagementMetadataReadCount: Int {
    get { read { $0.windowManagementMetadataReadCount } }
    set { read { $0.windowManagementMetadataReadCount = newValue } }
  }

  var windowManagementMetadataReuseCount: Int {
    get { read { $0.windowManagementMetadataReuseCount } }
    set { read { $0.windowManagementMetadataReuseCount = newValue } }
  }

  var privateWindowIDLookupCount: Int {
    get { read { $0.privateWindowIDLookupCount } }
    set { read { $0.privateWindowIDLookupCount = newValue } }
  }

  var publicWindowIDFallbackCount: Int {
    get { read { $0.publicWindowIDFallbackCount } }
    set { read { $0.publicWindowIDFallbackCount = newValue } }
  }

  var lastWindowSnapshotDurationMS: Double {
    get { read { $0.lastWindowSnapshotDurationMS } }
    set { read { $0.lastWindowSnapshotDurationMS = newValue } }
  }

  var maximumWindowSnapshotDurationMS: Double {
    get { read { $0.maximumWindowSnapshotDurationMS } }
    set { read { $0.maximumWindowSnapshotDurationMS = newValue } }
  }

  var windowSnapshotDurationSamplesMS: [Double] {
    get { read { $0.windowSnapshotDurationSamplesMS } }
    set { read { $0.windowSnapshotDurationSamplesMS = newValue } }
  }

  var fullWindowSnapshotCount: Int {
    get { read { $0.fullWindowSnapshotCount } }
    set { read { $0.fullWindowSnapshotCount = newValue } }
  }

  var incrementalWindowSnapshotCount: Int {
    get { read { $0.incrementalWindowSnapshotCount } }
    set { read { $0.incrementalWindowSnapshotCount = newValue } }
  }

  var cachedWindowSnapshotCount: Int {
    get { read { $0.cachedWindowSnapshotCount } }
    set { read { $0.cachedWindowSnapshotCount = newValue } }
  }

  var applicationInventorySnapshotCount: Int {
    get { read { $0.applicationInventorySnapshotCount } }
    set { read { $0.applicationInventorySnapshotCount = newValue } }
  }

  var applicationWindowListReadCount: Int {
    get { read { $0.applicationWindowListReadCount } }
    set { read { $0.applicationWindowListReadCount = newValue } }
  }

  var applicationInventoryDurationSamplesMS: [Double] {
    get { read { $0.applicationInventoryDurationSamplesMS } }
    set { read { $0.applicationInventoryDurationSamplesMS = newValue } }
  }

  var applicationWindowListDurationSamplesMS: [Double] {
    get { read { $0.applicationWindowListDurationSamplesMS } }
    set { read { $0.applicationWindowListDurationSamplesMS = newValue } }
  }

  var snapshotCGWindowCopyCount: Int {
    get { read { $0.snapshotCGWindowCopyCount } }
    set { read { $0.snapshotCGWindowCopyCount = newValue } }
  }

  var lastSnapshotCGWindowCopyDurationMS: Double {
    get { read { $0.lastSnapshotCGWindowCopyDurationMS } }
    set { read { $0.lastSnapshotCGWindowCopyDurationMS = newValue } }
  }

  var maximumSnapshotCGWindowCopyDurationMS: Double {
    get { read { $0.maximumSnapshotCGWindowCopyDurationMS } }
    set { read { $0.maximumSnapshotCGWindowCopyDurationMS = newValue } }
  }
  init(
    frameCoordinator: AXFrameCoordinator,
    userInputTracker: UserInputTracker
  ) {
    self.frameCoordinator = frameCoordinator
    self.userInputTracker = userInputTracker
  }
}



extension SnapshotEngine {
  func makeWindow(
    element: AXUIElement,
    processID: pid_t,
    appID: String,
    config: Config,
    publicCGWindows: () -> [CGWindowRecord]?,
    monitors: [MonitorSnapshot],
    preferredWindowID: WindowID?,
    excluding usedCGWindowIDs: Set<CGWindowID>,
    preparedAttributes: AXWindowAttributes? = nil
  ) -> WindowDiscoveryResult {
    let attributes = preparedAttributes
      ?? windowAttributes(element, processID: processID)
    let geometry = windowGeometryDiscovery(
      minimized: attributes.minimized,
      frame: { attributes.frame }
    )
    let frame: Rect
    switch geometry {
    case .unavailable:
      return .unavailable
    case .ignored:
      return attributes.minimized == true ? .ignored : .transientGeometry
    case .usable(let usableFrame):
      frame = usableFrame
    }
    let title = attributes.title
    let role = attributes.role
    let subrole = attributes.subrole
    let decision = config.decision(appID: appID, title: title, role: role)
    guard let publicCGWindows = publicCGWindows() else {
      return .unavailable
    }
    let eligibleCGWindows = eligibleCGWindowRecords(
      role: role,
      for: subrole,
      allowsConfiguredNonzeroLayer: decision.floating || decision.forceTiling,
      in: publicCGWindows
    )
    let publicRecord = cgWindowRecordForDiscovery(
      axWindowID: nil,
      preferredWindowID: preferredWindowID,
      processID: processID,
      title: title,
      frame: frame,
      records: eligibleCGWindows,
      excluding: usedCGWindowIDs
    )
    let record: CGWindowRecord?
    if let publicRecord {
      record = publicRecord
    } else {
      let axWindowID = {
          let assumedElement = AssumedThreadSafe(element)
          return onMain { $0.windowIDProvider.windowID(for: assumedElement.value) }
        }()
      if axWindowID == nil {
        publicWindowIDFallbackCount += 1
      } else {
        privateWindowIDLookupCount += 1
      }
      record = cgWindowRecordForDiscovery(
        axWindowID: axWindowID,
        preferredWindowID: preferredWindowID,
        processID: processID,
        title: title,
        frame: frame,
        records: eligibleCGWindows,
        excluding: usedCGWindowIDs
      )
    }
    guard let resolvedWindowID = record?.id else {
      return .unmatched
    }
    let monitorID = monitor(containing: frame, monitors: monitors)?.id
    return .discovered(
      Window(
        id: WindowID(rawValue: UInt64(resolvedWindowID)),
        appID: appID,
        title: title,
        frame: frame,
        role: role,
        subrole: subrole,
        processID: processID,
        isModal: attributes.modal == true,
        monitorID: monitorID,
        forceTiling: false
      ), resolvedWindowID, decision
    )
  }

  func windowDisposition(
    _ window: Window,
    element: AXUIElement,
    configuredFloating: Bool,
    forceTiling: Bool,
    previousDisposition: WindowDisposition?,
    reuseCachedCapabilities: Bool,
    preparedModalState: Bool? = nil
  ) -> WindowDisposition {
    if forceTiling || configuredFloating
      || window.role != kAXWindowRole
      || window.subrole != kAXStandardWindowSubrole
    {
      return classifyWindow(
        role: window.role,
        subrole: window.subrole,
        appID: window.appID,
        hasCloseButton: false,
        canResize: false,
        isModal: false,
        configuredFloating: configuredFloating,
        forceTiling: forceTiling
      )
    }
    if reuseCachedCapabilities,
      let capabilities = windowManagementCapabilities[window.id]
    {
      windowManagementMetadataReuseCount += 1
      var modalState = capabilities.isModal
      let refreshedModalState: Bool?
      if let preparedModalState {
        refreshedModalState = preparedModalState
      } else {
        var modalValue: CFTypeRef?
        let modalError = AXUIElementCopyAttributeValue(
          element,
          kAXModalAttribute as CFString,
          &modalValue
        )
        refreshedModalState = resolvedWindowModalState(
          error: modalError,
          observedValue: modalValue as? Bool,
          cachedValue: capabilities.isModal
        )
      }
      if let refreshedModalState {
        modalState = refreshedModalState
        windowManagementCapabilities[window.id] = WindowManagementCapabilities(
          hasCloseButton: capabilities.hasCloseButton,
          canResize: capabilities.canResize,
          isModal: refreshedModalState
        )
      }
      return classifyWindow(
        role: window.role,
        subrole: window.subrole,
        appID: window.appID,
        hasCloseButton: capabilities.hasCloseButton,
        canResize: capabilities.canResize,
        isModal: modalState,
        configuredFloating: false,
        forceTiling: false
      )
    }
    windowManagementMetadataReadCount += 1
    var closeButton: CFTypeRef?
    let closeButtonError = AXUIElementCopyAttributeValue(
      element,
      kAXCloseButtonAttribute as CFString,
      &closeButton
    )
    var sizeSettable = DarwinBoolean(false)
    let sizeSettableError = AXUIElementIsAttributeSettable(
      element,
      kAXSizeAttribute as CFString,
      &sizeSettable
    )
    var modalValue: CFTypeRef?
    let modalError = AXUIElementCopyAttributeValue(
      element,
      kAXModalAttribute as CFString,
      &modalValue
    )
    guard let isModal = resolvedWindowModalState(
      error: modalError,
      observedValue: modalValue as? Bool,
      cachedValue: windowManagementCapabilities[window.id]?.isModal
    ) else {
      return previousDisposition ?? .unavailable
    }
    if !configuredFloating,
      !forceTiling,
      let fallbackDisposition = fallbackDispositionForTransientWindowMetadata(
        role: window.role,
        subrole: window.subrole,
        closeButtonError: closeButtonError,
        sizeSettableError: sizeSettableError,
        previousDisposition: previousDisposition
      )
    {
      return fallbackDisposition
    }
    let capabilities = WindowManagementCapabilities(
      hasCloseButton: shouldTreatWindowAsClosable(
        error: closeButtonError,
        hasValue: closeButton != nil,
        wasPreviouslyManaged: previousDisposition != nil
      ),
      canResize: windowCanResize(
        sizeSettableError: sizeSettableError,
        isSettable: sizeSettable.boolValue
      ),
      isModal: isModal
    )
    windowManagementCapabilities[window.id] = capabilities
    return classifyWindow(
      role: window.role,
      subrole: window.subrole,
      appID: window.appID,
      hasCloseButton: capabilities.hasCloseButton,
      canResize: capabilities.canResize,
      isModal: capabilities.isModal,
      configuredFloating: configuredFloating,
      forceTiling: forceTiling
    )
  }

  func focusedWindowID(
    in windows: [Window]
  ) -> WindowID? {
    let frontmostProcessID = onMain { _ in NSWorkspace.shared.frontmostApplication }?.processIdentifier
    let system = AXUIElementCreateSystemWide()
    let focusedApplication: CFTypeRef? = AXMessagingTimeoutAccess.shared
      .withTimeout(
        focusSnapshotAccessibilityTimeoutSeconds,
        elements: [system]
      ) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          system,
          kAXFocusedApplicationAttribute as CFString,
          &value
        ) == .success else {
          return nil
        }
        return value
      }
    guard
      let focusedApplication
    else {
      return stableWindowID(processID: frontmostProcessID, in: windows)
    }
    var focusedProcessID: pid_t = 0
    let focusedApplicationElement = focusedApplication as! AXUIElement
    let readFocusedProcessID = AXMessagingTimeoutAccess.shared.withTimeout(
      focusSnapshotAccessibilityTimeoutSeconds,
      elements: [focusedApplicationElement]
    ) {
      AXUIElementGetPid(
        focusedApplicationElement,
        &focusedProcessID
      ) == .success
    }
    guard readFocusedProcessID else {
      return stableWindowID(processID: frontmostProcessID, in: windows)
    }
    let resolvedProcessID = consistentFocusedProcessID(
      accessibilityProcessID: focusedProcessID,
      frontmostProcessID: frontmostProcessID,
      verifiedNativeFocusProcessID: frontmostProcessID.flatMap { processID in
        nativeFocusEventMatchesTarget(
          eventPending: nativeFocusEventPending,
          eventProcessIDs: nativeFocusEventProcessIDs,
          hasUnknownEventProcess: nativeFocusEventHasUnknownProcess,
          focusedProcessID: processID
        ) ? processID : nil
      }
    )
    guard let resolvedProcessID else {
      return nil
    }
    if resolvedProcessID != focusedProcessID {
      let verifiedProcessHasSingleWindow = windows.filter {
        $0.processID == resolvedProcessID
      }.count == 1
      return stableWindowID(
        processID: resolvedProcessID,
        in: windows,
        allowPendingNativeFocus: verifiedProcessHasSingleWindow
      )
    }
    let focusedWindow: CFTypeRef? = AXMessagingTimeoutAccess.shared.withTimeout(
      focusSnapshotAccessibilityTimeoutSeconds,
      elements: [focusedApplicationElement]
    ) {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(
        focusedApplicationElement,
        kAXFocusedWindowAttribute as CFString,
        &value
      ) == .success else {
        return nil
      }
      return value
    }
    guard let focusedWindow else {
      return stableWindowID(processID: focusedProcessID, in: windows)
    }
    let focusedElement = focusedWindow as! AXUIElement
    if let exact = elements.first(where: { CFEqual($0.value, focusedElement) }) {
      return exact.key
    }
    guard let focusedFrame = AXMessagingTimeoutAccess.shared.withTimeout(
      focusSnapshotAccessibilityTimeoutSeconds,
      elements: [focusedElement],
      perform: { frame(of: focusedElement) }
    ) else {
      return stableWindowID(processID: focusedProcessID, in: windows)
    }
    return focusedWindowIDMatchingFrame(
      processID: focusedProcessID,
      focusedFrame: focusedFrame,
      windows: windows
    )
  }

  func stableWindowID(
    processID: pid_t?,
    in windows: [Window],
    allowPendingNativeFocus: Bool = false
  ) -> WindowID? {
    guard let processID else { return nil }
    let candidates = windows.filter { $0.processID == processID }
    let verifiedSingleWindowPendingFocus =
      nativeFocusEventMatchesTarget(
        eventPending: nativeFocusEventPending,
        eventProcessIDs: nativeFocusEventProcessIDs,
        hasUnknownEventProcess: nativeFocusEventHasUnknownProcess,
        focusedProcessID: processID
      ) && candidates.count == 1
    guard
      allowPendingNativeFocus
        || !nativeFocusEventPending
        || verifiedSingleWindowPendingFocus
    else { return nil }
    if let previous = lastFocusedWindowByProcess[processID],
      candidates.contains(where: { $0.id == previous })
    {
      return previous
    }
    return candidates.count == 1 ? candidates[0].id : nil
  }

  func frame(of element: AXUIElement) -> Rect? {
    guard let positionValue = copyAttribute(element, name: kAXPositionAttribute),
      let sizeValue = copyAttribute(element, name: kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else {
      return nil
    }
    return Rect(x: position.x, y: position.y, width: size.width, height: size.height)
  }

  func windowAttributes(
    _ element: AXUIElement,
    processID: pid_t
  ) -> AXWindowAttributes {
    let elementIdentity = AXWindowElementIdentity(
      processID: processID,
      element: element
    )
    if multipleAttributeReadsSupportedByProcess[processID] != false,
      let attributes = batchedWindowAttributes(element)
    {
      multipleAttributeReadsSupportedByProcess[processID] = true
      failedBatchedWindowAttributeReadsByElement[elementIdentity] = nil
      batchedWindowAttributeReadCount += 1
      return attributes
    }
    if multipleAttributeReadsSupportedByProcess[processID] != false {
      let failures = failedBatchedWindowAttributeReadsByElement[elementIdentity, default: 0] + 1
      failedBatchedWindowAttributeReadsByElement[elementIdentity] = failures
      if shouldDisableBatchedWindowAttributeReads(failureCount: failures) {
        multipleAttributeReadsSupportedByProcess[processID] = false
        failedBatchedWindowAttributeReadsByElement =
          failedBatchedWindowAttributeReadsByElement.filter { $0.key.processID != processID }
        return windowAttributes(element, processID: processID)
      }
      return AXWindowAttributes(
        minimized: nil,
        frame: nil,
        title: "",
        role: nil,
        subrole: nil
      )
    }
    fallbackWindowAttributeReadCount += 1
    return fallbackWindowAttributes(
      minimized: {
        value(
          element,
          attribute: kAXMinimizedAttribute,
          as: Bool.self
        )
      },
      frame: { self.frame(of: element) },
      title: {
        value(
          element,
          attribute: kAXTitleAttribute,
          as: String.self
        )
      },
      role: {
        value(element, attribute: kAXRoleAttribute, as: String.self)
      },
      subrole: {
        value(
          element,
          attribute: kAXSubroleAttribute,
          as: String.self
        )
      },
      modal: {
        value(
          element,
          attribute: kAXModalAttribute,
          as: Bool.self
        )
      }
    )
  }

  private func batchedWindowAttributes(
    _ element: AXUIElement
  ) -> AXWindowAttributes? {
    let read = copyBatchedWindowAttributes(element)
    guard let attributes = read.attributes else {
      if read.error == .notImplemented || read.error == .attributeUnsupported {
        var processID: pid_t = 0
        if AXUIElementGetPid(element, &processID) == .success {
          multipleAttributeReadsSupportedByProcess[processID] = false
        }
      }
      return nil
    }
    return attributes
  }

  func copyAttribute(_ element: AXUIElement, name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func value<Value>(
    _ element: AXUIElement,
    attribute: String,
    as type: Value.Type
  ) -> Value? {
    copyAttribute(element, name: attribute) as? Value
  }

  func copyElements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
    copyAttribute(element, name: attribute) as? [AXUIElement]
  }
}


private struct Storage {
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
  var failedBatchedWindowAttributeReadsByElement:
    [AXWindowElementIdentity: Int] = [:]
  var batchedWindowAttributeReadCount = 0
  var fallbackWindowAttributeReadCount = 0
  var windowManagementCapabilities: [WindowID: WindowManagementCapabilities] =
    [:]
  var windowManagementMetadataReadCount = 0
  var windowManagementMetadataReuseCount = 0
  var privateWindowIDLookupCount = 0
  var publicWindowIDFallbackCount = 0
  var targetFrames: [WindowID: Rect] = [:]
  var latestObservedFrames: [WindowID: Rect] = [:]
  var frameCommitExpectations: [WindowID: FrameCommitExpectation] = [:]
  var pendingFrameCorrections: [WindowID: Rect] = [:]
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
  var preparedTransientOwnerWindowIDs: [WindowID: WindowID] = [:]
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
  var lastHiddenWindowIDs = Set<WindowID>()
  var deferredFreshReadProcessIDs = Set<pid_t>()
  var deferredFreshReadsStartedAt: TimeInterval?
  var chunkedFullRefreshRemainingProcessIDs: Set<pid_t>?
  var incompatibleFreshReadDeadlines: [pid_t: TimeInterval] = [:]
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] = [:]
  var frameEventPending: Bool = false
  var mouseResizeGesturePending: Bool = false
  var mouseFocusReleasePending: Bool = false
  var nativeFocusEventGeneration: UInt64 = 0
  var mouseFocusReleaseEventGeneration: UInt64? = nil
  var nativeFocusEventPending: Bool = false
  var nativeFocusEventProcessIDs: Set<pid_t> = Set<pid_t>()
  var nativeFocusEventHasUnknownProcess: Bool = false
  var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] = [:]
  var lastMonitorFrames: [Rect] = []
  var pendingFrameDebtWindowIDs: Set<WindowID> = Set<WindowID>()
  var lastNativeFocusedWindowID: WindowID? = nil
  var verifiedNativeFocusedWindowID: WindowID? = nil
}
