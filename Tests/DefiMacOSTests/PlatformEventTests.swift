import AppKit
import DefiModel
import Testing

@testable import DefiMacOS

struct PlatformEventTests {
  @Test
  func simpleClickDoesNotSynchronizeDesktop() {
    var normalizer = MouseGestureEventNormalizer()
    let mouseDown = normalizer.actions(
      for: .leftMouseDown
    )
    let mouseUp = normalizer.actions(for: .leftMouseUp)

    #expect(
      mouseDown
        == MouseGestureEventNormalizer.Actions(
          refreshBorderStacking: true
        )
    )
    #expect(mouseUp == MouseGestureEventNormalizer.Actions())
  }

  @Test
  func draggedGestureSynchronizesOnFirstMovementAndMouseUp() {
    var normalizer = MouseGestureEventNormalizer()
    let mouseDown = normalizer.actions(
      for: .leftMouseDown
    )
    let firstMouseDragged = normalizer.actions(
      for: .leftMouseDragged
    )
    let secondMouseDragged = normalizer.actions(
      for: .leftMouseDragged
    )
    let firstMouseUp = normalizer.actions(
      for: .leftMouseUp
    )
    let secondMouseUp = normalizer.actions(
      for: .leftMouseUp
    )

    #expect(mouseDown.refreshBorderStacking)
    #expect(mouseDown.synchronizeDesktop == false)
    #expect(firstMouseDragged.synchronizeDesktop)
    #expect(secondMouseDragged == MouseGestureEventNormalizer.Actions())
    #expect(firstMouseUp.synchronizeDesktop)
    #expect(secondMouseUp == MouseGestureEventNormalizer.Actions())
  }

  @Test
  func borderStackingRefreshIsLatestSelectionWins() throws {
    var state = WindowBorderStackingRefreshState()
    let firstWindow = WindowID(rawValue: 1)
    let secondWindow = WindowID(rawValue: 2)
    let firstRequest = state.request(for: firstWindow)
    let first = try #require(firstRequest)
    let secondRequest = state.request(for: secondWindow)
    let second = try #require(secondRequest)

    #expect(state.shouldApply(first, activeWindowID: firstWindow) == false)
    #expect(state.shouldApply(second, activeWindowID: firstWindow) == false)
    #expect(state.shouldApply(second, activeWindowID: secondWindow))
  }

  @Test
  func frontmostBorderOccluderIgnoresTinyAuxiliaryWindows() {
    let auxiliaryWindow = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)

    let result = frontmostBorderOccludingWindowID(
      in: [
        NormalWindowStackEntry(
          windowID: auxiliaryWindow,
          frame: Rect(x: 8, y: 40, width: 66, height: 20)
        ),
        NormalWindowStackEntry(
          windowID: focusedWindow,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result == focusedWindow)
  }

  @Test
  func frontmostBorderOccluderKeepsDialogsAheadOfFocusedWindow() {
    let dialog = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)

    let result = frontmostBorderOccludingWindowID(
      in: [
        NormalWindowStackEntry(
          windowID: dialog,
          frame: Rect(x: 400, y: 300, width: 640, height: 480)
        ),
        NormalWindowStackEntry(
          windowID: focusedWindow,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result == dialog)
  }
}
