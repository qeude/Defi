import CoreGraphics
import DefiModel
import Foundation
import Testing

@testable import DefiMacOS

struct CursorTests {
  private let frame = Rect(x: 100, y: 200, width: 400, height: 600)

  @Test
  func windowServerRecordPreservesOptionalWindowName() throws {
    let bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
      .dictionaryRepresentation
    let parsed = try #require(
      cgWindowRecord([
        kCGWindowLayer as String: NSNumber(value: 20),
        kCGWindowNumber as String: NSNumber(value: 42),
        kCGWindowOwnerPID as String: NSNumber(value: 90),
        kCGWindowBounds as String: bounds,
        kCGWindowName as String: "Dock",
        kCGWindowMemoryUsage as String: NSNumber(value: 2_368),
      ])
    )

    #expect(parsed.id == 42)
    #expect(parsed.processID == 90)
    #expect(parsed.layer == 20)
    #expect(parsed.title == "Dock")
    #expect(parsed.frame == Rect(x: 10, y: 20, width: 30, height: 40))
    #expect(parsed.memoryUsage == 2_368)
  }

  @Test(
    arguments: zip(
      [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 500)],
      [CGPoint(x: 300, y: 500), nil]
    )
  )
  func cursorWarpsToCenterOnlyOutsideWindow(currentLocation: CGPoint, destination: CGPoint?) {
    #expect(
      cursorWarpDestination(
        frame: frame,
        currentLocation: currentLocation
      ) == destination
    )
  }

  @Test
  func hitTestedManagedWindowOverridesTransparentRawPointerID() {
    let rawOverlayID = WindowID(rawValue: 9)
    let managedWindowID = WindowID(rawValue: 1)
    let records = [
      CGWindowRecord(
        id: CGWindowID(rawOverlayID.rawValue),
        processID: 90,
        layer: 8,
        title: "Defi Border",
        frame: frame
      ),
      CGWindowRecord(
        id: CGWindowID(managedWindowID.rawValue),
        processID: 10,
        layer: 0,
        title: "Managed",
        frame: frame
      ),
    ]
    let hit = managedPointerHitTest(
      at: CGPoint(x: 300, y: 500),
      records: records,
      managedWindowIDs: [managedWindowID],
      nonblockingWindowIDs: [CGWindowID(rawOverlayID.rawValue)]
    )
    let hitTestedWindowID: WindowID?
    if case .managed(let windowID) = hit {
      hitTestedWindowID = windowID
    } else {
      hitTestedWindowID = nil
    }

    #expect(
      normalizedPointerWindowID(
        rawWindowID: rawOverlayID,
        hitTestedWindowID: hitTestedWindowID
      ) == managedWindowID
    )
    #expect(
      normalizedPointerWindowID(
        rawWindowID: rawOverlayID,
        hitTestedWindowID: nil
      ) == rawOverlayID
    )
  }

  @Test
  func privateBoundsRecoverHitTestFromRedactedCGGeometry() {
    let windowID = WindowID(rawValue: 1)
    let redacted = CGWindowRecord(
      id: 1,
      processID: 10,
      layer: 0,
      title: "",
      frame: Rect(x: 0, y: 940, width: 500, height: 500)
    )

    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: [redacted],
        managedWindowIDs: [windowID],
        frameProvider: { _ in self.frame }
      ) == .managed(windowID)
    )
  }

  @Test
  func publicHitTestFallbackPrefersObservedFrameOverTarget() {
    let observed = Rect(x: 100, y: 200, width: 400, height: 600)
    let target = Rect(x: -10_000, y: -10_000, width: 400, height: 600)

    #expect(
      resolvedPointerHitTestFrame(
        observedFrame: observed,
        snapshotFrame: nil,
        targetFrame: target
      ) == observed
    )
  }

  @Test
  func pointerHitTestCacheExpiresAndRejectsClockRollback() {
    #expect(
      pointerHitTestCacheIsFresh(
        cachedAt: nil,
        now: 10
      ) == false
    )
    #expect(
      pointerHitTestCacheIsFresh(
        cachedAt: 10,
        now: 10.049
      )
    )
    #expect(
      pointerHitTestCacheIsFresh(
        cachedAt: 10,
        now: 10.05
      ) == false
    )
    #expect(
      pointerHitTestCacheIsFresh(
        cachedAt: 10,
        now: 9
      ) == false
    )
  }

  @Test
  func rawPointerWindowTransitionsInvalidateHitTestCache() {
    #expect(
      pointerRawWindowTransitionRequiresRefresh(
        previousRawWindowID: nil,
        currentRawWindowID: nil
      ) == false)
    #expect(
      pointerRawWindowTransitionRequiresRefresh(
        previousRawWindowID: WindowID(rawValue: 1),
        currentRawWindowID: WindowID(rawValue: 2)
      )
    )
    #expect(
      pointerRawWindowTransitionRequiresRefresh(
        previousRawWindowID: WindowID(rawValue: 2),
        currentRawWindowID: nil
      )
    )
  }

  struct CursorWarpCurrencyCase: CustomTestStringConvertible, Sendable {
    let name: String
    let latestPointerMotionTimestamp: Double
    let latestUserInputTimestamp: Double
    var mouseButtonDown = false
    let isCurrent: Bool

    var testDescription: String { name }
  }

  static let cursorWarpCurrencyCases = [
    CursorWarpCurrencyCase(
      name: "newer physical motion rejects stale warp",
      latestPointerMotionTimestamp: 12,
      latestUserInputTimestamp: 10,
      isCurrent: false
    ),
    CursorWarpCurrencyCase(
      name: "motion within the input bound keeps warp current",
      latestPointerMotionTimestamp: 11,
      latestUserInputTimestamp: 10,
      isCurrent: true
    ),
    CursorWarpCurrencyCase(
      name: "newer general input rejects warp",
      latestPointerMotionTimestamp: 10,
      latestUserInputTimestamp: 12,
      isCurrent: false
    ),
    CursorWarpCurrencyCase(
      name: "held mouse button rejects warp",
      latestPointerMotionTimestamp: 10,
      latestUserInputTimestamp: 10,
      mouseButtonDown: true,
      isCurrent: false
    ),
  ]

  @Test(arguments: cursorWarpCurrencyCases)
  func staleMotionInputOrHeldButtonRejectsWarp(_ scenario: CursorWarpCurrencyCase) {
    #expect(
      cursorWarpIsCurrent(
        latestPointerMotionTimestamp: scenario.latestPointerMotionTimestamp,
        latestUserInputTimestamp: scenario.latestUserInputTimestamp,
        maximumInputTimestamp: 11,
        mouseButtonDown: scenario.mouseButtonDown
      ) == scenario.isCurrent
    )
  }

  @Test
  func everySupportedHeldMouseButtonRejectsWarp() {
    for heldRawValue in 0..<32 {
      #expect(
        anyMouseButtonIsDown { button in
          button.rawValue == heldRawValue
        }
      )
    }
    #expect(anyMouseButtonIsDown { _ in false } == false)
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

  @Test(arguments: [true, false])
  func floatingWarpFramePrefersTargetOnlyForCommittedTransition(prefersTargetFrame: Bool) {
    let target = Rect(x: 500, y: 200, width: 400, height: 600)
    let observed =
      prefersTargetFrame
      ? Rect(x: -10_000, y: 200, width: 400, height: 600)
      : Rect(x: 100, y: 200, width: 400, height: 600)

    #expect(
      resolvedCursorWarpFrame(
        isFloating: true,
        prefersTargetFrame: prefersTargetFrame,
        targetFrame: target,
        observedFrame: observed,
        snapshotFrame: prefersTargetFrame ? observed : nil
      ) == (prefersTargetFrame ? target : observed)
    )
  }

  struct HitTestCase: CustomTestStringConvertible, Sendable {
    let name: String
    let front: CGWindowID
    let processID: pid_t
    var layer = 0
    var title: String? = nil
    var managed: Set<WindowID> = [WindowID(rawValue: 1)]
    var nonblocking: Set<CGWindowID> = []
    let hit: ManagedPointerHit

    var testDescription: String { name }
  }

  static let hitTestCases = [
    HitTestCase(name: "frontmost managed window wins over a retained tiled window", front: 2, processID: 20,
      managed: [WindowID(rawValue: 1), WindowID(rawValue: 2)], hit: .managed(WindowID(rawValue: 2))),
    HitTestCase(name: "elevated managed sheet wins over its tiled window", front: 2, processID: 10, layer: 8,
      managed: [WindowID(rawValue: 1), WindowID(rawValue: 2)], hit: .managed(WindowID(rawValue: 2))),
    HitTestCase(name: "elevated auxiliary window blocks", front: 9, processID: 10, layer: 8, hit: .blocked),
    HitTestCase(name: "transparent system overlay passes through", front: 9, processID: 90, layer: 20,
      nonblocking: [9], hit: .managed(WindowID(rawValue: 1))),
    HitTestCase(name: "visible Dock surface blocks", front: 9, processID: 90, layer: 20, title: "Dock",
      hit: .blocked),
    HitTestCase(name: "unmanaged front window blocks", front: 9, processID: 90, hit: .blocked),
    HitTestCase(name: "managed process auxiliary window blocks", front: 9, processID: 10, hit: .blocked),
    HitTestCase(name: "known transparent normal surface passes through", front: 9, processID: 999,
      nonblocking: [9], hit: .managed(WindowID(rawValue: 1))),
  ]

  @Test(arguments: hitTestCases)
  func frontSurfaceDecidesManagedHit(_ scenario: HitTestCase) {
    let records = [
      record(id: scenario.front, processID: scenario.processID, layer: scenario.layer, title: scenario.title),
      record(id: 1, processID: 10),
    ]
    #expect(managedPointerHitTest(at: CGPoint(x: 300, y: 500), records: records,
      managedWindowIDs: scenario.managed, nonblockingWindowIDs: scenario.nonblocking) == scenario.hit)
  }

  // title, frame, memory usage -> transparent, whether the managed window behind is hit at (300, 500)
  @Test(arguments: [
    ("Dock", Rect(x: 0, y: 0, width: 1512, height: 982), nil, true, true),
    // the visible Dock strip is no full-display overlay and does not cover the point
    ("Dock", Rect(x: 0, y: 930, width: 1512, height: 52), nil, false, true),
    // a nameless lightweight Dock surface is transparent without capture permission
    ("", Rect(x: 0, y: 0, width: 1512, height: 982), 2_368, true, true),
    // a nameless full-display Mission Control surface blocks
    ("", Rect(x: 0, y: 0, width: 1512, height: 982), nil, false, false),
  ] as [(String, Rect, Int?, Bool, Bool)])
  func onlyFullDisplayDockOverlayIsTransparent(title: String, frame: Rect, memoryUsage: Int?,
    transparent: Bool, hitsManaged: Bool) {
    let records = [
      record(id: 9, processID: 90, layer: 20, title: title, frame: frame, memoryUsage: memoryUsage),
      record(id: 1, processID: 10, frame: Rect(x: 0, y: 0, width: 1512, height: 982)),
    ]
    let transparentIDs = transparentDockOverlayWindowIDs(records: records, dockProcessIDs: [90],
      monitorFrames: [Rect(x: 0, y: 37, width: 1512, height: 901)])
    #expect(transparentIDs == (transparent ? [9] : []))
    #expect(managedPointerHitTest(at: CGPoint(x: 300, y: 500), records: records,
      managedWindowIDs: [WindowID(rawValue: 1)], nonblockingWindowIDs: transparentIDs)
      == (hitsManaged ? .managed(WindowID(rawValue: 1)) : .blocked))
  }

  struct CursorOverlayCase: CustomTestStringConvertible, Sendable {
    let name: String
    var ownerName = ""
    let layer: Int
    let title: String
    let isTransparent: Bool

    var testDescription: String { name }
  }

  static let cursorOverlayCases = [
    CursorOverlayCase(
      name: "cursor surface is transparent to hit testing",
      layer: 2_147_483_630,
      title: "Cursor",
      isTransparent: true
    ),
    CursorOverlayCase(
      name: "nameless system cursor is transparent without capture permission",
      ownerName: "Window Server",
      layer: Int(CGWindowLevelForKey(.cursorWindow)),
      title: "",
      isTransparent: true
    ),
    CursorOverlayCase(
      name: "third party cursor palette blocks managed window",
      layer: 8,
      title: "Cursor",
      isTransparent: false
    ),
    CursorOverlayCase(
      name: "nameless third party cursor level window blocks managed window",
      layer: Int(CGWindowLevelForKey(.cursorWindow)),
      title: "",
      isTransparent: false
    ),
  ]

  @Test(arguments: cursorOverlayCases)
  func onlyCursorSurfaceIsTransparentToHitTesting(_ scenario: CursorOverlayCase) {
    let records = [
      record(
        id: 9,
        processID: 90,
        ownerName: scenario.ownerName,
        layer: scenario.layer,
        title: scenario.title,
        frame: Rect(x: 300, y: 500, width: 28, height: 40)
      ),
      record(id: 1, processID: 10),
    ]

    let transparentWindowIDs = transparentPointerOverlayWindowIDs(
      records: records
    )
    #expect(transparentWindowIDs == (scenario.isTransparent ? [9] : []))
    #expect(
      managedPointerHitTest(
        at: CGPoint(x: 300, y: 500),
        records: records,
        managedWindowIDs: [WindowID(rawValue: 1)],
        nonblockingWindowIDs: transparentWindowIDs
      ) == (scenario.isTransparent ? .managed(WindowID(rawValue: 1)) : .blocked)
    )
  }

  private func record(
    id: CGWindowID,
    processID: pid_t,
    ownerName: String = "",
    layer: Int = 0,
    title: String? = nil,
    frame: Rect? = nil,
    memoryUsage: Int? = nil
  ) -> CGWindowRecord {
    CGWindowRecord(
      id: id,
      processID: processID,
      ownerName: ownerName,
      layer: layer,
      title: title ?? "Window \(id)",
      frame: frame ?? self.frame,
      memoryUsage: memoryUsage
    )
  }
}
