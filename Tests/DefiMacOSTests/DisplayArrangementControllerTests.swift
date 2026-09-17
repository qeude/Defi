import CoreGraphics
import DefiCore
import DefiModel
import Testing
@testable import DefiMacOS

@MainActor
struct DisplayArrangementControllerTests {
  let first = MonitorID(rawValue: 1)
  let second = MonitorID(rawValue: 2)

  @Test
  func invalidationSuspendsRoutingUntilGeometryIsReconciled() throws {
    var current = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    let router = DisplayPointerRouter(warpPointer: { _ in .success })
    let controller = DisplayArrangementController(
      readFrames: { current }, applyFrames: { current = $0; return .success },
      primaryDisplay: { first }, pointerRouter: router
    )
    func crossing() throws -> CGEvent {
      let event = try #require(CGEvent(
        mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: CGPoint(x: 999, y: 350), mouseButton: .left
      ))
      event.setDoubleValueField(.mouseEventDeltaX, value: 5)
      return event
    }
    #expect(controller.reconcile())
    #expect(router.route(try crossing()))
    controller.invalidate()
    #expect(!router.route(try crossing()))
    #expect(!controller.reconcile()) // Unchanged geometry must republish the map.
    #expect(router.route(try crossing()))
    router.setActive(false)
    controller.invalidate()
    router.setActive(true)
    #expect(!router.route(try crossing()))
    let technical = current
    current = [:]
    #expect(!controller.reconcile())
    #expect(controller.needsReconciliation)
    #expect(!router.route(try crossing()))
    current = technical
    #expect(!controller.reconcile())
    #expect(router.route(try crossing()))
    router.setActive(false)
    controller.invalidate()
    _ = controller.reconcile()
    #expect(!router.route(try crossing()))
    current = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 0, y: -700, width: 1_000, height: 700),
    ]
    controller.invalidate()
    router.setActive(true)
    #expect(!router.route(try crossing()))
    #expect(!controller.reconcile())
    #expect(!router.route(try crossing())) // Vertical layout needs no warps.
  }

  @Test
  func successfulTransactionWithUnexpectedGeometryReportsMismatch() {
    let current = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    let controller = DisplayArrangementController(
      readFrames: { current }, applyFrames: { _ in .success },
      primaryDisplay: { first }
    )
    #expect(!controller.reconcile())
    #expect(controller.status == "observation-mismatch")
    #expect(controller.restore() == current)
  }

  @Test
  func `A live vertical rearrangement keeps native geometry and pointer routing`() {
    var current = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    var writes = 0
    let controller = DisplayArrangementController(
      readFrames: { current },
      applyFrames: { current = $0; writes += 1; return .success },
      primaryDisplay: { first }
    )
    #expect(controller.reconcile())
    let vertical = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 0, y: -700, width: 1_000, height: 700),
    ]
    current = vertical
    controller.invalidate()
    #expect(!controller.reconcile())
    #expect(current == vertical)
    #expect(controller.deskFrames == vertical)
    #expect(writes == 1)
    #expect(displayPointerDestination(
      x: 500, y: 0, deltaX: 0, deltaY: -10,
      technical: current, desk: controller.deskFrames
    ) == nil)
    controller.restore()
    #expect(current == vertical)
    #expect(writes == 1)
  }

  @Test
  func `Changing primary display and resolution preserves desk directions`() throws {
    var current = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    var primary = first
    let controller = DisplayArrangementController(
      readFrames: { current }, applyFrames: { current = $0; return .success },
      primaryDisplay: { primary }
    )
    _ = controller.reconcile()
    let newAnchor = try #require(current[second])
    current = current.mapValues {
      Rect(x: $0.x - newAnchor.x, y: $0.y - newAnchor.y, width: $0.width, height: $0.height)
    }
    primary = second
    controller.invalidate()
    _ = controller.reconcile()
    #expect(controller.deskFrames[first]?.x == -1_000)
    #expect(controller.deskFrames[second]?.x == 0)
    current[second]?.width = 1_600
    controller.invalidate()
    _ = controller.reconcile()
    #expect(spatialMonitor(from: first, toward: .right, frames: controller.deskFrames) == second)
    #expect(current[second]?.width == 1_600)
    #expect(current[second]?.x == 0)
    #expect(current[second]?.y == 0)
  }

  @Test
  func `Reconciliation is diffed and reconnect retains the desk map before restoration`() {
    let original = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    var current = original
    var writes = 0
    let controller = DisplayArrangementController(
      readFrames: { current },
      applyFrames: { current = $0; writes += 1; return .success },
      primaryDisplay: { first }
    )
    #expect(controller.reconcile())
    #expect(current != original)
    controller.invalidate()
    #expect(!controller.reconcile())
    #expect(writes == 1)
    current = [first: original[first]!]
    controller.invalidate()
    #expect(!controller.reconcile())
    current = isolatedDisplayArrangement(original, primary: first)
    controller.invalidate()
    _ = controller.reconcile()
    #expect(controller.deskFrames == original)
    controller.restore()
    #expect(current == original)
  }

  @Test
  func partialDisplayFailureDoesNotReapplyAfterInvalidation() {
    let original = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    var current = original
    var writes = 0
    let controller = DisplayArrangementController(
      readFrames: { current },
      applyFrames: { requested in
        writes += 1
        current = writes == 1
          ? [first: original[first]!, second: Rect(x: 900, y: 0, width: 1_000, height: 700)]
          : requested
        return .failure
      }, primaryDisplay: { first }
    )
    #expect(controller.reconcile())
    #expect(writes == 2)
    for _ in 0..<5 {
      controller.invalidate()
      #expect(!controller.reconcile())
    }
    #expect(writes == 2)
    #expect(current == original)
  }

  @Test
  func `Refused display transaction leaves native routing and does not retry every tick`() throws {
    let original = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    let router = DisplayPointerRouter(warpPointer: { _ in .success })
    router.update(technical: isolatedDisplayArrangement(original, primary: first), desk: original)
    let point = CGPoint(x: 999, y: 350)
    let crossing = try #require(CGEvent(
      mouseEventSource: nil, mouseType: .mouseMoved,
      mouseCursorPosition: point, mouseButton: .left
    ))
    crossing.setDoubleValueField(.mouseEventDeltaX, value: 5)
    #expect(router.route(crossing)) // Prove the old map would warp this crossing.
    crossing.location = point
    var writes = 0
    let controller = DisplayArrangementController(
      readFrames: { original }, applyFrames: { _ in writes += 1; return .failure },
      primaryDisplay: { first }, pointerRouter: router
    )
    #expect(!controller.reconcile())
    #expect(controller.deskFrames == original)
    #expect(controller.status.hasPrefix("failed:"))
    #expect(!router.route(crossing))
    #expect(crossing.location == point)
    #expect(router.warpCount == 1)
    #expect(!controller.reconcile())
    #expect(writes == 1)
  }
}
