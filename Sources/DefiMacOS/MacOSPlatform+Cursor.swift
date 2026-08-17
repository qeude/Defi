import AppKit
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
  latestUserInputTimestamp: TimeInterval,
  maximumInputTimestamp: TimeInterval,
  mouseButtonDown: Bool
) -> Bool {
  !mouseButtonDown
    && latestPointerMotionTimestamp <= maximumInputTimestamp
    && latestUserInputTimestamp <= maximumInputTimestamp
}

func anyMouseButtonIsDown(
  buttonState: (CGMouseButton) -> Bool
) -> Bool {
  (0..<32).contains { rawValue in
    guard let button = CGMouseButton(rawValue: UInt32(rawValue)) else {
      return false
    }
    return buttonState(button)
  }
}

func cursorWarpTimestampAfterNativeFocus(
  result: NativeFocusResult,
  requestedTimestamp: TimeInterval?
) -> TimeInterval? {
  guard result == .completed || result == .completedWithoutMutation else {
    return nil
  }
  return requestedTimestamp
}

func resolvedCursorWarpFrame(
  isFloating: Bool,
  prefersTargetFrame: Bool,
  targetFrame: Rect?,
  observedFrame: Rect?,
  snapshotFrame: Rect?
) -> Rect? {
  if isFloating, !prefersTargetFrame {
    return observedFrame ?? snapshotFrame ?? targetFrame
  }
  return targetFrame ?? observedFrame ?? snapshotFrame
}

enum ManagedPointerHit: Equatable {
  case managed(WindowID)
  case blocked
  case none
}

public func normalizedPointerWindowID(
  rawWindowID: WindowID?,
  hitTestedWindowID: WindowID?
) -> WindowID? {
  hitTestedWindowID ?? rawWindowID
}

let pointerHitTestCacheMaximumAge: TimeInterval = 0.05

public func pointerRawWindowTransitionRequiresRefresh(
  previousRawWindowID: WindowID?,
  currentRawWindowID: WindowID?
) -> Bool {
  previousRawWindowID != currentRawWindowID
}

func pointerHitTestCacheIsFresh(
  cachedAt: TimeInterval?,
  now: TimeInterval,
  maximumAge: TimeInterval = pointerHitTestCacheMaximumAge
) -> Bool {
  guard let cachedAt, now >= cachedAt else { return false }
  return now - cachedAt < maximumAge
}

func managedPointerHitTest(
  at location: CGPoint,
  records: [CGWindowRecord],
  managedWindowIDs: Set<WindowID>,
  nonblockingWindowIDs: Set<CGWindowID> = [],
  frameProvider: (CGWindowRecord) -> Rect? = { $0.frame }
) -> ManagedPointerHit {
  for record in records {
    guard let frame = frameProvider(record),
      location.x >= frame.x,
      location.x <= frame.x + frame.width,
      location.y >= frame.y,
      location.y <= frame.y + frame.height
    else {
      continue
    }
    let windowID = WindowID(rawValue: UInt64(record.id))
    if managedWindowIDs.contains(windowID) {
      return .managed(windowID)
    }
    if nonblockingWindowIDs.contains(record.id) {
      continue
    }
    return .blocked
  }
  return .none
}

func transparentDockOverlayWindowIDs(
  records: [CGWindowRecord],
  dockProcessIDs: Set<pid_t>,
  monitorFrames: [Rect]
) -> Set<CGWindowID> {
  Set(records.compactMap { record in
    let maximumTransparentBackingBytes =
      max(4_096, Int(record.frame.width * record.frame.height / 16))
    let hasTransparentBacking = record.memoryUsage.map {
      $0 <= maximumTransparentBackingBytes
    } ?? false
    guard record.layer > 0,
      dockProcessIDs.contains(record.processID),
      record.title == "Dock" || hasTransparentBacking,
      monitorFrames.contains(where: { monitorFrame in
        record.frame.x <= monitorFrame.x + 1
          && record.frame.y <= monitorFrame.y + 1
          && record.frame.x + record.frame.width
            >= monitorFrame.x + monitorFrame.width - 1
          && record.frame.y + record.frame.height
            >= monitorFrame.y + monitorFrame.height - 1
      })
    else {
      return nil
    }
    return record.id
  })
}

func transparentPointerOverlayWindowIDs(
  records: [CGWindowRecord]
) -> Set<CGWindowID> {
  let cursorWindowLevel = Int(CGWindowLevelForKey(.cursorWindow))
  return Set(records.compactMap { record in
    guard record.layer == cursorWindowLevel,
      record.title == "Cursor"
        || (record.title.isEmpty && record.ownerName == "Window Server"),
      record.frame.width <= 64,
      record.frame.height <= 64
    else {
      return nil
    }
    return record.id
  })
}

@MainActor
extension MacOSPlatform {
  public func invalidatePointerHitTestCache() {
    pointerHitTestSnapshotTimestamp = nil
  }

  private func pointerHitTestSnapshot() -> (
    records: [CGWindowRecord],
    dockProcessIDs: Set<pid_t>
  ) {
    // Unresolved pointer motion can arrive at 120 Hz. Keep WindowServer and
    // Dock enumeration out of the hot path while retaining a bounded staleness.
    let now = ProcessInfo.processInfo.systemUptime
    if pointerHitTestCacheIsFresh(
      cachedAt: pointerHitTestSnapshotTimestamp,
      now: now
    ) {
      return (pointerHitTestRecords, pointerHitTestDockProcessIDs)
    }

    let records = copyCGWindows(
      options: [.optionOnScreenOnly, .excludeDesktopElements]
    )
    let dockProcessIDs = Set(
      NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).map(\.processIdentifier)
    )
    pointerHitTestRecords = records
    pointerHitTestDockProcessIDs = dockProcessIDs
    pointerHitTestSnapshotTimestamp = now
    return (records, dockProcessIDs)
  }

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
    let snapshot = pointerHitTestSnapshot()
    let nonblockingWindowIDs = transparentDockOverlayWindowIDs(
      records: snapshot.records,
      dockProcessIDs: snapshot.dockProcessIDs,
      monitorFrames: lastMonitorFrames
    )
      .union(transparentPointerOverlayWindowIDs(records: snapshot.records))
      .union(borderManager.transparentSurfaceWindowIDs)
    let hit = managedPointerHitTest(
      at: location,
      records: snapshot.records,
      managedWindowIDs: lastSnapshotWindowIDs,
      nonblockingWindowIDs: nonblockingWindowIDs,
      frameProvider: { record in
        guard !screenCaptureAccessAvailable else { return record.frame }
        return borderBoundsProvider.frame(
          for: WindowID(rawValue: UInt64(record.id))
        ) ?? record.frame
      }
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
    unlessUserInputAfter maximumInputTimestamp: TimeInterval,
    preferringTargetFrame: Bool = false
  ) -> Bool {
    guard cursorWarpIsCurrent(
      latestPointerMotionTimestamp: pointerMotionTracker.latestTimestamp,
      latestUserInputTimestamp: userInputTracker.latestEventTimestamp,
      maximumInputTimestamp: maximumInputTimestamp,
      mouseButtonDown: anyMouseButtonIsDown { button in
        CGEventSource.buttonState(.combinedSessionState, button: button)
      }
    ),
      !lastHiddenWindowIDs.contains(windowID),
      let frame = cursorWarpFrame(
        for: windowID,
        preferringTargetFrame: preferringTargetFrame
      ),
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

  private func cursorWarpFrame(
    for windowID: WindowID,
    preferringTargetFrame: Bool = false
  ) -> Rect? {
    resolvedCursorWarpFrame(
      isFloating: floatingWindowIDs.contains(windowID),
      prefersTargetFrame: preferringTargetFrame,
      targetFrame: targetFrames[windowID],
      observedFrame: latestObservedFrames[windowID],
      snapshotFrame: lastSnapshotWindows.first {
        $0.id == windowID
      }?.frame
    )
  }
}
