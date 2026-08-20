import DefiModel

public func spatialMonitor(
  from sourceID: MonitorID,
  toward direction: Direction,
  frames: [MonitorID: Rect]
) -> MonitorID? {
  guard let source = frames[sourceID] else { return nil }
  let sourceCenter = (x: source.x + source.width / 2, y: source.y + source.height / 2)
  return frames.compactMap { monitorID, frame -> (MonitorID, Double)? in
    guard monitorID != sourceID else { return nil }
    let dx = frame.x + frame.width / 2 - sourceCenter.x
    let dy = frame.y + frame.height / 2 - sourceCenter.y
    let isCandidate: Bool
    switch direction {
    case .left: isCandidate = dx < 0 && abs(dx) >= abs(dy)
    case .right: isCandidate = dx > 0 && abs(dx) >= abs(dy)
    case .up: isCandidate = dy < 0 && abs(dy) >= abs(dx)
    case .down: isCandidate = dy > 0 && abs(dy) >= abs(dx)
    case .next, .previous, .first, .last: isCandidate = false
    }
    guard isCandidate else { return nil }
    return (monitorID, dx * dx + dy * dy)
  }.min {
    $0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 < $1.1
  }?.0
}

public func rebasedFloatingFrame(
  _ frame: Rect,
  from previousViewport: Rect,
  to nextViewport: Rect
) -> Rect {
  let previousHorizontalRange = max(previousViewport.width - frame.width, 1)
  let previousVerticalRange = max(previousViewport.height - frame.height, 1)
  let horizontalProgress = min(
    max((frame.x - previousViewport.x) / previousHorizontalRange, 0),
    1
  )
  let verticalProgress = min(
    max((frame.y - previousViewport.y) / previousVerticalRange, 0),
    1
  )
  return Rect(
    x: nextViewport.x + horizontalProgress * max(nextViewport.width - frame.width, 0),
    y: nextViewport.y + verticalProgress * max(nextViewport.height - frame.height, 0),
    width: frame.width,
    height: frame.height
  )
}
