import CoreGraphics
import DefiModel
import Testing

@testable import DefiMacOS

struct WindowDragTapTests {
  private let bits = CGEventFlags([.maskControl, .maskAlternate]).rawValue
  private let window = WindowID(rawValue: 7)

  private func send(_ tap: inout WindowDragTap, _ type: CGEventType, bits: UInt64? = nil, window: WindowID? = nil,
    accepts: Bool = true) -> (Bool, WindowDragAction?) {
    tap.handle(type, modifierBits: bits ?? self.bits, windowID: window ?? self.window, location: CGPoint(x: 1, y: 2),
      timestamp: 3, accepts: { _ in accepts })
  }

  @Test
  func takesTheWholeGestureOnceThePressMatches() {
    var tap = WindowDragTap(modifierBits: bits)
    #expect(send(&tap, .rightMouseDown) == (true, .began(.right, windowID: window, location: CGPoint(x: 1, y: 2), timestamp: 3)))
    // The other button stays the app's.
    #expect(send(&tap, .leftMouseDown) == (false, nil))
    #expect(send(&tap, .rightMouseDragged, bits: 0) == (true, .moved(location: CGPoint(x: 1, y: 2))))
    // Releasing the modifier first still ends the drag.
    #expect(send(&tap, .rightMouseUp, bits: 0) == (true, .ended(location: CGPoint(x: 1, y: 2), timestamp: 3)))
    #expect(send(&tap, .rightMouseDragged) == (false, nil))
  }

  @Test
  func leavesOtherPressesToApps() {
    var tap = WindowDragTap(modifierBits: bits)
    let shift = bits | CGEventFlags.maskShift.rawValue
    #expect(send(&tap, .leftMouseDown, bits: shift) == (false, nil))
    #expect(send(&tap, .leftMouseDown, bits: 0) == (false, nil))
    #expect(send(&tap, .leftMouseDown, accepts: false) == (false, nil))
    #expect(send(&tap, .leftMouseUp) == (false, nil))
    #expect(tap.held == nil)
  }

  @Test
  func aLostReleaseCancelsOnce() {
    var tap = WindowDragTap(modifierBits: bits)
    _ = send(&tap, .leftMouseDown)
    #expect(tap.reset() == .cancelled)
    #expect(tap.reset() == nil)
  }
}
