import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

struct CGWindowRecord: Sendable {
  let id: CGWindowID
  let processID: pid_t
  let ownerName: String
  let layer: Int
  let title: String
  let frame: Rect
  let isOnscreen: Bool
  let memoryUsage: Int?
  let alpha: Double

  init(
    id: CGWindowID,
    processID: pid_t,
    ownerName: String = "",
    layer: Int,
    title: String,
    frame: Rect,
    isOnscreen: Bool = true,
    memoryUsage: Int? = nil,
    alpha: Double = 1
  ) {
    self.id = id
    self.processID = processID
    self.ownerName = ownerName
    self.layer = layer
    self.title = title
    self.frame = frame
    self.isOnscreen = isOnscreen
    self.memoryUsage = memoryUsage
    self.alpha = alpha
  }
}

struct CGWindowInventory: Sendable {
  let records: [CGWindowRecord]
  let generation: UInt64
  let capturedAt: TimeInterval

  func recordsForBorderStacking(generation: UInt64, now: TimeInterval) -> [CGWindowRecord]? {
    // Only share a recent snapshot pass; native order events still force a read.
    guard self.generation == generation, now >= capturedAt,
      now - capturedAt <= 0.05
    else { return nil }
    return records
  }
}

func copyCGWindows(
  options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
) -> [CGWindowRecord] {
  copyCGWindowsIfAvailable(options: options) ?? []
}

func copyCGWindowsIfAvailable(
  options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
) -> [CGWindowRecord]? {
  guard
    let info = CGWindowListCopyWindowInfo(
      options,
      kCGNullWindowID
    ) as? [NSDictionary]
  else {
    return nil
  }
  // NSDictionary rows: bridging every entry to [String: Any] cost more than the copy.
  return info.compactMap(cgWindowRecord)
}

func cgWindowRecord(_ item: NSDictionary) -> CGWindowRecord? {
  guard let layer = item[kCGWindowLayer as String] as? NSNumber,
      let number = item[kCGWindowNumber as String] as? NSNumber,
      let ownerPID = item[kCGWindowOwnerPID as String] as? NSNumber,
      let bounds = item[kCGWindowBounds as String] as? NSDictionary,
      let cgRect = CGRect(dictionaryRepresentation: bounds)
  else {
    return nil
  }
  return CGWindowRecord(
    id: number.uint32Value,
    processID: ownerPID.int32Value,
    ownerName: item[kCGWindowOwnerName as String] as? String ?? "",
    layer: layer.intValue,
    title: item[kCGWindowName as String] as? String ?? "",
    frame: Rect(
      x: cgRect.minX,
      y: cgRect.minY,
      width: cgRect.width,
      height: cgRect.height
    ),
    isOnscreen: (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
      ?? false,
    memoryUsage: (item[kCGWindowMemoryUsage as String] as? NSNumber)?.intValue,
    alpha: (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
  )
}

func eligibleCGWindowRecords(
  role: String?,
  for subrole: String?,
  allowsConfiguredNonzeroLayer: Bool = false,
  in records: [CGWindowRecord]
) -> [CGWindowRecord] {
  records.filter {
    windowLayerIsEligible($0.layer, role: role, subrole: subrole, allowsConfiguredNonzeroLayer: allowsConfiguredNonzeroLayer)
  }
}

func cgWindowRecordForDiscovery(
  axWindowID: CGWindowID? = nil,
  preferredWindowID: WindowID?,
  processID: pid_t,
  title: String,
  frame: Rect,
  records: [CGWindowRecord],
  excluding usedWindowIDs: Set<CGWindowID>
) -> CGWindowRecord? {
  let exactWindowID = axWindowID.map { WindowID(rawValue: UInt64($0)) }
    ?? preferredWindowID
  if let exactWindowID {
    guard let windowID = CGWindowID(exactly: exactWindowID.rawValue),
      !usedWindowIDs.contains(windowID)
    else {
      return nil
    }
    return records.first {
      $0.id == windowID && $0.processID == processID
    }
  }
  return bestCGWindow(
    processID: processID,
    title: title,
    frame: frame,
    records: records,
    excluding: usedWindowIDs
  )
}

func nativeFullscreenWindowIDs(
  windows: [Window],
  cgWindows: [CGWindowRecord],
  monitors: [MonitorSnapshot],
  lastFocusedWindowByProcess: [pid_t: WindowID]
) -> Set<WindowID> {
  let physicalFrames = monitors.map(\.physicalFrame)
  guard !physicalFrames.isEmpty else { return [] }
  let windowsByID = Dictionary(windows.map { ($0.id, $0) }) { current, _ in current }
  let windowsByProcess = Dictionary(
    grouping: windowsByID.values.compactMap { window in
      window.processID.map { ($0, window) }
    },
    by: \.0
  ).mapValues { $0.map(\.1) }
  let layerZeroSurfaces = cgWindows.filter { $0.layer == 0 }
  let exactFullscreenSurfaceIDs = Set(
    layerZeroSurfaces.compactMap { surface in
      physicalFrames.contains(where: { fullscreenFrameMatches(surface.frame, $0) })
        ? WindowID(rawValue: UInt64(surface.id))
        : nil
    })
  var result = Set<WindowID>(
    windows.compactMap { window in
      guard
        physicalFrames.contains(where: {
          fullscreenFrameMatches(window.frame, $0)
        })
      else { return nil }
      if exactFullscreenSurfaceIDs.contains(window.id) {
        return window.id
      }
      return window.processID.flatMap { lastFocusedWindowByProcess[$0] }
        ?? window.id
    })

  let fullscreenProcessIDs = nativeFullscreenProcessIDs(
    cgWindows: cgWindows,
    monitors: monitors
  )
  for processID in fullscreenProcessIDs {
    let candidates = windowsByProcess[processID] ?? []
    let exactCandidates = candidates.filter {
      exactFullscreenSurfaceIDs.contains($0.id)
    }
    if !exactCandidates.isEmpty {
      result.formUnion(exactCandidates.map(\.id))
    } else if let lastFocusedID = lastFocusedWindowByProcess[processID] {
      result.insert(lastFocusedID)
    } else if candidates.count == 1 {
      result.insert(candidates[0].id)
    }
  }
  return result
}

func nativeFullscreenProcessIDs(
  cgWindows: [CGWindowRecord],
  monitors: [MonitorSnapshot]
) -> Set<pid_t> {
  let physicalFrames = monitors.map(\.physicalFrame)
  guard !physicalFrames.isEmpty else { return [] }
  return Set(
    Dictionary(grouping: cgWindows.filter { $0.layer == 0 }, by: \.processID)
      .compactMap { processID, surfaces in
        physicalFrames.contains { physicalFrame in
          fullscreenSurfaceGroupMatches(
            surfaces,
            physicalFrame
          )
        } ? processID : nil
      }
  )
}

func activeNativeFullscreenWindowIDs(
  processIDsByWindowID: [WindowID: pid_t],
  cgWindows: [CGWindowRecord],
  monitors: [MonitorSnapshot]
) -> Set<WindowID> {
  let onscreenSurfaces = cgWindows.filter(\.isOnscreen)
  let activeProcessIDs = nativeFullscreenProcessIDs(
    cgWindows: onscreenSurfaces,
    monitors: monitors
  )
  return Set(processIDsByWindowID.compactMap { windowID, processID in
    if activeProcessIDs.contains(processID) { return windowID }
    guard let surfaceID = CGWindowID(exactly: windowID.rawValue),
      let surface = onscreenSurfaces.first(where: {
        $0.id == surfaceID && $0.processID == processID && $0.layer == 0
      }),
      monitors.contains(where: {
        activeFullscreenSurfaceMatches(surface.frame, $0.physicalFrame)
    })
    else { return nil }
    return windowID
  })
}

func retainedNativeFullscreenProcessIDsByWindowID(
  detectedWindowIDs: Set<WindowID>,
  previous: [WindowID: pid_t],
  observedProcessIDs: [WindowID: pid_t],
  fullscreenProcessIDs: Set<pid_t>,
  explicitlyRemovedWindowIDs: Set<WindowID>
) -> [WindowID: pid_t] {
  let detectedProcessIDs = Set(detectedWindowIDs.compactMap { observedProcessIDs[$0] })
  var retained = previous.filter {
    !detectedProcessIDs.contains($0.value)
  }
  for windowID in detectedWindowIDs {
    if let processID = observedProcessIDs[windowID] {
      retained[windowID] = processID
    }
  }
  return retained.filter {
    fullscreenProcessIDs.contains($0.value)
      && !explicitlyRemovedWindowIDs.contains($0.key)
  }
}

func fullscreenMaskedWindowIDs(
  previousWindowIDs: Set<WindowID>,
  nativeFullscreenWindowIDs: Set<WindowID>,
  explicitlyRemovedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  guard !nativeFullscreenWindowIDs.isEmpty else { return [] }
  return previousWindowIDs.subtracting(explicitlyRemovedWindowIDs)
}

func stabilizedNativeFullscreenWindowIDs(
  detectedWindowIDs: Set<WindowID>,
  previousExitDeadlines: [WindowID: TimeInterval],
  explicitlyRemovedWindowIDs: Set<WindowID>,
  restoredWindowIDs: Set<WindowID> = [],
  now: TimeInterval,
  exitGrace: TimeInterval = 0.75
) -> (windowIDs: Set<WindowID>, exitDeadlines: [WindowID: TimeInterval]) {
  // A window back on the desktop at its own size has finished exiting: the grace
  // only held its layout, focus ring and placeholder about a second longer.
  var deadlines = previousExitDeadlines.filter {
    $0.value > now && !explicitlyRemovedWindowIDs.contains($0.key)
      && !restoredWindowIDs.contains($0.key)
  }
  for windowID in detectedWindowIDs {
    deadlines[windowID] = now + exitGrace
  }
  return (Set(deadlines.keys), deadlines)
}

private func fullscreenSurfaceGroupMatches(
  _ surfaces: [CGWindowRecord],
  _ physicalFrame: Rect,
  tolerance: Double = 2
) -> Bool {
  let fullWidthSurfaces = surfaces.filter { surface in
    abs(surface.frame.x - physicalFrame.x) <= tolerance
      && abs(surface.frame.width - physicalFrame.width) <= tolerance
      && surface.frame.y >= physicalFrame.y - tolerance
      && surface.frame.y + surface.frame.height
        <= physicalFrame.y + physicalFrame.height + tolerance
  }
  guard
    fullWidthSurfaces.contains(where: {
      $0.frame.height >= physicalFrame.height * 0.8
    })
  else { return false }

  var coveredThrough = physicalFrame.y
  for surface in fullWidthSurfaces.sorted(by: { $0.frame.y < $1.frame.y }) {
    guard surface.frame.y <= coveredThrough + tolerance else { break }
    coveredThrough = max(
      coveredThrough,
      surface.frame.y + surface.frame.height
    )
  }
  guard coveredThrough >= physicalFrame.y + physicalFrame.height - tolerance
  else { return false }
  if fullWidthSurfaces.contains(where: {
    $0.isOnscreen
      && ($0.title.isEmpty
        || fullscreenFrameMatches($0.frame, physicalFrame))
  }) {
    return true
  }
  return !surfaces.contains(where: \.isOnscreen)
}

func fullscreenFrameMatches(
  _ candidate: Rect,
  _ physicalFrame: Rect,
  tolerance: Double = 2
) -> Bool {
  abs(candidate.x - physicalFrame.x) <= tolerance
    && abs(candidate.y - physicalFrame.y) <= tolerance
    && abs(candidate.width - physicalFrame.width) <= tolerance
    && abs(candidate.height - physicalFrame.height) <= tolerance
}

/// Windows whose own surface is on screen without covering a display.
func restoredNativeFullscreenWindowIDs(
  cgWindows: [CGWindowRecord],
  monitors: [MonitorSnapshot]
) -> Set<WindowID> {
  Set(cgWindows.compactMap { record in
    guard record.isOnscreen, record.layer == 0,
      !monitors.contains(where: { activeFullscreenSurfaceMatches(record.frame, $0.physicalFrame) })
    else { return nil }
    return WindowID(rawValue: UInt64(record.id))
  })
}

private func activeFullscreenSurfaceMatches(
  _ candidate: Rect,
  _ physicalFrame: Rect,
  tolerance: Double = 2
) -> Bool {
  abs(candidate.x - physicalFrame.x) <= tolerance
    && abs(candidate.width - physicalFrame.width) <= tolerance
    && abs(candidate.y + candidate.height - physicalFrame.y - physicalFrame.height)
      <= tolerance
    && candidate.height >= physicalFrame.height * 0.8
}

func targetWindowFocusIsConfirmed(
  _ focusedAttribute: Bool?,
  applicationFocusedWindowMatches: () -> Bool
) -> Bool {
  if focusedAttribute == true { return true }
  return applicationFocusedWindowMatches()
}

func requiredTopologyWindows(
  applicationWindows: [pid_t: [AXUIElement]],
  managedWindows: [pid_t: [AXUIElement]],
  previouslyManagedWindows: [pid_t: [AXUIElement]],
  minimizedWindows: [pid_t: [AXUIElement]] = [:]
) -> [pid_t: [AXUIElement]] {
  Dictionary(
    uniqueKeysWithValues: applicationWindows.map { processID, windows in
      let candidates =
        (managedWindows[processID] ?? [])
        + (previouslyManagedWindows[processID] ?? [])
        + (minimizedWindows[processID] ?? [])
      let required = windows.filter { window in
        candidates.contains(where: { CFEqual($0, window) })
      }
      return (processID, required)
    }
  )
}

func topologyWindowsRequiringCoverage(
  requested: [AXUIElement],
  previouslyRequired: [AXUIElement],
  observed: [AXUIElement],
  applicationWindows: [AXUIElement]
) -> [AXUIElement] {
  var required = requested.filter { candidate in
    applicationWindows.contains(where: { CFEqual($0, candidate) })
  }
  for candidate in previouslyRequired
  where applicationWindows.contains(where: { CFEqual($0, candidate) })
    && !observed.contains(where: { CFEqual($0, candidate) })
    && !required.contains(where: { CFEqual($0, candidate) })
  {
    required.append(candidate)
  }
  return required
}

func frameWindowsRequiringCoverage(
  requested: [AXUIElement],
  transientGeometry: [AXUIElement],
  applicationWindows: [AXUIElement]
) -> [AXUIElement] {
  var required = requested.filter { candidate in
    applicationWindows.contains(where: { CFEqual($0, candidate) })
  }
  for candidate in transientGeometry
  where applicationWindows.contains(where: { CFEqual($0, candidate) })
    && !required.contains(where: { CFEqual($0, candidate) })
  {
    required.append(candidate)
  }
  return required
}

func windowStackEntries(_ info: [[CFString: Any]]) -> [WindowStackEntry] {
  info.compactMap { item -> WindowStackEntry? in
    guard
      let layer = item[kCGWindowLayer] as? NSNumber,
      let processID = item[kCGWindowOwnerPID] as? NSNumber,
      let number = item[kCGWindowNumber] as? NSNumber,
      let bounds = item[kCGWindowBounds] as? [String: Any],
      let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else {
      return nil
    }
    return WindowStackEntry(
      windowID: WindowID(rawValue: number.uint64Value),
      processID: processID.int32Value,
      layer: layer.intValue,
      frame: Rect(x: cgRect.minX, y: cgRect.minY, width: cgRect.width, height: cgRect.height)
    )
  }
}

func copyOnScreenWindowStackEntries() -> [WindowStackEntry] {
  let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
  return windowStackEntries(info as? [[CFString: Any]] ?? [])
}

func copyWindowBorderStacking(
  targetWindowID: WindowID?,
  targetProcessID: pid_t?,
  targetFrame: Rect?,
  monitorFrames: [Rect],
  knownWindowIDs: Set<WindowID>,
  onScreen: [WindowStackEntry]? = nil
) -> WindowBorderStacking {
  let canQueryAboveTarget = targetWindowID != nil
    && targetProcessID != nil
    && targetFrame != nil
  // A list already read front to back holds the windows above the target: no second read.
  let above = canQueryAboveTarget
    ? onScreen.flatMap { list in list.firstIndex { $0.windowID == targetWindowID }.map { Array(list[..<$0]) } }
    : nil
  guard
    let info = above != nil ? [] : CGWindowListCopyWindowInfo(
      canQueryAboveTarget
        ? [.optionOnScreenAboveWindow, .excludeDesktopElements]
        : [.optionOnScreenOnly, .excludeDesktopElements],
      canQueryAboveTarget
        ? CGWindowID(targetWindowID!.rawValue)
        : kCGNullWindowID
    ) as? [[CFString: Any]]
  else {
    return .inactive(for: targetWindowID)
  }
  let ownProcessID = ProcessInfo.processInfo.processIdentifier
  var entries = above ?? windowStackEntries(info)
  if let targetWindowID, let targetProcessID, let targetFrame {
    entries.append(WindowStackEntry(
      windowID: targetWindowID,
      processID: targetProcessID,
      layer: NSWindow.Level.normal.rawValue,
      frame: targetFrame
    ))
  }
  return windowBorderStacking(
    targetWindowID: targetWindowID,
    ownProcessID: ownProcessID,
    floatingLevel: NSWindow.Level.floating.rawValue,
    entries: entries,
    monitorFrames: monitorFrames,
    knownWindowIDs: knownWindowIDs
  )
}

func bestCGWindow(
  processID: pid_t,
  title: String,
  frame: Rect,
  records: [CGWindowRecord],
  excluding usedWindowIDs: Set<CGWindowID> = [],
  maximumDistance: Double = 80
) -> CGWindowRecord? {
  let candidates = records.filter {
    $0.processID == processID && !usedWindowIDs.contains($0.id)
  }
  guard
    let closest = candidates.min(by: { lhs, rhs in
      let lhsDistance = frameDistance(lhs.frame, frame)
      let rhsDistance = frameDistance(rhs.frame, frame)
      if abs(lhsDistance - rhsDistance) > 0.5 {
        return lhsDistance < rhsDistance
      }
      // An ordered-out native tab shares its visible sibling's frame and often its title.
      if lhs.isOnscreen != rhs.isOnscreen { return lhs.isOnscreen }
      return windowTitleMatchRank(lhs.title, title) < windowTitleMatchRank(rhs.title, title)
    }),
    frameDistance(closest.frame, frame) <= maximumDistance
  else {
    return nil
  }
  return closest
}

func cgWindowDiscoveryNeedsExactID(
  preferredWindowID: WindowID? = nil,
  processID: pid_t,
  title: String,
  frame: Rect,
  records: [CGWindowRecord],
  excluding usedWindowIDs: Set<CGWindowID>,
  maximumDistance: Double = 80
) -> Bool {
  guard let closest = bestCGWindow(
    processID: processID,
    title: title,
    frame: frame,
    records: records,
    excluding: usedWindowIDs,
    maximumDistance: maximumDistance
  ) else { return false }
  if let preferredWindowID, preferredWindowID.rawValue != UInt64(closest.id) {
    return true
  }
  // A hidden tab shares its group's title and frame: a new tab, not yet listed on
  // screen, would otherwise take its identity.
  if preferredWindowID == nil, !closest.isOnscreen { return true }
  let closestDistance = frameDistance(closest.frame, frame)
  let closestTitleRank = windowTitleMatchRank(closest.title, title)
  return records.contains { candidate in
    candidate.id != closest.id
      && candidate.processID == processID
      && !usedWindowIDs.contains(candidate.id)
      && abs(frameDistance(candidate.frame, frame) - closestDistance) <= 0.5
      && candidate.isOnscreen == closest.isOnscreen
      && windowTitleMatchRank(candidate.title, title) == closestTitleRank
  }
}

func closestFocusRecoveryWindowIndex(
  target: (frame: Rect, title: String),
  candidates: [(frame: Rect, title: String)],
  maximumDistance: Double = 80
) -> Int? {
  guard let index = candidates.indices.min(by: {
    let lhsDistance = frameDistance(candidates[$0].frame, target.frame)
    let rhsDistance = frameDistance(candidates[$1].frame, target.frame)
    if abs(lhsDistance - rhsDistance) > 0.5 {
      return lhsDistance < rhsDistance
    }
    return windowTitleMatchRank(candidates[$0].title, target.title)
      < windowTitleMatchRank(candidates[$1].title, target.title)
  }),
    frameDistance(candidates[index].frame, target.frame) <= maximumDistance
  else {
    return nil
  }
  return index
}

private func windowTitleMatchRank(_ cgTitle: String, _ accessibilityTitle: String) -> Int {
  guard !cgTitle.isEmpty, !accessibilityTitle.isEmpty else { return 1 }
  return cgTitle == accessibilityTitle ? 0 : 2
}

enum WindowDisposition: String, Codable, Equatable, Sendable {
  case tiled
  case floating
  case ignored
  case unavailable
}

func floatingOrigin(
  for disposition: WindowDisposition,
  configuredFloating: Bool
) -> FloatingOrigin? {
  guard disposition == .floating else { return nil }
  return configuredFloating ? .configured : .automatic
}

/// The frame of a titled document window outside a native tab group, read with a short
/// timeout; `.some(nil)` for other windows, nil when the app does not answer in time.
func ownWindowFrame(_ element: AXUIElement) -> Rect?? {
  AXMessagingTimeoutAccess.shared.withTimeout(accessibilityReadTimeoutSeconds, elements: [element]) {
    var values: CFArray?
    AXUIElementCopyMultipleAttributeValues(element,
      [kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray,
      [], &values)
    let read = values as? [AnyObject] ?? []
    guard read.count == 4, let subrole = read[0] as? String else { return nil }
    guard subrole == kAXStandardWindowSubrole else { return .some(nil) }
    let tabbed = (read[3] as? [AXUIElement] ?? []).contains { child in
      var role: CFTypeRef?, tabs: CFTypeRef?
      AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
      guard role as? String == kAXTabGroupRole else { return false }
      AXUIElementCopyAttributeValue(child, kAXTabsAttribute as CFString, &tabs)
      return ((tabs as? [AXUIElement])?.count ?? 0) > 1
    }
    return .some(tabbed ? nil : frameFromAXValues(positionValue: read[1], sizeValue: read[2]))
  }
}

func fallbackDispositionForTransientWindowMetadata(
  role: String?,
  subrole: String?,
  closeButtonError: AXError,
  sizeSettableError: AXError,
  previousDisposition: WindowDisposition?
) -> WindowDisposition? {
  guard role == kAXWindowRole,
    subrole == kAXStandardWindowSubrole
  else {
    return nil
  }
  guard axMetadataErrorIsTransient(closeButtonError)
    || axMetadataErrorIsTransient(sizeSettableError)
  else {
    return nil
  }
  return previousDisposition ?? .unavailable
}

func windowCanResize(
  sizeSettableError: AXError,
  isSettable: Bool
) -> Bool {
  switch sizeSettableError {
  case .success:
    isSettable
  case .attributeUnsupported:
    false
  default:
    true
  }
}

func resolvedWindowModalState(
  error: AXError,
  observedValue: Bool?,
  cachedValue: Bool?
) -> Bool? {
  switch error {
  case .success:
    observedValue ?? false
  case .attributeUnsupported, .noValue:
    false
  default:
    cachedValue
  }
}

private func axMetadataErrorIsTransient(_ error: AXError) -> Bool {
  switch error {
  case .success, .attributeUnsupported, .noValue:
    false
  default:
    true
  }
}

func shouldTreatWindowAsClosable(
  error: AXError,
  hasValue: Bool,
  wasPreviouslyManaged: Bool
) -> Bool {
  switch error {
  case .success:
    hasValue
  case .attributeUnsupported, .noValue:
    false
  default:
    wasPreviouslyManaged
  }
}

func shouldSelectSpecificWindow(
  activatesApplication: Bool,
  hasUnmanagedAuxiliaryWindows: Bool,
  hasMultipleManagedWindows: Bool,
  focusWritePending: Bool,
  targetWasLastFocused: Bool
) -> Bool {
  (activatesApplication && hasUnmanagedAuxiliaryWindows)
    || (hasMultipleManagedWindows && (focusWritePending || !targetWasLastFocused))
}

func monitor(
  containing frame: Rect,
  monitors: [MonitorSnapshot]
) -> MonitorSnapshot? {
  let centerX = frame.x + frame.width / 2
  let centerY = frame.y + frame.height / 2
  return monitors.first {
    centerX >= $0.frame.x
      && centerX < $0.frame.x + $0.frame.width
      && centerY >= $0.frame.y
      && centerY < $0.frame.y + $0.frame.height
  }
}

func frameDistance(_ lhs: Rect, _ rhs: Rect) -> Double {
  abs(lhs.x - rhs.x)
    + abs(lhs.y - rhs.y)
    + abs(lhs.width - rhs.width)
    + abs(lhs.height - rhs.height)
}

func targetIntersectsAnyMonitor(
  _ frame: Rect,
  monitors: [MonitorSnapshot]
) -> Bool {
  monitors.contains { targetIntersects(frame, monitor: $0.frame) }
}

func targetIntersects(_ frame: Rect, monitor: Rect) -> Bool {
  frame.x + frame.width > monitor.x
    && frame.x < monitor.x + monitor.width
    && frame.y + frame.height > monitor.y
    && frame.y < monitor.y + monitor.height
}

func approximatelyEqual(_ lhs: Rect, _ rhs: Rect) -> Bool {
  frameDistance(lhs, rhs) < 2
}
