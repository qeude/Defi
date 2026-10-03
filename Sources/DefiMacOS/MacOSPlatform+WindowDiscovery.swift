import DefiRuntime
import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

let focusSnapshotAccessibilityTimeoutSeconds: Float = 0.05
extension SnapshotEngine {
  func prepareWindowAttributes(
    processIDs refreshingProcessIDs: Set<pid_t>,
    shouldReadProcess: (pid_t) -> Bool = { _ in true }
  ) -> (
    attributes: [WindowID: AXWindowAttributes],
    owners: [WindowID: WindowID],
    applications: [pid_t: PreparedAXApplicationWindows]
  ) {
    let revisions = preparedWindowReadRevisions
    let inputTracker = userInputTracker
    let inputTimestamp = inputTracker.latestEventTimestamp
    let readIsCurrent: @Sendable (pid_t) -> Bool = { [self] processID in
      inputTracker.latestEventTimestamp == inputTimestamp
        && !preparedWindowReadRevisions.invalidatedProcessIDs(
          since: revisions, candidates: [processID]
        ).contains(processID)
    }
    let windowProcessIDs = processIDs
    let batchSupport = multipleAttributeReadsSupportedByProcess
    let candidates = elements.compactMap { windowID, element -> PreparedAXWindowElement? in
      guard let processID = windowProcessIDs[windowID],
        refreshingProcessIDs.contains(processID)
      else { return nil }
      return PreparedAXWindowElement(
        windowID: windowID, processID: processID, element: element,
        usesBatchedAttributeReads: batchSupport[processID] != false
      )
    }
    let applicationCandidates = applications.compactMap { processID, element in
      refreshingProcessIDs.contains(processID)
        ? PreparedAXApplicationElement(processID: processID, element: element) : nil
    }
    let windowsByProcess = Dictionary(grouping: candidates, by: \.processID)
    let applicationsByProcess = Dictionary(uniqueKeysWithValues: applicationCandidates.map {
      ($0.processID, $0)
    })
    let jobs = refreshingProcessIDs.sorted().compactMap { processID -> PreparedAXProcessRead? in
      let windows = (windowsByProcess[processID] ?? []).sorted { $0.windowID.rawValue < $1.windowID.rawValue }
      let application = applicationsByProcess[processID]
      guard !windows.isEmpty || application != nil else { return nil }
      return PreparedAXProcessRead(processID: processID, windows: windows, application: application)
    }
    let collected = collectPreparedAXProcessReads(
      jobs,
      shouldStart: { processID in
        guard readIsCurrent(processID), shouldReadProcess(processID) else { return false }
        if let candidate = applicationsByProcess[processID] {
          onMain { platform in
            platform.eventMonitor?.prepareForWindowDiscovery(
              processID: processID, application: candidate.element
            )
          }
        }
        return true
      },
      read: { job in
        let reads = job.windows.compactMap { candidate -> PreparedAXWindowRead? in
          guard readIsCurrent(candidate.processID) else {
            return nil
          }
          return AXMessagingTimeoutAccess.shared.withTimeout(
            0.05,
            elements: [candidate.element]
          ) {
            var attributes: AXWindowAttributes?
            var parent: AXUIElement?
            var sheets: [AXUIElement]?
            if candidate.usesBatchedAttributeReads {
              let read = copyBatchedWindowAttributes(
                candidate.element,
                includingTransientRelationships: true
              )
              attributes = read.attributes
              parent = read.parent
              sheets = read.sheets
            }
            if parent == nil || sheets == nil {
              let fallback = copyTransientOwnerRelationships(candidate.element)
              parent = parent ?? fallback.parent
              sheets = sheets ?? fallback.sheets
            }
            return PreparedAXWindowRead(
              windowID: candidate.windowID,
              attributes: attributes,
              parent: parent,
              sheets: sheets ?? []
            )
          }
        }
        var applicationWindows: PreparedAXApplicationWindows?
        if let candidate = job.application, readIsCurrent(job.processID) {
          let readStartedAt = ProcessInfo.processInfo.systemUptime
          let windows = AXMessagingTimeoutAccess.shared.withTimeout(0.05, elements: [candidate.element]) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
              candidate.element, kAXWindowsAttribute as CFString, &value
            ) == .success else { return nil as [AXUIElement]? }
            return value as? [AXUIElement]
          }
          applicationWindows = windows.map {
            PreparedAXApplicationWindows(elements: $0,
              durationMS: (ProcessInfo.processInfo.systemUptime - readStartedAt) * 1_000)
          }
        }
        return PreparedAXProcessReadResult(
          processID: job.processID, windows: reads, application: applicationWindows
        )
      }
    )
    let reads = collected.flatMap(\.windows)
    let applicationWindows = Dictionary(uniqueKeysWithValues: collected.compactMap { result in
      result.application.map { (result.processID, $0) }
    })
    let attributes: [WindowID: AXWindowAttributes] = Dictionary(
      uniqueKeysWithValues: reads.compactMap { read in
        read.attributes.map { (read.windowID, $0) }
      }
    )
    let transientOwnerWindowIDs = transientOwnerWindowIDsFromPreparedRelationships(
      elements: Dictionary(uniqueKeysWithValues: candidates.map {
        ($0.windowID, $0.element)
      }),
      parents: Dictionary(uniqueKeysWithValues: reads.compactMap { read in
        read.parent.map { (read.windowID, $0) }
      }),
      sheets: Dictionary(uniqueKeysWithValues: reads.map {
        ($0.windowID, $0.sheets)
      })
    )
    guard inputTimestamp == inputTracker.latestEventTimestamp
    else { return ([:], [:], [:]) }
    let invalidated = preparedWindowReadRevisions.invalidatedProcessIDs(
      since: revisions, candidates: refreshingProcessIDs
    )
    func isValid(_ windowID: WindowID) -> Bool {
      windowProcessIDs[windowID].map { !invalidated.contains($0) } ?? false
    }
    return (
      attributes.filter { isValid($0.key) },
      transientOwnerWindowIDs.filter { isValid($0.key) && isValid($0.value) },
      applicationWindows.filter { !invalidated.contains($0.key) }
    )
  }
}

@MainActor
extension MacOSPlatform {

  public func discoverMonitors() -> [MonitorSnapshot] {
    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
    return NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else {
        return nil
      }
      let visible = screen.visibleFrame
      let physical = screen.frame
      return MonitorSnapshot(
        id: MonitorID(rawValue: number.uint64Value),
        frame: Rect(
          x: visible.minX,
          y: mainTop - visible.maxY,
          width: visible.width,
          height: visible.height
        ),
        stableID: stableDisplayIdentifier(CGDirectDisplayID(number.uint32Value)),
        physicalFrame: Rect(
          x: physical.minX,
          y: mainTop - physical.maxY,
          width: physical.width,
          height: physical.height
        ),
        refreshRateHz: Double(screen.maximumFramesPerSecond)
      )
    }
  }
}

struct AXWindowElementIdentity: Hashable {
  let processID: pid_t
  let element: AXUIElement
}
