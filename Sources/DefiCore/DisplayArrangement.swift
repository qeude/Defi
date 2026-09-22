import DefiModel

/// Technical coordinates only. Commands and pointer navigation keep the desk map.
public func isolatedDisplayArrangement(
  _ frames: [MonitorID: Rect], primary: MonitorID
) -> [MonitorID: Rect] {
  guard let primaryFrame = frames[primary], frames.count > 1 else { return frames }
  let verticalOrder = frames.values.sorted { $0.y < $1.y }
  guard zip(verticalOrder, verticalOrder.dropFirst()).contains(where: {
    $0.y + $0.height > $1.y
  }) else { return frames }
  let ordered = frames.keys.sorted {
    let left = frames[$0]!, right = frames[$1]!
    return left.width == right.width ? $0.rawValue < $1.rawValue : left.width > right.width
  }
  var result: [MonitorID: Rect] = [:]
  var x = 0.0, y = 0.0
  for (index, id) in ordered.enumerated() {
    var frame = frames[id]!
    if index > 0 { y -= frame.height }
    frame.x = x
    frame.y = y
    result[id] = frame
    x += frame.width
  }
  let anchor = result[primary]!
  for id in ordered {
    result[id]!.x += primaryFrame.x - anchor.x
    result[id]!.y += primaryFrame.y - anchor.y
  }
  return result
}

public struct DisplayPointerDestination: Equatable, Sendable {
  public let monitorID: MonitorID
  public let x: Double
  public let y: Double
}

/// Cross a desk edge at the same vertical/horizontal desk coordinate. Do not
/// warp through portions of an edge with no neighboring display.
public func displayPointerDestination(
  x: Double, y: Double, deltaX: Double, deltaY: Double,
  technical: [MonitorID: Rect], desk: [MonitorID: Rect]
) -> DisplayPointerDestination? {
  guard technical != desk else { return nil }
  let orderedIDs = technical.keys.sorted(by: { $0.rawValue < $1.rawValue })
  func containing(_ x: Double, _ y: Double) -> MonitorID? {
    orderedIDs.first {
      let frame = technical[$0]!
      return x >= frame.x && x < frame.x + frame.width
        && y >= frame.y && y < frame.y + frame.height
    }
  }
  // A single event can overshoot into the technical gap before macOS clamps it.
  guard let sourceID = containing(x, y) ?? containing(x - deltaX, y - deltaY),
    let source = technical[sourceID], let logical = desk[sourceID]
  else { return nil }
  let localX = x - source.x, localY = y - source.y
  let edges: [(Direction, Bool)] = [
    (.left, localX <= 1 && deltaX < 0),
    (.right, localX >= source.width - 2 && deltaX > 0),
    (.up, localY <= 1 && deltaY < 0),
    (.down, localY >= source.height - 2 && deltaY > 0),
  ]
  for (direction, crossing) in edges where crossing {
    for id in orderedIDs where id != sourceID {
      guard let target = desk[id], let native = technical[id] else { continue }
      let deskX = logical.x + localX / source.width * logical.width
      let deskY = logical.y + localY / source.height * logical.height
      switch direction {
      case .left where abs(target.x + target.width - logical.x) <= 1
        && deskY >= target.y && deskY < target.y + target.height:
        return DisplayPointerDestination(monitorID: id, x: max(native.x, native.x + native.width + min(localX, -3)),
                                         y: native.y + (deskY - target.y) / target.height * native.height)
      case .right where abs(target.x - logical.x - logical.width) <= 1
        && deskY >= target.y && deskY < target.y + target.height:
        return DisplayPointerDestination(monitorID: id, x: min(native.x + native.width - 1, native.x + max(localX - source.width, 2)),
                                         y: native.y + (deskY - target.y) / target.height * native.height)
      case .up where abs(target.y + target.height - logical.y) <= 1
        && deskX >= target.x && deskX < target.x + target.width:
        return DisplayPointerDestination(monitorID: id, x: native.x + (deskX - target.x) / target.width * native.width,
                                         y: max(native.y, native.y + native.height + min(localY, -3)))
      case .down where abs(target.y - logical.y - logical.height) <= 1
        && deskX >= target.x && deskX < target.x + target.width:
        return DisplayPointerDestination(monitorID: id, x: native.x + (deskX - target.x) / target.width * native.width,
                                         y: min(native.y + native.height - 1, native.y + max(localY - source.height, 2)))
      default: continue
      }
    }
  }
  return nil
}
