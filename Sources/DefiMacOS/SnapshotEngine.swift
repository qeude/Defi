import AppKit
import ApplicationServices
import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime

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

/// Snapshot passes run on a serial queue; shared snapshot state is lock-guarded
/// for concurrent main-thread readers.
final class SnapshotEngine: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Storage()

  let frameCoordinator: AXFrameCoordinator
  let userInputTracker: UserInputTracker

  private func withLockedStorage<T>(_ body: (inout Storage) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }

  weak var host: MacOSPlatform?

  private let snapshotQueue = DispatchQueue(
    label: "com.quentin.defi.snapshot",
    qos: .userInitiated
  )

  func beginSnapshot(
    config: Config,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool,
    forceApplicationInventoryRefresh: Bool,
    completion: @escaping @NavigationActor @Sendable (DesktopSnapshot) -> Void
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
      NavigationActor.enqueue { completion(result) }
    }
  }

  /// Runs main-actor work from the engine. Joins the main thread when called
  /// off it; executes inline when already there (synchronous test path).
  func onMain<T>(_ work: @MainActor (MacOSPlatform) -> T) -> T {
    precondition(
      host != nil,
      "SnapshotEngine.host must be assigned before snapshotting"
    )
    let box: AssumedThreadSafe<T> =
      Thread.isMainThread
      ? MainActor.assumeIsolated {
          return AssumedThreadSafe(work(host!))
        }
      : DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          return AssumedThreadSafe(work(host!))
        }
      }
    return box.value
  }

  func invalidateWindowSnapshot() {
    withLockedStorage {
      $0.windowSnapshotObservationGeneration &+= 1
      $0.preparedWindowReadRevisions.invalidate(processID: nil)
    }
  }

  var processWindowRetryDeadlines: [pid_t: TimeInterval] {
    get { withLockedStorage { $0.processWindowRetryDeadlines } }
    set { withLockedStorage { $0.processWindowRetryDeadlines = newValue } }
  }

  var discoveryMeasurementAccess: DiscoveryMeasurementAccess? {
    get { withLockedStorage { $0.discoveryMeasurementAccess } }
    set { withLockedStorage { $0.discoveryMeasurementAccess = newValue } }
  }

  var preparedWindowReadRevisions: PreparedWindowReadRevisions {
    withLockedStorage { $0.preparedWindowReadRevisions }
  }

  var pendingObservations: SnapshotObservations {
    withLockedStorage { $0.pendingObservations }
  }

  func recordObservation(
    _ kind: PlatformEventKind,
    processID: pid_t?,
    windowID: WindowID? = nil,
    createdElement: AXUIElement? = nil,
    inputTimestamp: TimeInterval? = nil
  ) {
    withLockedStorage { storage in
      if kind == .applicationTerminated || (kind == .windows && windowID != nil) {
        let invalidated = kind == .applicationTerminated
          ? Set(storage.processIDs.compactMap { $0.value == processID ? $0.key : nil })
          : Set(windowID.map { [$0] } ?? [])
        for windowID in invalidated { storage.borderBindingRevisions[windowID] = nil }
        frameCoordinator.forgetBorderGeometry(for: invalidated)
      }
      storage.windowSnapshotObservationGeneration &+= 1
      switch windowSnapshotInvalidation(for: kind, processID: processID) {
      case .full: storage.preparedWindowReadRevisions.invalidate(processID: nil)
      case .process(let processID): storage.preparedWindowReadRevisions.invalidate(processID: processID)
      case .none:
        if let processID {
          storage.preparedWindowReadRevisions.invalidate(processID: processID)
        }
      }
      if kind == .windowCreated, let processID, let createdElement {
        storage.pendingObservations.createdElements[processID, default: []].append(createdElement)
      }
      switch windowSnapshotInvalidation(for: kind, processID: processID) {
      case .process(let processID):
        storage.pendingObservations.topologyPending = true
        storage.pendingObservations.topologyProcessIDs.insert(processID)
      case .full:
        storage.pendingObservations.topologyRequiresFullSnapshot = true
        if kind == .windowCreated || kind == .windows || kind == .application
          || kind == .applicationTerminated
        {
          storage.pendingObservations.topologyPending = true
        }
      case .none:
        break
      }
      if let inputTimestamp,
        let timestamp = updatedWindowTopologyInputTimestamp(
          for: kind,
          latestInputTimestamp: inputTimestamp,
          previousTimestamp: storage.pendingObservations.topologyInputTimestamp
        )
      {
        storage.pendingObservations.topologyInputTimestamp = max(
          storage.pendingObservations.topologyInputTimestamp ?? timestamp,
          timestamp
        )
      }
      if kind == .windows, let windowID {
        storage.pendingObservations.destroyedWindowIDs.insert(windowID)
      }
      if kind == .frame || kind == .mouse || kind == .mouseRelease {
        storage.pendingObservations.framePending = true
        if let processID {
          storage.pendingObservations.frameProcessIDs.insert(processID)
        } else {
          storage.pendingObservations.frameRequiresFullSnapshot = true
        }
        if let windowID {
          storage.pendingObservations.frameWindowIDs.insert(windowID)
        } else {
          storage.pendingObservations.frameIncludesUnscopedRefresh = true
        }
      }
    }
  }

  func invalidateAccessibilitySession() {
    withLockedStorage {
      $0.advanceBorderBindingRevisions(for: Set($0.elements.keys))
      frameCoordinator.forgetBorderGeometry(for: Set($0.elements.keys))
      $0.accessibilitySessionResetPending = true
      $0.preparedWindowReadRevisions.invalidate(processID: nil)
    }
  }

  func consumeObservations() -> SnapshotObservations {
    withLockedStorage {
      if $0.accessibilitySessionResetPending {
        // Reset on the snapshot queue, after any pass from the previous session.
        // Keep window identities and logical observations for reconciliation.
        $0.accessibilitySessionResetPending = false
        $0.pendingObservations.createdElements.removeAll(keepingCapacity: true)
        $0.applications.removeAll(keepingCapacity: true)
        $0.lastApplicationWindowElements.removeAll(keepingCapacity: true)
        $0.unmatchedWindowElementsByProcess.removeAll(keepingCapacity: true)
        $0.unmatchedWindowRetryAttemptsByProcess.removeAll(keepingCapacity: true)
        $0.windowListReadRetryAttemptsByProcess.removeAll(keepingCapacity: true)
        $0.incompatibleFreshReadDeadlines.removeAll(keepingCapacity: true)
        $0.enhancedUIByProcess.removeAll(keepingCapacity: true)
        $0.multipleAttributeReadsSupportedByProcess.removeAll(keepingCapacity: true)
        $0.failedBatchedWindowAttributeReadsByElement.removeAll(keepingCapacity: true)
        $0.chunkedFullRefreshRemainingProcessIDs = nil
        $0.hasCompletedWindowSnapshot = false
      }
      let observations = $0.pendingObservations
      $0.pendingObservations = SnapshotObservations()
      return observations
    }
  }

  func recordFrameRefresh(
    windowIDs: Set<WindowID>,
    processIDs: Set<pid_t>,
    requiresFullSnapshot: Bool,
    invalidatesPreparedObservations: Bool = true
  ) {
    withLockedStorage {
      let knownProcessIDs = $0.processIDs
      if invalidatesPreparedObservations {
        $0.windowSnapshotObservationGeneration &+= 1
        let affectedProcesses = processIDs.union(windowIDs.compactMap { knownProcessIDs[$0] })
        if requiresFullSnapshot || affectedProcesses.isEmpty
          || !windowIDs.isSubset(of: Set(knownProcessIDs.keys))
        {
          $0.preparedWindowReadRevisions.invalidate(processID: nil)
        } else {
          for processID in affectedProcesses {
            $0.preparedWindowReadRevisions.invalidate(processID: processID)
          }
        }
      }
      $0.pendingObservations.framePending = true
      $0.pendingObservations.frameWindowIDs.formUnion(windowIDs)
      $0.pendingObservations.frameProcessIDs.formUnion(processIDs)
      let scopedProcessIDs = Set(windowIDs.compactMap { knownProcessIDs[$0] })
      $0.pendingObservations.frameIncludesUnscopedRefresh =
        $0.pendingObservations.frameIncludesUnscopedRefresh
          || windowIDs.isEmpty || !processIDs.isSubset(of: scopedProcessIDs)
      $0.pendingObservations.frameRequiresFullSnapshot =
        $0.pendingObservations.frameRequiresFullSnapshot || requiresFullSnapshot
    }
  }

  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] {
    get { withLockedStorage { $0.initialFrameSettlementDeadlines } }
    set { withLockedStorage { $0.initialFrameSettlementDeadlines = newValue } }
  }

  var mouseResizeGesturePending: Bool {
    get { withLockedStorage { $0.mouseResizeGesturePending } }
    set { withLockedStorage { $0.mouseResizeGesturePending = newValue } }
  }

  var mouseFocusReleasePending: Bool {
    get { withLockedStorage { $0.mouseFocusReleasePending } }
    set { withLockedStorage { $0.mouseFocusReleasePending = newValue } }
  }

  var nativeFocusEventGeneration: UInt64 {
    get { withLockedStorage { $0.nativeFocusEventGeneration } }
    set { withLockedStorage { $0.nativeFocusEventGeneration = newValue } }
  }

  var mouseFocusReleaseEventGeneration: UInt64? {
    get { withLockedStorage { $0.mouseFocusReleaseEventGeneration } }
    set { withLockedStorage { $0.mouseFocusReleaseEventGeneration = newValue } }
  }

  var nativeFocusEventPending: Bool {
    get { withLockedStorage { $0.nativeFocusEventPending } }
    set { withLockedStorage { $0.nativeFocusEventPending = newValue } }
  }

  var nativeFocusEventProcessIDs: Set<pid_t> {
    get { withLockedStorage { $0.nativeFocusEventProcessIDs } }
    set { withLockedStorage { $0.nativeFocusEventProcessIDs = newValue } }
  }

  var nativeFocusEventHasUnknownProcess: Bool {
    get { withLockedStorage { $0.nativeFocusEventHasUnknownProcess } }
    set { withLockedStorage { $0.nativeFocusEventHasUnknownProcess = newValue } }
  }

  var lastFocusedWindowByProcess: [pid_t: WindowID] {
    get { withLockedStorage { $0.lastFocusedWindowByProcess } }
    set { withLockedStorage { $0.lastFocusedWindowByProcess = newValue } }
  }

  var nativeFullscreenExitDeadlines: [WindowID: TimeInterval] {
    get { withLockedStorage { $0.nativeFullscreenExitDeadlines } }
    set { withLockedStorage { $0.nativeFullscreenExitDeadlines = newValue } }
  }
  var nativeFullscreenProcessIDsByWindowID: [WindowID: pid_t] {
    get { withLockedStorage { $0.nativeFullscreenProcessIDsByWindowID } }
    set { withLockedStorage { $0.nativeFullscreenProcessIDsByWindowID = newValue } }
  }

  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] {
    get { withLockedStorage { $0.internalFocusSuppressions } }
    set { withLockedStorage { $0.internalFocusSuppressions = newValue } }
  }

  var lastMonitorFrames: [Rect] {
    get { withLockedStorage { $0.lastMonitorFrames } }
    set { withLockedStorage { $0.lastMonitorFrames = newValue } }
  }

  var pendingFrameDebtWindowIDs: Set<WindowID> {
    get { withLockedStorage { $0.pendingFrameDebtWindowIDs } }
    set { withLockedStorage { $0.pendingFrameDebtWindowIDs = newValue } }
  }

  var lastNativeFocusedWindowID: WindowID? {
    get { withLockedStorage { $0.lastNativeFocusedWindowID } }
    set { withLockedStorage { $0.lastNativeFocusedWindowID = newValue } }
  }

  var verifiedNativeFocusedWindowID: WindowID? {
    get { withLockedStorage { $0.verifiedNativeFocusedWindowID } }
    set { withLockedStorage { $0.verifiedNativeFocusedWindowID = newValue } }
  }

  var lastUnconfirmedActivationTimestamp: TimeInterval? {
    get { withLockedStorage { $0.lastUnconfirmedActivationTimestamp } }
    set { withLockedStorage { $0.lastUnconfirmedActivationTimestamp = newValue } }
  }

  // MARK: registries

  func borderGeometryTargets(for windowIDs: Set<WindowID>) -> [BorderGeometryReadTarget] {
    withLockedStorage { storage in
      guard !storage.accessibilitySessionResetPending else { return [] }
      return windowIDs.sorted { $0.rawValue < $1.rawValue }.compactMap { windowID in
        guard let element = storage.elements[windowID],
          let processID = storage.processIDs[windowID],
          let application = storage.applications[processID],
          let revision = storage.borderBindingRevisions[windowID]
        else { return nil }
        return BorderGeometryReadTarget(windowID: windowID, processID: processID,
          application: application, element: element, bindingRevision: revision)
      }
    }
  }

  func borderBindingIsCurrent(_ target: BorderGeometryReadTarget) -> Bool {
    withLockedStorage { $0.borderBindingIsCurrent(target) }
  }

  func recordCachedBorderFrame(for windowID: WindowID) {
    withLockedStorage { storage in
      frameCoordinator.lock.lock()
      defer { frameCoordinator.lock.unlock() }
      guard storage.elements[windowID] != nil, !storage.accessibilitySessionResetPending,
        let frame = frameCoordinator.borderGeometries[windowID]?.frame
      else { return }
      storage.latestObservedFrames[windowID] = frame
    }
  }

  func acceptBorderObservation(_ observation: BorderGeometryObservation) -> Bool {
    withLockedStorage { storage in
      frameCoordinator.lock.lock()
      defer { frameCoordinator.lock.unlock() }
      guard storage.borderBindingIsCurrent(observation.ticket.target),
        frameCoordinator.acceptBorderObservationLocked(observation)
      else { return false }
      storage.latestObservedFrames[observation.windowID] = observation.frame
      return true
    }
  }

  func reconcileAcceptedObservations(_ observations: [BorderGeometryObservation])
    -> [BorderGeometryObservation] {
    withLockedStorage { storage in
      frameCoordinator.lock.lock()
      defer { frameCoordinator.lock.unlock() }
      return observations.filter { observation in
        guard storage.borderBindingIsCurrent(observation.ticket.target),
          frameCoordinator.acceptBorderObservationLocked(observation, completingWrite: true)
        else { return false }
        storage.latestObservedFrames[observation.windowID] = observation.frame
        return true
      }
    }
  }

  func consumeAcceptedFrames(_ observations: [BorderGeometryObservation]) -> [WindowID: Rect] {
    withLockedStorage { storage in
      frameCoordinator.lock.lock()
      defer { frameCoordinator.lock.unlock() }
      var frames: [WindowID: Rect] = [:]
      for observation in observations {
        guard storage.borderBindingIsCurrent(observation.ticket.target),
          frameCoordinator.observationIsCurrentLocked(observation)
        else { continue }
        storage.latestObservedFrames[observation.windowID] = observation.frame
        frames[observation.windowID] = observation.frame
      }
      return frames
    }
  }

  var elements: [WindowID: AXUIElement] {
    get { withLockedStorage { $0.elements } }
    set {
      withLockedStorage { storage in
        let changed = Set(storage.elements.keys).union(newValue.keys).filter {
          !sameAXElement(storage.elements[$0], newValue[$0])
            || (newValue[$0] != nil && storage.borderBindingRevisions[$0] == nil)
        }
        storage.elements = newValue
        storage.advanceBorderBindingRevisions(for: Set(changed))
        frameCoordinator.forgetBorderGeometry(for: Set(changed))
      }
    }
  }

  var processIDs: [WindowID: pid_t] {
    get { withLockedStorage { $0.processIDs } }
    set {
      withLockedStorage { storage in
        let changed = Set(storage.processIDs.keys).union(newValue.keys).filter {
          storage.processIDs[$0] != newValue[$0]
        }
        storage.processIDs = newValue
        storage.advanceBorderBindingRevisions(for: Set(changed))
        frameCoordinator.forgetBorderGeometry(for: Set(changed))
      }
    }
  }

  var applications: [pid_t: AXUIElement] {
    get { withLockedStorage { $0.applications } }
    set {
      withLockedStorage { storage in
        let changedProcesses = Set(storage.applications.keys).union(newValue.keys).filter {
          !sameAXElement(storage.applications[$0], newValue[$0])
        }
        let changedWindows = Set(storage.processIDs.compactMap {
          changedProcesses.contains($0.value) ? $0.key : nil
        })
        storage.advanceBorderBindingRevisions(for: changedWindows)
        frameCoordinator.forgetBorderGeometry(for: changedWindows)
        storage.applications = newValue
        storage.unmatchedWindowElementsByProcess = storage.unmatchedWindowElementsByProcess.filter {
          newValue[$0.key] != nil
        }
        storage.unmatchedWindowRetryAttemptsByProcess = storage.unmatchedWindowRetryAttemptsByProcess.filter {
          newValue[$0.key] != nil && storage.unmatchedWindowElementsByProcess[$0.key]?.isEmpty == false
        }
        storage.windowListReadRetryAttemptsByProcess = storage.windowListReadRetryAttemptsByProcess.filter {
          newValue[$0.key] != nil
        }
        storage.processWindowRetryDeadlines = storage.processWindowRetryDeadlines.filter {
          newValue[$0.key] != nil
        }
        // An empty inventory cannot leave a full-refresh continuation pending.
        if newValue.isEmpty { storage.chunkedFullRefreshRemainingProcessIDs = nil }
      }
    }
  }

  var applicationIDsByProcess: [pid_t: String] {
    get { withLockedStorage { $0.applicationIDsByProcess } }
    set { withLockedStorage { $0.applicationIDsByProcess = newValue } }
  }

  var applicationWindowCounts: [pid_t: Int] {
    get { withLockedStorage { $0.applicationWindowCounts } }
    set { withLockedStorage { $0.applicationWindowCounts = newValue } }
  }

  var overviewPresentationActive: Bool {
    get { withLockedStorage { $0.overviewPresentationActive } }
    set { withLockedStorage { $0.overviewPresentationActive = newValue } }
  }

  var lastSnapshotWindows: [Window] {
    get { withLockedStorage { $0.lastSnapshotWindows } }
    set { withLockedStorage { $0.lastSnapshotWindows = newValue } }
  }

  var lastSnapshotWindowIDs: Set<WindowID> {
    get { withLockedStorage { $0.lastSnapshotWindowIDs } }
    set { withLockedStorage { $0.lastSnapshotWindowIDs = newValue } }
  }

  var lastSnapshotProcessIDs: Set<pid_t> {
    get { withLockedStorage { $0.lastSnapshotProcessIDs } }
    set { withLockedStorage { $0.lastSnapshotProcessIDs = newValue } }
  }

  var lastResolvedFrontmostProcessID: pid_t? {
    get { withLockedStorage { $0.lastResolvedFrontmostProcessID } }
    set { withLockedStorage { $0.lastResolvedFrontmostProcessID = newValue } }
  }

  var floatingWindowIDs: Set<WindowID> {
    get { withLockedStorage { $0.floatingWindowIDs } }
    set { withLockedStorage { $0.floatingWindowIDs = newValue } }
  }

  // MARK: discovery caches and retry bookkeeping

  var lastApplicationWindowElements: [pid_t: [AXUIElement]] {
    get { withLockedStorage { $0.lastApplicationWindowElements } }
    set { withLockedStorage { $0.lastApplicationWindowElements = newValue } }
  }

  var minimizedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { withLockedStorage { $0.minimizedWindowElementsByProcess } }
    set { withLockedStorage { $0.minimizedWindowElementsByProcess = newValue } }
  }

  var transientGeometryWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { withLockedStorage { $0.transientGeometryWindowElementsByProcess } }
    set { withLockedStorage { $0.transientGeometryWindowElementsByProcess = newValue } }
  }

  var unmatchedWindowElementsByProcess: [pid_t: [AXUIElement]] {
    get { withLockedStorage { $0.unmatchedWindowElementsByProcess } }
    set { withLockedStorage { $0.unmatchedWindowElementsByProcess = newValue } }
  }

  var unmatchedWindowRetryAttemptsByProcess: [pid_t: Int] {
    get { withLockedStorage { $0.unmatchedWindowRetryAttemptsByProcess } }
    set { withLockedStorage { $0.unmatchedWindowRetryAttemptsByProcess = newValue } }
  }

  var windowListReadRetryAttemptsByProcess: [pid_t: Int] {
    get { withLockedStorage { $0.windowListReadRetryAttemptsByProcess } }
    set { withLockedStorage { $0.windowListReadRetryAttemptsByProcess = newValue } }
  }

  var cgWindowInventoryRetryAttempts: Int? {
    get { withLockedStorage { $0.cgWindowInventoryRetryAttempts } }
    set { withLockedStorage { $0.cgWindowInventoryRetryAttempts = newValue } }
  }

  var retainedWindowIDs: Set<WindowID> {
    get { withLockedStorage { $0.retainedWindowIDs } }
    set { withLockedStorage { $0.retainedWindowIDs = newValue } }
  }

  var retainedWindowDeadlines: [WindowID: TimeInterval] {
    get { withLockedStorage { $0.retainedWindowDeadlines } }
    set { withLockedStorage { $0.retainedWindowDeadlines = newValue } }
  }

  var transientOwnerWindowIDs: [WindowID: WindowID] {
    get { withLockedStorage { $0.transientOwnerWindowIDs } }
    set { withLockedStorage { $0.transientOwnerWindowIDs = newValue } }
  }

  var transientOwnerResolutionAttempts: [WindowID: Int] {
    get { withLockedStorage { $0.transientOwnerResolutionAttempts } }
    set { withLockedStorage { $0.transientOwnerResolutionAttempts = newValue } }
  }

  var transientOwnerResolutionRetryAfter: [WindowID: TimeInterval] {
    get { withLockedStorage { $0.transientOwnerResolutionRetryAfter } }
    set { withLockedStorage { $0.transientOwnerResolutionRetryAfter = newValue } }
  }

  var windowManagementCapabilities: [WindowID: WindowManagementCapabilities] {
    get { withLockedStorage { $0.windowManagementCapabilities } }
    set { withLockedStorage { $0.windowManagementCapabilities = newValue } }
  }

  var nativeWindowTabGroupsByWindowID: [WindowID: NativeWindowTabGroup] {
    get { withLockedStorage { $0.nativeWindowTabGroupsByWindowID } }
    set { withLockedStorage { $0.nativeWindowTabGroupsByWindowID = newValue } }
  }

  var enhancedUIByProcess: [pid_t: Bool] {
    get { withLockedStorage { $0.enhancedUIByProcess } }
    set { withLockedStorage { $0.enhancedUIByProcess = newValue } }
  }

  var multipleAttributeReadsSupportedByProcess: [pid_t: Bool] {
    get { withLockedStorage { $0.multipleAttributeReadsSupportedByProcess } }
    set { withLockedStorage { $0.multipleAttributeReadsSupportedByProcess = newValue } }
  }

  var failedBatchedWindowAttributeReadsByElement: [AXWindowElementIdentity: Int]
  {
    get { withLockedStorage { $0.failedBatchedWindowAttributeReadsByElement } }
    set { withLockedStorage { $0.failedBatchedWindowAttributeReadsByElement = newValue } }
  }

  // MARK: frame reconciliation inputs

  var targetFrames: [WindowID: Rect] {
    get { withLockedStorage { $0.targetFrames } }
    set { withLockedStorage { $0.targetFrames = newValue } }
  }

  func recordObservedFrame(_ frame: Rect?, for windowID: WindowID) {
    withLockedStorage { $0.latestObservedFrames[windowID] = frame }
  }

  var latestObservedFrames: [WindowID: Rect] {
    get { withLockedStorage { $0.latestObservedFrames } }
    set { withLockedStorage { $0.latestObservedFrames = newValue } }
  }

  var frameCommitExpectations: [WindowID: FrameCommitExpectation] {
    get { withLockedStorage { $0.frameCommitExpectations } }
    set { withLockedStorage { $0.frameCommitExpectations = newValue } }
  }

  var pendingFrameCorrections: [WindowID: Rect] {
    get { withLockedStorage { $0.pendingFrameCorrections } }
    set { withLockedStorage { $0.pendingFrameCorrections = newValue } }
  }

  var newlyDiscoveredWindowIDs: Set<WindowID> {
    get { withLockedStorage { $0.newlyDiscoveredWindowIDs } }
    set { withLockedStorage { $0.newlyDiscoveredWindowIDs = newValue } }
  }

  var hasCompletedWindowSnapshot: Bool {
    get { withLockedStorage { $0.hasCompletedWindowSnapshot } }
    set { withLockedStorage { $0.hasCompletedWindowSnapshot = newValue } }
  }

  // MARK: pending observation events

  var windowSnapshotObservationGeneration: UInt64 {
    get { withLockedStorage { $0.windowSnapshotObservationGeneration } }
    set {
      withLockedStorage {
        $0.windowSnapshotObservationGeneration = newValue
        $0.preparedWindowReadRevisions.invalidate(processID: nil)
      }
    }
  }

  // MARK: window inventory

  var lastCGWindowInventory: [CGWindowRecord]? {
    withLockedStorage { $0.lastCGWindowInventory?.records }
  }

  func publishCGWindowInventory(_ inventory: CGWindowInventory?) {
    withLockedStorage { $0.lastCGWindowInventory = inventory }
  }

  var cgWindowDiscoveryRetries: CGWindowDiscoveryRetryTracker {
    get { withLockedStorage { $0.cgWindowDiscoveryRetries } }
    set { withLockedStorage { $0.cgWindowDiscoveryRetries = newValue } }
  }

  var cgWindowDiscoveryDiagnostics: [CGWindowDiscoveryDiagnostic] {
    get { withLockedStorage { $0.cgWindowDiscoveryDiagnostics } }
    set { withLockedStorage { $0.cgWindowDiscoveryDiagnostics = newValue } }
  }

  var cgWindowDiscoveryTraceSignatures: [CGWindowDiscoveryIdentity: String] {
    get { withLockedStorage { $0.cgWindowDiscoveryTraceSignatures } }
    set { withLockedStorage { $0.cgWindowDiscoveryTraceSignatures = newValue } }
  }

  func cgWindowDiscoveryStatus(now: TimeInterval) -> String {
    withLockedStorage { formattedCGWindowDiscoveryStatus($0.cgWindowDiscoveryDiagnostics, now: now) }
  }

  func dueCGWindowDiscoveryRetryProcessIDs(now: TimeInterval) -> Set<pid_t> {
    withLockedStorage { $0.cgWindowDiscoveryRetries.dueProcessIDs(now: now) }
  }

  func cgWindowDiscoveryRetryInterval(now: TimeInterval) -> TimeInterval? {
    withLockedStorage { $0.cgWindowDiscoveryRetries.refreshInterval(now: now) }
  }

  func borderStackingInventory(now: TimeInterval) -> [CGWindowRecord]? {
    withLockedStorage {
      $0.lastCGWindowInventory?.recordsForBorderStacking(
        generation: $0.windowSnapshotObservationGeneration, now: now
      )
    }
  }

  // MARK: freshness budgets

  var deferredFreshReadProcessIDs: Set<pid_t> {
    get { withLockedStorage { $0.deferredFreshReadProcessIDs } }
    set { withLockedStorage { $0.deferredFreshReadProcessIDs = newValue } }
  }

  var deferredFreshReadsStartedAt: TimeInterval? {
    get { withLockedStorage { $0.deferredFreshReadsStartedAt } }
    set { withLockedStorage { $0.deferredFreshReadsStartedAt = newValue } }
  }

  var chunkedFullRefreshRemainingProcessIDs: Set<pid_t>? {
    get { withLockedStorage { $0.chunkedFullRefreshRemainingProcessIDs } }
    set { withLockedStorage { $0.chunkedFullRefreshRemainingProcessIDs = newValue } }
  }

  var incompatibleFreshReadDeadlines: [pid_t: TimeInterval] {
    get { withLockedStorage { $0.incompatibleFreshReadDeadlines } }
    set { withLockedStorage { $0.incompatibleFreshReadDeadlines = newValue } }
  }

  // MARK: telemetry

  var lastHiddenWindowIDs: Set<WindowID> {
    get { withLockedStorage { $0.lastHiddenWindowIDs } }
    set { withLockedStorage { $0.lastHiddenWindowIDs = newValue } }
  }

  var deferredFrameCommitMismatchCount: Int {
    get { withLockedStorage { $0.deferredFrameCommitMismatchCount } }
    set { withLockedStorage { $0.deferredFrameCommitMismatchCount = newValue } }
  }

  var observedFrameCommitCount: Int {
    get { withLockedStorage { $0.observedFrameCommitCount } }
    set { withLockedStorage { $0.observedFrameCommitCount = newValue } }
  }

  var maximumObservedFrameCommitLatencyMS: Double {
    get { withLockedStorage { $0.maximumObservedFrameCommitLatencyMS } }
    set { withLockedStorage { $0.maximumObservedFrameCommitLatencyMS = newValue } }
  }

  var batchedWindowAttributeReadCount: Int {
    get { withLockedStorage { $0.batchedWindowAttributeReadCount } }
    set { withLockedStorage { $0.batchedWindowAttributeReadCount = newValue } }
  }

  var fallbackWindowAttributeReadCount: Int {
    get { withLockedStorage { $0.fallbackWindowAttributeReadCount } }
    set { withLockedStorage { $0.fallbackWindowAttributeReadCount = newValue } }
  }

  var windowManagementMetadataReadCount: Int {
    get { withLockedStorage { $0.windowManagementMetadataReadCount } }
    set { withLockedStorage { $0.windowManagementMetadataReadCount = newValue } }
  }

  var windowManagementMetadataReuseCount: Int {
    get { withLockedStorage { $0.windowManagementMetadataReuseCount } }
    set { withLockedStorage { $0.windowManagementMetadataReuseCount = newValue } }
  }

  var privateWindowIDLookupCount: Int {
    get { withLockedStorage { $0.privateWindowIDLookupCount } }
    set { withLockedStorage { $0.privateWindowIDLookupCount = newValue } }
  }

  var publicWindowIDFallbackCount: Int {
    get { withLockedStorage { $0.publicWindowIDFallbackCount } }
    set { withLockedStorage { $0.publicWindowIDFallbackCount = newValue } }
  }

  var lastWindowSnapshotDurationMS: Double {
    get { withLockedStorage { $0.lastWindowSnapshotDurationMS } }
    set { withLockedStorage { $0.lastWindowSnapshotDurationMS = newValue } }
  }

  var maximumWindowSnapshotDurationMS: Double {
    get { withLockedStorage { $0.maximumWindowSnapshotDurationMS } }
    set { withLockedStorage { $0.maximumWindowSnapshotDurationMS = newValue } }
  }

  var windowSnapshotDurationSamplesMS: [Double] {
    get { withLockedStorage { $0.windowSnapshotDurationSamplesMS } }
    set { withLockedStorage { $0.windowSnapshotDurationSamplesMS = newValue } }
  }

  var fullWindowSnapshotCount: Int {
    get { withLockedStorage { $0.fullWindowSnapshotCount } }
    set { withLockedStorage { $0.fullWindowSnapshotCount = newValue } }
  }

  var incrementalWindowSnapshotCount: Int {
    get { withLockedStorage { $0.incrementalWindowSnapshotCount } }
    set { withLockedStorage { $0.incrementalWindowSnapshotCount = newValue } }
  }

  var cachedWindowSnapshotCount: Int {
    get { withLockedStorage { $0.cachedWindowSnapshotCount } }
    set { withLockedStorage { $0.cachedWindowSnapshotCount = newValue } }
  }

  var applicationInventorySnapshotCount: Int {
    get { withLockedStorage { $0.applicationInventorySnapshotCount } }
    set { withLockedStorage { $0.applicationInventorySnapshotCount = newValue } }
  }

  var applicationWindowListReadCount: Int {
    get { withLockedStorage { $0.applicationWindowListReadCount } }
    set { withLockedStorage { $0.applicationWindowListReadCount = newValue } }
  }

  var applicationInventoryDurationSamplesMS: [Double] {
    get { withLockedStorage { $0.applicationInventoryDurationSamplesMS } }
    set { withLockedStorage { $0.applicationInventoryDurationSamplesMS = newValue } }
  }

  var applicationWindowListDurationSamplesMS: [Double] {
    get { withLockedStorage { $0.applicationWindowListDurationSamplesMS } }
    set { withLockedStorage { $0.applicationWindowListDurationSamplesMS = newValue } }
  }

  var snapshotCGWindowCopyCount: Int {
    get { withLockedStorage { $0.snapshotCGWindowCopyCount } }
    set { withLockedStorage { $0.snapshotCGWindowCopyCount = newValue } }
  }

  var lastSnapshotCGWindowCopyDurationMS: Double {
    get { withLockedStorage { $0.lastSnapshotCGWindowCopyDurationMS } }
    set { withLockedStorage { $0.lastSnapshotCGWindowCopyDurationMS = newValue } }
  }

  var maximumSnapshotCGWindowCopyDurationMS: Double {
    get { withLockedStorage { $0.maximumSnapshotCGWindowCopyDurationMS } }
    set { withLockedStorage { $0.maximumSnapshotCGWindowCopyDurationMS = newValue } }
  }
  init(
    frameCoordinator: AXFrameCoordinator,
    userInputTracker: UserInputTracker
  ) {
    self.frameCoordinator = frameCoordinator
    self.userInputTracker = userInputTracker
    frameCoordinator.snapshotEngine = self
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
    let attributes =
      preparedAttributes
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
      return .ignored(
        reason: attributes.minimized == true ? "AX-minimized" : "frame-below-80x60",
        title: attributes.title
      )
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
    var record = publicRecord
    let hasEligiblePublicCandidate = eligibleCGWindows.contains {
      $0.processID == processID && !usedCGWindowIDs.contains($0.id)
    }
    let supportsExactWindowID = role == kAXWindowRole || role == kAXSheetRole
    if supportsExactWindowID
      && ((publicRecord == nil && hasEligiblePublicCandidate)
        || cgWindowDiscoveryNeedsExactID(
          preferredWindowID: preferredWindowID,
          processID: processID,
          title: title,
          frame: frame,
          records: eligibleCGWindows,
          excluding: usedCGWindowIDs
        ))
    {
      let axWindowID = {
        let assumedElement = AssumedThreadSafe(element)
        return onMain { $0.windowIDProvider.windowID(for: assumedElement.value) }
      }()
      if axWindowID == nil {
        publicWindowIDFallbackCount += 1
      } else {
        privateWindowIDLookupCount += 1
      }
      if let axWindowID {
        record =
          cgWindowRecordForDiscovery(
            axWindowID: axWindowID,
            preferredWindowID: nil,
            processID: processID,
            title: title,
            frame: frame,
            records: eligibleCGWindows,
            excluding: usedCGWindowIDs
          ) ?? record
      }
    }
    guard let resolvedWindowID = record?.id else {
      return .unmatched(title: title)
    }
    let windowID = WindowID(rawValue: UInt64(resolvedWindowID))
    let previousWindow = lastSnapshotWindows.first {
      $0.id == windowID && $0.processID == processID
    }
    let sizeConstraints = windowSizeConstraintsForSnapshot(
      previousWindow: previousWindow, overviewActive: overviewPresentationActive
    ) {
      onMain { platform in
        if let ownedWindowID = platform.borderManager.ownedSurfaceWindowID {
          platform.borderBoundsProvider.probe(ownedWindowID: ownedWindowID)
        }
        return platform.borderBoundsProvider.sizeConstraints(for: windowID)
      }
    }
    let monitorID = monitor(containing: frame, monitors: monitors)?.id
    return .discovered(
      Window(
        id: windowID,
        appID: appID,
        title: title,
        frame: frame,
        role: role,
        subrole: subrole,
        processID: processID,
        isModal: attributes.modal == true,
        monitorID: monitorID,
        forceTiling: false,
        minimumTiledWidth: sizeConstraints?.minimumWidth,
        maximumTiledWidth: sizeConstraints?.maximumWidth,
        maximumTiledHeight: sizeConstraints?.maximumHeight
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
    guard
      let isModal = resolvedWindowModalState(
        error: modalError,
        observedValue: modalValue as? Bool,
        cachedValue: windowManagementCapabilities[window.id]?.isModal
      )
    else {
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
    in windows: [Window],
    frontmostProcessID: pid_t?,
    requiresConfirmedWindow: Bool = false
  ) -> WindowID? {
    let system = AXUIElementCreateSystemWide()
    let focusedApplication: CFTypeRef? = AXMessagingTimeoutAccess.shared
      .withTimeout(
        focusSnapshotAccessibilityTimeoutSeconds,
        elements: [system]
      ) {
        var value: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(
            system,
            kAXFocusedApplicationAttribute as CFString,
            &value
          ) == .success
        else {
          return nil
        }
        return value
      }
    var focusedProcessID: pid_t = 0
    let systemFocusedElement = focusedApplication.map { $0 as! AXUIElement }
    let readFocusedProcessID = systemFocusedElement.map { element in
      AXMessagingTimeoutAccess.shared.withTimeout(
        focusSnapshotAccessibilityTimeoutSeconds,
        elements: [element]
      ) {
        AXUIElementGetPid(element, &focusedProcessID) == .success
      }
    } ?? false
    let verifiedNativeFocusProcessID = frontmostProcessID.flatMap { processID in
      nativeFocusEventMatchesTarget(
        eventPending: nativeFocusEventPending,
        eventProcessIDs: nativeFocusEventProcessIDs,
        hasUnknownEventProcess: nativeFocusEventHasUnknownProcess,
        focusedProcessID: processID
      ) ? processID : nil
    }
    let resolvedProcessID = consistentFocusedProcessID(
      accessibilityProcessID: readFocusedProcessID ? focusedProcessID : nil,
      frontmostProcessID: frontmostProcessID,
      verifiedNativeFocusProcessID: verifiedNativeFocusProcessID
    )
    guard let resolvedProcessID else {
      return nil
    }
    if !readFocusedProcessID && nativeFocusEventPending
      && verifiedNativeFocusProcessID != resolvedProcessID
    { return nil }
    // A missing system-wide AX answer can still be confirmed by a fresh
    // focused-window read from the frontmost app; a conflicting answer cannot.
    if requiresConfirmedWindow && readFocusedProcessID && focusedProcessID != resolvedProcessID
      && verifiedNativeFocusProcessID != resolvedProcessID
    { return nil }
    let focusedApplicationElement: AXUIElement =
      readFocusedProcessID && focusedProcessID == resolvedProcessID
      ? systemFocusedElement! : AXUIElementCreateApplication(resolvedProcessID)
    if resolvedProcessID != focusedProcessID && !requiresConfirmedWindow {
      if let stable = stableWindowID(
        processID: resolvedProcessID,
        in: windows
      ) { return stable }
    }
    let focusedWindow: CFTypeRef? = AXMessagingTimeoutAccess.shared.withTimeout(
      focusSnapshotAccessibilityTimeoutSeconds,
      elements: [focusedApplicationElement]
    ) {
      var value: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          focusedApplicationElement,
          kAXFocusedWindowAttribute as CFString,
          &value
        ) == .success
      else {
        return nil
      }
      return value
    }
    guard let focusedWindow else {
      return requiresConfirmedWindow ? nil : stableWindowID(processID: resolvedProcessID, in: windows)
    }
    let focusedElement = focusedWindow as! AXUIElement
    if let exact = elements.first(where: { CFEqual($0.value, focusedElement) }) {
      return exact.key
    }
    guard
      let focusedFrame = AXMessagingTimeoutAccess.shared.withTimeout(
        focusSnapshotAccessibilityTimeoutSeconds,
        elements: [focusedElement],
        perform: { frame(of: focusedElement) }
      )
    else {
      return requiresConfirmedWindow ? nil : stableWindowID(processID: resolvedProcessID, in: windows)
    }
    return focusedWindowIDMatchingFrame(
      processID: resolvedProcessID,
      focusedFrame: focusedFrame,
      windows: windows
    )
  }

  /// Activation fallback for slow-AX processes. When AX focus confirmation
  /// lags a genuine app activation, performs one bounded fresh read of the
  /// frontmost process's AX window list and admits its window only when that
  /// read proves there is exactly one window and it is the single managed
  /// one. A sibling created but not yet discovered appears in the fresh
  /// list, forcing nil so multi-window cases keep requiring AX
  /// confirmation. Returns nil for unknown processes and on AX timeout.
  func singleFreshWindowID(
    frontmostProcessID: pid_t?,
    in windows: [Window]
  ) -> WindowID? {
    guard let frontmostProcessID,
      let appElement = applications[frontmostProcessID]
    else { return nil }
    let rawWindows: [AXUIElement]? = AXMessagingTimeoutAccess.shared.withTimeout(
      focusSnapshotAccessibilityTimeoutSeconds,
      elements: [appElement]
    ) {
      copyElements(appElement, attribute: kAXWindowsAttribute)
    }
    guard rawWindows?.count == 1,
      let rawWindow = rawWindows?.first,
      let match = singleManagedWindowID(processID: frontmostProcessID, in: windows),
      let element = elements[match],
      CFEqual(rawWindow, element)
    else { return nil }
    return match
  }

  func stableWindowID(
    processID: pid_t?,
    in windows: [Window]
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
    guard !nativeFocusEventPending || verifiedSingleWindowPendingFocus else { return nil }
    if let previous = lastFocusedWindowByProcess[processID],
      candidates.contains(where: { $0.id == previous })
    {
      return previous
    }
    return candidates.count == 1 ? candidates[0].id : nil
  }

  func frame(of element: AXUIElement) -> Rect? {
    guard let positionValue = copyAttribute(element, name: kAXPositionAttribute),
      let sizeValue = copyAttribute(element, name: kAXSizeAttribute)
    else { return nil }
    return frameFromAXValues(positionValue: positionValue, sizeValue: sizeValue)
  }

  func nativeWindowTabGroup(
    in element: AXUIElement,
    windowFrame: Rect,
    allowsTransientFrameMismatch: Bool = false
  ) -> NativeWindowTabGroup? {
    guard let children = copyElements(element, attribute: kAXChildrenAttribute) else {
      return nil
    }
    for child in children {
      guard value(child, attribute: kAXRoleAttribute, as: String.self) == kAXTabGroupRole,
        let tabGroupFrame = frame(of: child),
        allowsTransientFrameMismatch
          || nativeTabGroupFrameIsInWindowChrome(
            tabGroupFrame,
            windowFrame: windowFrame
          ),
        let tabs = copyElements(child, attribute: kAXTabsAttribute),
        tabs.count > 1
      else { continue }
      let selectedTabTitle: String?
      if let selectedTabValue = copyAttribute(child, name: kAXValueAttribute),
        CFGetTypeID(selectedTabValue) == AXUIElementGetTypeID()
      {
        selectedTabTitle = value(
          selectedTabValue as! AXUIElement,
          attribute: kAXTitleAttribute,
          as: String.self
        )
      } else {
        selectedTabTitle = nil
      }
      return NativeWindowTabGroup(
        tabTitles: tabs.map {
          value($0, attribute: kAXTitleAttribute, as: String.self) ?? ""
        },
        selectedTabTitle: selectedTabTitle
      )
    }
    return nil
  }

  func windowAttributes(
    _ element: AXUIElement,
    processID: pid_t
  ) -> AXWindowAttributes {
    if let access = discoveryMeasurementAccess { return access.windowAttributes(element, processID) }
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
  var processWindowRetryDeadlines: [pid_t: TimeInterval] = [:]
  var discoveryMeasurementAccess: DiscoveryMeasurementAccess?
  var pendingObservations = SnapshotObservations()
  var nextBorderBindingRevision: UInt64 = 0
  var borderBindingRevisions: [WindowID: UInt64] = [:]

  mutating func advanceBorderBindingRevisions(for windowIDs: Set<WindowID>) {
    for windowID in windowIDs {
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
  var nativeWindowTabGroupsByWindowID: [WindowID: NativeWindowTabGroup] = [:]
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
  var incompatibleFreshReadDeadlines: [pid_t: TimeInterval] = [:]
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] = [:]
  var mouseResizeGesturePending: Bool = false
  var mouseFocusReleasePending: Bool = false
  var nativeFocusEventGeneration: UInt64 = 0
  var mouseFocusReleaseEventGeneration: UInt64? = nil
  var nativeFocusEventPending: Bool = false
  var nativeFocusEventProcessIDs: Set<pid_t> = Set<pid_t>()
  var nativeFocusEventHasUnknownProcess: Bool = false
  var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  var nativeFullscreenExitDeadlines: [WindowID: TimeInterval] = [:]
  var nativeFullscreenProcessIDsByWindowID: [WindowID: pid_t] = [:]
  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] = [:]
  var lastMonitorFrames: [Rect] = []
  var pendingFrameDebtWindowIDs: Set<WindowID> = Set<WindowID>()
  var lastNativeFocusedWindowID: WindowID? = nil
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
      maximumWidth: $0.maximumTiledWidth, maximumHeight: $0.maximumTiledHeight)
  }
}

private func sameAXElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil): return true
  case let (lhs?, rhs?): return CFEqual(lhs, rhs)
  default: return false
  }
}

extension SnapshotEngine {
  @discardableResult
  func synchronizeProcessWindowRetryDeadlines(now: TimeInterval) -> [pid_t: TimeInterval] {
    withLockedStorage { state in
      let unmatched = state.unmatchedWindowElementsByProcess.compactMap { pid, elements in
        !elements.isEmpty && unmatchedWindowRetryIsPending(attempts: state.unmatchedWindowRetryAttemptsByProcess[pid] ?? 0)
          ? pid : nil
      }
      let failedLists = state.windowListReadRetryAttemptsByProcess.compactMap { pid, attempts in
        unmatchedWindowRetryIsPending(attempts: attempts) ? pid : nil
      }
      let retained = retainedWindowRefreshProcessIDs(
        retainedWindowIDs: state.retainedWindowIDs, processIDs: state.processIDs
      ).intersection(state.applications.keys)
      let pending = Set(unmatched).union(failedLists).union(retained)
      var deadlines = state.processWindowRetryDeadlines.filter { pending.contains($0.key) }
      for pid in pending where deadlines[pid] == nil { deadlines[pid] = now + 0.1 }
      for (windowID, deadline) in state.retainedWindowDeadlines {
        guard let pid = state.processIDs[windowID], pending.contains(pid) else { continue }
        deadlines[pid] = min(deadlines[pid] ?? deadline, deadline)
      }
      state.processWindowRetryDeadlines = deadlines
      return deadlines
    }
  }

  func recordProcessWindowRetryRead(processID: pid_t, now: TimeInterval, retained: Set<WindowID>) {
    withLockedStorage { state in
      let pending = state.unmatchedWindowElementsByProcess[processID]?.isEmpty == false
        && unmatchedWindowRetryIsPending(attempts: state.unmatchedWindowRetryAttemptsByProcess[processID] ?? 0)
        || state.windowListReadRetryAttemptsByProcess[processID].map { unmatchedWindowRetryIsPending(attempts: $0) } == true
        || !retained.isEmpty
      let previous = state.processWindowRetryDeadlines[processID]
      state.processWindowRetryDeadlines[processID] = pending
        ? (previous.map { $0 > now + 0.000001 ? min($0, now + 0.1) : now + 0.1 } ?? now + 0.1)
        : nil
    }
  }

  func recordWindowListRetryResult(processID: pid_t, succeeded: Bool, now: TimeInterval) {
    withLockedStorage { state in
      let previous = state.windowListReadRetryAttemptsByProcess[processID]
      if !succeeded, previous != nil,
        let deadline = state.processWindowRetryDeadlines[processID], deadline > now + 0.000001
      { return }
      state.windowListReadRetryAttemptsByProcess[processID] = updatedWindowListReadRetryAttempts(
        previousAttempts: previous, readSucceeded: succeeded
      )
    }
  }

  func dueProcessWindowRetryIDs(now: TimeInterval) -> Set<pid_t> {
    Set(synchronizeProcessWindowRetryDeadlines(now: now).compactMap {
      $0.value <= now + 0.000001 ? $0.key : nil
    })
  }

  func nextProcessWindowRetryAt(now: TimeInterval) -> TimeInterval? {
    synchronizeProcessWindowRetryDeadlines(now: now).values.min()
  }
}
