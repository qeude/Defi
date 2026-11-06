import CoreGraphics
import DefiModel
import Foundation
import Testing
@testable import DefiMacOS

struct ScrollGestureTests {
  private func touch(_ phase: Int64, dx: Double = 0, dy: Double = 0, held: Bool = true,
    at time: TimeInterval) -> ScrollGestureInput {
    ScrollGestureInput(phase: phase, dx: dx, dy: dy, modifierHeld: held, timestamp: time)
  }

  private func momentum(_ phase: Int64, at time: TimeInterval) -> ScrollGestureInput {
    ScrollGestureInput(momentumPhase: phase, dx: -30, modifierHeld: false, timestamp: time)
  }

  @Test
  func `A modified swipe is owned from touch to the end of its momentum`() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.handle(touch(128, at: 0), enabled: true) == (true, []))
    #expect(recognizer.handle(touch(1, at: 0.01), enabled: true).consumed)
    #expect(recognizer.handle(touch(2, dx: -10, at: 0.02), enabled: true) == (true, []))
    // 16 points decide the axis; the content then starts from rest.
    let lock = recognizer.handle(touch(2, dx: -10, held: false, at: 0.03), enabled: true)
    #expect(lock == (true, [.panBegan(id: 1, vertical: false, location: .zero, timestamp: 0.03)]))
    #expect(recognizer.pan?.travel == 0)
    _ = recognizer.handle(touch(2, dx: -20, at: 0.04), enabled: true)
    _ = recognizer.handle(touch(2, dx: -20, at: 0.05), enabled: true)
    #expect(recognizer.pan?.travel == -40)
    let end = recognizer.handle(touch(4, at: 0.05), enabled: true)
    #expect(end.consumed)
    // Niri's tracker: 40 points over the 20 ms of kept history.
    guard case .panEnded(1, -40, let velocity, 0.05)? = end.actions.first else {
      Issue.record("expected the pan to end, got \(end.actions)")
      return
    }
    #expect(abs(velocity + 2_000) < 0.01)
    #expect(recognizer.handle(momentum(1, at: 0.06), enabled: true).consumed)
    #expect(recognizer.handle(momentum(2, at: 0.07), enabled: true).consumed)
    #expect(recognizer.handle(momentum(3, at: 0.08), enabled: true).consumed)
    #expect(!recognizer.handle(momentum(2, at: 0.09), enabled: true).consumed)
  }

  @Test
  func `Three fingers swipe from their mean position, and end when the count changes`() {
    var swipe = FingerSwipe(fingers: 3)
    let at = { (x: Double, ids: [Int]) in ids.map { (id: $0, position: CGPoint(x: x, y: 0.5)) } }
    #expect(swipe.update(at(0.5, [1, 2])) == nil)
    #expect(swipe.update(at(0.5, [1, 2, 3]))! == (1, 0, 0))
    // Fingers moving left reveal what lies right: negative, a tenth of the trackpad.
    let step = swipe.update(at(0.4, [1, 2, 3]))!
    #expect(step.phase == 2 && abs(step.dx + FingerSwipe.travelPerWidth / 10) < 1e-6 && step.dy == 0)
    // A finger swapped for another: no jump.
    #expect(swipe.update(at(0.1, [1, 2, 4])) == nil)
    #expect(swipe.update(at(0.1, [1, 2, 3, 4]))! == (4, 0, 0))
    #expect(swipe.update(at(0.1, [1])) == nil)
  }

  @Test
  func `macOS keeps the swipe directions its trackpad settings give the chosen finger count`() {
    // The user's settings: three-finger Mission Control, four-finger Spaces and Mission Control.
    let settings = ["TrackpadThreeFingerVertSwipeGesture": 2, "TrackpadThreeFingerHorizSwipeGesture": 0,
      "TrackpadFourFingerHorizSwipeGesture": 2, "TrackpadFourFingerVertSwipeGesture": 2,
      "TrackpadThreeFingerDrag": 0]
    let read = { (key: String, domain: String) in
      domain == "com.apple.AppleMultitouchTrackpad" ? settings[key] : nil }
    #expect(systemTrackpadSwipes(fingers: 2, read: read) == (false, false))
    #expect(systemTrackpadSwipes(fingers: 3, read: read) == (false, true))
    #expect(systemTrackpadSwipes(fingers: 4, read: read) == (true, true))
    // Settings never written keep macOS's defaults, which take every swipe.
    #expect(systemTrackpadSwipes(fingers: 3, read: { _, _ in nil }) == (true, true))
    // The built-in trackpad's copy wins; the Bluetooth one stands in when it is missing.
    let bluetooth = { (key: String, domain: String) -> Int? in
      domain.contains("Bluetooth") ? (key == "TrackpadThreeFingerDrag" ? 1 : 0) : nil }
    #expect(systemTrackpadSwipes(fingers: 3, read: bluetooth) == (true, true))
    #expect(systemTrackpadSwipes(fingers: 4, read: bluetooth) == (false, false))
  }

  @Test
  func `A swipe on an axis macOS owns is left alone`() {
    var recognizer = ScrollGestureRecognizer(vertical: false)
    #expect(recognizer.handle(touch(1, at: 0), enabled: true).consumed)
    #expect(recognizer.handle(touch(2, dy: -20, at: 0.01), enabled: true) == (true, []))
    #expect(recognizer.pan == nil)
    #expect(recognizer.handle(touch(4, at: 0.02), enabled: true).actions.isEmpty)
  }

  @Test
  func `Event times are read in whichever clock the event used`() {
    // Hardware stamps mach ticks (24 MHz), software nanoseconds; both read 10 s here.
    let ticks: UInt64 = 240_000_000, nanoseconds: UInt64 = 10_000_000_000
    #expect(abs(eventSeconds(ticks, ticks: ticks, nanoseconds: nanoseconds, scale: 125.0 / 3) - 10) < 1e-9)
    #expect(abs(eventSeconds(nanoseconds, ticks: ticks, nanoseconds: nanoseconds, scale: 125.0 / 3) - 10) < 1e-9)
  }

  @Test
  func `A swipe started without the modifier stays the app's`() {
    var recognizer = ScrollGestureRecognizer()
    #expect(!recognizer.handle(touch(1, held: false, at: 0), enabled: true).consumed)
    #expect(!recognizer.handle(touch(2, dx: -40, at: 0.01), enabled: true).consumed)
    #expect(!recognizer.handle(touch(4, at: 0.02), enabled: true).consumed)
    #expect(!recognizer.handle(momentum(1, at: 0.03), enabled: true).consumed)
    #expect(recognizer.pan == nil)
  }

  @Test
  func `Nothing is taken while gestures are disabled, as in the overview`() {
    var recognizer = ScrollGestureRecognizer()
    #expect(!recognizer.handle(touch(1, at: 0), enabled: false).consumed)
    #expect(!recognizer.handle(ScrollGestureInput(lineY: -1, modifierHeld: true), enabled: false).consumed)
  }

  @Test
  func `A vertical swipe pans the workspaces, a lift without travel nothing`() {
    var recognizer = ScrollGestureRecognizer()
    _ = recognizer.handle(touch(1, at: 0), enabled: true)
    #expect(recognizer.handle(touch(2, dx: 3, dy: -20, at: 0.01), enabled: true).actions
      == [.panBegan(id: 1, vertical: true, location: .zero, timestamp: 0.01)])
    _ = recognizer.handle(touch(2, dx: 50, dy: -30, at: 0.02), enabled: true)
    #expect(recognizer.pan?.travel == -30)
    #expect(recognizer.handle(touch(4, at: 0.3), enabled: true).actions
      == [.panEnded(id: 1, travel: -30, velocity: 0, timestamp: 0.3)])
    _ = recognizer.handle(touch(128, at: 1), enabled: true)
    #expect(recognizer.handle(touch(8, at: 1.1), enabled: true) == (true, []))
  }

  @Test
  func `A lift after a pause carries no momentum`() {
    var recognizer = ScrollGestureRecognizer()
    _ = recognizer.handle(touch(1, at: 0), enabled: true)
    _ = recognizer.handle(touch(2, dx: 20, at: 0.01), enabled: true)
    _ = recognizer.handle(touch(2, dx: 40, at: 0.02), enabled: true)
    let end = recognizer.handle(touch(4, at: 0.3), enabled: true)
    #expect(end.actions == [.panEnded(id: 1, travel: 40, velocity: 0, timestamp: 0.3)])
  }

  @Test
  func `A new touch ends a pan whose lift was lost`() {
    var recognizer = ScrollGestureRecognizer()
    _ = recognizer.handle(touch(1, at: 0), enabled: true)
    _ = recognizer.handle(touch(2, dx: 20, at: 0.01), enabled: true)
    _ = recognizer.handle(touch(2, dx: 20, at: 0.02), enabled: true)
    let next = recognizer.handle(touch(1, held: false, at: 1), enabled: true)
    #expect(next == (false, [.panEnded(id: 1, travel: 20, velocity: 0, timestamp: 1)]))
    #expect(recognizer.pan == nil)
  }

  @Test
  func `A modified wheel steps columns sideways and workspaces vertically`() {
    var recognizer = ScrollGestureRecognizer()
    #expect(recognizer.handle(ScrollGestureInput(lineX: -1, modifierHeld: true, timestamp: 0), enabled: true)
      == (true, [.focusColumn(.right, timestamp: 0)]))
    #expect(recognizer.handle(
      ScrollGestureInput(lineY: 1, modifierHeld: true, shiftHeld: true, timestamp: 0.01), enabled: true)
      == (true, [.focusColumn(.left, timestamp: 0.01)]))
    #expect(recognizer.handle(ScrollGestureInput(lineY: -1, modifierHeld: true, timestamp: 0.02), enabled: true)
      == (true, [.focusWorkspace(.down, timestamp: 0.02)]))
    // A spinning wheel switches at most one workspace per cooldown, as Niri's cooldown-ms=150.
    #expect(recognizer.handle(ScrollGestureInput(lineY: -1, modifierHeld: true, timestamp: 0.05), enabled: true)
      == (true, []))
    #expect(!recognizer.handle(ScrollGestureInput(lineY: -1, timestamp: 0.3), enabled: true).consumed)
  }

  @Test
  func `A software Hyper announced by key events arms a trackpad swipe without flags`() throws {
    let hyper = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
    let event = try #require(CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -4, wheel3: 0))
    #expect(!ScrollGestureInput(event, modifierBits: hyper).modifierHeld)
    #expect(ScrollGestureInput(event, modifierBits: hyper, announcedModifierBits: hyper).modifierHeld)
  }

  @Test
  func `Shift in the modifier keeps the wheel vertical`() {
    var recognizer = ScrollGestureRecognizer(modifierIncludesShift: true)
    #expect(recognizer.handle(
      ScrollGestureInput(lineY: 1, modifierHeld: true, shiftHeld: true, timestamp: 0), enabled: true)
      == (true, [.focusWorkspace(.up, timestamp: 0)]))
  }
}
