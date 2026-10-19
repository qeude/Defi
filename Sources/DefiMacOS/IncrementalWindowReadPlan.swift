import ApplicationServices
import DefiModel

func discoveryWindowListReadIsRequired(
  hasCachedWindows: Bool, refreshesAllWindowLists: Bool,
  topologyProcessWasInvalidated: Bool, hasCreatedElements: Bool,
  forceWindowListRefresh: Bool, forceProcessWindowListRefresh: Bool,
  refreshesApplicationInventory: Bool
) -> Bool {
  if hasCreatedElements && hasCachedWindows && !forceWindowListRefresh
    && !forceProcessWindowListRefresh && !refreshesApplicationInventory { return false }
  return applicationWindowListRefreshIsRequired(
    hasCachedWindows: hasCachedWindows, refreshesAllWindowLists: refreshesAllWindowLists,
    topologyProcessWasInvalidated: topologyProcessWasInvalidated
  )
}

func discoveryWindowAttributeReadIsRequired(
  refreshesWindowList: Bool, frameRefreshWindowIDs: Set<WindowID>?,
  previousWindowID: WindowID?, hasCachedWindow: Bool
) -> Bool {
  guard !refreshesWindowList, let frameRefreshWindowIDs, let previousWindowID,
    hasCachedWindow, CGWindowID(exactly: previousWindowID.rawValue) != nil
  else { return true }
  return frameRefreshWindowIDs.contains(previousWindowID)
}

struct PreparedIncrementalDiscoveryReads {
  var attributes: [WindowID: AXWindowAttributes] = [:]
  var applications: [pid_t: PreparedAXApplicationWindows] = [:]
  var deferredProcessIDs: Set<pid_t> = []
  var revisions: PreparedWindowReadRevisions
  var inputTimestamp: TimeInterval

  func isCurrent(_ engine: SnapshotEngine, processID: pid_t) -> Bool {
    engine.userInputTracker.latestEventTimestamp == inputTimestamp
      && !engine.preparedWindowReadRevisions.invalidatedProcessIDs(
        since: revisions, candidates: [processID]
      ).contains(processID)
  }
}

extension SnapshotEngine {
  func prepareIncrementalDiscoveryReads(
    processIDs requested: Set<pid_t>, listProcessIDs: Set<pid_t>, windowListRefreshProcessIDs: Set<pid_t>,
    existingWindowIDsByProcessAndElementHash: [pid_t: [UInt: [WindowID]]]? = nil,
    frameRefreshWindowIDs: Set<WindowID>?, explicitlyDestroyedWindowIDs: Set<WindowID>,
    shouldReadProcess: (pid_t) -> Bool
  ) -> PreparedIncrementalDiscoveryReads {
    let revisions = preparedWindowReadRevisions
    let timestamp = userInputTracker.latestEventTimestamp
    var result = PreparedIncrementalDiscoveryReads(revisions: revisions, inputTimestamp: timestamp)
    let isCurrent: @Sendable (pid_t) -> Bool = { [self] pid in
      userInputTracker.latestEventTimestamp == timestamp
        && !preparedWindowReadRevisions.invalidatedProcessIDs(since: revisions, candidates: [pid]).contains(pid)
    }
    let previousElements = elements
    let previousPIDs = processIDs
    let bindings: [pid_t: [UInt: [WindowID]]]
    if let existingWindowIDsByProcessAndElementHash { bindings = existingWindowIDsByProcessAndElementHash }
    else {
      var known: [pid_t: [UInt: [WindowID]]] = [:]
      for (id, element) in previousElements.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        guard let pid = previousPIDs[id] else { continue }
        known[pid, default: [:]][CFHash(element), default: []].append(id)
      }
      bindings = known
    }
    let previousWindows = Set(lastSnapshotWindows.map(\.id))
    let applicationElements = applications
    let cachedLists = lastApplicationWindowElements
    let admitted = requested.filter { pid in
      guard applicationElements[pid] != nil else { return false }
      guard shouldReadProcess(pid) else { result.deferredProcessIDs.insert(pid); return false }
      return true
    }
    let lists = admitted.intersection(listProcessIDs).sorted().compactMap { pid -> PreparedAXProcessRead? in
      guard let application = applicationElements[pid] else { return nil }
      return PreparedAXProcessRead(processID: pid, windows: [],
        application: PreparedAXApplicationElement(processID: pid, element: application))
    }
    let listResults = collectPreparedAXProcessReads(lists, shouldStart: { pid in
      guard isCurrent(pid), shouldReadProcess(pid), let application = applicationElements[pid] else { return false }
      let safe = AssumedThreadSafe(application)
      onMain { $0.eventMonitor?.prepareForWindowDiscovery(processID: pid, application: safe.value) }
      return true
    }, read: { [self] job in
      guard isCurrent(job.processID), let application = job.application else {
        return PreparedAXProcessReadResult(processID: job.processID, windows: [], application: nil)
      }
      let start = ProcessInfo.processInfo.systemUptime
      let windows = AXMessagingTimeoutAccess.shared.withTimeout(snapshotAccessibilityTimeoutSeconds, elements: [application.element]) {
        self.readDiscoveryApplicationWindows(application.element, processID: job.processID)
      }
      return PreparedAXProcessReadResult(processID: job.processID, windows: [],
        application: PreparedAXApplicationWindows(elements: windows,
          durationMS: (ProcessInfo.processInfo.systemUptime - start) * 1000))
    })
    for read in listResults where isCurrent(read.processID) { result.applications[read.processID] = read.application }
    var jobs: [PreparedAXProcessRead] = []
    for pid in admitted.sorted() where isCurrent(pid) {
      let candidates: [AXUIElement]?
      if let list = result.applications[pid] { candidates = list.elements ?? cachedLists[pid] }
      else { candidates = cachedLists[pid] }
      let windows = (candidates ?? []).compactMap { element -> PreparedAXWindowElement? in
        guard let id = bindings[pid]?[CFHash(element)]?.first(where: { CFEqual(previousElements[$0], element) }),
          !explicitlyDestroyedWindowIDs.contains(id),
          discoveryWindowAttributeReadIsRequired(refreshesWindowList: windowListRefreshProcessIDs.contains(pid),
            frameRefreshWindowIDs: frameRefreshWindowIDs, previousWindowID: id, hasCachedWindow: previousWindows.contains(id))
        else { return nil }
        return PreparedAXWindowElement(windowID: id, processID: pid, element: element, usesBatchedAttributeReads: true)
      }
      let unique = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
      if !unique.isEmpty { jobs.append(PreparedAXProcessRead(processID: pid,
        windows: unique.values.sorted { $0.windowID.rawValue < $1.windowID.rawValue }, application: nil)) }
    }
    let reads = collectPreparedAXProcessReads(jobs, shouldStart: { isCurrent($0) && shouldReadProcess($0) }, read: { [self] job in
      let windows = job.windows.compactMap { candidate -> PreparedAXWindowRead? in
        guard isCurrent(job.processID) else { return nil }
        let attributes = AXMessagingTimeoutAccess.shared.withTimeout(snapshotAccessibilityTimeoutSeconds, elements: [candidate.element]) {
          self.windowAttributes(candidate.element, processID: job.processID)
        }
        return PreparedAXWindowRead(windowID: candidate.windowID, attributes: attributes, parent: nil, sheets: [])
      }
      return PreparedAXProcessReadResult(processID: job.processID, windows: windows, application: nil)
    })
    for read in reads where isCurrent(read.processID) {
      for window in read.windows { result.attributes[window.windowID] = window.attributes }
    }
    result.applications = result.applications.filter { isCurrent($0.key) }
    result.attributes = result.attributes.filter { previousPIDs[$0.key].map(isCurrent) ?? false }
    return result
  }

  func prepareIncrementalOwnerReads(
    windowIDs: Set<WindowID>, elements: [WindowID: AXUIElement], processIDs: [WindowID: pid_t]
  ) -> [WindowID: AXUIElement?] {
    let revisions = preparedWindowReadRevisions
    let timestamp = userInputTracker.latestEventTimestamp
    let isCurrent: @Sendable (pid_t) -> Bool = { [self] pid in
      userInputTracker.latestEventTimestamp == timestamp
        && !preparedWindowReadRevisions.invalidatedProcessIDs(since: revisions, candidates: [pid]).contains(pid)
    }
    let candidates = windowIDs.compactMap { id -> PreparedAXWindowElement? in
      guard let pid = processIDs[id], let element = elements[id] else { return nil }
      return PreparedAXWindowElement(windowID: id, processID: pid, element: element, usesBatchedAttributeReads: false)
    }
    let jobs = Dictionary(grouping: candidates, by: \.processID).sorted { $0.key < $1.key }.map {
      PreparedAXProcessRead(processID: $0.key, windows: $0.value.sorted { $0.windowID.rawValue < $1.windowID.rawValue }, application: nil)
    }
    let reads = collectPreparedAXProcessReads(jobs, shouldStart: isCurrent, read: { [self] job in
      let windows = job.windows.compactMap { candidate -> PreparedAXWindowRead? in
        guard isCurrent(job.processID) else { return nil }
        let parent = AXMessagingTimeoutAccess.shared.withTimeout(snapshotAccessibilityTimeoutSeconds, elements: [candidate.element]) {
          self.readDiscoveryParent(candidate.element)
        }
        return PreparedAXWindowRead(windowID: candidate.windowID, attributes: nil, parent: parent, sheets: [])
      }
      return PreparedAXProcessReadResult(processID: job.processID, windows: windows, application: nil)
    })
    var parents: [WindowID: AXUIElement?] = [:]
    for read in reads where isCurrent(read.processID) {
      for window in read.windows { parents[window.windowID] = .some(window.parent) }
    }
    return parents.filter { processIDs[$0.key].map(isCurrent) ?? false }
  }
}
