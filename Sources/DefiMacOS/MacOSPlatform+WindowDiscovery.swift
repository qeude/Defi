import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let focusSnapshotAccessibilityTimeoutSeconds: Float = 0.05
@MainActor
extension MacOSPlatform {

  public func prepareAXWindowAttributesIfNeeded(
    completion: @escaping @MainActor @Sendable () -> Void
  ) -> Bool {
    if preparedAXWindowAttributesAvailable { return false }
    guard !axWindowAttributePreparationPending else { return true }
    let capturedWindowIDs = Set(elements.keys)
    let capturedProcessIDs = Set(applications.keys)
    let candidates: [PreparedAXWindowElement] = elements.compactMap {
      windowID, element in
      guard let processID = processIDs[windowID],
        multipleAttributeReadsSupportedByProcess[processID] != false
      else {
        return nil
      }
      return PreparedAXWindowElement(
        windowID: windowID,
        processID: processID,
        element: element
      )
    }
    guard !candidates.isEmpty else {
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
      let attributes: [WindowID: AXWindowAttributes] = Dictionary(
        uniqueKeysWithValues: candidates.compactMap { candidate in
          guard inputTracker.latestEventTimestamp == inputTimestamp else {
            return nil
          }
          return AXMessagingTimeoutAccess.shared.withTimeout(
            0.05,
            elements: [candidate.element]
          ) {
            copyBatchedWindowAttributes(candidate.element).attributes.map {
              (candidate.windowID, $0)
            }
          }
        }
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
            completion()
            return
          }
          self.preparedAXWindowAttributes = attributes
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
          completion()
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
      let axWindowID = windowIDProvider.windowID(for: element)
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
    let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
    guard allowPendingNativeFocus || !nativeFocusEventPending else { return nil }
    guard let processID else { return nil }
    let candidates = windows.filter { $0.processID == processID }
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

struct AXWindowElementIdentity: Hashable {
  let processID: pid_t
  let element: AXUIElement
}
