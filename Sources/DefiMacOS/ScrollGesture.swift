import AppKit
import ApplicationServices
import DefiModel
import Foundation

/// What a scroll gesture asks of the daemon. Travel is in scroll points along the pan's
/// axis, signed like the event: negative reveals what lies right (or below).
public enum ScrollGestureAction: Equatable, Sendable {
  /// A pan started at `location` (global top-left coordinates): sideways along the
  /// strip, or vertical through the workspaces.
  case panBegan(id: UInt64, vertical: Bool, location: CGPoint, timestamp: TimeInterval)
  /// The fingers lifted; `velocity` is the travel per second just before, as Niri tracks it.
  case panEnded(id: UInt64, travel: Double, velocity: Double, timestamp: TimeInterval)
  case focusColumn(Direction, timestamp: TimeInterval)
  case focusWorkspace(Direction, timestamp: TimeInterval)
}

/// One scroll event, normalized from its CGEvent fields.
struct ScrollGestureInput: Equatable {
  var phase: Int64 = 0
  var momentumPhase: Int64 = 0
  var dx = 0.0
  var dy = 0.0
  var lineX: Int64 = 0
  var lineY: Int64 = 0
  var modifierHeld = false
  var shiftHeld = false
  var location = CGPoint.zero
  /// In the hotkeys' convention, for ordering against other input.
  var timestamp: TimeInterval = 0
  /// Real seconds, for speeds and cooldowns; nil when `timestamp` already is.
  var seconds: TimeInterval?
  var clock: TimeInterval { seconds ?? timestamp }
}

/// Owns every gesture that starts with the modifier held, from the first touch through
/// its momentum, so the app under the pointer never sees half of it. A gesture that
/// starts without the modifier is never taken, even if the modifier is pressed later.
/// Like Niri's three-finger swipe: once it has moved 16 points it picks an axis for good,
/// and only then does the content start following the fingers.
struct ScrollGestureRecognizer {
  private struct Gesture {
    let id: UInt64
    var x = 0.0
    var y = 0.0
    var vertical: Bool?
    var travel = 0.0
    var history: [(time: TimeInterval, delta: Double)] = []
  }

  private static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4, cancelled: Int64 = 8
  private static let mayBegin: Int64 = 128, momentumEnded: Int64 = 3
  /// GNOME Shell's and Niri's threshold before a swipe picks its axis.
  static let axisLock = 16.0
  /// Niri's swipe tracker keeps this much history for the release velocity.
  static let velocityHistory = 0.15
  static let wheelWorkspaceCooldown = 0.15

  private var gesture: Gesture?
  private var swallowsMomentum = false
  private var nextID: UInt64 = 0
  private var lastWheelWorkspaceStep = -Double.infinity
  /// Whether the shift key itself is the gesture modifier: shift then cannot turn a wheel sideways.
  let modifierIncludesShift: Bool
  /// The axes a swipe may pan; a swipe locking onto another axis is left alone.
  let horizontal: Bool, vertical: Bool

  init(modifierIncludesShift: Bool = false, horizontal: Bool = true, vertical: Bool = true) {
    self.modifierIncludesShift = modifierIncludesShift
    self.horizontal = horizontal
    self.vertical = vertical
  }

  /// The running pan and its travel so far.
  var pan: (id: UInt64, travel: Double)? {
    gesture.flatMap { $0.vertical == nil ? nil : ($0.id, $0.travel) }
  }

  /// Returns whether the event is consumed, and what it asks for.
  mutating func handle(_ input: ScrollGestureInput, enabled: Bool) -> (consumed: Bool, actions: [ScrollGestureAction]) {
    let phase = input.phase
    if phase == Self.mayBegin || phase == Self.began {
      swallowsMomentum = false
      // mayBegin then began: the same touch.
      if phase == Self.began, let current = gesture, current.vertical == nil { return (true, []) }
      // A gesture whose end was lost (the tap was disabled) ends here.
      let stale = gesture.flatMap { $0.vertical == nil ? nil : $0 }.map {
        ScrollGestureAction.panEnded(id: $0.id, travel: $0.travel, velocity: 0, timestamp: input.timestamp)
      }
      gesture = nil
      guard enabled, input.modifierHeld else { return (false, stale.map { [$0] } ?? []) }
      nextID &+= 1
      gesture = Gesture(id: nextID)
      return (true, stale.map { [$0] } ?? [])
    }
    if phase == Self.changed {
      guard var current = gesture else { return (false, []) }
      var actions: [ScrollGestureAction] = []
      if let vertical = current.vertical {
        let delta = vertical ? input.dy : input.dx
        current.travel += delta
        Self.push(delta, at: input.clock, to: &current.history)
      } else {
        current.x += input.dx
        current.y += input.dy
        // The decision distance is not applied: the content starts from rest, without a jump.
        if current.x * current.x + current.y * current.y >= Self.axisLock * Self.axisLock {
          let vertical = abs(current.y) > abs(current.x)
          // macOS owns that axis for this swipe.
          guard vertical ? self.vertical : horizontal else {
            gesture = nil
            return (true, [])
          }
          current.vertical = vertical
          Self.push(0, at: input.clock, to: &current.history)
          actions.append(.panBegan(id: current.id, vertical: vertical, location: input.location,
            timestamp: input.timestamp))
        }
      }
      gesture = current
      return (true, actions)
    }
    if phase == Self.ended || phase == Self.cancelled {
      guard var current = gesture else { return (false, []) }
      gesture = nil
      swallowsMomentum = true
      guard current.vertical != nil else { return (true, []) }
      // Idle time before the lift counts, as in Niri: a pause releases without momentum.
      Self.push(0, at: input.clock, to: &current.history)
      return (true, [.panEnded(id: current.id, travel: current.travel,
        velocity: phase == Self.ended ? Self.velocity(current.history) : 0, timestamp: input.timestamp)])
    }
    if input.momentumPhase != 0 {
      guard swallowsMomentum else { return (false, []) }
      if input.momentumPhase == Self.momentumEnded { swallowsMomentum = false }
      return (true, [])
    }
    // A wheel, or a smooth device without phases: one step per line, like Niri's
    // Mod+Wheel binds (workspaces rate-limited to one per 150 ms).
    guard enabled, input.modifierHeld, gesture == nil else { return (false, []) }
    let lineX = input.lineX != 0 || modifierIncludesShift || !input.shiftHeld ? input.lineX : input.lineY
    if lineX != 0 {
      return (true, [.focusColumn(lineX < 0 ? .right : .left, timestamp: input.timestamp)])
    }
    guard input.lineY != 0 else { return (true, []) }
    guard input.clock - lastWheelWorkspaceStep >= Self.wheelWorkspaceCooldown else { return (true, []) }
    lastWheelWorkspaceStep = input.clock
    return (true, [.focusWorkspace(input.lineY < 0 ? .down : .up, timestamp: input.timestamp)])
  }

  private static func push(_ delta: Double, at time: TimeInterval,
    to history: inout [(time: TimeInterval, delta: Double)]) {
    if let last = history.last, time < last.time { return }
    history.append((time, delta))
    history.removeAll { time > $0.time + velocityHistory }
  }

  /// Niri's swipe tracker: the travel over the kept history divided by its duration.
  private static func velocity(_ history: [(time: TimeInterval, delta: Double)]) -> Double {
    guard let first = history.first, let last = history.last, last.time > first.time else { return 0 }
    return history.reduce(0) { $0 + $1.delta } / (last.time - first.time)
  }
}

extension ScrollGestureInput {
  init(_ event: CGEvent, modifierBits: UInt64, announcedModifierBits: UInt64 = 0) {
    phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
    dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
    lineX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    lineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let held = hotKeyModifierBits(event.flags) | announcedModifierBits
    modifierHeld = held & modifierBits == modifierBits
    shiftHeld = event.flags.contains(.maskShift)
    location = event.location
    timestamp = Double(event.timestamp) / 1_000_000_000
    seconds = eventSeconds(event.timestamp)
  }
}

/// Turns the touches of trackpad gesture events into the phases of a scroll gesture,
/// for swipes with three or four fingers, which send no scroll events.
struct FingerSwipe {
  /// Scroll points per trackpad width: a swipe across the whole trackpad moves the
  /// strip two displays at the default speed, whatever the trackpad's size.
  static let travelPerWidth = 3000.0
  let fingers: Int
  private var touches: Set<Int>?
  private var last = CGPoint.zero

  init(fingers: Int) { self.fingers = fingers }

  /// The scroll phase and travel since the previous event, or nil when nothing changed.
  /// `touches` are the identities and normalized positions (origin bottom-left) of the
  /// fingers on the trackpad.
  mutating func update(_ current: [(id: Int, position: CGPoint)]) -> (phase: Int64, dx: Double, dy: Double)? {
    guard current.count == fingers else {
      guard touches != nil else { return nil }
      touches = nil
      return (4, 0, 0)
    }
    let ids = Set(current.map(\.id))
    let mean = CGPoint(
      x: current.reduce(0) { $0 + $1.position.x } / Double(fingers),
      y: current.reduce(0) { $0 + $1.position.y } / Double(fingers))
    defer { touches = ids; last = mean }
    guard let touches else { return (1, 0, 0) }
    // A finger swapped for another: take the new positions without a jump.
    guard touches == ids, mean != last else { return nil }
    return (2, (mean.x - last.x) * Self.travelPerWidth, (last.y - mean.y) * Self.travelPerWidth)
  }
}

extension ScrollGestureInput {
  /// A gesture event's touches as one step of a finger swipe, or nil when it is none.
  init?(gesture event: CGEvent, swipe: inout FingerSwipe, modifierBits: UInt64, announcedModifierBits: UInt64) {
    guard let touches = NSEvent(cgEvent: event)?.touches(matching: .touching, in: nil),
      let step = swipe.update(touches.map { ((($0.identity as AnyObject).hash), $0.normalizedPosition) })
    else { return nil }
    phase = step.phase
    dx = step.dx
    dy = step.dy
    let held = hotKeyModifierBits(event.flags) | announcedModifierBits
    modifierHeld = held & modifierBits == modifierBits
    location = event.location
    timestamp = Double(event.timestamp) / 1_000_000_000
    seconds = eventSeconds(event.timestamp)
  }
}

/// Which axes macOS already gives to a swipe with this many fingers, from the trackpad
/// settings, so that Defi leaves those swipes to it.
public func systemTrackpadSwipes(
  fingers: Int,
  read: (_ key: String, _ domain: String) -> Int? = {
    CFPreferencesCopyAppValue($0 as CFString, $1 as CFString) as? Int
  }
) -> (horizontal: Bool, vertical: Bool) {
  guard fingers >= 3 else { return (false, false) }
  // System Settings writes the same value for the built-in and the Bluetooth trackpad.
  // A key never written keeps macOS's default: swipes taken, three-finger drag off.
  func enabled(_ key: String) -> Bool {
    let value = read(key, "com.apple.AppleMultitouchTrackpad")
      ?? read(key, "com.apple.driver.AppleBluetoothMultitouch.trackpad")
    return (value ?? (key.hasSuffix("Drag") ? 0 : 2)) != 0
  }
  let name = fingers == 3 ? "Three" : "Four"
  let drag = fingers == 3 && enabled("TrackpadThreeFingerDrag")
  return (drag || enabled("Trackpad\(name)FingerHorizSwipeGesture"),
    drag || enabled("Trackpad\(name)FingerVertSwipeGesture"))
}

private let machNanoseconds: Double = {
  var info = mach_timebase_info_data_t()
  mach_timebase_info(&info)
  return Double(info.numer) / Double(info.denom)
}()

/// Hardware events carry mach ticks, events posted by software nanoseconds: whichever clock
/// reads nearer now is the event's.
func eventSeconds(_ stamp: UInt64, ticks: UInt64 = mach_absolute_time(),
  nanoseconds: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), scale: Double = machNanoseconds) -> TimeInterval {
  let fromTicks = abs(Double(stamp) - Double(ticks)), fromNanoseconds = abs(Double(stamp) - Double(nanoseconds))
  return Double(stamp) * (fromTicks < fromNanoseconds ? scale : 1) / 1_000_000_000
}
