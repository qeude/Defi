import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

struct CGWindowRecord {
  let id: CGWindowID
  let processID: pid_t
  let ownerName: String
  let layer: Int
  let title: String
  let frame: Rect
  let memoryUsage: Int?

  init(
    id: CGWindowID,
    processID: pid_t,
    ownerName: String = "",
    layer: Int,
    title: String,
    frame: Rect,
    memoryUsage: Int? = nil
  ) {
    self.id = id
    self.processID = processID
    self.ownerName = ownerName
    self.layer = layer
    self.title = title
    self.frame = frame
    self.memoryUsage = memoryUsage
  }
}

func resolvedCGWindowID(
  matchedRecord: CGWindowRecord?,
  preferredWindowID: WindowID?
) -> CGWindowID? {
  if let matchedRecord {
    return matchedRecord.id
  }
  guard let preferredWindowID else { return nil }
  return CGWindowID(exactly: preferredWindowID.rawValue)
}

func copyCGWindows(
  options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
) -> [CGWindowRecord] {
  guard
    let info = CGWindowListCopyWindowInfo(
      options,
      kCGNullWindowID
    ) as? [[String: Any]]
  else {
    return []
  }
  return info.compactMap(cgWindowRecord)
}

func cgWindowRecord(_ item: [String: Any]) -> CGWindowRecord? {
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
    memoryUsage: (item[kCGWindowMemoryUsage as String] as? NSNumber)?.intValue
  )
}

func eligibleCGWindowRecords(
  role: String?,
  for subrole: String?,
  allowsConfiguredNonzeroLayer: Bool = false,
  in records: [CGWindowRecord]
) -> [CGWindowRecord] {
  let acceptsFloatingLevel =
    allowsConfiguredNonzeroLayer
    || role == kAXSheetRole
    || subrole.map(automaticFloatingWindowSubroles.contains) == true
  return records.filter { record in
    record.layer == 0 || (acceptsFloatingLevel && record.layer > 0)
  }
}

func framesByWindowID(
  for windowIDs: Set<WindowID>,
  in records: [CGWindowRecord]
) -> [WindowID: Rect] {
  Dictionary(
    uniqueKeysWithValues: records.compactMap { record in
      let windowID = WindowID(rawValue: UInt64(record.id))
      return windowIDs.contains(windowID) ? (windowID, record.frame) : nil
    }
  )
}

func applicationInventoryRefreshInterval(
  reliableLifecycleObservation: Bool
) -> TimeInterval {
  reliableLifecycleObservation ? 5 : 0.3
}

public func boundedSnapshotRefreshDeadline(
  current: TimeInterval,
  now: TimeInterval,
  interval: TimeInterval,
  reset: Bool
) -> TimeInterval {
  let candidate = now + interval
  return reset ? candidate : min(current, candidate)
}

func windowListRefreshInterval(
  hasPendingUnmatchedRetry: Bool,
  reliableTopologyObservation: Bool
) -> TimeInterval {
  if hasPendingUnmatchedRetry { return 0.1 }
  return reliableTopologyObservation ? 5 : 0.3
}

func unmatchedWindowRetryIsPending(
  attempts: Int,
  maximumAttempts: Int = 3
) -> Bool {
  attempts < maximumAttempts
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
  previouslyManagedWindows: [pid_t: [AXUIElement]]
) -> [pid_t: [AXUIElement]] {
  Dictionary(
    uniqueKeysWithValues: applicationWindows.map { processID, windows in
      let candidates =
        (managedWindows[processID] ?? [])
        + (previouslyManagedWindows[processID] ?? [])
      let required = windows.filter { window in
        candidates.contains(where: { CFEqual($0, window) })
      }
      return (processID, required)
    }
  )
}

func copyWindowBorderStacking(
  targetWindowID: WindowID?,
  monitorFrames: [Rect],
  knownWindowIDs: Set<WindowID>
) -> WindowBorderStacking {
  guard
    let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[CFString: Any]]
  else {
    return .inactive(for: targetWindowID)
  }
  let ownProcessID = ProcessInfo.processInfo.processIdentifier
  let entries = info.compactMap { item -> WindowStackEntry? in
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
      frame: Rect(
        x: cgRect.minX,
        y: cgRect.minY,
        width: cgRect.width,
        height: cgRect.height
      )
    )
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
      return windowTitleMatchRank(lhs.title, title) < windowTitleMatchRank(rhs.title, title)
    }),
    frameDistance(closest.frame, frame) <= maximumDistance
  else {
    return nil
  }
  return closest
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

enum WindowDisposition: Equatable {
  case tiled
  case floating
  case ignored
}

func floatingOrigin(
  for disposition: WindowDisposition,
  configuredFloating: Bool
) -> FloatingOrigin? {
  guard disposition == .floating else { return nil }
  return configuredFloating ? .configured : .automatic
}

private let ignoredWindowApplicationIDs: Set<String> = [
  "com.apple.dock",
  "com.apple.systemuiserver",
  "com.raycast.macos",
]

private let automaticFloatingWindowSubroles: Set<String> = [
  "AXDialog",
  "AXFloatingWindow",
  "AXSystemDialog",
  "AXSystemFloatingWindow",
]

func classifyWindow(
  role: String?,
  subrole: String?,
  appID: String,
  hasCloseButton: Bool,
  canResize: Bool,
  configuredFloating: Bool,
  forceTiling: Bool
) -> WindowDisposition {
  if forceTiling { return .tiled }
  if configuredFloating { return .floating }
  if ignoredWindowApplicationIDs.contains(appID.lowercased()) { return .ignored }
  if role == kAXSheetRole { return .floating }
  guard role == kAXWindowRole else { return .ignored }
  if subrole == kAXStandardWindowSubrole, hasCloseButton, canResize {
    return .tiled
  }
  if subrole == kAXStandardWindowSubrole
    || subrole.map(automaticFloatingWindowSubroles.contains) == true
  {
    return .floating
  }
  return .ignored
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
  return previousDisposition ?? .ignored
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
  monitors.contains { monitor in
    frame.x + frame.width > monitor.frame.x
      && frame.x < monitor.frame.x + monitor.frame.width
      && frame.y + frame.height > monitor.frame.y
      && frame.y < monitor.frame.y + monitor.frame.height
  }
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
