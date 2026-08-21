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
final class SnapshotEngine: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Storage()

  private func read<T>(_ body: (inout Storage) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
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

  init() {}
}
