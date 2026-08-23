import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

let focusSnapshotAccessibilityTimeoutSeconds: Float = 0.05
@MainActor
extension MacOSPlatform {

  public func prepareAXWindowAttributesIfNeeded(
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) -> Bool {
    if preparedAXWindowAttributesAvailable { return false }
    guard !axWindowAttributePreparationPending else { return true }
    let capturedWindowIDs = Set(elements.keys)
    let capturedProcessIDs = Set(applications.keys)
    let candidates: [PreparedAXWindowElement] = elements.compactMap {
      windowID, element in
      guard let processID = processIDs[windowID] else { return nil }
      return PreparedAXWindowElement(
        windowID: windowID,
        processID: processID,
        element: element,
        usesBatchedAttributeReads:
          multipleAttributeReadsSupportedByProcess[processID] != false
      )
    }
    guard !candidates.isEmpty else {
      preparedTransientOwnerWindowIDs.removeAll(keepingCapacity: true)
      preparedAXWindowAttributesAvailable = true
      preparedAXWindowAttributesGeneration = windowSnapshotObservationGeneration
      preparedAXWindowAttributesInputTimestamp = userInputTracker.latestEventTimestamp
      preparedAXWindowAttributesWindowIDs = capturedWindowIDs
      preparedAXWindowAttributesProcessIDs = capturedProcessIDs
      return false
    }
    let generation = windowSnapshotObservationGeneration
    let inputTimestamp = userInputTracker.latestEventTimestamp
    let inputTracker = userInputTracker
    let windowIDs = capturedWindowIDs
    let applicationProcessIDs = capturedProcessIDs
    let applicationCandidates = applications.map {
      PreparedAXApplicationElement(processID: $0.key, element: $0.value)
    }
    for candidate in applicationCandidates {
      eventMonitor?.prepareForWindowDiscovery(
        processID: candidate.processID,
        application: candidate.element
      )
    }
    axWindowAttributePreparationPending = true
    DispatchQueue.global(qos: .utility).async {
      let startedAt = ProcessInfo.processInfo.systemUptime
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
      let durationMS =
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
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
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.axWindowAttributePreparationPending = false
          guard preparedAXWindowAttributesAreCurrent(
            capturedGeneration: generation,
            currentGeneration: self.windowSnapshotObservationGeneration,
            capturedInputTimestamp: inputTimestamp,
            currentInputTimestamp: self.userInputTracker.latestEventTimestamp,
            capturedWindowIDs: windowIDs,
            currentWindowIDs: Set(self.elements.keys),
            capturedProcessIDs: applicationProcessIDs,
            currentProcessIDs: Set(self.applications.keys)
          ) else {
            completion(false)
            return
          }
          self.preparedAXWindowAttributes = attributes
          self.preparedTransientOwnerWindowIDs = transientOwnerWindowIDs
          self.preparedAXApplicationWindows = applicationWindows
          self.preparedAXWindowAttributesAvailable = true
          self.preparedAXWindowAttributesGeneration = generation
          self.preparedAXWindowAttributesInputTimestamp = inputTimestamp
          self.preparedAXWindowAttributesWindowIDs = windowIDs
          self.preparedAXWindowAttributesProcessIDs = applicationProcessIDs
          let formattedDuration = String(format: "%.2f", durationMS)
          self.frameCoordinator.recordTrace(
            "snapshot-prefetch windows=\(attributes.count) ms=\(formattedDuration)"
          )
          completion(true)
        }
      }
    }
    return true
  }

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
