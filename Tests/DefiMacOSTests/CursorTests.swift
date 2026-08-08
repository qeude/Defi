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
        latestUserInputTimestamp: 10,
        maximumInputTimestamp: 11,
        mouseButtonDown: false
      ) == false
    )
    #expect(
      cursorWarpIsCurrent(
        latestPointerMotionTimestamp: 11,
        latestUserInputTimestamp: 10,
        maximumInputTimestamp: 11,
        mouseButtonDown: false
      )
    )
  }

  @Test
  func newerGeneralInputOrHeldButtonRejectsWarp() {
    #expect(
      !cursorWarpIsCurrent(
        latestPointerMotionTimestamp: 10,
        latestUserInputTimestamp: 12,
        maximumInputTimestamp: 11,
        mouseButtonDown: false
      )
    )
    #expect(
      !cursorWarpIsCurrent(
        latestPointerMotionTimestamp: 10,
        latestUserInputTimestamp: 10,
        maximumInputTimestamp: 11,
        mouseButtonDown: true
      )
    )
  }

  @Test
  func cursorWarpWaitsForConfirmedNativeFocus() {
    #expect(
      cursorWarpTimestampAfterNativeFocus(
        result: .completedWithoutMutation,
        requestedTimestamp: 12
      ) == 12
    )
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
    #expect(
      cursorWarpTimestampAfterNativeFocus(
        result: .failedAfterMutation,
        requestedTimestamp: 12
      ) == nil
    )
  }

  @Test
  func committedFloatingTransitionWarpsToTargetFrame() {
    let target = Rect(x: 500, y: 200, width: 400, height: 600)
    let observed = Rect(x: -10_000, y: 200, width: 400, height: 600)

    #expect(
      resolvedCursorWarpFrame(
        isFloating: true,
        prefersTargetFrame: true,
        targetFrame: target,
        observedFrame: observed,
        snapshotFrame: observed
      ) == target
    )
  }

  @Test
  func ordinaryFloatingWarpPrefersObservedFrame() {
    let target = Rect(x: 500, y: 200, width: 400, height: 600)
    let observed = Rect(x: 100, y: 200, width: 400, height: 600)

    #expect(
      resolvedCursorWarpFrame(
        isFloating: true,
        prefersTargetFrame: false,
        targetFrame: target,
        observedFrame: observed,
        snapshotFrame: nil
      ) == observed
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
        excludingProcessID: 999
      ) == .managed(floatingWindowID)
    )
  }

  @Test
  func elevatedManagedWindowWinsOverTiledWindow() {
    let tiledWindowID = WindowID(rawValue: 1)
    let sheetWindowID = WindowID(rawValue: 2)
    let records = [
      record(id: 2, processID: 10, layer: 8),
      record(id: 1, processID: 10),
    ]

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [tiledWindowID, sheetWindowID],
        excludingProcessID: 999
      ) == .managed(sheetWindowID)
    )
  }

  @Test
  func elevatedAuxiliaryWindowBlocksManagedWindowBehindIt() {
    let records = [
      record(id: 9, processID: 10, layer: 8),
      record(id: 1, processID: 10),
    ]

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [WindowID(rawValue: 1)],
        excludingProcessID: 999
      ) == .blocked
    )
  }

  @Test
  func transparentSystemOverlayDoesNotBlockManagedWindow() {
    let managedWindowID = WindowID(rawValue: 1)
    let records = [
      record(id: 9, processID: 90, layer: 20),
      record(id: 1, processID: 10),
    ]

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [managedWindowID],
        excludingProcessID: 999,
        nonblockingElevatedWindowIDs: [9]
      ) == .managed(managedWindowID)
    )
  }

  @Test
  func onlyFullDisplayDockSurfaceIsTransparentToHitTesting() {
    let physicalFrame = Rect(x: 0, y: 0, width: 1512, height: 982)
    let visibleFrame = Rect(x: 0, y: 37, width: 1512, height: 901)
    let records = [
      record(
        id: 9,
        processID: 90,
        layer: 20,
        title: "",
        frame: physicalFrame
      ),
      record(
        id: 8,
        processID: 90,
        layer: 20,
        title: "Dock",
        frame: Rect(x: 0, y: 930, width: 1512, height: 52)
      ),
    ]

    #expect(
      transparentDockOverlayWindowIDs(
        records: records,
        dockProcessIDs: [90],
        monitorFrames: [visibleFrame]
      ) == [9]
    )
  }

  @Test
  func visibleDockSurfaceStillBlocksManagedWindow() {
    let records = [
      record(id: 9, processID: 90, layer: 20, title: "Dock"),
      record(id: 1, processID: 10),
    ]

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [WindowID(rawValue: 1)],
        excludingProcessID: 999,
        nonblockingElevatedWindowIDs: []
      ) == .blocked
    )
  }

  @Test
  func cursorSurfaceIsTransparentToHitTesting() {
    let records = [
      record(
        id: 9,
        processID: 90,
        layer: 2_147_483_630,
        title: "Cursor",
        frame: Rect(x: 300, y: 500, width: 28, height: 40)
      ),
      record(id: 1, processID: 10),
    ]

    let transparentWindowIDs = transparentPointerOverlayWindowIDs(
      records: records
    )
    #expect(transparentWindowIDs == [9])
    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [WindowID(rawValue: 1)],
        excludingProcessID: 999,
        nonblockingElevatedWindowIDs: transparentWindowIDs
      ) == .managed(WindowID(rawValue: 1))
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
        excludingProcessID: 999
      ) == .blocked
    )
  }

  @Test
  func managedProcessAuxiliaryWindowBlocksManagedWindowBehindIt() {
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
        excludingProcessID: 999
      ) == .blocked
    )
  }

  private func record(
    id: CGWindowID,
    processID: pid_t,
    layer: Int = 0,
    title: String? = nil,
    frame: Rect? = nil
  ) -> CGWindowRecord {
    CGWindowRecord(
      id: id,
      processID: processID,
      layer: layer,
      title: title ?? "Window \(id)",
      frame: frame ?? self.frame
    )
  }
}
