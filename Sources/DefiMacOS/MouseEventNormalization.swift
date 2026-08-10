import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel


func eventTracksPhysicalPointerMotion(_ type: CGEventType) -> Bool {
  switch type {
  case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
    true
  default:
    false
  }
}

func eventIsMouseButtonDown(_ type: CGEventType) -> Bool {
  switch type {
  case .leftMouseDown, .rightMouseDown, .otherMouseDown:
    true
  default:
    false
  }
}

func eventTracksGeneralUserInput(
  _ type: CGEventType,
  scrollMomentumPhase: Int64? = nil
) -> Bool {
  type == .keyDown || type == .flagsChanged
    || (type == .scrollWheel && (scrollMomentumPhase ?? 0) == 0)
    || eventIsMouseButtonDown(type)
}

func eventEndsMouseFocusInteraction(_ type: NSEvent.EventType) -> Bool {
  switch type {
  case .leftMouseUp, .rightMouseUp, .otherMouseUp:
    true
  default:
    false
  }
}

func eventStartsMouseFocusInteraction(_ type: NSEvent.EventType) -> Bool {
  switch type {
  case .leftMouseDown, .rightMouseDown, .otherMouseDown:
    true
  default:
    false
  }
}

func mouseFocusIntentWindowID(rawWindowID: Int64) -> WindowID? {
  guard rawWindowID > 0 else { return nil }
  return WindowID(rawValue: UInt64(rawWindowID))
}

struct MouseGestureEventNormalizer {
  private enum Button: Hashable {
    case left
    case right
    case other(Int)

    init(eventType: NSEvent.EventType, buttonNumber: Int) {
      switch eventType {
      case .leftMouseDown, .leftMouseUp:
        self = .left
      case .rightMouseDown, .rightMouseUp:
        self = .right
      default:
        self = .other(buttonNumber)
      }
    }
  }

  enum Synchronization: Equatable {
    case gesture
  }

  struct Actions: Equatable {
    var refreshBorderStacking = false
    var startsGesture = false
    var synchronization: Synchronization?
    var endsFocusInteraction = false
  }

  private var heldButtons = Set<Button>()
  private var dragged = false

  mutating func actions(
    for eventType: NSEvent.EventType,
    buttonNumber: Int = 0
  ) -> Actions {
    switch eventType {
    case .leftMouseDown:
      heldButtons.insert(.left)
      dragged = false
      return Actions(refreshBorderStacking: true, startsGesture: true)
    case .rightMouseDown, .otherMouseDown:
      heldButtons.insert(
        Button(eventType: eventType, buttonNumber: buttonNumber)
      )
      return Actions()
    case .leftMouseDragged:
      guard heldButtons.contains(.left) else { return Actions() }
      dragged = true
      // Platform sync demand is a Boolean, so repeated drag events coalesce
      // while still scheduling fresh snapshots after live reorder animations.
      return Actions(synchronization: .gesture)
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      let button = Button(eventType: eventType, buttonNumber: buttonNumber)
      guard heldButtons.remove(button) != nil else { return Actions() }
      let wasDragged = button == .left && dragged
      if button == .left {
        dragged = false
      }
      return Actions(
        synchronization: wasDragged ? .gesture : nil,
        endsFocusInteraction: heldButtons.isEmpty
      )
    default:
      return Actions()
    }
  }

  mutating func reset() -> Bool {
    let hadHeldButtons = !heldButtons.isEmpty
    heldButtons.removeAll(keepingCapacity: true)
    dragged = false
    return hadHeldButtons
  }
}
