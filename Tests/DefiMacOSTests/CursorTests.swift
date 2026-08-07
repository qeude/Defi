import CoreGraphics
import DefiModel
import Testing

@testable import DefiMacOS

struct CursorTests {
  private let frame = Rect(x: 100, y: 200, width: 400, height: 600)

  @Test
  func cursorOutsideWindowWarpsToCenter() {
    #expect(
      cursorWarpDestination(
        frame: frame,
        currentLocation: CGPoint(x: 0, y: 0)
      ) == CGPoint(x: 300, y: 500)
    )
  }

  @Test
  func cursorAlreadyInsideWindowDoesNotWarp() {
    #expect(
      cursorWarpDestination(
        frame: frame,
        currentLocation: CGPoint(x: 300, y: 500)
      ) == nil
    )
  }

  @Test
  func newerPhysicalMotionRejectsStaleWarp() {
    #expect(
      cursorWarpIsCurrent(
        latestPointerMotionTimestamp: 12,
        maximumPointerMotionTimestamp: 11
      ) == false
    )
    #expect(
      cursorWarpIsCurrent(
        latestPointerMotionTimestamp: 11,
        maximumPointerMotionTimestamp: 11
      )
    )
  }

  @Test
  func cursorWarpWaitsForConfirmedNativeFocus() {
    #expect(
      cursorWarpTimestampAfterNativeFocus(
        result: .completed,
        requestedTimestamp: 12
      ) == 12
    )
    #expect(
      cursorWarpTimestampAfterNativeFocus(
        result: .cancelled,
        requestedTimestamp: 12
      ) == nil
    )
    #expect(
      cursorWarpTimestampAfterNativeFocus(
        result: .cancelledAfterMutation,
        requestedTimestamp: 12
      ) == nil
    )
    #expect(
      cursorWarpTimestampAfterNativeFocus(
        result: .failed,
        requestedTimestamp: 12
      ) == nil
    )
  }

  @Test
  func frontmostManagedWindowWinsOverRetainedTiledWindow() {
    let tiledWindowID = WindowID(rawValue: 1)
    let floatingWindowID = WindowID(rawValue: 2)
    let records = [
      record(id: 2, processID: 20),
      record(id: 1, processID: 10),
    ]

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [tiledWindowID, floatingWindowID],
        managedProcessIDs: [10, 20],
        excludingProcessID: 999
      ) == .managed(floatingWindowID)
    )
  }

  @Test
  func unmanagedFrontWindowBlocksManagedWindowBehindIt() {
    let records = [
      record(id: 9, processID: 90),
      record(id: 1, processID: 10),
    ]

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [WindowID(rawValue: 1)],
        managedProcessIDs: [10],
        excludingProcessID: 999
      ) == .blocked
    )
  }

  @Test
  func managedProcessAuxiliaryWindowAllowsManagedWindowBehindIt() {
    let managedWindowID = WindowID(rawValue: 1)
    let records = [
      record(id: 9, processID: 10),
      record(id: 1, processID: 10),
    ]

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [managedWindowID],
        managedProcessIDs: [10],
        excludingProcessID: 999
      ) == .managed(managedWindowID)
    )
  }

  private func record(id: CGWindowID, processID: pid_t) -> CGWindowRecord {
    CGWindowRecord(
      id: id,
      processID: processID,
      layer: 0,
      title: "Window \(id)",
      frame: frame
    )
  }
}
