import CoreGraphics
import DefiModel
import Foundation

func cursorWarpDestination(
  frame: Rect,
  currentLocation: CGPoint
) -> CGPoint? {
  guard frame.width > 0, frame.height > 0 else { return nil }
  let containsCurrentLocation =
    currentLocation.x >= frame.x
    && currentLocation.x <= frame.x + frame.width
    && currentLocation.y >= frame.y
    && currentLocation.y <= frame.y + frame.height
  guard !containsCurrentLocation else { return nil }
  return CGPoint(
    x: frame.x + frame.width / 2,
    y: frame.y + frame.height / 2
  )
}

func cursorWarpIsCurrent(
  latestPointerMotionTimestamp: TimeInterval,
  maximumPointerMotionTimestamp: TimeInterval
) -> Bool {
  latestPointerMotionTimestamp <= maximumPointerMotionTimestamp
}

func cursorWarpTimestampAfterNativeFocus(
  result: NativeFocusResult,
  requestedTimestamp: TimeInterval?
) -> TimeInterval? {
  guard result == .completed else { return nil }
  return requestedTimestamp
}

enum ManagedPointerHit: Equatable {
  case managed(WindowID)
  case blocked
  case none
}

func managedPointerHitTest(
  at location: CGPoint,
  records: [CGWindowRecord],
  managedWindowIDs: Set<WindowID>,
  managedProcessIDs: Set<pid_t>,
  excludingProcessID: pid_t
) -> ManagedPointerHit {
  for record in records
  where record.layer == 0
    && record.processID != excludingProcessID
    && location.x >= record.frame.x
    && location.x <= record.frame.x + record.frame.width
    && location.y >= record.frame.y
    && location.y <= record.frame.y + record.frame.height
  {
    let windowID = WindowID(rawValue: UInt64(record.id))
    if managedWindowIDs.contains(windowID) {
      return .managed(windowID)
    }
    if !managedProcessIDs.contains(record.processID) {
      return .blocked
    }
  }
  return .none
}

@MainActor
extension MacOSPlatform {
  public func managedWindowIDUnderPointer(
    retaining previousWindowID: WindowID? = nil
  ) -> WindowID? {
    guard let location = CGEvent(source: nil)?.location else { return nil }
    return managedWindowID(at: location, retaining: previousWindowID)
  }

  public func managedWindowID(
    at location: CGPoint,
    retaining previousWindowID: WindowID? = nil
  ) -> WindowID? {
    let hit = managedPointerHitTest(
      at: location,
      records: copyCGWindows(
        options: [.optionOnScreenOnly, .excludeDesktopElements]
      ),
      managedWindowIDs: lastSnapshotWindowIDs,
      managedProcessIDs: lastSnapshotProcessIDs,
      excludingProcessID: ProcessInfo.processInfo.processIdentifier
    )
    switch hit {
    case .managed(let windowID):
      return windowID
    case .blocked:
      return nil
    case .none:
      break
    }

    if let previousWindowID,
      !floatingWindowIDs.contains(previousWindowID),
      !lastHiddenWindowIDs.contains(previousWindowID),
      let frame = cursorWarpFrame(for: previousWindowID),
      location.x >= frame.x,
      location.x <= frame.x + frame.width,
      location.y >= frame.y,
      location.y <= frame.y + frame.height
    {
      return previousWindowID
    }
    return nil
  }

  @discardableResult
  public func warpCursor(
    to windowID: WindowID,
    unlessPointerMovedAfter maximumPointerMotionTimestamp: TimeInterval
  ) -> Bool {
    guard cursorWarpIsCurrent(
      latestPointerMotionTimestamp: pointerMotionTracker.latestTimestamp,
      maximumPointerMotionTimestamp: maximumPointerMotionTimestamp
    ),
      !lastHiddenWindowIDs.contains(windowID),
      let frame = cursorWarpFrame(for: windowID),
      let currentLocation = CGEvent(source: nil)?.location,
      let destination = cursorWarpDestination(
        frame: frame,
        currentLocation: currentLocation
      )
    else {
      cursorWarpSkippedCount += 1
      return false
    }

    guard CGWarpMouseCursorPosition(destination) == .success else {
      cursorWarpFailedCount += 1
      return false
    }
    cursorWarpAppliedCount += 1
    return true
  }

  public var cursorWarpPerformance:
    (applied: Int, skipped: Int, failed: Int)
  {
    (
      applied: cursorWarpAppliedCount,
      skipped: cursorWarpSkippedCount,
      failed: cursorWarpFailedCount
    )
  }

  private func cursorWarpFrame(for windowID: WindowID) -> Rect? {
    if floatingWindowIDs.contains(windowID) {
      return latestObservedFrames[windowID]
        ?? lastSnapshotWindows.first(where: { $0.id == windowID })?.frame
        ?? targetFrames[windowID]
    }
    return targetFrames[windowID]
      ?? latestObservedFrames[windowID]
      ?? lastSnapshotWindows.first(where: { $0.id == windowID })?.frame
  }
}
