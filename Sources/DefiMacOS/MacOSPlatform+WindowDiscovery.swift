import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

let focusSnapshotAccessibilityTimeoutSeconds: Float = 0.05
extension SnapshotEngine {
  func prepareWindowAttributes(processIDs refreshingProcessIDs: Set<pid_t>) -> (
    attributes: [WindowID: AXWindowAttributes],
    owners: [WindowID: WindowID],
    applications: [pid_t: PreparedAXApplicationWindows]
  ) {
    let generation = windowSnapshotObservationGeneration
    let inputTracker = userInputTracker
    let inputTimestamp = inputTracker.latestEventTimestamp
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
    for candidate in applicationCandidates {
      onMain { platform in
        platform.eventMonitor?.prepareForWindowDiscovery(
          processID: candidate.processID, application: candidate.element
        )
      }
    }
    let reads = candidates.compactMap { candidate -> PreparedAXWindowRead? in
      guard inputTracker.latestEventTimestamp == inputTimestamp else {
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
    let applicationWindows: [pid_t: PreparedAXApplicationWindows] =
      Dictionary(
        uniqueKeysWithValues: applicationCandidates.compactMap { candidate in
          guard inputTracker.latestEventTimestamp == inputTimestamp else {
            return nil
          }
          let readStartedAt = ProcessInfo.processInfo.systemUptime
          let windows = AXMessagingTimeoutAccess.shared.withTimeout(
            0.05,
            elements: [candidate.element]
          ) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
              candidate.element,
              kAXWindowsAttribute as CFString,
              &value
            ) == .success else {
              return nil as [AXUIElement]?
            }
            return value as? [AXUIElement]
          }
          let readDurationMS =
            (ProcessInfo.processInfo.systemUptime - readStartedAt) * 1_000
          return windows.map {
            (
              candidate.processID,
              PreparedAXApplicationWindows(
                elements: $0,
                durationMS: readDurationMS
              )
            )
          }
        }
      )
    guard generation == windowSnapshotObservationGeneration,
      inputTimestamp == inputTracker.latestEventTimestamp
    else { return ([:], [:], [:]) }
    return (attributes, transientOwnerWindowIDs, applicationWindows)
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
