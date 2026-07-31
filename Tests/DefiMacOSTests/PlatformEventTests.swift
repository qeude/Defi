import AppKit
import Testing

@testable import DefiMacOS

struct PlatformEventTests {
  @Test
  func simpleClickDoesNotSynchronizeDesktop() {
    var normalizer = MouseGestureEventNormalizer()
    let mouseDown = normalizer.shouldSynchronizeDesktop(
      for: .leftMouseDown
    )
    let mouseUp = normalizer.shouldSynchronizeDesktop(for: .leftMouseUp)

    #expect(mouseDown == false)
    #expect(mouseUp == false)
  }

  @Test
  func draggedGestureSynchronizesOnFirstMovementAndMouseUp() {
    var normalizer = MouseGestureEventNormalizer()
    let mouseDown = normalizer.shouldSynchronizeDesktop(
      for: .leftMouseDown
    )
    let firstMouseDragged = normalizer.shouldSynchronizeDesktop(
      for: .leftMouseDragged
    )
    let secondMouseDragged = normalizer.shouldSynchronizeDesktop(
      for: .leftMouseDragged
    )
    let firstMouseUp = normalizer.shouldSynchronizeDesktop(
      for: .leftMouseUp
    )
    let secondMouseUp = normalizer.shouldSynchronizeDesktop(
      for: .leftMouseUp
    )

    #expect(mouseDown == false)
    #expect(firstMouseDragged)
    #expect(secondMouseDragged == false)
    #expect(firstMouseUp)
    #expect(secondMouseUp == false)
  }
}
