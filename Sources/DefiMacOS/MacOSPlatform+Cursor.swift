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

func managedPointerHitTest(
  at location: CGPoint,
  records: [CGWindowRecord],
  managedWindowIDs: Set<WindowID>,
  managedProcessIDs: Set<pid_t>,
  excludingProcessID: pid_t,
  nonblockingElevatedWindowIDs: Set<CGWindowID> = []
) -> ManagedPointerHit {
  for record in records
  where record.processID != excludingProcessID
    && location.x >= record.frame.x
    && location.x <= record.frame.x + record.frame.width
    && location.y >= record.frame.y
    && location.y <= record.frame.y + record.frame.height
  {
    let windowID = WindowID(rawValue: UInt64(record.id))
    if managedWindowIDs.contains(windowID) {
      return .managed(windowID)
    }
    if record.layer > 0, nonblockingElevatedWindowIDs.contains(record.id) {
      continue
    }
    if record.layer > 0 || !managedProcessIDs.contains(record.processID) {
      return .blocked
    }
  }
  return .none
}

func transparentDockOverlayWindowIDs(
  records: [CGWindowRecord],
  dockProcessIDs: Set<pid_t>,
  monitorFrames: [Rect]
) -> Set<CGWindowID> {
  Set(records.compactMap { record in
    guard record.layer > 0,
      dockProcessIDs.contains(record.processID),
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
    let records = copyCGWindows(
      options: [.optionOnScreenOnly, .excludeDesktopElements]
    )
    let dockProcessIDs = Set(
      NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).map(\.processIdentifier)
    )
    let hit = managedPointerHitTest(
      at: location,
      records: records,
      managedWindowIDs: lastSnapshotWindowIDs,
      managedProcessIDs: lastSnapshotProcessIDs,
      excludingProcessID: ProcessInfo.processInfo.processIdentifier,
      nonblockingElevatedWindowIDs: transparentDockOverlayWindowIDs(
        records: records,
        dockProcessIDs: dockProcessIDs,
        monitorFrames: lastMonitorFrames
      )
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
      mouseButtonDown:
        CGEventSource.buttonState(.combinedSessionState, button: .left)
        || CGEventSource.buttonState(.combinedSessionState, button: .right)
        || CGEventSource.buttonState(.combinedSessionState, button: .center)
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
