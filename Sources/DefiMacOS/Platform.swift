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
  let title: String
  let frame: Rect
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

func copyCGWindows() -> [CGWindowRecord] {
  guard
    let info = CGWindowListCopyWindowInfo(
      [.optionAll, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[CFString: Any]]
  else {
    return []
  }
  return info.compactMap { item in
    guard (item[kCGWindowLayer] as? NSNumber)?.intValue == 0,
      let number = item[kCGWindowNumber] as? NSNumber,
      let ownerPID = item[kCGWindowOwnerPID] as? NSNumber,
      let bounds = item[kCGWindowBounds] as? NSDictionary,
      let cgRect = CGRect(dictionaryRepresentation: bounds)
    else {
      return nil
    }
    return CGWindowRecord(
      id: number.uint32Value,
      processID: ownerPID.int32Value,
      title: item[kCGWindowName] as? String ?? "",
      frame: Rect(
        x: cgRect.minX,
        y: cgRect.minY,
        width: cgRect.width,
        height: cgRect.height
      )
    )
  }
}

func copyFrontmostNormalWindowID() -> WindowID? {
  guard
    let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[CFString: Any]]
  else {
    return nil
  }
  let ownProcessID = ProcessInfo.processInfo.processIdentifier
  let entries = info.compactMap { item -> NormalWindowStackEntry? in
    guard
      (item[kCGWindowLayer] as? NSNumber)?.intValue == 0,
      (item[kCGWindowOwnerPID] as? NSNumber)?.int32Value != ownProcessID,
      let number = item[kCGWindowNumber] as? NSNumber,
      let bounds = item[kCGWindowBounds] as? [String: Any],
      let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else {
      return nil
    }
    return NormalWindowStackEntry(
      windowID: WindowID(rawValue: number.uint64Value),
      frame: Rect(
        x: cgRect.minX,
        y: cgRect.minY,
        width: cgRect.width,
        height: cgRect.height
      )
    )
  }
  return frontmostBorderOccludingWindowID(in: entries)
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

private func windowTitleMatchRank(_ cgTitle: String, _ accessibilityTitle: String) -> Int {
  guard !cgTitle.isEmpty, !accessibilityTitle.isEmpty else { return 1 }
  return cgTitle == accessibilityTitle ? 0 : 2
}

func shouldManageWindow(
  role: String?,
  subrole: String?,
  appID: String,
  hasCloseButton: Bool,
  forceTiling: Bool
) -> Bool {
  if forceTiling { return true }
  guard role == kAXWindowRole,
    subrole == kAXStandardWindowSubrole,
    hasCloseButton
  else {
    return false
  }
  let ignoredApps = [
    "com.apple.dock",
    "com.apple.systemuiserver",
    "com.raycast.macos",
  ]
  return !ignoredApps.contains(appID.lowercased())
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
