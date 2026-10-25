import DefiModel

/// How much higher than predicted an app with a tall title bar may stop.
public let parkingVerticalSlack = 60.0

/// Where a hidden window waits: at its own size and height, one point inside
/// the side edge of its display nearest to it, so any uncovered motion is a
/// short horizontal slide. Corners, then the bottom edge, are the fallback when
/// both side edges touch another display; the first spot clear of every other
/// display wins.
///
/// macOS keeps a window's title bar between the menu bar and the visible bottom
/// of the display under most of its width, so a spot under another display would
/// be pulled onto it.
public func parkedFrame(
  _ frame: Rect, display: Rect, visibleFrame: Rect, otherDisplays: [Rect]
) -> Rect {
  let sliver = parkedSliverWidth
  let left = display.x, right = display.x + display.width
  let top = visibleFrame.y
  // The shortest title bar macOS keeps above the visible bottom.
  let bottom = visibleFrame.y + visibleFrame.height - 32
  let width = frame.width, height = frame.height
  let y = min(max(frame.y, top), bottom)
  let rightEdge = (right - sliver, y), leftEdge = (left - width + sliver, y)
  let sides = frame.x + width / 2 < left + display.width / 2
    ? [leftEdge, rightEdge] : [rightEdge, leftEdge]
  let candidates = (sides + [
    (right - sliver, bottom), (left - width + sliver, bottom),
    (right - sliver, top), (left - width + sliver, top), (left, bottom),
  ]).map { Rect(x: $0.0, y: $0.1, width: width, height: height) }
  func overlap(_ candidate: Rect) -> Double {
    let probe = Rect(
      x: candidate.x, y: candidate.y - parkingVerticalSlack,
      width: width, height: height + parkingVerticalSlack
    )
    let own = horizontalOverlap(candidate, display)
    return otherDisplays.reduce(0) { total, other in
      let shared = horizontalOverlap(candidate, other)
      return total + (shared > own ? shared * height : intersectionArea(probe, other))
    }
  }
  return candidates.min { overlap($0) < overlap($1) }!
}

private func horizontalOverlap(_ lhs: Rect, _ rhs: Rect) -> Double {
  max(min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x), 0)
}

private func intersectionArea(_ lhs: Rect, _ rhs: Rect) -> Double {
  let height = min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y)
  return horizontalOverlap(lhs, rhs) * max(height, 0)
}
