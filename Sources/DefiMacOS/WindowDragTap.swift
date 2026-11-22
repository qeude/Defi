import CoreGraphics
import DefiModel
import Foundation

public enum WindowDragButton: Equatable, Sendable {
  /// Moves the window.
  case left
  /// Resizes the window.
  case right
}

/// A window dragged anywhere with the drag modifier held, as Niri's Mod+drag.
public enum WindowDragAction: Equatable, Sendable {
  case began(WindowDragButton, windowID: WindowID, location: CGPoint, timestamp: TimeInterval)
  case moved(location: CGPoint)
  case ended(location: CGPoint, timestamp: TimeInterval)
  /// The tap lost track of the button: nothing commits.
  case cancelled
}

/// Takes a press with exactly the drag modifier on a managed window, and every drag and the
/// release of that button after it, so the app under the pointer never sees the gesture.
/// Runs on the tap thread.
struct WindowDragTap {
  let modifierBits: UInt64
  private(set) var held: WindowDragButton?

  init(modifierBits: UInt64) { self.modifierBits = modifierBits }

  static func button(_ type: CGEventType) -> WindowDragButton? {
    switch type {
    case .leftMouseDown, .leftMouseDragged, .leftMouseUp: .left
    case .rightMouseDown, .rightMouseDragged, .rightMouseUp: .right
    default: nil
    }
  }

  /// Returns whether the event is taken, and what it tells the daemon.
  mutating func handle(
    _ type: CGEventType, modifierBits: UInt64, windowID: WindowID?, location: CGPoint,
    timestamp: TimeInterval, accepts: (WindowID) -> Bool
  ) -> (consumed: Bool, action: WindowDragAction?) {
    guard let button = Self.button(type) else { return (false, nil) }
    switch type {
    case .leftMouseDown, .rightMouseDown:
      // Once taken, the release is taken too, even with the modifier let go meanwhile.
      guard held == nil, modifierBits == self.modifierBits, let windowID, accepts(windowID)
      else { return (false, nil) }
      held = button
      return (true, .began(button, windowID: windowID, location: location, timestamp: timestamp))
    case .leftMouseDragged, .rightMouseDragged:
      guard held == button else { return (false, nil) }
      return (true, .moved(location: location))
    default:
      guard held == button else { return (false, nil) }
      held = nil
      return (true, .ended(location: location, timestamp: timestamp))
    }
  }

  /// The tap was disabled: a release may have been missed.
  mutating func reset() -> WindowDragAction? {
    guard held != nil else { return nil }
    held = nil
    return .cancelled
  }
}

/// The front-most ordinary window under `point`, from the WindowServer list. A press posted by
/// software arrives without the window field macOS fills in for a hardware one.
func windowDragHitTest(at point: CGPoint) -> WindowID? {
  let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [NSDictionary] ?? []
  let own = getpid()
  for info in infos {
    guard (info[kCGWindowLayer as String] as? Int) == 0,
      (info[kCGWindowOwnerPID as String] as? pid_t) != own,
      let number = info[kCGWindowNumber as String] as? NSNumber,
      let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point)
    else { continue }
    return WindowID(rawValue: number.uint64Value)
  }
  return nil
}
