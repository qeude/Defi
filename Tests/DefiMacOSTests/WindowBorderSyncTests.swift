import CoreGraphics
import DefiCore
import DefiModel
import Testing

@testable import DefiMacOS

@MainActor
private final class FakeWindowEvents: WindowServerWindowEventSource {
  var startResult = true
  var requestResult = true
  var starts = 0
  var requests: [[UInt32]] = []
  var handler: (@MainActor (WindowServerWindowEvent) -> Void)?

  func start(_ handler: @escaping @MainActor (WindowServerWindowEvent) -> Void) -> Bool {
    starts += 1
    self.handler = handler
    return startResult
  }

  func requestNotifications(for windowIDs: [UInt32]) -> Bool {
    requests.append(windowIDs)
    return requestResult
  }
}

@MainActor
private final class FakeSurfaceMover: BorderSurfaceMoving {
  var result = true
  var batches: [[BorderSurfaceMove]] = []

  func move(_ moves: [BorderSurfaceMove]) -> Bool {
    batches.append(moves)
    return result
  }
}

private func id(_ raw: UInt64) -> WindowID { WindowID(rawValue: raw) }

@MainActor
struct WindowBorderSyncTests {
  private func makeSync(
    events: FakeWindowEvents = FakeWindowEvents(),
    mover: FakeSurfaceMover = FakeSurfaceMover(),
    scheduled: @escaping (@escaping @MainActor () -> Void) -> Void
  ) -> WindowBorderSync {
    WindowBorderSync(events: events, mover: mover, schedule: scheduled)
  }

  @Test func coalescesEventsIntoOnePassPerTurn() {
    var scheduled: [@MainActor () -> Void] = []
    let sync = makeSync { scheduled.append($0) }
    var passes: [Set<WindowID>] = []
    sync.onFlush = { passes.append($0) }
    sync.subscribe([id(1), id(2), id(3), id(4)])
    for _ in 0..<10 {
      sync.receive(.moved(id(1)))
      sync.receive(.resized(id(2)))
      sync.receive(.moved(id(3)))
      sync.receive(.moved(id(99)))
    }
    #expect(scheduled.count == 1)
    #expect(passes.isEmpty)
    scheduled[0]()
    #expect(passes == [[id(1), id(2), id(3)]])
    #expect(sync.eventCount == 40)
  }

  @Test func reorderAndCloseUseExistingPaths() {
    var scheduled: [@MainActor () -> Void] = []
    let sync = makeSync { scheduled.append($0) }
    var reorders = 0
    var closed: [WindowID] = []
    var passes: [Set<WindowID>] = []
    sync.onReordered = { reorders += 1 }
    sync.onClosed = { closed.append($0) }
    sync.onFlush = { passes.append($0) }
    sync.subscribe([id(1), id(2)])
    sync.receive(.moved(id(1)))
    sync.receive(.reordered(id(2)))
    sync.receive(.reordered(id(1)))
    sync.receive(.closed(id(1)))
    scheduled[0]()
    #expect(reorders == 1)
    #expect(closed == [id(1)])
    #expect(passes.isEmpty)
  }

  @Test func requestsNotificationsOnlyWhenSetChanges() {
    let events = FakeWindowEvents()
    let sync = makeSync(events: events) { _ in }
    sync.subscribe([])
    #expect(events.starts == 0)
    sync.subscribe([id(7), id(3)])
    sync.subscribe([id(3), id(7)])
    sync.subscribe([id(3)])
    sync.subscribe([id(3)])
    sync.subscribe([])
    #expect(events.starts == 1)
    #expect(events.requests == [[3, 7], [3], []])
  }

  @Test func probeFailureFallsBackForTheSession() {
    let events = FakeWindowEvents()
    events.startResult = false
    let sync = makeSync(events: events) { _ in }
    sync.subscribe([id(1)])
    sync.subscribe([id(2)])
    #expect(sync.backend == .fallback("notify"))
    #expect(events.starts == 1)
    #expect(events.requests.isEmpty)
    #expect(sync.fallbackCount == 1)
    #expect(sync.move([BorderSurfaceMove(windowNumber: 5, origin: .zero)]) == false)
  }

  @Test func moverFailureIsStickyAndCounted() {
    let mover = FakeSurfaceMover()
    let sync = makeSync(mover: mover) { _ in }
    let move = BorderSurfaceMove(windowNumber: 5, origin: CGPoint(x: 10, y: 20))
    #expect(sync.move([move, move]))
    #expect(sync.moveCount == 2)
    mover.result = false
    #expect(sync.move([move]) == false)
    mover.result = true
    #expect(sync.move([move]) == false)
    #expect(mover.batches.count == 2)
    #expect(sync.backend == .fallback("move"))
    #expect(sync.statusDescription
      == "borderSync=fallback:move borderSyncEvents=0 borderSyncMoves=2 borderSyncFallbacks=1 borderSyncReconciles=0")
  }

  @Test func reconcileReadsAllTrackedWindowsOnce() {
    let sync = makeSync { _ in }
    var passes: [Set<WindowID>] = []
    sync.onFlush = { passes.append($0) }
    sync.reconcile([id(1), id(2)])
    #expect(passes == [[id(1), id(2)]])
    #expect(sync.reconcileCount == 1)
    sync.downgrade("bounds")
    sync.reconcile([id(1)])
    #expect(passes.count == 1)
  }

  @Test func windowServerBoundsWinOverAccessibilityCaches() {
    let bounds = Rect(x: 100, y: 50, width: 800, height: 600)
    let displayed = Rect(x: 400, y: 50, width: 800, height: 600)
    let planned = Rect(x: 900, y: 50, width: 800, height: 600)
    #expect(windowBorderGeometryFrame(
      windowServerDriven: true, windowServerFrame: bounds,
      displayedFrame: displayed, plannedFrame: planned) == bounds)
    #expect(windowBorderGeometryFrame(
      windowServerDriven: true, windowServerFrame: nil,
      displayedFrame: displayed, plannedFrame: planned) == planned)
    #expect(windowBorderGeometryFrame(
      windowServerDriven: false, windowServerFrame: bounds,
      displayedFrame: displayed, plannedFrame: planned) == displayed)
  }

  @Test func eventCodesMapToTypedEvents() {
    #expect(WindowServerWindowEvent(code: 806, windowID: id(4)) == .moved(id(4)))
    #expect(WindowServerWindowEvent(code: 807, windowID: id(4)) == .resized(id(4)))
    #expect(WindowServerWindowEvent(code: 808, windowID: id(4)) == .reordered(id(4)))
    #expect(WindowServerWindowEvent(code: 804, windowID: id(4)) == .closed(id(4)))
    #expect(WindowServerWindowEvent(code: 805, windowID: id(4)) == nil)
  }

  /// Runs `triggers` (in ms) against a fake clock; returns the pass times.
  private func settlePasses(triggers: [Int], until end: Int) -> (passes: [Int], scheduled: Int) {
    var now = 0
    var pending: [(at: Int, cancelled: Bool, work: @MainActor () -> Void)] = []
    let settle = WindowBorderStackingSettle { delay, work in
      pending.append((now + delay, false, work))
      let index = pending.count - 1
      return { pending[index].cancelled = true }
    }
    var passes: [Int] = []
    settle.onPass = { passes.append(now) }
    for time in triggers + [end] {
      while let next = pending.indices
        .filter({ !pending[$0].cancelled && pending[$0].at <= time })
        .min(by: { pending[$0].at < pending[$1].at })
      {
        now = pending[next].at
        pending[next].cancelled = true
        pending[next].work()
      }
      now = time
      if time != end { settle.trigger() }
    }
    return (passes, pending.count)
  }

  @Test func reorderSettlesAt16_40_80AndCoalescesALaterTrigger() {
    #expect(settlePasses(triggers: [0], until: 200) == ([16, 40, 80], 3))
    #expect(settlePasses(triggers: [0, 20], until: 200) == ([16, 36, 60, 100], 6))
  }

  @Test func borderAuditComparesEdgesWithWindowServerBounds() {
    let expected: [WindowID: [UInt32: Rect]] = [
      id(1): [10: Rect(x: 0, y: 0, width: 800, height: 8), 11: Rect(x: 0, y: 592, width: 800, height: 8)],
      id(2): [20: Rect(x: 900, y: 0, width: 800, height: 8)],
      id(3): [30: Rect(x: 0, y: 0, width: 10, height: 10)],
    ]
    let actual: [UInt32: Rect] = [
      10: Rect(x: 1, y: 0, width: 800, height: 8),
      11: Rect(x: 0, y: 592, width: 800, height: 8),
      20: Rect(x: 1_299, y: 0, width: 800, height: 8),
    ]
    #expect(
      windowBorderAuditReport(expected: expected, actual: actual, backend: "windowserver")
        == "backend=windowserver compared=2 mismatches>2pt=1 worst=399.00pt wid=2")
    #expect(
      windowBorderAuditReport(expected: [:], actual: [:], backend: "fallback:move")
        == "backend=fallback:move no-comparable-borders")
  }
}
