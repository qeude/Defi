import CoreGraphics
import DefiModel
import Foundation
import Synchronization
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
  func `Three fingers swipe by how far they moved, through a finger slipping, until they lift`() {
    var swipe = FingerSwipe(fingers: 3)
    let at = { (x: Double, ids: [Int]) in ids.map { (id: $0, position: CGPoint(x: x, y: 0.5)) } }
    let tenth = { (step: (phase: Int64, dx: Double, dy: Double, time: TimeInterval)?) in
      step.map { $0.phase == 2 && abs($0.dx + FingerSwipe.travelPerWidth / 10) < 1e-6 && $0.dy == 0 } == true
    }
    #expect(swipe.update(at(0.5, [1, 2]), time: 0) == nil)
    #expect(swipe.update(at(0.5, [1, 2, 3]), time: 0)! == (1, 0, 0, 0))
    // Fingers moving left reveal what lies right: negative, a tenth of the trackpad.
    #expect(tenth(swipe.update(at(0.4, [1, 2, 3]), time: 0.01)))
    // A finger swapped for another: no jump.
    #expect(swipe.update(at(0.4, [1, 2]) + at(0.9, [4]), time: 0.02) == nil)
    // A finger slipping off for a moment keeps the swipe, which follows those that stayed.
    #expect(tenth(swipe.update(at(0.3, [1, 2]), time: 0.03)))
    #expect(swipe.update(at(0.3, [1, 2]) + at(0.7, [5]), time: 0.04) == nil)
    let joined = at(0.2, [1, 2]) + at(0.6, [5]) + at(0.9, [6])
    #expect(tenth(swipe.update(joined, time: 0.05)))
    // One gone for longer ends the swipe when it left: the wait takes nothing from the flick.
    #expect(swipe.update(joined, time: 0.06) == nil)
    #expect(swipe.update(joined, time: 0.06 + FingerSwipe.slip)! == (4, 0, 0, 0.05))
    #expect(swipe.update(at(0.2, [1]), time: 0.3) == nil)
    // Lifting them all ends it at once, even one after the other.
    _ = swipe.update(at(0.5, [1, 2, 3]), time: 0.4)
    #expect(swipe.update([], time: 0.41)! == (4, 0, 0, 0.41))
    _ = swipe.update(at(0.5, [1, 2, 3]), time: 0.5)
    #expect(swipe.update(at(0.5, [1]), time: 0.51) == nil)
    #expect(swipe.update([], time: 0.52)! == (4, 0, 0, 0.51))
  }

  @Test
  func `The Overview follows fingers up and down, and the release finishes their way`() {
    let at = { (y: Double, x: Double, count: Int) in
      (1...count).map { (id: $0, position: CGPoint(x: x, y: y)) } }
    var swipe = OverviewSwipe(fingers: 4)
    var time = 0.0
    func move(_ y: Double, _ x: Double = 0.5, count: Int = 4, open: Bool = false, after: Double = 0.01)
      -> OverviewSwipeEvent? {
      time += after
      return swipe.update(at(y, x, count), time: time, overviewOpen: open)
    }
    func progress(_ event: OverviewSwipeEvent?) -> Double? {
      if case .changed(let progress) = event { progress } else { nil }
    }
    func lift(open: Bool = false, after: Double = 0.01) -> OverviewSwipeEvent? {
      time += after
      return swipe.update([], time: time, overviewOpen: open)
    }
    let along = { (travel: Double) in (travel - OverviewSwipe.start) / OverviewSwipe.travel }
    // Up begins opening once the axis is picked, then follows the fingers.
    #expect(move(0.5) == nil)
    #expect(move(0.502) == nil)
    #expect(move(0.51) == nil)
    #expect(move(0.53) == .began(opening: true))
    #expect(progress(move(0.55)).map { abs($0 - along(150)) < 1e-9 } == true)
    #expect(move(0.9) == .changed(progress: 1))
    // Still moving up: a flick finishes it.
    #expect(lift() == .ended(commit: true))
    // A short swipe up that stops before halfway goes back.
    _ = move(0.5); _ = move(0.53); _ = move(0.55)
    #expect(lift(after: 0.2) == .ended(commit: false))
    // A twitch flicked up goes back too: too little of the swipe to finish.
    _ = move(0.5); _ = move(0.53); _ = move(0.535)
    #expect(lift() == .ended(commit: false))
    // Even past the end, fingers flicked back down go back.
    for y in [0.5, 0.53, 0.75, 0.73, 0.71, 0.69, 0.67] { _ = move(y) }
    #expect(lift() == .ended(commit: false))
    // A finger slipping off for a moment keeps the swipe following; one gone for longer ends it.
    _ = move(0.5); _ = move(0.53); _ = move(0.6)
    #expect(progress(move(0.62, count: 2)).map { abs($0 - along(360)) < 1e-9 } == true)
    #expect(progress(move(0.64)).map { abs($0 - along(420)) < 1e-9 } == true)
    #expect(progress(move(0.66)).map { abs($0 - along(480)) < 1e-9 } == true)
    #expect(progress(move(0.68, count: 2)).map { abs($0 - along(540)) < 1e-9 } == true)
    #expect(move(0.68, count: 2, after: FingerSwipe.slip + 0.01) == .ended(commit: true))
    _ = lift()
    // Down closes an open Overview; down while closed asks nothing.
    _ = move(0.5, open: true)
    #expect(move(0.47, open: true) == .began(opening: false))
    #expect(progress(move(0.4, open: true)).map { abs($0 - along(300)) < 1e-9 } == true)
    #expect(lift(open: true) == .ended(commit: true))
    _ = move(0.5)
    #expect(move(0.48) == nil)
    #expect(lift() == nil)
    // A sideways swipe asks nothing, even if it later turns vertical.
    _ = move(0.5)
    #expect(move(0.5, 0.53) == nil)
    #expect(move(0.7, 0.53) == nil)
    #expect(lift() == nil)
    // Three fingers are not the Overview's, unless it is set to three.
    #expect(move(0.5, count: 3) == nil)
    #expect(move(0.7, count: 3) == nil)
    var three = OverviewSwipe(fingers: 3)
    _ = three.update(at(0.5, 0.5, 3), time: 0, overviewOpen: false)
    #expect(three.update(at(0.6, 0.5, 3), time: 0.01, overviewOpen: false) == .began(opening: true))
  }

  @Test
  func `A three- or four-finger swipe keeps its scroll and momentum from what lies under the pointer`() {
    let at = { (count: Int) in (1...count).map { (id: $0, position: CGPoint(x: 0.5, y: 0.5)) } }
    var swipe = FingerSwipe(fingers: 3)
    func takes(_ momentumPhase: Int64, phase: Int64 = 0) -> Bool {
      swipe.takesScroll(scrollPhase: phase, momentumPhase: momentumPhase)
    }
    #expect(!takes(0))
    _ = swipe.update(at(2), time: 0)
    #expect(!takes(0))
    _ = swipe.update(at(3), time: 0)
    #expect(takes(0, phase: 2))
    _ = swipe.update([], time: 0)
    // The scroll's end can reach Defi after the lift; its momentum stays the swipe's.
    #expect(takes(0, phase: 4))
    #expect(takes(1))
    #expect(takes(3))
    #expect(!takes(2))
    // A new scroll, or a wheel step, after a swipe without momentum reaches the app again.
    _ = swipe.update(at(3), time: 0)
    _ = swipe.update([], time: 0)
    #expect(!takes(0, phase: 128))
    _ = swipe.update(at(3), time: 0)
    _ = swipe.update([], time: 0)
    #expect(!takes(0))
  }

  /// The input monitor's tap runs on its own thread; AppKit gives a gesture's touches only on the main one.
  @MainActor
  @Test(.enabled(if: TrackpadGesture.freeAxis != nil, "needs a trackpad with a three-finger axis left free"))
  func `Three fingers seen on the tap thread pan the strip`() throws {
    let trackpad = try #require(TrackpadGesture()), vertical = try #require(TrackpadGesture.freeAxis as Bool?)
    let actions = Mutex<[ScrollGestureAction]>([])
    let monitor = InputMonitor(
      bindings: [:], userInputTracker: UserInputTracker(), pointerMotionTracker: PointerMotionTracker(),
      tracksPointerWindowTransitions: false, scrollGestureModifierBits: 0, scrollGestureFingers: 3,
      deliverScrollGesture: { action in actions.withLock { $0.append(action) } },
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in }, tapReenabled: { _ in })
    let type = try #require(CGEventType(rawValue: gestureEventType))
    nonisolated(unsafe) let events = trackpad.swipe(vertical: vertical)
    let tap = Thread {
      for event in events { _ = monitor.handle(type: type, event: event) }
      let deadline = Date().addingTimeInterval(2)
      // A timer keeps the run loop alive for the touches handed back from the main thread.
      RunLoop.current.add(Timer(timeInterval: 2, repeats: false) { _ in }, forMode: .common)
      while actions.withLock({ $0.count }) < 2, Date() < deadline { RunLoop.current.run(until: Date() + 0.01) }
    }
    tap.start()
    let deadline = Date().addingTimeInterval(2)
    while actions.withLock({ $0.count }) < 2, Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
    let seen = actions.withLock { $0 }
    guard seen.count == 2, case .panBegan(_, vertical, _, _) = seen[0], case .panEnded(_, let travel, _, _) = seen[1]
    else {
      Issue.record("a three-finger swipe must begin and end one pan, got \(seen)")
      return
    }
    #expect(travel != 0)
  }

  /// The Overview hears of the swipe before the toggle that opens it, then follows it to the lift.
  @MainActor
  @Test(.enabled(if: TrackpadGesture() != nil && !systemTrackpadSwipes(fingers: 3).vertical,
    "needs a trackpad with the three-finger vertical swipe left free"))
  func `Three fingers swiped up open the Overview, follow it, and settle by the lift`() throws {
    let trackpad = try #require(TrackpadGesture())
    let seen = Mutex<[String]>([])
    let monitor = InputMonitor(
      bindings: [:], userInputTracker: UserInputTracker(), pointerMotionTracker: PointerMotionTracker(),
      tracksPointerWindowTransitions: false, overviewGestureFingers: 3,
      deliverOverviewSwipe: { swipe in
        let name = switch swipe {
        case .began(let opening): "began(\(opening))"
        case .changed: "changed"
        case .ended(let commit): "ended(\(commit))"
        }
        seen.withLock { $0.append(name) }
      },
      deliver: { invocation in seen.withLock { $0.append(invocation.command) } },
      deliverOverview: { _ in }, deliverPointerMotion: { _ in }, tapReenabled: { _ in })
    let type = try #require(CGEventType(rawValue: gestureEventType))
    // Fingers up a third of the way, 10 ms apart, then lifted after resting 200 ms. The digitizer's
    // origin is at the top, AppKit's at the bottom. Stamped in mach ticks, like the trackpad's events.
    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    let start = mach_absolute_time(), nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
    let ticks = { (seconds: Double) in start + UInt64(seconds * 1e9 / nanosecondsPerTick) }
    nonisolated(unsafe) let events = (0...10).compactMap { step -> CGEvent? in
      let event = trackpad.event(at: CGPoint(x: 0.3, y: 0.7 - Double(step) * 0.01), flags: [])
      event?.timestamp = ticks(Double(step) * 0.01)
      return event
    } + [trackpad.event(at: CGPoint(x: 0.3, y: 0.6), touching: false, flags: [])].compactMap { event -> CGEvent? in
      event?.timestamp = ticks(0.3)
      return event
    }
    let done: @Sendable () -> Bool = { seen.withLock { $0.last?.hasPrefix("ended") == true } }
    let tap = Thread {
      for event in events { _ = monitor.handle(type: type, event: event) }
      let deadline = Date().addingTimeInterval(2)
      RunLoop.current.add(Timer(timeInterval: 2, repeats: false) { _ in }, forMode: .common)
      while !done(), Date() < deadline { RunLoop.current.run(until: Date() + 0.01) }
    }
    tap.start()
    let deadline = Date().addingTimeInterval(2)
    while !done(), Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
    let names = seen.withLock { $0 }
    #expect(names.first == "began(true)")
    #expect(names.dropFirst().first == "toggle-overview")
    #expect(names.contains("changed"))
    // Stopped short of halfway: it goes back.
    #expect(names.last == "ended(false)")
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
